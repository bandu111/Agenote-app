/// Server-owned onboarding state. Null on old accounts means no forced onboarding.
class PersonalizationData {
  const PersonalizationData({
    this.status = 'pending',
    this.step = 1,
    this.profession = '',
    this.professionOther = '',
    this.scenarios = const [],
    this.scenarioOther = '',
  });
  final String status, profession, professionOther, scenarioOther;
  final int step;
  final List<String> scenarios;
  bool get required => status == 'pending' || status == 'in_progress';
  factory PersonalizationData.fromJson(Map j) => PersonalizationData(
    status: j['status'] as String? ?? 'pending',
    step: j['step'] == 2 ? 2 : 1,
    profession: j['profession'] as String? ?? '',
    professionOther: j['profession_other'] as String? ?? '',
    scenarios: List<String>.from(j['scenarios'] as List? ?? const []),
    scenarioOther: j['scenario_other'] as String? ?? '',
  );
  Map<String, dynamic> toJson() => {
    'schema': 1,
    'status': status,
    'step': step,
    'profession': profession,
    'profession_other': professionOther,
    'scenarios': scenarios,
    'scenario_other': scenarioOther,
  };
}
