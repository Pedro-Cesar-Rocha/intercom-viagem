package com.pedrocesar.comboio

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.drawable.Icon
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/**
 * Serviço em primeiro plano: mantém o microfone, a CPU e o Wi-Fi ativos
 * enquanto a pessoa está na sala, inclusive com a tela apagada.
 */
class IntercomService : Service() {
    companion object {
        const val ACTION_START = "com.pedrocesar.comboio.action.START"
        const val ACTION_TOGGLE_MUTE = "com.pedrocesar.comboio.action.TOGGLE_MUTE"
        const val ACTION_LEAVE = "com.pedrocesar.comboio.action.LEAVE"
        private const val CHANNEL_ID = "comboio_intercom"
        private const val NOTIFICATION_ID = 4711
        private const val LOCK_TIMEOUT_MS = 12L * 60L * 60L * 1000L

        @Volatile
        var instance: IntercomService? = null

        @Volatile
        var actionListener: ((String) -> Unit)? = null
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private var lowLatencyLock: WifiManager.WifiLock? = null
    private var title = "Comboio"
    private var text = "Intercom ativo"
    private var muted = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_TOGGLE_MUTE -> {
                actionListener?.invoke("toggleMute")
                return START_NOT_STICKY
            }
            ACTION_LEAVE -> {
                actionListener?.invoke("leave")
                return START_NOT_STICKY
            }
        }
        if (intent != null) {
            title = intent.getStringExtra("title") ?: title
            text = intent.getStringExtra("text") ?: text
            muted = intent.getBooleanExtra("muted", muted)
        }
        val notification = buildNotification()
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (e: Exception) {
            stopSelf()
            return START_NOT_STICKY
        }
        acquireLocks()
        return START_NOT_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // O app foi fechado na lista de recentes: encerra a sessão.
        actionListener?.invoke("leave")
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        releaseLocks()
        instance = null
        try {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } catch (e: Exception) {
        }
        super.onDestroy()
    }

    fun update(newTitle: String, newText: String, newMuted: Boolean) {
        title = newTitle
        text = newText
        muted = newMuted
        try {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.notify(NOTIFICATION_ID, buildNotification())
        } catch (e: Exception) {
            // Sem permissão de notificação: o serviço segue funcionando.
        }
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Intercom ativo",
                NotificationManager.IMPORTANCE_LOW
            )
            channel.description = "Mostra quando o Comboio está na sala"
            channel.setShowBadge(false)
            nm.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(): Notification {
        val piFlags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        val launch = packageManager.getLaunchIntentForPackage(packageName)
            ?: Intent(this, MainActivity::class.java)
        launch.addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
        val contentIntent = PendingIntent.getActivity(this, 0, launch, piFlags)
        val muteIntent = PendingIntent.getService(
            this, 1,
            Intent(this, IntercomService::class.java).setAction(ACTION_TOGGLE_MUTE),
            piFlags
        )
        val leaveIntent = PendingIntent.getService(
            this, 2,
            Intent(this, IntercomService::class.java).setAction(ACTION_LEAVE),
            piFlags
        )
        val icon = Icon.createWithResource(this, R.drawable.ic_stat_comboio)
        val builder = newBuilder()
        builder
            .setSmallIcon(R.drawable.ic_stat_comboio)
            .setContentTitle(title)
            .setContentText(text)
            .setOngoing(true)
            .setShowWhen(false)
            .setContentIntent(contentIntent)
            .setCategory(Notification.CATEGORY_CALL)
            .addAction(
                Notification.Action.Builder(
                    icon,
                    if (muted) "Ativar microfone" else "Silenciar",
                    muteIntent
                ).build()
            )
            .addAction(Notification.Action.Builder(icon, "Sair", leaveIntent).build())
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
        }
        return builder.build()
    }

    @Suppress("DEPRECATION")
    private fun newBuilder(): Notification.Builder =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            Notification.Builder(this)
        }

    private fun acquireLocks() {
        try {
            if (wakeLock == null) {
                val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                val lock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "comboio:intercom")
                lock.setReferenceCounted(false)
                lock.acquire(LOCK_TIMEOUT_MS)
                wakeLock = lock
            }
            val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            if (wifiLock == null && Build.VERSION.SDK_INT < 34) {
                @Suppress("DEPRECATION")
                val lock = wm.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "comboio:wifi")
                lock.setReferenceCounted(false)
                lock.acquire()
                wifiLock = lock
            }
            if (lowLatencyLock == null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val lock = wm.createWifiLock(WifiManager.WIFI_MODE_FULL_LOW_LATENCY, "comboio:wifi-ll")
                lock.setReferenceCounted(false)
                lock.acquire()
                lowLatencyLock = lock
            }
        } catch (e: Exception) {
            // Sem as travas o app funciona, só com mais atraso em segundo plano.
        }
    }

    private fun releaseLocks() {
        try {
            wakeLock?.let { if (it.isHeld) it.release() }
        } catch (e: Exception) {
        }
        try {
            wifiLock?.let { if (it.isHeld) it.release() }
        } catch (e: Exception) {
        }
        try {
            lowLatencyLock?.let { if (it.isHeld) it.release() }
        } catch (e: Exception) {
        }
        wakeLock = null
        wifiLock = null
        lowLatencyLock = null
    }
}
