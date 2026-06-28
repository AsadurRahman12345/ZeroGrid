import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'message_model.dart';

// ──────────────────────────────────────────────────────────────────────────────
// StorageService
//
// A singleton Hive-based local database for ZeroGrid.
// Stores three types of data on-device:
//
//   BOX: messages  → complete chat history, keyed by endpointId
//   BOX: peers     → known peer public keys + display names
//   BOX: settings  → app configuration (local agent name, schema version, etc.)
//
// DATA FLOW
// ─────────
//  App launch   → StorageService.init() opens all Hive boxes
//  Message sent/received → StorageService.saveMessage()
//  ChatScreen opens → StorageService.getMessages(endpointId)
//  Peer connects → StorageService.savePeerKey()
//  P2PService boots → StorageService.getAllPeerKeys() pre-populates key cache
//
// SECURITY NOTE
// ─────────────
//  Hive files are stored in the app's private sandbox directory.
//  On Android:  /data/data/com.zerogrid.app/files/   (not accessible without root)
//  On iOS:      ~/Library/Application Support/         (excluded from iCloud backup)
//  For an additional layer, Hive supports an AES-256 encryption cipher via
//  HiveAesCipher. The encryption key itself should be stored in
//  flutter_secure_storage (which uses Android Keystore / iOS Keychain).
//  This is intentionally left as a production hardening step so the initial
//  implementation remains easy to debug.
// ──────────────────────────────────────────────────────────────────────────────

// ── Hive Box Names ────────────────────────────────────────────────────────────
const _kBoxMessages = 'zg_messages';
const _kBoxPeers    = 'zg_peers';
const _kBoxSettings = 'zg_settings';

// ── Settings Keys ─────────────────────────────────────────────────────────────
const _kSettingAgentName    = 'agent_name';
const _kSettingSchemaVersion = 'schema_version';
const int _kCurrentSchema   = 1;

class StorageService {
  // ── Singleton ────────────────────────────────────────────────────────────────
  static final StorageService _instance = StorageService._internal();
  factory StorageService() => _instance;
  StorageService._internal();

  // ── Box handles (set after init()) ───────────────────────────────────────────
  late Box<Map>          _messagesBox;
  late Box<Map>          _peersBox;
  late Box<dynamic>      _settingsBox;

  // ────────────────────────────────────────────────────────────────────────────
  // INIT
  // Call once at app startup, BEFORE any read/write operations.
  // ────────────────────────────────────────────────────────────────────────────
  Future<void> init() async {
    // hive_flutter's initFlutter() calls Hive.init() with the correct path for
    // the current platform (getApplicationDocumentsDirectory on mobile).
    await Hive.initFlutter();

    // Open all boxes concurrently for faster startup.
    final results = await Future.wait([
      Hive.openBox<Map>(_kBoxMessages),
      Hive.openBox<Map>(_kBoxPeers),
      Hive.openBox<dynamic>(_kBoxSettings),
    ]);

    _messagesBox = results[0] as Box<Map>;
    _peersBox    = results[1] as Box<Map>;
    _settingsBox = results[2] as Box<dynamic>;

    // Schema migration hook — run before any reads.
    await _runMigrations();

    debugPrint('[StorageService] ✅ Hive initialised');
    debugPrint('[StorageService]    messages: ${_messagesBox.length} conversations');
    debugPrint('[StorageService]    peers:    ${_peersBox.length} known peers');
  }

  // ────────────────────────────────────────────────────────────────────────────
  // MESSAGE STORAGE
  // ────────────────────────────────────────────────────────────────────────────

  /// Persists a single [MessageModel] for the given [endpointId].
  ///
  /// Hive does not support nested collections natively, so we store the entire
  /// conversation as a JSON-compatible List<Map> under the key [endpointId].
  /// On each save we read, append, and write back.
  /// For large histories (>10 000 messages), switch to a LazyBox.
  Future<void> saveMessage(String endpointId, MessageModel message) async {
    final existing = _readMessageList(endpointId);
    existing.add(message.toMap());
    await _messagesBox.put(endpointId, _toHiveMap({'messages': existing}));
    debugPrint('[StorageService] 💾 Saved message [${message.id.substring(0, 8)}] '
        'for $endpointId (total: ${existing.length})');
  }

  /// Saves an entire list of messages for [endpointId].
  /// Useful for bulk-writing after a session ends.
  Future<void> saveMessages(
      String endpointId, List<MessageModel> messages) async {
    final maps = messages.map((m) => m.toMap()).toList();
    await _messagesBox.put(endpointId, _toHiveMap({'messages': maps}));
    debugPrint('[StorageService] 💾 Bulk-saved ${messages.length} messages for $endpointId');
  }

  /// Retrieves the full ordered message history for [endpointId].
  /// Returns an empty list if no conversation exists yet.
  List<MessageModel> getMessages(String endpointId) {
    final raw = _readMessageList(endpointId);
    return raw.map((m) => MessageModel.fromMap(Map<String, dynamic>.from(m))).toList();
  }

  /// Returns every endpointId that has stored messages.
  List<String> getAllConversationIds() => _messagesBox.keys.cast<String>().toList();

  /// Permanently deletes the message history for [endpointId].
  Future<void> deleteConversation(String endpointId) async {
    await _messagesBox.delete(endpointId);
    debugPrint('[StorageService] 🗑  Deleted conversation: $endpointId');
  }

