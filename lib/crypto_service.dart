import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

// ──────────────────────────────────────────────────────────────────────────────
// CryptoService
//
// Responsible for ALL cryptographic operations in ZeroGrid:
//
//   KEY MANAGEMENT
//   ─────────────
//   • Generates an X25519 key pair the first time the app runs.
//   • Persists the private key bytes in the OS secure keychain
//     (Android Keystore / iOS Keychain) via flutter_secure_storage.
//   • Exposes the public key as a Base64 string for advertisement to peers.
//
//   SHARED SECRET DERIVATION (ECDH)
//   ─────────────────────────────────
//   • Uses X25519 Diffie-Hellman to derive a 32-byte shared secret from
//     (myPrivateKey, theirPublicKey) without ever transmitting the secret.
//   • Both sides independently compute the SAME secret — the foundation of
//     forward secrecy.
//
//   ENCRYPTION  (AES-256-GCM)
//   ──────────────────────────
//   • Encrypts the plaintext payload with the ECDH-derived shared secret.
//   • AES-GCM provides BOTH confidentiality (cipher) AND authenticity (MAC).
//   • A random 12-byte nonce is generated per message and prepended to the
//     ciphertext so the receiver can decrypt without any extra round-trip.
//
//   WIRE FORMAT of encryptedPayload field (all Base64-encoded together):
//     [ 12 bytes nonce ][ N bytes ciphertext ][ 16 bytes GCM tag ]
// ──────────────────────────────────────────────────────────────────────────────

class CryptoService {
  // ── Singleton ────────────────────────────────────────────────────────────────
  static final CryptoService _instance = CryptoService._internal();
  factory CryptoService() => _instance;
  CryptoService._internal();

  // ── Cryptographic algorithm instances ────────────────────────────────────────
  /// X25519: Elliptic-Curve Diffie-Hellman over Curve25519.
  final _x25519 = X25519();

  /// AES-256-GCM: Authenticated Encryption with Associated Data.
  /// 256-bit key, 128-bit authentication tag, 96-bit nonce.
  final _aesGcm = AesGcm.with256bits();

  // ── Secure Storage ────────────────────────────────────────────────────────────
  final _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  static const _privateKeyStorageKey = 'zerogrid_x25519_private_key';
  static const _publicKeyStorageKey = 'zerogrid_x25519_public_key';

  // ── In-memory key pair (loaded on init) ───────────────────────────────────────
  SimpleKeyPair? _keyPair;

  /// Base64-encoded public key of this device.
  /// Broadcast to peers via KEY_ANNOUNCEMENT packets.
  String? _publicKeyBase64;
  String get publicKeyBase64 {
    assert(_publicKeyBase64 != null,
        'CryptoService.init() must be awaited before use');
    return _publicKeyBase64!;
  }

  // ────────────────────────────────────────────────────────────────────────────
  // INITIALISE
  // Call once at app startup (before any P2P operations).
  // Loads an existing key pair from secure storage or generates a new one.
  // ────────────────────────────────────────────────────────────────────────────
  Future<void> init() async {
    try {
      final storedPrivate = await _storage.read(key: _privateKeyStorageKey);
      final storedPublic = await _storage.read(key: _publicKeyStorageKey);

      if (storedPrivate != null && storedPublic != null) {
        // ── Restore existing key pair ──────────────────────────────────────────
        final privateBytes = base64Decode(storedPrivate);
        final publicBytes = base64Decode(storedPublic);

        _keyPair = SimpleKeyPairData(
          privateBytes,
          publicKey: SimplePublicKey(publicBytes, type: KeyPairType.x25519),
          type: KeyPairType.x25519,
        );
        _publicKeyBase64 = storedPublic;
        debugPrint('[CryptoService] ✅ Loaded existing X25519 key pair');
      } else {
        // ── Generate a brand-new key pair ──────────────────────────────────────
        await _generateAndPersistKeyPair();
      }
    } catch (e) {
      // Storage failure (e.g. first install on some Android OEMs). Generate fresh.
      debugPrint('[CryptoService] ⚠️  Key load failed, generating new pair: $e');
      await _generateAndPersistKeyPair();
    }
  }

  Future<void> _generateAndPersistKeyPair() async {
    _keyPair = await _x25519.newKeyPair();
    final publicKey = await _keyPair!.extractPublicKey();
    final privateKeyData = await _keyPair!.extract();

    final privateBase64 = base64Encode(privateKeyData.bytes);
    final publicBase64 = base64Encode(publicKey.bytes);

    await _storage.write(key: _privateKeyStorageKey, value: privateBase64);
    await _storage.write(key: _publicKeyStorageKey, value: publicBase64);

    _publicKeyBase64 = publicBase64;
    debugPrint('[CryptoService] 🔑 Generated & saved new X25519 key pair');
    debugPrint('[CryptoService]    Public key: $publicBase64');
  }

