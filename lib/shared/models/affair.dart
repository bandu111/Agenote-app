enum AffairStatus { needsAttention, inProgress, completed }

class Affair {
  const Affair({required this.id, required this.title, required this.status});
  final String id;
  final String title;
  final AffairStatus status;
}
