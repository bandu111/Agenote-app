package com.example.yanshu

import android.Manifest
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import android.provider.CalendarContract
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/** 单日历 URI 兼容：按完整来源标记恢复，或按已绑定的原生事件 ID 回读；不扫无关日历。 */
class CalendarCompatBridge(private val context: Context, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "yanshu/calendar_compat")
    private val executor = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method !in setOf("read", "create", "deleteTestEvent", "deleteEmptyTestCalendar")) {
                result.notImplemented()
                return@setMethodCallHandler
            }
            executor.execute {
                try {
                    check(context.checkSelfPermission(Manifest.permission.READ_CALENDAR) == PackageManager.PERMISSION_GRANTED)
                    check(context.checkSelfPermission(Manifest.permission.WRITE_CALENDAR) == PackageManager.PERMISSION_GRANTED)
                    val args = call.arguments as Map<*, *>
                    val id = args["calendarId"].toString().toLong()
                    val marker = args["marker"] as String
                    require(marker.startsWith("[yanshu:") && marker.endsWith("]") && marker.length < 400)
                    val resolver = context.contentResolver
                    // 与旧插件的 calendars/{id} 查询不同，使用标准集合 URI 和参数化选择。
                    resolver.query(CalendarContract.Calendars.CONTENT_URI,
                        arrayOf(CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL), "_id = ?",
                        arrayOf(id.toString()), null).use { cursor ->
                        check(cursor != null && cursor.moveToFirst() && cursor.getInt(0) >= CalendarContract.Calendars.CAL_ACCESS_CONTRIBUTOR)
                    }
                    val existing = mutableListOf<Map<String, Any>>()
                    val columns = arrayOf(CalendarContract.Events._ID, CalendarContract.Events.TITLE,
                        CalendarContract.Events.DESCRIPTION, CalendarContract.Events.DTSTART, CalendarContract.Events.DTEND)
                    val requested = if (call.method == "read") (args["eventIds"] as? List<*>)?.map { it.toString() } else null
                    require(requested == null || requested.size <= 4 && requested.all { it.toLongOrNull() != null })
                    val hasIds = !requested.isNullOrEmpty()
                    val selection = if (hasIds) "calendar_id = ? AND _id IN (${requested!!.joinToString(",") { "?" }}) AND deleted = 0"
                        else "calendar_id = ? AND description LIKE ? AND deleted = 0"
                    val parameters = if (hasIds) (listOf(id.toString()) + requested!!).toTypedArray()
                        else arrayOf(id.toString(), "%$marker%")
                    resolver.query(CalendarContract.Events.CONTENT_URI, columns, selection, parameters, null).use { cursor ->
                        check(cursor != null)
                        while (cursor.moveToNext()) {
                            existing.add(mapOf("calendarId" to id.toString(), "eventId" to cursor.getLong(0).toString(),
                                "eventTitle" to (cursor.getString(1) ?: ""), "eventDescription" to (cursor.getString(2) ?: ""),
                                "eventStartDate" to cursor.getLong(3), "eventEndDate" to cursor.getLong(4),
                                "eventStartTimeZone" to "UTC", "eventEndTimeZone" to "UTC"))
                            check(existing.size <= 4)
                        }
                    }
                    val value: Any
                    if (call.method == "deleteEmptyTestCalendar") {
                        check(context.packageName.endsWith(".integration"))
                        resolver.query(CalendarContract.Calendars.CONTENT_URI,
                            arrayOf(CalendarContract.Calendars.CALENDAR_DISPLAY_NAME, CalendarContract.Calendars.ACCOUNT_NAME),
                            "_id = ?", arrayOf(id.toString()), null).use { cursor ->
                            check(cursor != null && cursor.moveToFirst() && cursor.getString(0) == "言枢" && cursor.getString(1) == "言枢")
                        }
                        resolver.query(CalendarContract.Events.CONTENT_URI, arrayOf(CalendarContract.Events._ID),
                            "calendar_id = ? AND deleted = 0", arrayOf(id.toString()), null).use { cursor ->
                            check(cursor != null && cursor.count == 0)
                        }
                        value = resolver.delete(CalendarContract.Calendars.CONTENT_URI, "_id = ?", arrayOf(id.toString()))
                    } else if (call.method == "deleteTestEvent") {
                        check(context.packageName.endsWith(".integration"))
                        value = resolver.delete(CalendarContract.Events.CONTENT_URI,
                            "calendar_id = ? AND description = ?", arrayOf(id.toString(), marker))
                    } else if (call.method == "read") {
                        value = existing.filter { requested.isNullOrEmpty() || requested.contains(it["eventId"]) }
                    } else {
                        val start = (args["start"] as Number).toLong()
                        val end = (args["end"] as Number).toLong()
                        val title = args["title"] as String
                        require(title.isNotBlank() && title.length <= 160 && end > start && end - start <= 86400000)
                        if (existing.isNotEmpty()) {
                            check(existing.size == 1 && existing[0]["eventTitle"] == title &&
                                existing[0]["eventStartDate"] == start && existing[0]["eventEndDate"] == end)
                            value = existing[0]["eventId"]!!
                        } else {
                            val values = ContentValues().apply {
                                put(CalendarContract.Events.CALENDAR_ID, id)
                                put(CalendarContract.Events.TITLE, title)
                                put(CalendarContract.Events.DESCRIPTION, marker)
                                put(CalendarContract.Events.DTSTART, start)
                                put(CalendarContract.Events.DTEND, end)
                                put(CalendarContract.Events.EVENT_TIMEZONE, "UTC")
                            }
                            val uri = resolver.insert(CalendarContract.Events.CONTENT_URI, values)
                            check(uri != null)
                            value = ContentUris.parseId(uri).toString()
                        }
                    }
                    main.post { result.success(value) }
                } catch (_: Exception) {
                    main.post { result.error("calendar_compat_unavailable", "系统日历操作未通过权限或回读检查", null) }
                }
            }
        }
    }
    fun close() {
        channel.setMethodCallHandler(null)
        executor.shutdown()
    }
}
