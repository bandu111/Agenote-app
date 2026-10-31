import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/core/viewmodels/loadable_view_model.dart';
import 'package:yanshu/shared/models/affair.dart';
import 'package:yanshu/shared/repositories/affairs_repository.dart';

class ControlledRepository implements AffairsRepository {
  final requests = <Completer<List<Affair>>>[];
  @override
  Future<List<Affair>> load() {
    final request = Completer<List<Affair>>();
    requests.add(request);
    return request.future;
  }
}

void main() {
  test(
    'failed load can retry and disposed model ignores late completion',
    () async {
      final repository = ControlledRepository();
      final model = LoadableViewModel(repository);
      final failed = model.refresh();
      repository.requests.last.completeError(StateError('offline'));
      await failed;
      expect(model.error, isNotNull);
      expect(model.loading, isFalse);
      final retry = model.refresh();
      repository.requests.last.complete([]);
      await retry;
      expect(model.error, isNull);
      final pending = model.refresh();
      model.dispose();
      repository.requests.last.complete([]);
      await pending;
    },
  );

  test('older responses cannot overwrite latest refresh', () async {
    final repository = ControlledRepository();
    final model = LoadableViewModel(repository);
    addTearDown(model.dispose);
    final older = model.refresh();
    final latest = model.refresh();
    repository.requests[1].complete([
      const Affair(
        id: 'new',
        title: '新结果',
        status: AffairStatus.needsAttention,
      ),
    ]);
    await latest;
    repository.requests[0].complete([]);
    await older;
    expect(model.items.single.id, 'new');
  });
}
