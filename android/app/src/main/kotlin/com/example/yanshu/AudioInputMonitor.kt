package com.example.yanshu

import android.content.Context
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.media.AudioRecordingConfiguration
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.BinaryMessenger

/** 只观察本应用的实际录音配置，不扫描其他账号或蓝牙设备。 */
class AudioInputMonitor(context: Context, messenger: BinaryMessenger) : EventChannel.StreamHandler {
    private val manager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val handler = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null
    private var listening = false
    private val methods = MethodChannel(messenger, "yanshu/audio_input")
    private val events = EventChannel(messenger, "yanshu/audio_input/events")
    private val callback = object : AudioManager.AudioRecordingCallback() {
        override fun onRecordingConfigChanged(configs: MutableList<AudioRecordingConfiguration>) {
            sink?.success(snapshot())
        }
    }

    init {
        methods.setMethodCallHandler { call, result ->
            if (call.method == "snapshot") result.success(snapshot()) else result.notImplemented()
        }
        events.setStreamHandler(this)
    }

    fun snapshot(): Map<String, Any> {
        // 普通应用只能获得自身的活动录音配置；停止/暂停时返回未核实。
        val config = manager.activeRecordingConfigurations.firstOrNull()
        val input = config?.audioDevice
        val type = when (input?.type) {
            AudioDeviceInfo.TYPE_BLUETOOTH_SCO, AudioDeviceInfo.TYPE_BLE_HEADSET -> "bluetooth"
            AudioDeviceInfo.TYPE_BUILTIN_MIC -> "builtIn"
            AudioDeviceInfo.TYPE_USB_DEVICE, AudioDeviceInfo.TYPE_USB_HEADSET,
            AudioDeviceInfo.TYPE_USB_ACCESSORY -> "usb"
            AudioDeviceInfo.TYPE_WIRED_HEADSET -> "wired"
            else -> "unknown"
        }
        return mapOf(
            "id" to (input?.id?.toString() ?: ""),
            "name" to (input?.productName?.toString() ?: ""),
            "type" to type,
            "verified" to (input != null && input.isSource),
            "sampleRate" to (config?.clientFormat?.sampleRate ?: 0),
            "channels" to (config?.clientFormat?.channelCount ?: 0),
            "silenced" to (Build.VERSION.SDK_INT >= 29 && config?.isClientSilenced == true)
        )
    }

    override fun onListen(arguments: Any?, eventSink: EventChannel.EventSink) {
        sink = eventSink
        manager.registerAudioRecordingCallback(callback, handler)
        listening = true
        sink?.success(snapshot())
    }

    override fun onCancel(arguments: Any?) {
        if (listening) manager.unregisterAudioRecordingCallback(callback)
        listening = false
        sink = null
    }

    fun close() {
        onCancel(null)
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
    }
}
