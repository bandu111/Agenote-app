import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/features/meeting/meeting_models.dart';
import 'package:yanshu/features/offline_recordings/card_file_transport.dart';
import 'package:yanshu/features/offline_recordings/offline_recordings_model.dart';

void main() {
  test(
    'card list metadata accepts SDK numeric strings and keeps file identity',
    () {
      final recording = CardRecording.parse({
        'name': '20261029103000.opus',
        'size': '24000',
        'time': '600',
      });
      expect(recording.name, '20261029103000.opus');
      expect(recording.bytes, 24000);
      expect(recording.seconds, 600);
    },
  );
  test(
    'invalid or excessively large recordings are rejected before downloading',
    () {
      for (final value in [
        {'name': '', 'size': 40, 'time': 1},
        {'name': 'a', 'size': -1, 'time': 1},
        {'name': 'a', 'size': 0, 'time': 1},
        {'name': 'a', 'size': 512 * 1024 * 1024 + 1, 'time': 1},
        {'name': 'a', 'size': 40, 'time': -1},
        {'name': 'a', 'size': 'corrupt', 'time': 1},
      ]) {
        expect(() => CardRecording.parse(value), throwsFormatException);
      }
    },
  );
  test(
    'stable offline identity isolates owners, devices and file revisions',
    () {
      final id = offlineRecordingId('owner-a', 'sn-a', 'file.opus', 100);
      expect(offlineRecordingId('owner-a', 'sn-a', 'file.opus', 100), id);
      expect(
        offlineRecordingId('owner-b', 'sn-a', 'file.opus', 100),
        isNot(id),
      );
      expect(
        offlineRecordingId('owner-a', 'sn-b', 'file.opus', 100),
        isNot(id),
      );
      expect(
        offlineRecordingId('owner-a', 'sn-a', 'file.opus', 101),
        isNot(id),
      );
      expect(id, matches(RegExp(r'^offline-[a-f0-9]{40}$')));
    },
  );
  test(
    'identity uses unambiguous fields even when values contain separators',
    () {
      expect(
        offlineRecordingId('a:b', 'c', 'f', 1),
        isNot(offlineRecordingId('a', 'b:c', 'f', 1)),
      );
    },
  );
  test(
    'queue restart resets interrupted operations but preserves exclusions and completion',
    () {
      final source = OfflineRecording(
        id: 'id',
        name: 'recording',
        deviceId: 'sn',
        size: 100,
        seconds: 10,
        startedAt: DateTime.utc(2026, 10, 29),
        state: 'uploading',
        excluded: true,
        meetingId: 'meeting',
      );
      final restored = OfflineRecording.fromJson(
        jsonDecode(jsonEncode(source.toJson())) as Map,
      );
      expect(restored.state, 'waiting');
      expect(restored.excluded, isTrue);
      expect(restored.meetingId, 'meeting');
      source.state = 'complete';
      expect(OfflineRecording.fromJson(source.toJson()).complete, isTrue);
    },
  );
  test(
    'meeting persistence retains manual sync consent and original card identity',
    () {
      final record = MeetingRecord(
        id: 'id',
        startedAt: DateTime.utc(2026, 10, 29),
        demo: false,
        ownerId: 'a',
        ended: true,
        offlineSyncHeld: true,
        recordingCardIdentity: 'sn',
        recordingCardFileName: 'original.opus',
      );
      final restored = MeetingRecord.fromJson(
        jsonDecode(jsonEncode(record.toJson())) as Map<String, dynamic>,
      );
      expect(restored.offlineSyncHeld, isTrue);
      expect(restored.recordingCardIdentity, 'sn');
      expect(restored.recordingCardFileName, 'original.opus');
      expect(restored.copy(offlineSyncHeld: false).offlineSyncHeld, isFalse);
      expect(restored.copy().recordingCardFileName, 'original.opus');
    },
  );
  test('legacy meetings remain compatible without new offline fields', () {
    final json =
        MeetingRecord(
            id: 'id',
            startedAt: DateTime.utc(2026),
            demo: false,
          ).toJson()
          ..remove('offlineSyncHeld')
          ..remove('recordingCardIdentity')
          ..remove('recordingCardFileName');
    final restored = MeetingRecord.fromJson(json);
    expect(restored.offlineSyncHeld, isFalse);
    expect(restored.recordingCardIdentity, isNull);
  });
}