  // ────────────────────────────────────────────────────────────────────────────
  // ENCRYPT
  //
  // 1. Derive shared secret via X25519 ECDH with recipient's public key.
  // 2. Generate a cryptographically random 12-byte nonce.
  // 3. Encrypt plaintext with AES-256-GCM using the shared secret.
  // 4. Return Base64( nonce || ciphertext || gcm_tag ).
  // ────────────────────────────────────────────────────────────────────────────
  Future<String> encrypt(String plaintext, String recipientPublicKeyBase64) async {
    if (_keyPair == null) {
      throw StateError(
          '[CryptoService] encrypt() called before init(). '
          'Await CryptoService.init() at app startup.');
    }
    try {
      // Reconstruct the recipient's public key from Base64
      final recipientPublicKey = SimplePublicKey(
        base64Decode(recipientPublicKeyBase64),
        type: KeyPairType.x25519,
      );

      // X25519 ECDH → 32-byte shared secret
      final sharedSecret = await _x25519.sharedSecretKey(
        keyPair: _keyPair!,
        remotePublicKey: recipientPublicKey,
      );
      final sharedSecretBytes = await sharedSecret.extractBytes();

      // Wrap the raw bytes as an AES-GCM secret key
      final aesKey = SecretKey(sharedSecretBytes);

      // Encrypt with AES-256-GCM (nonce is auto-generated internally)
      final secretBox = await _aesGcm.encrypt(
        utf8.encode(plaintext),
        secretKey: aesKey,
      );

      // Wire format: nonce(12) || ciphertext(N) || mac(16)
      final combined = Uint8List.fromList([
        ...secretBox.nonce,
        ...secretBox.cipherText,
        ...secretBox.mac.bytes,
      ]);

      return base64Encode(combined);
    } catch (e) {
      debugPrint('[CryptoService] ❌ Encrypt error: $e');
      rethrow;
    }
  }

  // ────────────────────────────────────────────────────────────────────────────
  // DECRYPT
  //
  // Exact inverse of encrypt():
  // 1. Decode Base64 → split into nonce / ciphertext / mac.
  // 2. Derive shared secret using sender's public key.
  // 3. Decrypt with AES-256-GCM — throws if the MAC is invalid (tampered data).
  // 4. Return the original plaintext string.
  // ────────────────────────────────────────────────────────────────────────────
  Future<String> decrypt(String encryptedBase64, String senderPublicKeyBase64) async {
    if (_keyPair == null) {
      throw StateError(
          '[CryptoService] decrypt() called before init(). '
          'Await CryptoService.init() at app startup.');
    }
    try {
      final combined = base64Decode(encryptedBase64);

      // Split according to the wire format
      const nonceLength = 12;
      const macLength = 16;
      final nonce = combined.sublist(0, nonceLength);
      final mac = combined.sublist(combined.length - macLength);
      final cipherText =
          combined.sublist(nonceLength, combined.length - macLength);

      // Reconstruct sender's public key
      final senderPublicKey = SimplePublicKey(
        base64Decode(senderPublicKeyBase64),
        type: KeyPairType.x25519,
      );

      // X25519 ECDH → shared secret (same result as the sender computed)
      final sharedSecret = await _x25519.sharedSecretKey(
        keyPair: _keyPair!,
        remotePublicKey: senderPublicKey,
      );
      final sharedSecretBytes = await sharedSecret.extractBytes();
      final aesKey = SecretKey(sharedSecretBytes);

      // AES-256-GCM decrypt — throws SecretBoxAuthenticationError if MAC fails
      final secretBox = SecretBox(
        cipherText,
        nonce: nonce,
        mac: Mac(mac),
      );
      final plainBytes = await _aesGcm.decrypt(secretBox, secretKey: aesKey);

      return utf8.decode(plainBytes);
    } catch (e) {
      debugPrint('[CryptoService] ❌ Decrypt error: $e');
      rethrow;
    }
  }

  // ────────────────────────────────────────────────────────────────────────────
  // HELPERS
  // ────────────────────────────────────────────────────────────────────────────

  /// Returns true if [candidatePublicKeyBase64] matches this device's public key.
  /// Used by the mesh router to decide: am I the final destination?
  bool isMyPublicKey(String candidatePublicKeyBase64) =>
      candidatePublicKeyBase64 == _publicKeyBase64;
}
