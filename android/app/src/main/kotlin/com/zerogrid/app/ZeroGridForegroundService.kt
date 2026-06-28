package com.zerogrid.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat

/**
 * ZeroGridForegroundService
 *
 * An Android Foreground Service that keeps the Nearby Connections radio stack
 * alive when the app is minimised, the screen is locked, or the user switches
 * to another app.
 *
 * WHY A FOREGROUND SERVICE?
 * ─────────────────────────
 * Android aggressively kills background processes to conserve battery.
 * A Foreground Service is exempt from this because it holds a visible
 * persistent notification — the OS contract is: "as long as the user can see
 * this notification, the service is allowed to run indefinitely."
 *
 * HOW IT INTEGRATES WITH FLUTTER
 * ───────────────────────────────
 * The flutter_background_service plugin's Android implementation internally
 * starts THIS class (or its own built-in service).  We define this class so
 * that the notification text, icon, and channel are fully under our control.
 *
 * NOTIFICATION DESIGN
 * ────────────────────
 * Channel: ZEROGRID_MESH_CHANNEL (importance = LOW → no sound, no pop-up)
 * Text:    "ZeroGrid is active — protecting your mesh network"
 * Action:  Tap → brings the main activity to the foreground
 *
 * LIFECYCLE
 * ──────────
 *  onCreate  → create notification channel
 *  onStartCommand → call startForeground() with the notification
 *  onDestroy → service is being torn down; Nearby cleanup handled in Dart
 */
class ZeroGridForegroundService : Service() {

    companion object {
        private const val TAG = "ZeroGridService"
        const val CHANNEL_ID = "ZEROGRID_MESH_CHANNEL"
        const val CHANNEL_NAME = "ZeroGrid Mesh Service"
        const val NOTIFICATION_ID = 1001

        /** Starts the foreground service from any Context. */
        fun start(context: Context) {
            val intent = Intent(context, ZeroGridForegroundService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
            Log.d(TAG, "Foreground service start requested")
        }

        /** Stops the foreground service. */
        fun stop(context: Context) {
            context.stopService(Intent(context, ZeroGridForegroundService::class.java))
            Log.d(TAG, "Foreground service stop requested")
        }
    }

    // ── Service Lifecycle ─────────────────────────────────────────────────────

    override fun onCreate() {
        super.onCreate()
        Log.d(TAG, "onCreate()")
        createNotificationChannel()
    }

    /**
     * Called every time the service is (re)started.
     * START_STICKY = the OS will attempt to restart this service automatically
     * if it is killed due to memory pressure, passing a null Intent on restart.
     */
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.d(TAG, "onStartCommand() — promoting to foreground")
        startForeground(NOTIFICATION_ID, buildNotification())
        return START_STICKY
    }

    /** This is not a bound service; return null. */
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        super.onDestroy()
        Log.d(TAG, "onDestroy() — foreground service stopped")
        stopForeground(STOP_FOREGROUND_REMOVE)
    }

    // ── Notification ──────────────────────────────────────────────────────────

    /**
     * Notification channels are mandatory on Android 8.0+ (API 26+).
     * LOW importance = shown in the notification drawer with no sound or vibration.
     * This is the correct importance level for a persistent background service;
     * anything higher would be intrusive.
     */
    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                CHANNEL_NAME,
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "ZeroGrid mesh radio — keeps P2P connections alive in the background"
                setShowBadge(false)         // No badge dot on app icon
                enableLights(false)         // No notification light
                enableVibration(false)      // No vibration
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            }

            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(channel)
            Log.d(TAG, "Notification channel created")
        }
    }

    /**
     * Builds the persistent status-bar notification.
     *
     * Design:
     *   - Title:   "ZeroGrid Active"  (teal brand colour via tint)
     *   - Content: "Protecting your mesh network in the background"
     *   - Icon:    Uses Android's built-in wifi icon as placeholder.
     *              Replace R.drawable.ic_stat_zerogrid with a proper monochrome
     *              24×24dp notification icon in your res/drawable folder.
     *   - Tap:     Opens MainActivity (FLAG_IMMUTABLE required on API 31+)
     */
    private fun buildNotification(): Notification {
        val launchIntent = packageManager
            .getLaunchIntentForPackage(packageName)
            ?.apply { flags = Intent.FLAG_ACTIVITY_SINGLE_TOP }

        val pendingFlags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }

        val tapIntent = PendingIntent.getActivity(this, 0, launchIntent, pendingFlags)

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("ZeroGrid Active")
            .setContentText("Protecting your mesh network in the background")
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth) // Replace with custom icon
            .setColor(0xFF00E5FF.toInt())          // Cyber Teal tint
            .setColorized(false)
            .setOngoing(true)                      // Cannot be dismissed by user swipe
            .setSilent(true)                       // No sound on updates
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setContentIntent(tapIntent)
            .setForegroundServiceBehavior(
                NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE   // Show immediately, no delay
            )
            .build()
    }
}