  // ── Private helper ────────────────────────────────────────────────────────
  List<dynamic> _readMessageList(String endpointId) {
    final box = _messagesBox.get(endpointId);
    if (box == null) return [];
    return List<dynamic>.from(box['messages'] as List? ?? []);
  }

  // ────────────────────────────────────────────────────────────────────────────
  // PEER KEY STORAGE
  // ────────────────────────────────────────────────────────────────────────────

  /// Saves or updates the X25519 public key for a known peer.
  ///
  /// This ensures that if the app restarts, all previously connected peers'
  /// public keys are immediately available — no re-connection needed to encrypt.
  Future<void> savePeerKey({
    required String endpointId,
    required String endpointName,
    required String publicKeyBase64,
  }) async {
    await _peersBox.put(endpointId, _toHiveMap({
      'endpointId': endpointId,
      'endpointName': endpointName,
      'publicKeyBase64': publicKeyBase64,
      'lastSeen': DateTime.now().toUtc().toIso8601String(),
    }));
    debugPrint('[StorageService] 🔑 Saved key for $endpointName ($endpointId)');
  }

  /// Returns the stored public key for [endpointId], or null if not found.
  String? getPeerKey(String endpointId) {
    final data = _peersBox.get(endpointId);
    return data?['publicKeyBase64'] as String?;
  }

  /// Returns a map of { endpointId → publicKeyBase64 } for ALL known peers.
  /// Called during P2PService.init() to pre-populate the in-memory key cache.
  Map<String, String> getAllPeerKeys() {
    final result = <String, String>{};
    for (final entry in _peersBox.toMap().entries) {
      final id = entry.key as String;
      final key = (entry.value as Map?)?['publicKeyBase64'] as String?;
      if (key != null) result[id] = key;
    }
    debugPrint('[StorageService] 🔑 Loaded ${result.length} peer keys from storage');
    return result;
  }

  /// Returns the stored display name for [endpointId], or null.
  String? getPeerName(String endpointId) {
    final data = _peersBox.get(endpointId);
    return data?['endpointName'] as String?;
  }

  /// Deletes a peer record (e.g., when user explicitly "forgets" a peer).
  Future<void> deletePeer(String endpointId) async {
    await _peersBox.delete(endpointId);
    debugPrint('[StorageService] 🗑  Deleted peer: $endpointId');
  }

  // ────────────────────────────────────────────────────────────────────────────
  // SETTINGS STORAGE
  // ────────────────────────────────────────────────────────────────────────────

  /// Reads/writes the locally configured agent display name.
  String? get agentName => _settingsBox.get(_kSettingAgentName) as String?;
  Future<void> setAgentName(String name) async {
    await _settingsBox.put(_kSettingAgentName, name);
    debugPrint('[StorageService] ⚙️  Agent name set: $name');
  }

  // ────────────────────────────────────────────────────────────────────────────
  // MAINTENANCE
  // ────────────────────────────────────────────────────────────────────────────

  /// Removes messages older than [maxAgeDays] from ALL conversations.
  /// Call from the BGProcessingTask (iOS) or a WorkManager job (Android).
  Future<int> pruneOldMessages({int maxAgeDays = 30}) async {
    final cutoff = DateTime.now().toUtc().subtract(Duration(days: maxAgeDays));
    int pruned = 0;

    for (final id in getAllConversationIds()) {
      final all = _readMessageList(id);
      final filtered = all.where((m) {
        final ts = DateTime.tryParse(m['timestamp'] as String? ?? '');
        return ts != null && ts.isAfter(cutoff);
      }).toList();
      if (filtered.length < all.length) {
        pruned += all.length - filtered.length;
        await _messagesBox.put(id, _toHiveMap({'messages': filtered}));
      }
    }

    debugPrint('[StorageService] 🧹 Pruned $pruned messages older than $maxAgeDays days');
    return pruned;
  }

  /// Compacts all Hive boxes to reclaim disk space from deleted entries.
  Future<void> compact() async {
    await Future.wait([
      _messagesBox.compact(),
      _peersBox.compact(),
      _settingsBox.compact(),
    ]);
    debugPrint('[StorageService] 📦 Hive boxes compacted');
  }

  /// Closes all boxes gracefully. Call on app exit.
  Future<void> close() async {
    await Hive.close();
    debugPrint('[StorageService] 🛑 All Hive boxes closed');
  }

  // ── Private: Schema Migrations ────────────────────────────────────────────
  Future<void> _runMigrations() async {
    final stored = _settingsBox.get(_kSettingSchemaVersion) as int? ?? 0;
    if (stored < _kCurrentSchema) {
      debugPrint('[StorageService] 🔄 Migrating schema $stored → $_kCurrentSchema');
      // Future migrations go here:
      // if (stored < 2) { ... }
      await _settingsBox.put(_kSettingSchemaVersion, _kCurrentSchema);
    }
  }

  // ── Private: Hive type coercion ───────────────────────────────────────────
  // Hive Box<Map> expects a Map, not Map<String, dynamic>. This cast is
  // safe because Hive serialises Map to binary and deserialises back.
  Map _toHiveMap(Map<String, dynamic> m) => m;
}
