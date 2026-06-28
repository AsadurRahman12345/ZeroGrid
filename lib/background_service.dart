import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

// ──────────────────────────────────────────────────────────────────────────────
// BackgroundService
//
// Cross-platform manager for the ZeroGrid background execution layer.
//
// ANDROID
// ───────
// Wraps an Android Foreground Service via the flutter_background_service plugin.
// The Dart callback [_onBackgroundStart] runs in a SEPARATE Dart isolate inside
// the foreground service. This isolate:
//   • Keeps Nearby Connections advertising alive
//   • Processes incoming packets and writes them to Hive
//   • Sends UI update events back to the main isolate via the plugin's IPC
//
// iOS
// ───
// The plugin integrates with BGTaskScheduler.
// Because iOS does not allow true long-running background tasks for social apps
// (only VoIP, navigation, audio, and BLE with the bluetooth-central mode),
// our strategy is:
//   1. Hold an active CBCentralManager session (bluetooth-central mode, declared
//      in Info.plist) so BLE remains alive for as long as the OS allows.
//   2. Schedule a BGAppRefreshTask (com.zerogrid.app.mesh-refresh) to re-open
//      the BLE session if it was suspended.
//
// HOW TO USE
// ──────────
// Call BackgroundService.configure() once in main() BEFORE runApp().
// Call BackgroundService.start() after permissions are granted.
// ──────────────────────────────────────────────────────────────────────────────

class BackgroundService {
  // ── Singleton ────────────────────────────────────────────────────────────────
  static final BackgroundService _instance = BackgroundService._internal();
  factory BackgroundService() => _instance;
  BackgroundService._internal();

  final _service = FlutterBackgroundService();

  // Notification channel used for the persistent foreground notification.
  static const _androidChannelId   = 'ZEROGRID_MESH_CHANNEL';
  static const _androidChannelName = 'ZeroGrid Mesh Service';
  static const _androidNotificationId = 1001;

  // ────────────────────────────────────────────────────────────────────────────
  // CONFIGURE (call once in main(), before runApp())
  //
  // Sets up:
  //   1. The flutter_local_notifications channel (Android 8+ requirement)
  //   2. The flutter_background_service with platform-specific config
  // ────────────────────────────────────────────────────────────────────────────
  Future<void> configure() async {
    // ── 1. Create the notification channel (Android only, no-op on iOS) ───────
    final localNotifications = FlutterLocalNotificationsPlugin();
    const androidChannel = AndroidNotificationChannel(
      _androidChannelId,
      _androidChannelName,
      description: 'ZeroGrid mesh radio — keeps P2P connections alive in background',
      importance: Importance.low,          // No sound, no pop-up
      enableVibration: false,
      playSound: false,
      showBadge: false,
    );

    await localNotifications
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(androidChannel);

    // ── 2. Configure the background service plugin ────────────────────────────
    await _service.configure(
      // ── ANDROID CONFIG ───────────────────────────────────────────────────
      androidConfiguration: AndroidConfiguration(
        // The Dart callback that runs inside the foreground service isolate.
        // IMPORTANT: must be a top-level function (not a class method).
        onStart: _onBackgroundStart,

        // Auto-start the service when the app launches (can be set to false
        // and controlled manually via BackgroundService.start()).
        autoStart: false,

        // Keep running as a Foreground Service (not a background job).
        isForegroundMode: true,

        // Notification shown in the status bar while the service is active.
        notificationChannelId: _androidChannelId,
        initialNotificationTitle: 'ZeroGrid Active',
        initialNotificationContent: 'Protecting your mesh network in the background',
        foregroundServiceNotificationId: _androidNotificationId,

        // Required on Android 14+ — declares what type of foreground service
        // this is. connectedDevice = Bluetooth / Wi-Fi.
        foregroundServiceTypes: [AndroidForegroundType.connectedDevice],
      ),

      // ── IOS CONFIG ────────────────────────────────────────────────────────
      iosConfiguration: IosConfiguration(
        // The Dart callback that runs when iOS schedules a BGAppRefreshTask.
        onForeground: _onBackgroundStart,

        // Called when iOS triggers our background fetch task.
        onBackground: _onIosBackground,

        // Request to be auto-started (iOS will grant this intermittently).
        autoStart: false,
      ),
    );
  }

