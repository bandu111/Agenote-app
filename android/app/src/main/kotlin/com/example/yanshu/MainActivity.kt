package com.example.yanshu

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.content.Intent
import android.os.Build

class MainActivity : FlutterActivity() {
    private var recordingActivity: RecordingActivityBridge? = null
    private var inputMonitor: AudioInputMonitor? = null
    private var recordingChannel: MethodChannel? = null
    private var localNotifications: LocalNotificationsBridge? = null
    private var calendarCompat: CalendarCompatBridge? = null
    private var soniNoteBridge: SoniNoteBridge? = null
    private var pdfInfoBridge: PdfInfoBridge? = null
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        recordingActivity = RecordingActivityBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        pdfInfoBridge = PdfInfoBridge(flutterEngine.dartExecutor.binaryMessenger)
        soniNoteBridge = SoniNoteBridge(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
        inputMonitor = AudioInputMonitor(this, flutterEngine.dartExecutor.binaryMessenger)
        localNotifications = LocalNotificationsBridge(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
        localNotifications?.open(intent)
        calendarCompat = CalendarCompatBridge(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
        recordingChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "yanshu/recording_background")
        recordingChannel?.setMethodCallHandler { call, result ->
            try {
                val intent = Intent(this, RecordingService::class.java)
                    .putExtra("externalDevice", call.argument<Boolean>("externalDevice") == true)
                when (call.method) {
                    "start" -> { if (Build.VERSION.SDK_INT >= 26) startForegroundService(intent) else startService(intent); result.success(null) }
                    "stop" -> { stopService(intent); result.success(null) }
                    else -> result.notImplemented()
                }
            } catch (error: Exception) { result.error("recording_service_unavailable", "后台录音服务未能启动", null) }
        }
    }
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        recordingActivity?.open(intent)
        localNotifications?.open(intent)
    }
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        recordingActivity?.permissionResult(requestCode, grantResults)
    }
    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        recordingActivity?.close()
        recordingActivity = null
        pdfInfoBridge?.close()
        pdfInfoBridge = null
        soniNoteBridge?.close()
        soniNoteBridge = null
        inputMonitor?.close()
        inputMonitor = null
        recordingChannel?.setMethodCallHandler(null)
        recordingChannel = null
        localNotifications?.close()
        localNotifications = null
        calendarCompat?.close()
        calendarCompat = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
