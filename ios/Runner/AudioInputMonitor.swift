import AVFoundation
import Flutter

/// 读取实际采音端口；耳机播放端口不能证明正在使用耳机麦克风。
final class AudioInputMonitor: NSObject, FlutterStreamHandler {
  private var observer: NSObjectProtocol?
  private var sink: FlutterEventSink?
  private let methods: FlutterMethodChannel
  private let events: FlutterEventChannel

  init(messenger: FlutterBinaryMessenger) {
    methods = FlutterMethodChannel(name: "yanshu/audio_input", binaryMessenger: messenger)
    events = FlutterEventChannel(name: "yanshu/audio_input/events", binaryMessenger: messenger)
    super.init()
    methods.setMethodCallHandler { [weak self] call, result in
      if call.method == "snapshot" { result(self?.snapshot() ?? [:]) }
      else { result(FlutterMethodNotImplemented) }
    }
    events.setStreamHandler(self)
  }

  private func snapshot() -> [String: Any] {
    let session = AVAudioSession.sharedInstance()
    let input = session.currentRoute.inputs.first
    let type: String
    switch input?.portType {
    case .bluetoothHFP, .bluetoothLE: type = "bluetooth"
    case .builtInMic: type = "builtIn"
    case .usbAudio: type = "usb"
    case .headsetMic: type = "wired"
    default: type = "unknown"
    }
    return ["id": input?.uid ?? "", "name": input?.portName ?? "",
            "type": type, "verified": input != nil, "silenced": false,
            "sampleRate": Int(session.sampleRate), "channels": session.inputNumberOfChannels]
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    observer = NotificationCenter.default.addObserver(
      forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      guard let self = self else { return }
      self.sink?(self.snapshot())
    }
    events(snapshot())
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    if let observer = observer { NotificationCenter.default.removeObserver(observer) }
    observer = nil
    sink = nil
    return nil
  }

  deinit {
    if let observer = observer { NotificationCenter.default.removeObserver(observer) }
  }
}