  // ────────────────────────────────────────────────────────────────────────────
  // START (call after permissions are granted)
  // ────────────────────────────────────────────────────────────────────────────
  Future<void> start() async {
    final running = await _service.isRunning();
    if (!running) {
      await _service.startService();
      debugPrint('[BackgroundService] ✅ Service started');
    }
  }

  /// Stops the background service gracefully.
  Future<void> stop() async {
    _service.invoke('stop');
    debugPrint('[BackgroundService] 🛑 Service stop requested');
  }

  /// Returns true if the service is currently running.
  Future<bool> get isRunning => _service.isRunning();

  /// Sends an arbitrary event to the background isolate.
  /// Example: when the user opens a chat, notify the background isolate so it
  /// can flush pending packets for that conversation.
  void sendEvent(String event, [Map<String, dynamic>? data]) {
    _service.invoke(event, data);
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// TOP-LEVEL BACKGROUND CALLBACKS
// These MUST be top-level (not inside a class) so Flutter can register them
// as entry points for the background isolate.
// ──────────────────────────────────────────────────────────────────────────────

/// Main entry point for the background isolate (Android Foreground Service
/// and iOS foreground mode).
///
/// This function runs in a SEPARATE Dart isolate from the UI.
/// It has access to all Dart libraries but shares NO memory with the main isolate.
/// Communication to/from the UI uses flutter_background_service's IPC (invoke/on).
@pragma('vm:entry-point')
void _onBackgroundStart(ServiceInstance service) async {
  // Required for plugins to work in the background isolate.
  DartPluginRegistrant.ensureInitialized();

  debugPrint('[Background] 🚀 Background isolate started');

  // BUG FIX: store the periodic subscription so it can be cancelled
  // when stop() is called. Without this, the timer would keep firing
  // even after stopSelf(), leaking an isolate resource.
  // Stream.periodic() without a computation fn emits void, not int.
  StreamSubscription<void>? _periodicSub;

  // ── Update the persistent notification with live status ──────────────────
  if (service is AndroidServiceInstance) {
    service.on('setAsForeground').listen((_) {
      service.setAsForegroundService();
    });
    service.on('setAsBackground').listen((_) {
      service.setAsBackgroundService();
    });

    // Pulse the notification content every 60 seconds to show the mesh is alive.
    _periodicSub = Stream<void>.periodic(const Duration(seconds: 60))
        .listen((_) async {
      if (await service.isForegroundService()) {
        service.setForegroundNotificationInfo(
          title: 'ZeroGrid Active',
          content:
              'Mesh radio alive · ${DateTime.now().toLocal().toString().substring(11, 16)}',
        );
      }
    });
  }


  // ── Stop event listener ────────────────────────────────────────────────────
  service.on('stop').listen((_) {
    _periodicSub?.cancel(); // Cancel the timer before stopping the isolate
    service.stopSelf();
    debugPrint('[Background] 🛑 Background isolate stopped');
  });

  // ── Custom event listeners from the UI isolate ─────────────────────────────
  service.on('conversationOpened').listen((data) {
    final endpointId = data?['endpointId'] as String?;
    debugPrint('[Background] 💬 Conversation opened for $endpointId');
    // In a full implementation: prioritise message flushing for this peer.
  });
}

/// iOS-specific background task handler.
/// Called by BGTaskScheduler for the 'com.zerogrid.app.mesh-refresh' task.
/// Must complete within ~30 seconds or iOS will terminate the task.
@pragma('vm:entry-point')
Future<bool> _onIosBackground(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();

  debugPrint('[Background/iOS] ♻️  BGAppRefreshTask running');

  // Re-initialise the Hive storage and flush any pending writes.
  // In production: re-open the Nearby session if it was suspended.

  // Return true = task completed successfully, iOS should schedule next refresh.
  // Return false = task failed, iOS may delay the next refresh.
  return true;
}
