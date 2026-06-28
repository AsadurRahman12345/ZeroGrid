import 'dart:convert';
import 'package:uuid/uuid.dart';

// ──────────────────────────────────────────────────────────────────────────────
// MeshPacket
//
// The fundamental unit of data in the ZeroGrid mesh network. Every piece of
// information transmitted between nodes — whether a user message, a key
// announcement, or an acknowledgement — is wrapped in a MeshPacket.
//
// PACKET TYPES
// ────────────
//  MESSAGE          – A user-initiated encrypted chat message.
//  KEY_ANNOUNCEMENT – Sent immediately after a Nearby connection is established.
//                     Contains the sender's X25519 public key so the peer can
//                     encrypt future messages addressed to this device.
//  ACK              – Lightweight delivery acknowledgement (future use).
//
// HOP-COUNT ROUTING
// ──────────────────
//  Each relay node that forwards this packet increments [hopCount].
//  If [hopCount] reaches [maxHops] the packet is silently dropped to prevent
//  infinite loops in a densely connected mesh.
//
// WIRE FORMAT
// ───────────
//  Serialised as compact JSON, UTF-8 encoded, then handed to the Nearby
//  Connections BYTES payload API.  Maximum safe payload size via BLE is ~500 KB;
//  typical text messages are < 1 KB.
// ──────────────────────────────────────────────────────────────────────────────

const _uuid = Uuid();

/// Packet type discriminator.
enum PacketType {
  message,          // Encrypted chat payload
  keyAnnouncement,  // Public key broadcast on connection
  ack,              // Delivery confirmation (reserved for future use)
}

extension PacketTypeExt on PacketType {
  String get wire {
    switch (this) {
      case PacketType.message:         return 'MESSAGE';
      case PacketType.keyAnnouncement: return 'KEY_ANNOUNCEMENT';
      case PacketType.ack:             return 'ACK';
    }
  }

  static PacketType fromWire(String s) {
    switch (s) {
      case 'KEY_ANNOUNCEMENT': return PacketType.keyAnnouncement;
      case 'ACK':              return PacketType.ack;
      default:                 return PacketType.message;
    }
  }
}

class MeshPacket {
  // ── Routing header ────────────────────────────────────────────────────────────

  /// UUID v4. Unique per packet. Used for deduplication — if a relay sees a
  /// packetId it has already forwarded, it silently drops it.
  final String packetId;

  /// Type of this packet (see enum above).
  final PacketType type;

  /// X25519 public key of the originating device (Base64).
  /// Used by the final recipient to perform ECDH and decrypt the payload.
  final String senderPublicKey;

  /// Nearby Connections endpointId of the IMMEDIATE sender of this hop.
  /// Updated by each relay so ACKs and replies know the next-hop back.
  final String senderEndpointId;

  /// X25519 public key of the FINAL destination device (Base64).
  /// Each relay compares this against its own public key to decide:
  ///   match  → I am the destination, decrypt and surface to UI.
  ///   no match → I am a relay, forward to the next connected peer.
  final String destinationPublicKey;

  /// Human-readable name of the final destination (e.g. "Agent_BETA").
  /// Used by the UI to display "To: Agent_BETA" in the relay confirmation.
  final String finalDestinationName;

  // ── Hop control ──────────────────────────────────────────────────────────────

  /// Number of relay hops this packet has already traversed.
  /// Incremented by each forwarding node BEFORE retransmitting.
  final int hopCount;

  /// Hard upper bound on relay hops. Prevents infinite routing loops.
  /// Default: 5. Sufficient for a dense room-sized mesh.
  final int maxHops;

  // ── Payload ──────────────────────────────────────────────────────────────────

  /// The actual data for this packet.
  ///
  /// For [PacketType.message]:
  ///   Base64( 12-byte nonce || AES-256-GCM ciphertext || 16-byte MAC )
  ///   Only the device whose private key corresponds to [destinationPublicKey]
  ///   can decrypt this field.
  ///
  /// For [PacketType.keyAnnouncement]:
  ///   A plain Base64 X25519 public key string (no encryption needed — it's
  ///   a public key by definition).
  ///
  /// For [PacketType.ack]:
  ///   The packetId of the MESSAGE being acknowledged.
  final String encryptedPayload;

