package io.github.kk339.lanlink

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log

/**
 * Keeps lanlink's process alive while the app is in the background.
 *
 * WHY THIS EXISTS (docs/13 §4, and the "在线一会儿就离线" report): discovery
 * timers, the multicast sockets and the resident HTTPS server all live in the
 * **one main Dart isolate**. Android freezes a *cached* app, so once the screen
 * goes off — or the user switches away — that isolate stops being scheduled, the
 * 5-second announcements stop going out, and every peer times us out as offline
 * after `offlineAfter`. A foreground service raises the process's importance so
 * the isolate keeps running. Same stack, same fix as LocalSend 1.18.0.
 *
 * The service type is `connectedDevice`, **not** `dataSync`: from Android 15 a
 * `dataSync` service is capped at a cumulative 6 hours per 24 (then `onTimeout`
 * → ANR if we do not stop), which is fatal for "stay reachable" (docs/13 §4).
 * `connectedDevice`'s runtime prerequisite is one of a set of permissions that
 * includes `CHANGE_WIFI_MULTICAST_STATE` — which this app already needs anyway.
 *
 * Lifespan: exactly the app's. `START_NOT_STICKY` (never resurrected without an
 * engine behind it) and `android:stopWithTask="true"` (removed with the task), so
 * it can never outlive the UI as an orphan notification. Nothing here runs from
 * device boot — there is no `BOOT_COMPLETED` receiver.
 */
class LanlinkForegroundService : Service() {

    companion object {
        private const val CHANNEL_ID = "lanlink.alive"
        private const val NOTIFICATION_ID = 0x1a11
        private const val LOG_TAG = "lanlink-fgs"

        /** Action that starts (or re-asserts) the foreground state. */
        const val ACTION_START = "io.github.kk339.lanlink.action.FGS_START"

        /** Action that stops the service. */
        const val ACTION_STOP = "io.github.kk339.lanlink.action.FGS_STOP"

        /** Whether the service currently holds the foreground state. */
        @Volatile
        var isRunning: Boolean = false
            private set

        /**
         * The last start failure, for the Dart side to surface ("起不来要能看见").
         * The service's own `startForeground` call happens after
         * `startForegroundService` has already returned to Dart, so a failure
         * there cannot be reported synchronously — this is the channel for it.
         */
        @Volatile
        var lastError: String? = null
            private set

        /** Builds an intent that [onStartCommand] understands. */
        fun intent(context: Context, action: String): Intent =
            Intent(context, LanlinkForegroundService::class.java).setAction(action)
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var multicastLock: WifiManager.MulticastLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }
        try {
            goForeground()
        } catch (error: Exception) {
            // e.g. ForegroundServiceStartNotAllowedException started from the
            // background, or a missing service-type declaration. Never silent:
            // record it for the Dart side and shut down cleanly.
            lastError = error.message ?: error.javaClass.simpleName
            Log.e(LOG_TAG, "startForeground failed: $lastError")
            stopSelf()
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        releaseLocks()
        removeForeground()
        isRunning = false
        super.onDestroy()
    }

    private fun goForeground() {
        if (isRunning) {
            return
        }
        ensureChannel()
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        acquireLocks()
        lastError = null
        isRunning = true
        Log.i(LOG_TAG, "foreground, wake lock held: ${wakeLock?.isHeld == true}")
    }

    /** Creates the notification channel once (no-op before API 26). */
    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }
        val manager =
            getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) != null) {
            return
        }
        val channel = NotificationChannel(
            CHANNEL_ID,
            "lanlink 后台运行",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "让 lanlink 在后台继续被其他设备发现、并继续收发文件"
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    /** The always-present "lanlink is running" notice. */
    private fun buildNotification(): Notification {
        val open = packageManager.getLaunchIntentForPackage(packageName)
        val builder = newBuilder()
        builder
            .setContentTitle("lanlink 正在后台运行")
            .setContentText("保持设备发现与文件互传")
            .setSmallIcon(android.R.drawable.stat_sys_download_done)
            .setOngoing(true)
        if (open != null) {
            builder.setContentIntent(
                PendingIntent.getActivity(
                    this,
                    0,
                    open,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                ),
            )
        }
        return builder.build()
    }

    /** A builder bound to [CHANNEL_ID] on API 26+, or the legacy one below it. */
    private fun newBuilder(): Notification.Builder =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            legacyBuilder()
        }

    @Suppress("DEPRECATION")
    private fun legacyBuilder(): Notification.Builder = Notification.Builder(this)

    /**
     * Takes the two locks whose absence breaks background work:
     *
     * * a `PARTIAL_WAKE_LOCK`, without which the CPU may still doze with the
     *   screen off and the announce timer stops — the very symptom being fixed;
     * * a `MulticastLock`, without which the Wi-Fi stack filters out the
     *   multicast announcements, so peers cannot find us (docs/13 §4).
     *
     * The multicast lock keeps the DEFAULT reference counting and shares
     * `MainActivity`'s `lanlink` tag, so this holder and the discovery layer's
     * coexist correctly. Both locks are released in [onDestroy], so they can
     * never outlive the service.
     */
    private fun acquireLocks() {
        if (wakeLock == null) {
            val power = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = power
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "$LOG_TAG:wake")
                .apply {
                    setReferenceCounted(false)
                    acquire()
                }
        }
        if (multicastLock == null) {
            val wifi = applicationContext
                .getSystemService(Context.WIFI_SERVICE) as? WifiManager
            // Tag `lanlink` and DEFAULT reference counting, matching
            // `MainActivity`'s lock: the two holders then share the one
            // framework-level Wi-Fi multicast lock correctly, so a release by
            // either only decrements its own reference. (With
            // `setReferenceCounted(false)` one release would turn multicast off
            // for the whole app while the other holder still thought it held
            // the lock — the "we can no longer see anyone" failure.)
            multicastLock = wifi?.createMulticastLock("lanlink")?.apply { acquire() }
        }
    }

    private fun releaseLocks() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        multicastLock?.let { if (it.isHeld) it.release() }
        multicastLock = null
    }

    @Suppress("DEPRECATION")
    private fun removeForeground() {
        stopForeground(true)
    }
}
