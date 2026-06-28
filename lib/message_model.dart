import 'dart:convert';
import 'package:uuid/uuid.dart';

// ──────────────────────────────────────────────────────────────────────────────
// MessageModel
//
// A clean, serializable data class that represents a single chat message in the
// ZeroGrid mesh network. Every message sent over the wire is JSON-encoded into
// a UTF-8 byte array and decoded back on the other side using this model.
//
// Wire format (compact JSON example):
// {
//   "id":          "a1b2-c3d4-...",
//   "senderName":  "Agent_XVZQ",
//   "textMessage": "Hello from node 7",
//   "timestamp":   "2026-06-27T23:36:00.000Z",
//   "isReceived":  false
// }
// ──────────────────────────────────────────────────────────────────────────────

const _uuid = Uuid();

class MessageModel {
  /// Universally unique ID. Generated locally at creation time with UUID v4.
  /// Used by the UI to avoid duplicate rendering if a payload is delivered twice.
  final String id;

  /// Advertised endpoint name of the sender (e.g. "Agent_XVZQ").
  final String senderName;

  /// The human-readable message content.
  final String textMessage;

  /// UTC ISO-8601 timestamp set when the message object is created.
  final DateTime timestamp;

  /// True  → this message was inbound (received from a remote peer).
  /// False → this message was outbound (sent by the local user).
  final bool isReceived;

  MessageModel({
    String? id,
    required this.senderName,
    required this.textMessage,
    DateTime? timestamp,
    required this.isReceived,
  })  : id = id ?? _uuid.v4(),
        timestamp = timestamp ?? DateTime.now().toUtc();

  // ── Serialization ────────────────────────────────────────────────────────────

  /// Converts this message to a plain Dart [Map] ready for JSON encoding.
  Map<String, dynamic> toMap() => {
        'id': id,
        'senderName': senderName,
        'textMessage': textMessage,
        'timestamp': timestamp.toIso8601String(),
        'isReceived': isReceived,
      };

  /// Reconstructs a [MessageModel] from a decoded JSON [Map].
  factory MessageModel.fromMap(Map<String, dynamic> map) => MessageModel(
        id: map['id'] as String,
        senderName: map['senderName'] as String,
        textMessage: map['textMessage'] as String,
        timestamp: DateTime.parse(map['timestamp'] as String),
        isReceived: map['isReceived'] as bool,
      );

  // ── Byte-level serialization (for Nearby Connections payload) ────────────────

  /// Encodes the message as a compact JSON string, then converts it to a UTF-8
  /// [List<int>] (byte array) suitable for [Nearby.sendBytesPayload].
  List<int> toBytes() => utf8.encode(jsonEncode(toMap()));

  /// Decodes a UTF-8 byte array received from [Nearby.onPayLoadRecieved] back
  /// into a [MessageModel]. Throws [FormatException] on malformed input.
  factory MessageModel.fromBytes(List<int> bytes) {
    final jsonString = utf8.decode(bytes);
    final map = jsonDecode(jsonString) as Map<String, dynamic>;
    return MessageModel.fromMap(map);
  }

  // ── UI helpers ───────────────────────────────────────────────────────────────

  /// Formatted time string for display under the chat bubble (e.g. "11:42 AM").
  String get formattedTime {
    final local = timestamp.toLocal();
    final hour = local.hour;
    final minute = local.minute.toString().padLeft(2, '0');
    final period = hour < 12 ? 'AM' : 'PM';
    final displayHour = hour % 12 == 0 ? 12 : hour % 12;
    return '$displayHour:$minute $period';
  }

  /// Short delivery metadata label shown below each bubble.
  /// Sent messages show the encryption hop; received ones show the transport.
  String get deliveryMeta =>
      isReceived ? 'Delivered via Bluetooth · Hop-0' : 'Encrypted · Hop-0';

  @override
  String toString() =>
      'MessageModel(id: $id, sender: $senderName, text: $textMessage)';
}
