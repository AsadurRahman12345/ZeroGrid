import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart'; // provides defaultTargetPlatform
import 'package:nearby_connections/nearby_connections.dart';
import 'package:permission_handler/permission_handler.dart';

import 'message_model.dart';
import 'mesh_packet.dart';
import 'crypto_service.dart';
import 'storage_service.dart';

// ──────────────────────────────────────────────────────────────────────────────
// DiscoveredPeer
// ──────────────────────────────────────────────────────────────────────────────
enum PeerState { found, connecting, connected, disconnected }

class DiscoveredPeer {
  final String endpointId;
  String endpointName;       // mutable: user may rename their device between sessions
  final double signalStrength;
  PeerState state;

  /// X25519 public key received via KEY_ANNOUNCEMENT.
  /// Null until the announcement arrives after connection.
  String? publicKey;

  DiscoveredPeer({
    required this.endpointId,
    required this.endpointName,
    this.signalStrength = 0.5,
    this.state = PeerState.found,
    this.publicKey,
  });

  String get statusLabel {
    switch (state) {
      case PeerState.found:        return 'Tap to Connect';
      case PeerState.connecting:   return 'Connecting...';
      case PeerState.connected:    return 'Connected';
      case PeerState.disconnected: return 'Disconnected';
    }
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// P2PService  (Mesh-enabled, E2EE)
//
// This is the nerve centre of ZeroGrid. It handles:
//
//   LAYER 1 – Transport     : Google Nearby Connections (BLE + Wi-Fi Direct)
//   LAYER 2 – Framing       : MeshPacket JSON serialisation / deserialisation
//   LAYER 3 – Routing       : Multi-hop relay with hop-count TTL
//   LAYER 4 – Security      : X25519 ECDH key exchange + AES-256-GCM E2EE
//   LAYER 5 – State / UI    : ChangeNotifier + Stream<MessageModel>
//
// ROUTING DECISION (runs on EVERY received packet):
//
//    ┌─ Is packet type KEY_ANNOUNCEMENT? ──→ store public key, stop.
//    │
//    ├─ Is destinationPublicKey == MY public key?
//    │      YES → Decrypt encryptedPayload → push to messageStream → show UI
//    │
//    └─ Is destinationPublicKey != MY public key?
//           Is packet expired (hopCount >= maxHops)?  YES → drop silently
//           Find a connected peer that is NOT the packet's senderEndpointId
//           Increment hopCount → retransmit → silent relay (no UI change)
// ──────────────────────────────────────────────────────────────────────────────
class P2PService extends ChangeNotifier {
  // ── Singleton ────────────────────────────────────────────────────────────────
  static final P2PService _instance = P2PService._internal();
  factory P2PService() => _instance;
  P2PService._internal();

  // ── Service handles ──────────────────────────────────────────────────────────
  final Nearby _nearby = Nearby();
  final CryptoService _crypto = CryptoService();

  // ── Constants ─────────────────────────────────────────────────────────────────
  static const String _serviceId = 'com.zerogrid.app';
  static const Strategy _strategy = Strategy.P2P_CLUSTER;

  // ── Identity ──────────────────────────────────────────────────────────────────
  String localEndpointName = 'Agent_${_randomSuffix()}';

  /// Our X25519 public key — set after [init()] resolves.
  String get localPublicKey => _crypto.publicKeyBase64;

  // ── Public reactive state ─────────────────────────────────────────────────────
  final Map<String, DiscoveredPeer> peers = {};
  final Map<String, List<MessageModel>> messageHistory = {};

  /// Typed stream of decrypted, verified inbound messages.
  /// ChatScreen subscribes and filters by endpointId.
  final StreamController<MessageModel> _messageController =
      StreamController.broadcast();
  Stream<MessageModel> get messageStream => _messageController.stream;

  // ── Deduplication table ───────────────────────────────────────────────────────
  /// Stores packetIds of recently seen packets to prevent relay loops.
  /// In production: cap at ~1000 entries and rotate by timestamp.
  final Set<String> _seenPacketIds = {};

  bool _isAdvertising = false;
  bool _isDiscovering = false;
  bool _disposed = false; // Guard: prevents notifyListeners() after dispose()
  bool get isAdvertising => _isAdvertising;
  bool get isDiscovering => _isDiscovering;

  // ────────────────────────────────────────────────────────────────────────────
  // INIT
  // Must be called at app start (before any P2P operations).
  // Loads X25519 key pair AND restores known peer keys from Hive so
  // conversations can be encrypted immediately without a re-connect.
  // ────────────────────────────────────────────────────────────────────────────
  Future<void> init() async {
    await _crypto.init();
    debugPrint('[P2PService] 🔐 Local public key: ${localPublicKey.substring(0, 16)}…');

    // ── Restore agent name from storage (if user has set one before) ───────────
    final stored = StorageService().agentName;
    if (stored != null) localEndpointName = stored;

    // ── Pre-populate in-memory peer key cache from Hive ───────────────────────
    // This means previously seen peers can have messages encrypted for them
    // immediately on next launch, without waiting for a KEY_ANNOUNCEMENT.
    final storedKeys = StorageService().getAllPeerKeys();
    for (final entry in storedKeys.entries) {
      peers.putIfAbsent(
        entry.key,
        () => DiscoveredPeer(
          endpointId: entry.key,
          endpointName: StorageService().getPeerName(entry.key) ?? entry.key,
          publicKey: entry.value,
        ),
      );
    }
    debugPrint('[P2PService] 📦 Pre-loaded ${storedKeys.length} peer keys from storage');

    // ── Restore message history from Hive into the in-memory cache ─────────────
    for (final id in StorageService().getAllConversationIds()) {
      messageHistory.putIfAbsent(id, () => StorageService().getMessages(id));
    }
    debugPrint('[P2PService] 💬 Restored ${messageHistory.length} conversations from storage');
  }

  // ────────────────────────────────────────────────────────────────────────────
  // PERMISSIONS
  // ────────────────────────────────────────────────────────────────────────────
  Future<bool> requestPermissions() async {
    final statuses = await [
      Permission.bluetooth,
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
      Permission.bluetoothScan,
      Permission.location,
      // nearbyWifi (formerly nearbyWifiDevices) — Android 13+ only.
      // permission_handler 12.x uses nearbyWifiDevices spelling.
      if (defaultTargetPlatform == TargetPlatform.android)
        Permission.nearbyWifiDevices,
    ].request();

    // BUG FIX: On iOS, location can return PermissionStatus.limited
    // (user chose "Allow Once" or "Approximate"). This is still usable
    // for BLE scanning — treating it as denied blocks the app needlessly.
    // We accept granted OR limited; everything else is a hard block.
    bool allGranted = true;
    final acceptable = {PermissionStatus.granted, PermissionStatus.limited};
    for (final entry in statuses.entries) {
      if (!acceptable.contains(entry.value)) {
        debugPrint('[P2PService] ⚠️  Permission denied: ${entry.key} = ${entry.value}');
        allGranted = false;
      }
    }
    return allGranted;
  }

  // ────────────────────────────────────────────────────────────────────────────
  // ADVERTISING
  // ────────────────────────────────────────────────────────────────────────────
  Future<void> startAdvertising() async {
    if (_isAdvertising) return;
    try {
      await _nearby.startAdvertising(
        localEndpointName,
        _strategy,
        serviceId: _serviceId,
        onConnectionInitiated: _onConnectionInitiated,
        onConnectionResult: _onConnectionResult,
        onDisconnected: _onDisconnected,
      );
      _isAdvertising = true;
      debugPrint('[P2PService] ✅ Advertising as "$localEndpointName"');
      notifyListeners();
    } catch (e) {
      debugPrint('[P2PService] ❌ startAdvertising: $e');
    }
  }

  // ────────────────────────────────────────────────────────────────────────────
  // DISCOVERY
  // ────────────────────────────────────────────────────────────────────────────
  Future<void> startDiscovery() async {
    if (_isDiscovering) return;
    try {
      await _nearby.startDiscovery(
        localEndpointName,
        _strategy,
        serviceId: _serviceId,
        onEndpointFound:
            (String endpointId, String endpointName, String serviceId) {
          debugPrint('[P2PService] 👁  Found: $endpointName ($endpointId)');

          // BUG FIX: use putIfAbsent so that if a peer was restored from
          // Hive storage (with its public key already set), we do NOT
          // overwrite it with a fresh DiscoveredPeer(publicKey: null).
          // Only add a new entry if this endpointId is genuinely unknown.
          peers.putIfAbsent(
            endpointId,
            () => DiscoveredPeer(
              endpointId: endpointId,
              endpointName: endpointName,
            ),
          );
          // Refresh display name in case it changed between sessions.
          peers[endpointId]!.endpointName = endpointName;
          messageHistory.putIfAbsent(endpointId, () => []);
          if (!_disposed) notifyListeners();
        },
        onEndpointLost: (String? endpointId) {
          if (endpointId == null) return;
          debugPrint('[P2PService] 📡 Lost: $endpointId');
          peers.remove(endpointId);
          if (!_disposed) notifyListeners();
        },
      );
      _isDiscovering = true;
      debugPrint('[P2PService] 🔍 Discovery started');
      notifyListeners();
    } catch (e) {
      debugPrint('[P2PService] ❌ startDiscovery: $e');
    }
  }

  // ────────────────────────────────────────────────────────────────────────────
  // CONNECT TO PEER
  // ────────────────────────────────────────────────────────────────────────────
  Future<void> connectToPeer(String endpointId) async {
    final peer = peers[endpointId];
    if (peer == null) return;
    peer.state = PeerState.connecting;
    notifyListeners();
    try {
      await _nearby.requestConnection(
        localEndpointName,
        endpointId,
        onConnectionInitiated: _onConnectionInitiated,
        onConnectionResult: _onConnectionResult,
        onDisconnected: _onDisconnected,
      );
    } catch (e) {
      peer.state = PeerState.found;
      notifyListeners();
      debugPrint('[P2PService] ❌ connectToPeer: $e');
    }
  }

  // ────────────────────────────────────────────────────────────────────────────
  // SEND ENCRYPTED MESSAGE  ← Main API called by ChatScreen
  //
  // Encryption pipeline:
  //   plaintext
  //   → CryptoService.encrypt(plaintext, destinationPublicKey)
  //   → Base64(nonce || AES-GCM ciphertext || MAC)
  //   → MeshPacket.message(encryptedPayload: …)
  //   → MeshPacket.toBytes()
  //   → Nearby.sendBytesPayload(nextHopEndpointId, bytes)
  //
  // If the target is directly connected (1-hop), the message goes straight.
  // If not, the nearest connected peer receives it and the relay logic fires.
  // ────────────────────────────────────────────────────────────────────────────
  Future<void> sendMessage(
      String targetEndpointId, MessageModel message) async {
    final targetPeer = peers[targetEndpointId];
    if (targetPeer == null) {
      throw StateError('Peer $targetEndpointId not in known peers map');
    }
    if (targetPeer.publicKey == null) {
      throw StateError(
          'No public key for ${targetPeer.endpointName}. '
          'KEY_ANNOUNCEMENT not yet received.');
    }

    try {
      // 1. Encrypt the plaintext using the target's X25519 public key
      final encryptedPayload = await _crypto.encrypt(
        message.textMessage,
        targetPeer.publicKey!,
      );

      // 2. Wrap in a MeshPacket with routing headers
      final packet = MeshPacket.message(
        senderPublicKey: localPublicKey,
        senderEndpointId: _nearbyLocalEndpointId,
        destinationPublicKey: targetPeer.publicKey!,
        finalDestinationName: targetPeer.endpointName,
        encryptedPayload: encryptedPayload,
      );

      // 3. Transmit to the target (direct) or nearest relay (multi-hop)
      final nextHop = _findNextHop(targetEndpointId);
      await _transmitPacket(packet, nextHop);

      // 4. Record in local history, persist to Hive, push to stream (sender's bubble)
      messageHistory.putIfAbsent(targetEndpointId, () => []).add(message);
      StorageService().saveMessage(targetEndpointId, message);
      _messageController.add(message);

      debugPrint(
          '[P2PService] 📨 Sent [${packet.packetId.substring(0, 8)}] '
          '→ ${targetPeer.endpointName} (via $nextHop)');
    } catch (e) {
      debugPrint('[P2PService] ❌ sendMessage: $e');
      rethrow;
    }
  }


  // ────────────────────────────────────────────────────────────────────────────
  // STOP ALL
  // ────────────────────────────────────────────────────────────────────────────
  Future<void> stopAll() async {
    await _nearby.stopAdvertising();
    await _nearby.stopDiscovery();
    await _nearby.stopAllEndpoints();
    _isAdvertising = false;
    _isDiscovering = false;
    peers.clear();
    notifyListeners();
    debugPrint('[P2PService] 🛑 All sessions stopped');
  }

  // ════════════════════════════════════════════════════════════════════════════
  // PRIVATE: Nearby Connections callbacks
  // ════════════════════════════════════════════════════════════════════════════

  void _onConnectionInitiated(
      String endpointId, ConnectionInfo connectionInfo) {
    debugPrint('[P2PService] 🤝 Initiated with ${connectionInfo.endpointName}');

    _nearby.acceptConnection(
      endpointId,
      onPayLoadRecieved: _onPayloadReceived,
      onPayloadTransferUpdate: (_, __) {},
    );

    peers.putIfAbsent(
      endpointId,
      () => DiscoveredPeer(
        endpointId: endpointId,
        endpointName: connectionInfo.endpointName,
      ),
    );
  }

  void _onConnectionResult(String endpointId, Status status) {
    if (status == Status.CONNECTED) {
      debugPrint('[P2PService] ✅ Connected: $endpointId');
      peers[endpointId]?.state = PeerState.connected;
      messageHistory.putIfAbsent(endpointId, () => []);

      // ── KEY EXCHANGE: broadcast our public key to the newly connected peer ──
      // This is always the first packet. Until it arrives on the other side,
      // they cannot encrypt messages for us.
      _sendKeyAnnouncement(endpointId);
    } else {
      debugPrint('[P2PService] ❌ Connection failed: $endpointId');
      peers[endpointId]?.state = PeerState.found;
    }
    if (!_disposed) notifyListeners();
  }

  void _onDisconnected(String endpointId) {
    debugPrint('[P2PService] 💔 Disconnected: $endpointId');
    peers[endpointId]?.state = PeerState.disconnected;
    if (!_disposed) notifyListeners();
  }

  // ════════════════════════════════════════════════════════════════════════════
  // PRIVATE: Payload reception — THE MESH ROUTING BRAIN
  //
  // Every incoming byte array passes through this single function.
  // The routing decision tree executes here synchronously before any async IO.
  // ════════════════════════════════════════════════════════════════════════════
  Future<void> _onPayloadReceived(
      String fromEndpointId, Payload payload) async {
    if (payload.type != PayloadType.BYTES || payload.bytes == null) return;

    MeshPacket packet;
    try {
      packet = MeshPacket.fromBytes(payload.bytes!);
    } catch (e) {
      // Malformed bytes — could be a non-ZeroGrid packet on the same channel
      debugPrint('[P2PService] ⚠️  Could not parse MeshPacket from $fromEndpointId: $e');
      return;
    }

    debugPrint('[P2PService] 📦 Received $packet');

    // ── DEDUPLICATION GUARD ────────────────────────────────────────────────────
    // Prevents a packet from being processed or relayed more than once
    // (can happen in dense meshes where multiple paths exist).
    if (_seenPacketIds.contains(packet.packetId)) {
      debugPrint('[P2PService] 🔁 Duplicate packet ${packet.packetId.substring(0, 8)}, dropping');
      return;
    }
    _seenPacketIds.add(packet.packetId);

    // ── ROUTING DECISION ───────────────────────────────────────────────────────
    switch (packet.type) {

      // ── CASE A: Key Announcement ─────────────────────────────────────────────
      // Store the sender's public key. Not forwarded — maxHops == 1 by design.
      case PacketType.keyAnnouncement:
        _handleKeyAnnouncement(packet, fromEndpointId);
        break;

      // ── CASE B: Encrypted Message ─────────────────────────────────────────────
      case PacketType.message:
        if (_crypto.isMyPublicKey(packet.destinationPublicKey)) {
          // ── I AM THE FINAL DESTINATION ────────────────────────────────────────
          await _decryptAndSurface(packet, fromEndpointId);
        } else {
          // ── I AM A RELAY NODE ─────────────────────────────────────────────────
          await _relayPacket(packet, fromEndpointId);
        }
        break;

      // ── CASE C: Acknowledgement (reserved) ───────────────────────────────────
      case PacketType.ack:
        debugPrint('[P2PService] ✔  ACK for ${packet.encryptedPayload.substring(0, 8)}');
        break;
    }
  }

  // ════════════════════════════════════════════════════════════════════════════
  // PRIVATE: Routing handlers
  // ════════════════════════════════════════════════════════════════════════════

  /// Handles an incoming KEY_ANNOUNCEMENT by storing the sender's public key.
  void _handleKeyAnnouncement(MeshPacket packet, String fromEndpointId) {
    final peer = peers[fromEndpointId];
    if (peer != null) {
      peer.publicKey = packet.encryptedPayload; // payload IS the public key
      debugPrint(
          '[P2PService] 🔑 Stored public key for ${peer.endpointName}: '
          '${peer.publicKey!.substring(0, 16)}…');

      // ── Persist to Hive so the key survives app restarts ────────────────────
      StorageService().savePeerKey(
        endpointId: peer.endpointId,
        endpointName: peer.endpointName,
        publicKeyBase64: peer.publicKey!,
      );

      notifyListeners(); // UI can now show "ready to encrypt" indicator
    }
  }

  /// I am the final destination: decrypt and push to UI.
  Future<void> _decryptAndSurface(
      MeshPacket packet, String fromEndpointId) async {
    try {
      final plaintext = await _crypto.decrypt(
        packet.encryptedPayload,
        packet.senderPublicKey,
      );

      // Find the endpointId of the original sender by matching their public key
      final senderEntry = peers.entries.firstWhere(
        (e) => e.value.publicKey == packet.senderPublicKey,
        orElse: () => MapEntry(
          fromEndpointId,
          peers[fromEndpointId] ??
              DiscoveredPeer(
                endpointId: fromEndpointId,
                endpointName: 'Unknown',
              ),
        ),
      );

      final message = MessageModel(
        senderName: senderEntry.value.endpointName,
        textMessage: plaintext,
        isReceived: true,
      );

      messageHistory
          .putIfAbsent(senderEntry.key, () => [])
          .add(message);
      _messageController.add(message);

      // ── Persist received message to Hive ───────────────────────────────
      StorageService().saveMessage(senderEntry.key, message);

      debugPrint(
          '[P2PService] 🔓 Decrypted message from ${senderEntry.value.endpointName} '
          '(${packet.hopCount} hop${packet.hopCount == 1 ? '' : 's'}): '
          '"$plaintext"');
    } catch (e) {
      // Decryption failure = wrong key or tampered packet. Drop it.
      debugPrint('[P2PService] 🚫 Decryption failed (tampered packet?): $e');
    }
  }

  /// I am a relay node: forward the packet toward the destination.
  /// The user whose device is relaying sees NOTHING on their UI.
  Future<void> _relayPacket(
      MeshPacket packet, String fromEndpointId) async {

    // ── HOP LIMIT CHECK ───────────────────────────────────────────────────────
    if (packet.isExpired) {
      debugPrint(
          '[P2PService] ⏱  Packet ${packet.packetId.substring(0, 8)} expired '
          '(${packet.hopCount}/${packet.maxHops} hops). Dropping.');
      return;
    }

    // ── FIND NEXT HOP ─────────────────────────────────────────────────────────
    // Strategy: first try the exact destination; otherwise forward to any
    // connected peer that is NOT the one who just sent this packet to us
    // (avoids immediately bouncing back).
    final connectedPeers = peers.values
        .where((p) =>
            p.state == PeerState.connected &&
            p.endpointId != fromEndpointId)
        .toList();

    if (connectedPeers.isEmpty) {
      debugPrint('[P2PService] 🚧 No relay path available for '
          '${packet.packetId.substring(0, 8)}. Dropping.');
      return;
    }

    // Prefer a peer whose public key matches the destination exactly
    final directMatch = connectedPeers.where(
        (p) => p.publicKey == packet.destinationPublicKey);
    final nextHopPeer = directMatch.isNotEmpty
        ? directMatch.first
        : connectedPeers.first; // Best-effort: forward to any connected node

    // Increment hop count and stamp with our endpointId as the new sender
    final relayedPacket =
        packet.withIncrementedHop(_nearbyLocalEndpointId);

    await _transmitPacket(relayedPacket, nextHopPeer.endpointId);

    debugPrint(
        '[P2PService] 🔄 Relayed [${packet.packetId.substring(0, 8)}] '
        '→ ${nextHopPeer.endpointName} (hop ${relayedPacket.hopCount}/${relayedPacket.maxHops})');
  }

  // ════════════════════════════════════════════════════════════════════════════
  // PRIVATE: Transmission helpers
  // ════════════════════════════════════════════════════════════════════════════

  /// Sends a KEY_ANNOUNCEMENT to [endpointId] immediately after connection.
  Future<void> _sendKeyAnnouncement(String endpointId) async {
    final packet = MeshPacket.keyAnnouncement(
      senderPublicKey: localPublicKey,
      senderEndpointId: _nearbyLocalEndpointId,
      senderName: localEndpointName,
    );
    await _transmitPacket(packet, endpointId);
    debugPrint('[P2PService] 📢 Sent KEY_ANNOUNCEMENT to $endpointId');
  }

  /// Low-level transmit: serialise [packet] and hand it to Nearby Connections.
  Future<void> _transmitPacket(MeshPacket packet, String endpointId) async {
    final bytes = Uint8List.fromList(packet.toBytes());
    await _nearby.sendBytesPayload(endpointId, bytes);
  }

  /// Finds the best immediate next-hop endpointId for a target.
  /// Returns the target itself if directly connected; otherwise falls back
  /// to the first available connected peer.
  String _findNextHop(String targetEndpointId) {
    final target = peers[targetEndpointId];
    if (target?.state == PeerState.connected) return targetEndpointId;

    // Target not directly reachable — find any connected peer to relay via
    final relay = peers.values.firstWhere(
      (p) => p.state == PeerState.connected,
      orElse: () => throw StateError('No connected peers available for routing'),
    );
    return relay.endpointId;
  }

  /// Placeholder for the local Nearby endpointId.
  /// In production, capture the real value from a Nearby API call if available.
  String get _nearbyLocalEndpointId => 'local_${localPublicKey.substring(0, 8)}';

  @override
  void dispose() {
    // BUG FIX: Set _disposed BEFORE calling stopAll() so that any
    // notifyListeners() calls triggered inside stopAll() (or its async
    // callbacks) are silently ignored rather than crashing with
    // "setState() called after dispose()" in debug mode.
    _disposed = true;
    stopAll();
    _messageController.close();
    super.dispose();
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────
String _randomSuffix() {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
  final seed = DateTime.now().millisecondsSinceEpoch;
  return String.fromCharCodes(
    List.generate(4, (i) => chars.codeUnitAt((seed + i * 37) % chars.length)),
  );
}
