package com.example.yanshu

import android.Manifest
import android.bluetooth.BluetoothManager
import android.content.*
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.os.IBinder
import io.flutter.plugin.common.MethodCall
import com.wind.pnote.ui.DeviceDataListener
import com.wind.pnote.ui.PNote
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.lang.ref.WeakReference

/** Device control and opt-in live audio; no file transfer, Wi-Fi or firmware mutation. */
class SoniNoteBridge(private val context: Context, messenger: BinaryMessenger) : DeviceDataListener {
    // PNote stores its listener statically; do not let it retain a released Flutter engine.
    private class Relay(bridge: SoniNoteBridge) : DeviceDataListener {
        private val target = WeakReference(bridge)
        override fun onDeviceDataEvent(data: String?) { target.get()?.onDeviceDataEvent(data) }
        override fun onDeviceRecordData(data: ByteArray?) { target.get()?.onDeviceRecordData(data) }
        override fun onDeviceFileData(data: ByteArray?) { target.get()?.onDeviceFileData(data) }
    }
    private val relay = Relay(this)
    private val main = Handler(Looper.getMainLooper())
    private val methods = MethodChannel(messenger, "yanshu/soninote")
    private val events = EventChannel(messenger, "yanshu/soninote/events")
    private val audioEvents = EventChannel(messenger, "yanshu/soninote/audio")
    @Volatile private var audioSink: EventChannel.EventSink? = null
    private val audioQueued = java.util.concurrent.atomic.AtomicInteger(0)
    private var audioSequence = 0L
    private var appForeground = true
    private fun reportAppState() {
        if (initialized && sdkReady && connected && !closed) {
            // Firmware stops its live-audio notifications for SDK state 2.
            // An explicit meeting subscription is an active capture session,
            // maintained by our connected-device foreground service.
            PNote.sendAppShowState(if (appForeground || audioSink != null) 1 else 2)
        }
    }
    private var sink: EventChannel.EventSink? = null
    private var initialized = false
    private var sdkReady = false
    private var sdkServiceProbe: Any? = null
    private var controlProbe: io.reactivex.disposables.Disposable? = null
    private var commandHandler: MethodChannel.MethodCallHandler? = null
    private val waiting = mutableListOf<Pair<MethodCall, MethodChannel.Result>>()
    private val bindings = mutableMapOf<ServiceConnection, ServiceConnection>()
    private val sdkContext = object : ContextWrapper(context) {
        override fun bindService(intent: Intent, original: ServiceConnection, flags: Int): Boolean {
            val wrapped = object : ServiceConnection {
                override fun onServiceConnected(name: ComponentName, binder: IBinder) {
                    original.onServiceConnected(name, binder)
                    if ((context.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0) {
                        sdkServiceProbe = runCatching { binder.javaClass.getMethod("getService").invoke(binder) }.getOrNull()
                    }
                    sdkReady = true
                    val ready = waiting.toList(); waiting.clear()
                    ready.forEach { (call, result) -> commandHandler?.onMethodCall(call, result) }
                }
                override fun onServiceDisconnected(name: ComponentName) {
                    sdkReady = false; original.onServiceDisconnected(name)
                    emit("error", mapOf("code" to "sdk_service_lost", "message" to "设备服务已断开，请重新进入应用"), global = true)
                }
            }
            bindings[original] = wrapped
            return super.bindService(intent, wrapped, flags)
        }
        override fun unbindService(original: ServiceConnection) {
            super.unbindService(bindings.remove(original) ?: original)
        }
    }
    private var closed = false
    private var scanning = false
    private var scanRevision = 0L
    @Volatile private var epoch = 0
    private var deviceId: String? = null
    private var connected = false
    private var recovering = false
    private val discovered = mutableMapOf<String, String>()
    private var lastButton = ""
    private var lastButtonAt = 0L
    private var lastRecordingState = "unknown"
    private val bluetoothReceiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context?, intent: Intent?) {
            status()
            if (!enabled()) {
                scanning = false
                if (deviceId != null) emit("connection", mapOf("connected" to false))
                connected = false; recovering = false; deviceId = null
            }
        }
    }
    init {
        audioEvents.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) { audioSequence = 0; audioSink = events; reportAppState() }
            override fun onCancel(arguments: Any?) { audioSink = null; reportAppState() }
        })
        if (Build.VERSION.SDK_INT >= 33) context.registerReceiver(bluetoothReceiver,
            IntentFilter(android.bluetooth.BluetoothAdapter.ACTION_STATE_CHANGED), Context.RECEIVER_EXPORTED)
        else context.registerReceiver(bluetoothReceiver, IntentFilter(android.bluetooth.BluetoothAdapter.ACTION_STATE_CHANGED))
        events.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) { sink = events; status() }
            override fun onCancel(arguments: Any?) { sink = null }
        })
        commandHandler = MethodChannel.MethodCallHandler { call, result ->
            try {
                if (call.method == "androidApi") { result.success(Build.VERSION.SDK_INT); return@MethodCallHandler }
                if (call.method == "debugControlProbe") {
                    if ((context.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) == 0) {
                        result.error("debug_only", "仅调试包可用", null); return@MethodCallHandler
                    }
                    controlProbe?.dispose(); controlProbe = null
                    if (call.argument<Boolean>("enabled") == true) {
                        val service = sdkServiceProbe ?: error("SDK service unavailable")
                        fun field(name: String): Any? = service.javaClass.getDeclaredField(name).apply { isAccessible = true }.get(service)
                        val connection = field("rxBleConnection") as? com.polidea.rxandroidble2.RxBleConnection ?: error("BLE disconnected")
                        val characteristic = field("notifyBluetoothGattCharacteristic") as? android.bluetooth.BluetoothGattCharacteristic ?: error("Control characteristic unavailable")
                        controlProbe = connection.setupNotification(characteristic).flatMap { it }.subscribe({ bytes ->
                            val at = SystemClock.elapsedRealtime()
                            val hex = bytes.take(256).joinToString("") { "%02x".format(it.toInt() and 255) }
                            main.post { emit("control_packet_probe", mapOf("atMs" to at, "length" to bytes.size, "hex" to hex)) }
                        }, { main.post { emit("control_packet_probe", mapOf("error" to "control_probe_failed")) } })
                    }
                    result.success(null); return@MethodCallHandler
                }
                if (call.method == "status") { status(); result.success(null); return@MethodCallHandler }
                if (call.method == "stopScan" && !sdkReady) {
                    scanRevision++
                    scanning = false
                    val scans = waiting.filter { it.first.method == "startScan" }
                    waiting.removeAll(scans.toSet())
                    scans.forEach { (_, r) -> r.error("scan_cancelled", "扫描已停止", null) }
                    result.success(null); return@MethodCallHandler
                }
                if (call.method == "disconnect" && !sdkReady) {
                    // A connection queued behind SDK bindService must be cancelled
                    // before the service becomes ready, not replayed after dismissal.
                    val pending = waiting.filter { it.first.method == "connect" }
                    waiting.removeAll(pending.toSet())
                    pending.lastOrNull()?.first?.let {
                        epoch = it.argument<Int>("epoch") ?: 0
                        deviceId = it.argument<String>("device_id")
                    }
                    pending.forEach { (_, r) -> r.error("connect_cancelled", "连接已取消", null) }
                    if (deviceId != null) emit("connection", mapOf("connected" to false))
                    deviceId = null; connected = false; recovering = false
                    result.success(null); return@MethodCallHandler
                }
                if (!authorized()) { result.error("permission_denied", "请允许蓝牙权限", null); return@MethodCallHandler }
                if (!enabled()) { result.error("bluetooth_off", "请开启系统蓝牙", null); return@MethodCallHandler }
                if (!initialized) {
                    initialized = true
                    waiting.add(call to result)
                    PNote.setShowLog(false)
                    PNote.init(sdkContext, relay)
                    main.postDelayed({
                        if (!sdkReady) {
                            val expired = waiting.toList(); waiting.clear()
                            expired.forEach { (_, r) -> r.error("sdk_init_timeout", "设备服务初始化超时，请重新进入应用", null) }
                        }
                    }, 8000)
                    return@MethodCallHandler
                }
                if (!sdkReady) { result.error("sdk_not_ready", "设备服务未就绪，请稍后重试", null); return@MethodCallHandler }
                when (call.method) {
                    "startScan" -> {
                        check(deviceId == null && !recovering) { "connection_busy" }
                        scanRevision++; discovered.clear(); scanning = true; PNote.startSearch()
                    }
                    "stopScan" -> { scanRevision++; scanning = false; PNote.stopSearch() }
                    "connect" -> {
                        check(deviceId == null && !recovering) { "connection_busy" }
                        val id = call.argument<String>("device_id") ?: ""
                        val name = discovered[id] ?: throw IllegalArgumentException("device_not_discovered")
                        epoch = call.argument<Int>("epoch") ?: 0
                        deviceId = id; connected = false; lastButton = ""; scanning = false; lastRecordingState = "unknown"
                        PNote.stopSearch(); PNote.connectDevice(name, id)
                    }
                    "disconnect" -> {
                        recovering = true; scanning = false; PNote.stopSearch(); PNote.closeConnect()
                    }
                    else -> {
                        check(connected && !recovering) { "device_disconnected" }
                        when (call.method) {
                            "syncTime" -> PNote.syncTime()
                            "battery" -> PNote.getCBC()
                            "capacity" -> PNote.getDeviceCapacity()
                            "firmware" -> PNote.getDeviceVersion()
                            "firmwareCode" -> PNote.getDeviceVersionCode()
                            "listFiles" -> PNote.getRecordFileList()
                            "downloadFile" -> {
                                check(lastRecordingState == "idle") { "recording_busy" }
                                val name = call.argument<String>("name") ?: throw IllegalArgumentException("file_name")
                                val offset = call.argument<Int>("offset") ?: 0
                                check(name.isNotBlank() && offset >= 0)
                                PNote.startGetFile(name, offset)
                            }
                            "stopDownload" -> PNote.stopGetFile(call.argument<String>("name") ?: "")
                            "serial" -> PNote.getSn()
                            "recording" -> PNote.getRecordState()
                            "duration" -> PNote.getTimeOnlyRecording()
                            "startRecording" -> PNote.startRecord()
                            "pauseRecording" -> PNote.pauseRecord()
                            "resumeRecording" -> PNote.continueRecord()
                            "stopRecording" -> PNote.stopRecord()
                            "foreground" -> { appForeground = call.arguments == true; reportAppState() }
                            else -> { result.notImplemented(); return@MethodCallHandler }
                        }
                    }
                }
                result.success(null) // Submitted, never treated as hardware confirmation.
            } catch (_: Exception) {
                waiting.removeAll { it.second === result }
                result.error("sdk_command_failed", "设备命令未能提交，请检查连接后重试", null)
            }
        }
        methods.setMethodCallHandler(commandHandler)
    }
    private fun authorized(): Boolean {
        val needed = if (Build.VERSION.SDK_INT >= 31)
            listOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
        else listOf(Manifest.permission.ACCESS_FINE_LOCATION)
        return needed.all { context.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }
    }
    private fun enabled(): Boolean = try {
        context.getSystemService(BluetoothManager::class.java)?.adapter?.isEnabled == true
    } catch (_: SecurityException) { false }
    private fun status() = emit("bluetooth", mapOf("authorized" to authorized(), "enabled" to enabled()), global = true)
    private fun emit(type: String, data: Map<String, Any?>, global: Boolean = false, id: String? = deviceId) {
        if (closed) return
        sink?.success(mapOf("event_type" to type, "epoch" to if (global) 0 else epoch,
            "device_id" to id, "data" to data, "timestamp" to java.time.Instant.now().toString()))
    }
    private fun compatible(name: String) = Regex("^(CB08|SoniNote)(?:.*)$", RegexOption.IGNORE_CASE).matches(name)
    override fun onDeviceDataEvent(raw: String?) {
        // Capture current generation before posting, so queued callbacks from old sessions are rejected.
        val capturedEpoch = epoch
        val capturedScan = scanRevision
        main.post {
            if (closed || capturedEpoch != epoch || raw == null || raw.length > 4096) return@post
            try {
                val root = JSONObject(raw); val cmd = root.optString("cmd")
                val data = root.optJSONObject("data") ?: JSONObject()
                if (cmd !in setOf("1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "13", "17", "18")) {
                    if (connected && cmd.matches(Regex("[0-9]{1,3}")))
                        emit("diagnostic", mapOf("code" to "unsupported_sdk_event_$cmd"))
                    return@post
                }
                if (root.optString("state", "0") != "0") {
                    if (cmd == "2") { emit("connection", mapOf("connected" to false)); connected = false; deviceId = null; recovering = false }
                    else emit("error", mapOf("code" to "sdk_response_$cmd", "message" to "设备响应失败，请刷新状态"), global = cmd == "1")
                    return@post
                }
                if (cmd == "4") {
                    emit("files", mapOf("items" to (root.optJSONArray("data")?.toString() ?: "[]"), "finish" to root.optString("finish")))
                    return@post
                }
                if (cmd == "5") {
                    emit("file_state", mapOf("state" to data.optString("record_file_state"), "name" to data.optString("name")))
                    return@post
                }
                if (cmd == "1") {
                    if (capturedScan != scanRevision) return@post
                    val name = data.optString("name"); val id = data.optString("address")
                    if (!scanning || !compatible(name) || id.isEmpty() || id == "null") return@post
                    discovered[id] = name
                    emit("discovered", mapOf("name" to name, "productType" to data.optString("productType")), global = true, id = id)
                    return@post
                }
                if (deviceId == null) return@post
                if (cmd == "2") {
                    val id = data.optString("address")
                    if (id.isNotEmpty() && id != "null" && id != deviceId) return@post
                    val yes = data.optString("connect_state") in setOf("1", "true")
                    if (yes && recovering) { PNote.closeConnect(); return@post }
                    connected = yes
                    emit("connection", mapOf("connected" to yes))
                    if (!yes) { recovering = false; deviceId = null }
                    return@post
                }
                if (!connected || recovering) return@post
                when (cmd) {
                    "3" -> {
                        lastButton = ""
                        val state = when (data.optString("record_state")) { "0" -> "idle"; "1" -> "recording"; "2" -> "paused"; else -> "unknown" }
                        lastRecordingState = state
                        emit("recording", mapOf("state" to state, "saved" to (state == "idle"), "fileName" to data.optString("fileName")))
                    }
                    "9" -> {
                        // Documented query value 2 means not recording, not proof that a paused file was saved.
                        val state = when (data.optString("recordState")) {
                            "1" -> "recording"
                            "2" -> if (lastRecordingState == "paused") "paused" else "idle"
                            else -> "unknown"
                        }
                        if (lastRecordingState == "unknown") lastRecordingState = state
                        emit("recording", mapOf("state" to state, "query" to true))
                    }
                    "8" -> {
                        val button = data.optString("event"); val now = SystemClock.elapsedRealtime()
                        // Observe before protocol retransmission filtering. These are NOT
                        // physical click counts and must not directly trigger gestures.
                        emit("button_observed", mapOf("button" to button, "atMs" to now))
                        if (button == lastButton && now - lastButtonAt < 1200) return@post
                        lastButton = button; lastButtonAt = now
                        when (button) { "1" -> PNote.startBtnBackRecord(); "3" -> PNote.stopBtnBackRecord()
                            "5" -> PNote.pauseBtnBackRecord(); "7" -> PNote.continueBtnBackRecord(); else -> return@post }
                        emit("button", mapOf("button" to button))
                        // Wait for cmd 3 to confirm; never repeat the App recording command here.
                    }
                    else -> {
                        val pair = when (cmd) {
                            "6" -> "battery" to listOf("cbc")
                            "7" -> "serial" to listOf("sn")
                            "13" -> "capacity" to listOf("totalSpace", "residueSpace")
                            "17" -> "firmware" to listOf("version")
                            "18" -> "firmware_code" to listOf("versionCode")
                            else -> "duration" to listOf("recordTime")
                        }
                        emit(pair.first, pair.second.associateWith { key -> if (data.has(key)) data.optString(key) else null })
                    }
                }
            } catch (_: Exception) {
                emit("error", mapOf("code" to "malformed_sdk_event", "message" to "设备事件无法解析，请查询状态"))
            }
        }
    }
    override fun onDeviceRecordData(data: ByteArray?) {
        val listener = audioSink ?: return
        if (data == null || data.isEmpty() || closed) return
        val generation = epoch
        if (data.size > 4096 || audioQueued.incrementAndGet() > 128) {
            if (data.size <= 4096) audioQueued.decrementAndGet()
            main.post { if (audioSink === listener) { listener.error("audio_overrun", "录音卡音频接收积压，请重新连接", null); audioSink = null } }
            return
        }
        val copy = data.copyOf()
        main.post {
            audioQueued.decrementAndGet()
            if (!closed && connected && generation == epoch && audioSink === listener) {
                listener.success(mapOf("epoch" to generation, "device_id" to deviceId,
                    "sequence" to audioSequence++, "bytes" to copy))
            }
        }
    }
    override fun onDeviceFileData(data: ByteArray?) {
        if (data == null || data.isEmpty()) return
        val capturedEpoch = epoch
        val copy = data.copyOf()
        main.post { if (!closed && connected && capturedEpoch == epoch) emit("file_bytes", mapOf("bytes" to copy)) }
    }
    fun close() {
        if (initialized) { try { PNote.stopSearch(); PNote.closeConnect() } catch (_: Exception) {} }
        waiting.forEach { (_, r) -> r.error("sdk_closed", "设备服务已关闭", null) }; waiting.clear()
        if (initialized) { try { PNote.unBindService(sdkContext) } catch (_: Exception) {} }
        closed = true; sink = null; audioSink = null; methods.setMethodCallHandler(null); events.setStreamHandler(null); audioEvents.setStreamHandler(null)
        controlProbe?.dispose(); controlProbe = null; sdkServiceProbe = null
        main.removeCallbacksAndMessages(null)
        try { context.unregisterReceiver(bluetoothReceiver) } catch (_: Exception) {}
    }
}