  // ────────────────────────────────────────────────────────────────────────────
  const MeshPacket({
    required this.packetId,
    required this.type,
    required this.senderPublicKey,
    required this.senderEndpointId,
    required this.destinationPublicKey,
    required this.finalDestinationName,
    required this.hopCount,
    required this.maxHops,
    required this.encryptedPayload,
  });

  // ── Factory constructors ────────────────────────────────────────────────────

  /// Creates a new outbound message packet.
  factory MeshPacket.message({
    required String senderPublicKey,
    required String senderEndpointId,
    required String destinationPublicKey,
    required String finalDestinationName,
    required String encryptedPayload,
    int maxHops = 5,
  }) =>
      MeshPacket(
        packetId: _uuid.v4(),
        type: PacketType.message,
        senderPublicKey: senderPublicKey,
        senderEndpointId: senderEndpointId,
        destinationPublicKey: destinationPublicKey,
        finalDestinationName: finalDestinationName,
        hopCount: 0,
        maxHops: maxHops,
        encryptedPayload: encryptedPayload,
      );

  /// Creates a KEY_ANNOUNCEMENT packet (sent right after connection).
  factory MeshPacket.keyAnnouncement({
    required String senderPublicKey,
    required String senderEndpointId,
    required String senderName,
  }) =>
      MeshPacket(
        packetId: _uuid.v4(),
        type: PacketType.keyAnnouncement,
        senderPublicKey: senderPublicKey,
        senderEndpointId: senderEndpointId,
        destinationPublicKey: '', // Broadcast — no specific destination
        finalDestinationName: '',
        hopCount: 0,
        maxHops: 1, // Key announcements are NOT relayed
        encryptedPayload: senderPublicKey, // Payload IS the public key
      );

  // ── Hop increment ─────────────────────────────────────────────────────────────
  /// Returns a new [MeshPacket] with [hopCount] incremented by 1 and
  /// [senderEndpointId] updated to the current relay node's endpointId.
  /// The original is immutable.
  MeshPacket withIncrementedHop(String relayEndpointId) => MeshPacket(
        packetId: packetId,
        type: type,
        senderPublicKey: senderPublicKey,
        senderEndpointId: relayEndpointId, // Update to current relay
        destinationPublicKey: destinationPublicKey,
        finalDestinationName: finalDestinationName,
        hopCount: hopCount + 1,
        maxHops: maxHops,
        encryptedPayload: encryptedPayload,
      );

  // ── Guard ─────────────────────────────────────────────────────────────────────
  /// Returns true if this packet has exceeded its maximum hop allowance.
  bool get isExpired => hopCount >= maxHops;

  // ── Serialization ─────────────────────────────────────────────────────────────

  Map<String, dynamic> toMap() => {
        'packetId': packetId,
        'type': type.wire,
        'senderPublicKey': senderPublicKey,
        'senderEndpointId': senderEndpointId,
        'destinationPublicKey': destinationPublicKey,
        'finalDestinationName': finalDestinationName,
        'hopCount': hopCount,
        'maxHops': maxHops,
        'encryptedPayload': encryptedPayload,
      };

  factory MeshPacket.fromMap(Map<String, dynamic> m) => MeshPacket(
        packetId: m['packetId'] as String,
        type: PacketTypeExt.fromWire(m['type'] as String),
        senderPublicKey: m['senderPublicKey'] as String,
        senderEndpointId: m['senderEndpointId'] as String,
        destinationPublicKey: m['destinationPublicKey'] as String,
        finalDestinationName: m['finalDestinationName'] as String,
        hopCount: m['hopCount'] as int,
        maxHops: m['maxHops'] as int,
        encryptedPayload: m['encryptedPayload'] as String,
      );

  /// Encodes to compact JSON then UTF-8 bytes — ready for [Nearby.sendBytesPayload].
  List<int> toBytes() => utf8.encode(jsonEncode(toMap()));

  /// Reconstructs a [MeshPacket] from bytes received in [onPayLoadRecieved].
  factory MeshPacket.fromBytes(List<int> bytes) =>
      MeshPacket.fromMap(jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>);

  @override
  String toString() =>
      'MeshPacket(id: ${packetId.substring(0, 8)}, '
      'type: ${type.wire}, hops: $hopCount/$maxHops, '
      'dest: ${destinationPublicKey.isEmpty ? "broadcast" : destinationPublicKey.substring(0, 8)})';
}
