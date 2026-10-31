import '../models/affair.dart';

abstract interface class AffairsRepository {
  Future<List<Affair>> load();
}

/// Development-only empty source. No simulated agent or fake events.
class LocalEmptyAffairsRepository implements AffairsRepository {
  @override
  Future<List<Affair>> load() async => const [];
}
