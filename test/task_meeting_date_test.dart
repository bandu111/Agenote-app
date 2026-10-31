import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/core/network/api_client.dart';
import 'package:yanshu/features/home/repositories/dio_home_repository.dart';
import 'package:yanshu/features/home/viewmodels/schedule_view_model.dart';
import 'dio_auth_repository_test.dart' show TestAdapter, envelope;
import 'test_schedule_clock.dart';

void main() {
  for (final explicitDate in [true, false]) {
    test(
      'undated action stays on meeting date across UTC+8 midnight, explicit=$explicitDate',
      () async {
        final api =
            ApiClient(
                baseUrl: 'https://test.example/',
                dio: Dio()
                  ..httpClientAdapter = TestAdapter(
                    (_) async => (
                      200,
                      envelope({
                        'tasks': [
                          {
                            'id': 'minutes:a:b',
                            'title': '提交报告',
                            'version': 1,
                            'createdAt': '2030-10-22T20:30:00Z',
                            'deadline': null,
                            if (explicitDate) 'sourceMeetingDate': '2030-10-22',
                            'sourceRoute': '/meetings/a/minutes?action=b',
                          },
                        ],
                      }),
                    ),
                  ),
              )
              ..accountId = (() => 'owner')
              ..accessToken = (() async => 'token');
        final vm = ScheduleViewModel(
          DioHomeRepository(api),
          clock: TestScheduleClock(DateTime.utc(2030, 10, 23)),
          taskChecklist: true,
          listenToTime: false,
        );
        addTearDown(vm.dispose);
        vm.refreshAccount();
        await Future<void>.delayed(Duration.zero);
        await vm.refresh();
        expect(vm.entriesOn(DateTime(2030, 10, 22)).single.item.title, '提交报告');
        expect(vm.entriesOn(DateTime(2030, 10, 23)), isEmpty);
        expect(
          vm.entriesOn(DateTime(2030, 10, 22)).single.item.hasDeadline,
          false,
        );
      },
    );
  }
}
