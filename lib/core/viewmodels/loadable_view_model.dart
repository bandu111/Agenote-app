import 'package:flutter/foundation.dart';
import '../../shared/models/affair.dart';
import '../../shared/repositories/affairs_repository.dart';

class LoadableViewModel extends ChangeNotifier {
  LoadableViewModel(this.repository);
  final AffairsRepository repository;
  List<Affair> items = const [];
  bool loading = true;
  String? error;
  bool _disposed = false;
  int _revision = 0;
  Future<void> refresh() async {
    final revision = ++_revision;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final result = await repository.load();
      if (_disposed || revision != _revision) return;
      items = List.unmodifiable(result);
    } catch (_) {
      if (_disposed || revision != _revision) return;
      error = '暂时无法加载，请重试。';
    }
    loading = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
