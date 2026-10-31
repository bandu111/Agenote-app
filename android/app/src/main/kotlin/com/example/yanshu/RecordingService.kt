package com.example.yanshu

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Bundle
import android.os.IBinder
import android.os.PowerManager
import android.provider.Settings
import android.graphics.drawable.Icon

/** Existing capture foreground service. Status updates never start it. */
class RecordingService : Service() {
    companion object {
        const val NOTIFICATION_ID = 7101
        private const val CHANNEL = "agenote_recording_status_v1"
        @Volatile var current: RecordingService? = null
        @Volatile private var presentation: Map<String, Any?>? = null
        fun updatePresentation(context: Context, data: Map<String, Any?>) {
            presentation = data
            current?.publish()
        }
        fun reconcileIdle(context: Context) {
            presentation = null
            val live = current
            if(live == null) context.getSystemService(NotificationManager::class.java).cancel(NOTIFICATION_ID)
            else live.publish() // A surviving native service is unknown, never falsely "recording".
        }
    }
    private var wakeLock: PowerManager.WakeLock? = null
    private fun notification(): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        if(Build.VERSION.SDK_INT >= 26) manager.createNotificationChannel(
            NotificationChannel(CHANNEL,"录音实时状态",NotificationManager.IMPORTANCE_DEFAULT).apply {
                description = "在锁屏显示当前录音状态和时长，点击返回会议"
                setSound(null, null)
                enableVibration(false)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            }
        )
        val data = presentation
        val id = data?.get("meetingId") as? String
        val launch = Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        if(id != null) launch.putExtra("agenote_meeting_id", id)
        val pending = PendingIntent.getActivity(this,71,launch,PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val builder = if(Build.VERSION.SDK_INT >= 26) Notification.Builder(this,CHANNEL) else Notification.Builder(this)
        val capturing = data?.get("capturing") == true
        val label = data?.get("stateLabel") as? String ?: "采音状态待核实"
        // Only source/status metadata is public; no transcript, meeting title or serial number.
        val source = (data?.get("sourceLabel") as? String)?.take(60) ?: "打开 Agenote 检查录音"
        val details = data?.get("details") as? Map<*, *>
        val rows = mutableListOf(if(data == null) source else source + " · " + (data["transcription"] as? String ?: ""))
        for((key, title) in listOf("audio" to "音频", "battery" to "电量", "storage" to "存储", "firmware" to "固件")) {
            val value = (details?.get(key) as? String)?.take(80)
            if(!value.isNullOrBlank()) rows.add("$title $value")
        }
        val text = rows.joinToString("\n")
        builder.setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setContentTitle("Agenote · $label").setContentText(text)
            .setContentIntent(pending).setOngoing(true).setOnlyAlertOnce(true)
            .setColor(0xFF065CFF.toInt()).setVisibility(Notification.VISIBILITY_PUBLIC)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setStyle(Notification.BigTextStyle().bigText(text))
        // Android 12+ otherwise defers some FGS notifications by about ten seconds.
        // Recording status is time-sensitive and must be visible as capture starts.
        if(Build.VERSION.SDK_INT >= 31) builder.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
        val elapsed = (data?.get("elapsedMs") as? Number)?.toLong() ?: 0L
        if(capturing) builder.setWhen(System.currentTimeMillis()-elapsed).setShowWhen(true).setUsesChronometer(true)
        else builder.setShowWhen(false).setUsesChronometer(false)
        // Public NotificationCompat extra (framework setter is 36.1+). No hidden API.
        // Public Android 16 API. Eligibility and actual promotion remain OS decisions.
        if(Build.VERSION.SDK_INT >= 36 && capturing) {
            builder.addExtras(Bundle().apply { putBoolean("android.requestPromotedOngoing", true) }).setShortCriticalText("录音中")
            if(!manager.canPostPromotedNotifications()) {
                val settings = Intent("android.settings.APP_NOTIFICATION_PROMOTION_SETTINGS")
                    .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                val fallback = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                    .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                val action = PendingIntent.getActivity(this,72,
                    if(settings.resolveActivity(packageManager) != null) settings else fallback,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
                builder.addAction(Notification.Action.Builder(
                    Icon.createWithResource(this, android.R.drawable.ic_menu_preferences),
                    "开启实时通知", action).build())
            }
        }
        return builder.build()
    }
    private fun publish() { getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, notification()) }
    override fun onCreate() { super.onCreate(); current = this }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if(intent == null) {stopSelf(); return START_NOT_STICKY}
        val type = if(intent.getBooleanExtra("externalDevice",false)) ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE else ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
        if(Build.VERSION.SDK_INT >= 29) startForeground(NOTIFICATION_ID,notification(),type) else startForeground(NOTIFICATION_ID,notification())
        if(wakeLock == null) wakeLock=(getSystemService(POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK,"$packageName:meeting").apply { acquire(4*60*60*1000L) }
        return START_NOT_STICKY
    }
    override fun onBind(intent: Intent?): IBinder? = null
    override fun onDestroy() {
        current=null;presentation=null
        wakeLock?.let {if(it.isHeld) it.release()};wakeLock=null
        if(Build.VERSION.SDK_INT >= 24) stopForeground(STOP_FOREGROUND_REMOVE) else @Suppress("DEPRECATION") stopForeground(true)
        super.onDestroy()
    }
}
