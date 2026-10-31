enum RecorderConnection { disconnected, connecting, connected, disconnecting }

enum RecorderState {
  unknown,
  idle,
  starting,
  recording,
  pausing,
  paused,
  resuming,
  stopping,
}

class RecorderDevice {
  const RecorderDevice(this.id, this.name, {this.productType});
  final String id, name;
  final String? productType;
}

class RecorderInfo {
  int? battery, totalKb, freeKb, firmwareCode, seconds;
  bool? charging;
  String? firmware, serialNumber;
  final Map<String, DateTime> observedAt = {};
  int? get usedKb =>
      totalKb != null && freeKb != null ? totalKb! - freeKb! : null;
  double? get usage => totalKb != null && totalKb! > 0 && usedKb != null
      ? usedKb! / totalKb!
      : null;
  static int? number(Object? value) => int.tryParse('$value');
  void update(String type, Map<String, dynamic> data) {
    if (type == 'battery') {
      final n = number(data['cbc']);
      charging = n == 110
          ? true
          : n != null && n >= 0 && n <= 100
          ? false
          : null;
      battery = n != null && n >= 0 && n <= 100 ? n : null;
    } else if (type == 'capacity') {
      final total = number(data['totalSpace']),
          free = number(data['residueSpace']);
      final valid =
          total != null &&
          free != null &&
          total > 0 &&
          free >= 0 &&
          free <= total;
      totalKb = valid ? total : null;
      freeKb = valid ? free : null;
    } else if (type == 'firmware') {
      firmware = cleanText(data['version']);
    } else if (type == 'firmware_code') {
      firmwareCode = number(data['versionCode']);
    } else if (type == 'duration') {
      final value = number(data['recordTime']);
      seconds = value != null && value >= 0 ? value : null;
    } else if (type == 'serial') {
      serialNumber = cleanText(data['sn']);
    }
    observedAt[type] = DateTime.now();
  }

  static String? cleanText(Object? raw) {
    final value = raw?.toString().trim();
    return value == null ||
            value.isEmpty ||
            const ['null', '<null>', 'undefined'].contains(value.toLowerCase())
        ? null
        : value;
  }
}

/// A local record is deliberately independent from the current BLE connection.
class SavedRecorderDevice {
  const SavedRecorderDevice({
    required this.recordId,
    required this.platform,
    required this.device,
    required this.addedAt,
    this.serialNumber,
    this.firmware,
    this.updatedAt,
    this.serialObservedAt,
    this.firmwareObservedAt,
    this.customName,
  });
  final String recordId, platform;
  final RecorderDevice device;
  final DateTime addedAt;
  final String? serialNumber, firmware;
  final String? customName;
  String get displayName => RecorderInfo.cleanText(customName) ?? 'AI Voice';
  final DateTime? updatedAt;
  final DateTime? serialObservedAt, firmwareObservedAt;
  SavedRecorderDevice withInfo(RecorderInfo info, {RecorderDevice? device}) =>
      SavedRecorderDevice(
        recordId: recordId,
        platform: platform,
        device: device ?? this.device,
        addedAt: addedAt,
        serialNumber: info.serialNumber ?? serialNumber,
        firmware: info.firmware ?? firmware,
        updatedAt: DateTime.now(),
        serialObservedAt: info.serialNumber == null
            ? serialObservedAt
            : info.observedAt['serial'] ?? serialObservedAt,
        firmwareObservedAt: info.firmware == null
            ? firmwareObservedAt
            : info.observedAt['firmware'] ?? firmwareObservedAt,
        customName: customName,
      );
  SavedRecorderDevice withName(String name) => SavedRecorderDevice(
    recordId: recordId,
    platform: platform,
    device: device,
    addedAt: addedAt,
    serialNumber: serialNumber,
    firmware: firmware,
    updatedAt: updatedAt,
    serialObservedAt: serialObservedAt,
    firmwareObservedAt: firmwareObservedAt,
    customName: name,
  );
  Map<String, Object?> toJson() => {
    'recordId': recordId,
    'platform': platform,
    'id': device.id,
    'name': device.name,
    'customName': customName,
    'productType': device.productType,
    'addedAt': addedAt.toIso8601String(),
    'sn': serialNumber,
    'firmware': firmware,
    'updatedAt': updatedAt?.toIso8601String(),
    'serialObservedAt': serialObservedAt?.toIso8601String(),
    'firmwareObservedAt': firmwareObservedAt?.toIso8601String(),
  };
  factory SavedRecorderDevice.fromJson(Map<String, dynamic> json) =>
      SavedRecorderDevice(
        recordId: json['recordId'] as String,
        platform: json['platform'] as String,
        device: RecorderDevice(
          json['id'] as String,
          json['name'] as String,
          productType: json['productType'] as String?,
        ),
        addedAt: DateTime.parse(json['addedAt'] as String),
        serialNumber: RecorderInfo.cleanText(json['sn']),
        firmware: RecorderInfo.cleanText(json['firmware']),
        customName: RecorderInfo.cleanText(json['customName']),
        updatedAt: DateTime.tryParse('${json['updatedAt']}'),
        serialObservedAt: DateTime.tryParse('${json['serialObservedAt']}'),
        firmwareObservedAt: DateTime.tryParse('${json['firmwareObservedAt']}'),
      );
}

class RecorderEvent {
  const RecorderEvent(
    this.type, {
    this.epoch = 0,
    this.deviceId,
    this.data = const {},
  });
  final String type;
  final int epoch;
  final String? deviceId;
  final Map<String, dynamic> data;
}

class RecorderFailure implements Exception {
  const RecorderFailure(this.code, this.message);
  final String code, message;
}
