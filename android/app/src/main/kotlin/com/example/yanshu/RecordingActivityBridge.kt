package com.example.yanshu

import android.Manifest
import android.app.Notification
import android.app.NotificationManager
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/** Local status only: no push SDK and no starting a microphone/service here. */
class RecordingActivityBridge(private val activity: FlutterActivity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "agenote/recording_activity")
    private var lastSequence = 0L
    private var pendingMeeting: String? = null
    private var notificationPrompted = false
    private var offerPromotionAfterPermission = false
    private fun offerPromotionSettingsOnce() {
        if (Build.VERSION.SDK_INT < 36 || activity.getSystemService(NotificationManager::class.java).canPostPromotedNotifications()) return
        val preferences = activity.getSharedPreferences("agenote_recording_status", android.content.Context.MODE_PRIVATE)
        if(preferences.getBoolean("promotion_guidance_shown", false)) return
        channel.invokeMethod("showPermissionGuide", mapOf("platform" to "android"), object : MethodChannel.Result {
            override fun success(result: Any?) {
                preferences.edit().putBoolean("promotion_guidance_shown", true).apply()
                if(result == true) openPromotionSettings()
            }
            override fun error(code: String, message: String?, details: Any?) {}
            override fun notImplemented() {}
        })
    }

    private fun openPromotionSettings() {
        if (Build.VERSION.SDK_INT < 36) return
        val intent = Intent("android.settings.APP_NOTIFICATION_PROMOTION_SETTINGS")
            .putExtra(Settings.EXTRA_APP_PACKAGE, activity.packageName)
        val fallback = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
            .putExtra(Settings.EXTRA_APP_PACKAGE, activity.packageName)
        activity.startActivity(if(intent.resolveActivity(activity.packageManager) != null) intent else fallback)
    }
    private fun offerRecordingNotifications() {
        if(notificationPrompted || !activity.hasWindowFocus() || Build.VERSION.SDK_INT < 33) return
        notificationPrompted = true
        if(activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            offerPromotionAfterPermission = true
            activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 7199)
        } else {
            offerPromotionSettingsOnce()
        }
    }
    fun permissionResult(requestCode: Int, grantResults: IntArray) {
        if(requestCode != 7199) return
        val offer = offerPromotionAfterPermission
        offerPromotionAfterPermission = false
        if(offer && grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED && Build.VERSION.SDK_INT >= 36 &&
            !activity.getSystemService(NotificationManager::class.java).canPostPromotedNotifications()) offerPromotionSettingsOnce()
    }
    init {
        channel.setMethodCallHandler { call, result ->
            try {
                when(call.method) {
                    "capabilities" -> result.success(capabilities())
                    "permissionSettings" -> result.success(mapOf(
                        "androidApi" to Build.VERSION.SDK_INT,
                        "liveActivitiesSupported" to (Build.VERSION.SDK_INT >= 36),
                        "liveActivitiesAllowed" to (Build.VERSION.SDK_INT >= 36 && activity.getSystemService(NotificationManager::class.java).canPostPromotedNotifications())
                        // OEM lock-screen switches have no portable public read API.
                    ))
                    "openNotificationSettings" -> {
                        val intent = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                            .putExtra(Settings.EXTRA_APP_PACKAGE, activity.packageName)
                        activity.startActivity(intent)
                        result.success(true)
                    }
                    "takeOpenMeeting" -> { result.success(pendingMeeting); pendingMeeting = null }
                    "requestNotifications" -> {
                        if (Build.VERSION.SDK_INT >= 33 && activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                            activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 7199)
                        }
                        result.success(null)
                    }
                    "requestLiveUpdates" -> {
                        openPromotionSettings()
                        result.success(Build.VERSION.SDK_INT >= 36)
                    }
                    "sync" -> {
                        val data = (call.arguments as? Map<*, *>)?.entries?.filter { it.key is String }?.associate { it.key as String to it.value }
                        if(data == null) { RecordingService.reconcileIdle(activity) }
                        else {
                            val id = data["meetingId"] as? String
                            val seq = (data["sequence"] as? Number)?.toLong() ?: 0L
                            if(id == null || !id.matches(Regex("[a-zA-Z0-9_-]{1,128}"))) {
                                result.error("invalid_meeting", "无效会议", null); return@setMethodCallHandler
                            }
                            if(seq > lastSequence) {
                                lastSequence = seq; RecordingService.updatePresentation(activity, data)
                                if(data["capturing"] == true) offerRecordingNotifications()
                            }
                        }
                        result.success(capabilities())
                    }
                    else -> result.notImplemented()
                }
            } catch (_: Exception) { result.error("status_unavailable", "系统录音状态展示暂不可用", null) }
        }
        open(activity.intent)
    }
    fun open(intent: Intent?) {
        val id = intent?.getStringExtra("agenote_meeting_id") ?: return
        if(!id.matches(Regex("[a-zA-Z0-9_-]{1,128}"))) return
        pendingMeeting = id
        channel.invokeMethod("openMeeting", id)
        intent.removeExtra("agenote_meeting_id")
    }
    private fun capabilities(): Map<String, Any> {
        val manager = activity.getSystemService(NotificationManager::class.java)
        val allowed = Build.VERSION.SDK_INT < 24 || manager.areNotificationsEnabled()
        val promotedAllowed = Build.VERSION.SDK_INT >= 36 && manager.canPostPromotedNotifications()
        val posted = if(Build.VERSION.SDK_INT >= 23) manager.activeNotifications.firstOrNull { it.id == RecordingService.NOTIFICATION_ID }?.notification else null
        val promoted = Build.VERSION.SDK_INT >= 36 && posted != null && posted.flags and Notification.FLAG_PROMOTED_ONGOING != 0
        return mapOf("platform" to "android", "notificationsAllowed" to allowed,
            "liveUpdatesApi" to (Build.VERSION.SDK_INT >= 36), "promotedAllowed" to promotedAllowed,
            "promotableCharacteristics" to (Build.VERSION.SDK_INT >= 36 && posted != null && posted.hasPromotableCharacteristics()),
            "promoted" to promoted, "serviceRunning" to (RecordingService.current != null),
            "presentation" to if(promoted) "liveUpdate" else if(posted != null && allowed) "ongoingNotification" else "inAppOnly")
    }
    fun close() { channel.setMethodCallHandler(null) }
}
