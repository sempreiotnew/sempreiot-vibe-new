package com.example.sempreiot_central_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/**
 * Keeps the central's process alive while the tablet is locked, the screen is
 * off or the app is not the one on screen.
 *
 * Without it the app is an ordinary activity: once the screen locks Android
 * stops the activity, the process becomes a cached process and (Android 12+)
 * is frozen — the usb_serial read thread, the Dart isolate with the MQTT
 * PINGREQ timer, the supervision watchdog, everything stops. The board loses
 * its ACKs and AWS IoT drops the session after 1.5 × keep-alive.
 *
 * A process with a foreground service is never cached, so it is never frozen.
 * The partial wake lock keeps the CPU running the Dart timers and the USB
 * reader with the screen off. The Flutter engine stays in this same process:
 * nothing of the SAFR pipeline moves here, this is only the shell that keeps
 * it running.
 *
 * Doze (screen off, unplugged, still) also cuts the network for every app
 * that is not exempt from battery optimisation; that exemption is not asked
 * for here (no dialog on the central, ever) — it is set once by
 * `tools/prepare_tablet.sh`. [MainActivity] reports whether it is in place.
 *
 * Type `connectedDevice` on purpose: it is the type for a USB-attached
 * peripheral, has no time limit, and the app already meets its Android 14
 * prerequisite (CHANGE_NETWORK_STATE). `dataSync` would be stopped by
 * Android 15 after 6 hours a day.
 *
 * No Wi-Fi lock: on Android 10+ the low-latency mode works only with the
 * app in the foreground, and the high-performance mode is a no-op since
 * Android 14. What keeps the socket alive is the wake lock plus the Doze
 * exemption.
 *
 * The notification is the one Android requires for a foreground service; it
 * is silent (IMPORTANCE_LOW) and, on Android 13+ without the notification
 * permission the app never asks for, not shown at all. The service runs the
 * same either way.
 */
class CentralLinkService : Service() {
    companion object {
        const val ACTION_STOP = "com.sempreiot.central.keepalive.STOP"
        private const val CHANNEL_ID = "central_link"
        private const val NOTIFICATION_ID = 1

        @Volatile
        var running: Boolean = false
            private set
    }

    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }
        startInForeground()
        acquireWakeLock()
        running = true
        return START_STICKY
    }

    override fun onDestroy() {
        running = false
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        super.onDestroy()
    }

    private fun startInForeground() {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val builder: Notification.Builder
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Ligação com a placa",
                NotificationManager.IMPORTANCE_LOW,
            )
            channel.setShowBadge(false)
            manager.createNotificationChannel(channel)
            builder = Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            builder = Notification.Builder(this)
        }
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val notification = builder
            .setContentTitle("SempreIoT Central")
            .setContentText("Ligada à placa e à nuvem")
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentIntent(open)
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun acquireWakeLock() {
        if (wakeLock != null) return
        val power = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "sempreiot:central-link")
            .apply {
                setReferenceCounted(false)
                acquire()
            }
    }
}
