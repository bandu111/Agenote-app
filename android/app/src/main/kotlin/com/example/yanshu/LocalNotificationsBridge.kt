package com.example.yanshu

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/** 仅本地通知，账号和清除状态双重核对，不触碰录音前台服务通知。 */
class LocalNotificationsBridge(private val context: Context, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "agenote/local-notifications")
    private val prefs = context.getSharedPreferences("agenote_local_notices", Context.MODE_PRIVATE)
    private val manager = context.getSystemService(NotificationManager::class.java)
    private val tagPrefix = "agenote-actions:"
    private fun permissionGranted() = (Build.VERSION.SDK_INT < 33 || context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) &&
        (Build.VERSION.SDK_INT < 24 || manager.areNotificationsEnabled()) && (Build.VERSION.SDK_INT < 26 || manager.getNotificationChannel("agenote_actions_v1")?.importance != NotificationManager.IMPORTANCE_NONE)
    private fun owned(tag: String?) = tag == "agenote-actions" || tag?.startsWith(tagPrefix) == true
    init {
        channel.setMethodCallHandler { call, result ->
            try {
                val owner = call.argument<String>("owner")
                when (call.method) {
                    "configure" -> {
                        val enabled = call.argument<Boolean>("enabled") == true
                        if (owner != prefs.getString("owner", null) || !enabled) clear()
                        if (owner != prefs.getString("owner", null)) prefs.edit().remove("opened").apply()
                        prefs.edit().putString("owner", owner).putBoolean("enabled", enabled).apply()
                        if (Build.VERSION.SDK_INT >= 26) manager.createNotificationChannel(
                            NotificationChannel("agenote_actions_v1", "待补全与风险", NotificationManager.IMPORTANCE_DEFAULT)
                                .apply { description = "仅提示需要补全的事项和明确风险" })
                        result.success(null)
                    }
                    "sync" -> {
                        if (owner == prefs.getString("owner", null)) {
                            val ids = call.argument<List<String>>("ids").orEmpty().map { tagPrefix + it }.toSet()
                            val badge = (call.argument<Int>("badge") ?: 0).coerceAtLeast(0)
                            prefs.edit().putInt("badge", badge).apply()
                            manager.activeNotifications.filter { owned(it.tag) }.forEach {
                                if (it.tag !in ids) manager.cancel(it.tag, it.id)
                                else if (it.notification.number != badge) {
                                    val builder = if (Build.VERSION.SDK_INT >= 24) Notification.Builder.recoverBuilder(context, it.notification)
                                    else Notification.Builder(context).setSmallIcon(it.notification.smallIcon)
                                        .setContentTitle(it.notification.extras.getCharSequence(Notification.EXTRA_TITLE))
                                        .setContentText(it.notification.extras.getCharSequence(Notification.EXTRA_TEXT))
                                        .setContentIntent(it.notification.contentIntent).setAutoCancel(true)
                                    manager.notify(it.tag, it.id, builder.setNumber(badge).setOnlyAlertOnce(true).build())
                                }
                            }
                        }
                        result.success(null)
                    }
                    "show" -> {
                        if (owner == null || owner != prefs.getString("owner", null) || !prefs.getBoolean("enabled", false)
                            || !permissionGranted()) result.success(false)
                        else {
                            val id = call.argument<String>("id").orEmpty()
                            // 完整字符串 tag + 固定 int 构成通知身份，避免 32 位 hash 碰撞。
                            // PendingIntent 以完整 action 区分；不用 data，避免触发 Flutter 深链。
                            val intent = Intent(context, MainActivity::class.java)
                                .setAction("agenote.local-notice:" + android.net.Uri.encode(owner) + ":" + android.net.Uri.encode(id))
                                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                                .putExtra("agenoteNoticeOwner", owner)
                            val pending = PendingIntent.getActivity(context, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
                            val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(context, "agenote_actions_v1") else Notification.Builder(context)
                            val title = call.argument<String>("title").orEmpty()
                            val body = call.argument<String>("body").orEmpty()
                            manager.notify(tagPrefix + id, 0, builder.setSmallIcon(android.R.drawable.ic_dialog_info)
                                .setContentTitle(title).setContentText(body).setStyle(Notification.BigTextStyle().bigText(body))
                                .setContentIntent(pending).setAutoCancel(true).setOnlyAlertOnce(call.argument<Boolean>("silent") == true)
                                .setVisibility(Notification.VISIBILITY_PRIVATE).setNumber(call.argument<Int>("badge") ?: 0).build())
                            result.success(true)
                        }
                    }
                    "status" -> {
                        val granted = permissionGranted()
                        result.success(mapOf("permissionGranted" to granted,
                            "activeCount" to manager.activeNotifications.count { owned(it.tag) },
                            "activeIds" to manager.activeNotifications.filter { it.tag?.startsWith(tagPrefix) == true }.map { it.tag!!.removePrefix(tagPrefix) }, "badge" to prefs.getInt("badge", 0)))
                    }
                    "takeOpen" -> {
                        result.success(prefs.getString("opened", null))
                        prefs.edit().remove("opened").apply()
                    }
                    else -> result.notImplemented()
                }
            } catch (_: Exception) { result.error("local_notification_unavailable", "本地通知暂不可用", null) }
        }
    }
    private fun clear() { manager.activeNotifications.filter { owned(it.tag) }.forEach { manager.cancel(it.tag, it.id) }; prefs.edit().putInt("badge", 0).apply() }
    fun open(intent: Intent?) {
        val owner = intent?.getStringExtra("agenoteNoticeOwner") ?: return
        intent.removeExtra("agenoteNoticeOwner")
        if (owner == prefs.getString("owner", null) && prefs.getBoolean("enabled", false)) {
            prefs.edit().putString("opened", owner).apply()
            channel.invokeMethod("opened", owner)
        }
    }
    fun close() { channel.setMethodCallHandler(null) }
}
