import 'personalization_data.dart';

class ProfileData {
  const ProfileData({
    this.personalization,
    this.accountId = '',
    this.cloudVersion = 0,
    this.name = '',
    this.job = '',
    this.company = '',
    this.email = '',
    this.phone = '',
    this.avatar,
    this.language = 'zh',
    this.appearance = 'system',
    this.sessionActive = true,
    this.hapticFeedback = true,
    this.backgroundNotifications = false,
  });
  final PersonalizationData? personalization;
  final int cloudVersion;
  final String accountId,
      name,
      job,
      company,
      email,
      phone,
      language,
      appearance;
  final String? avatar;
  final bool sessionActive;
  final bool hapticFeedback, backgroundNotifications;
  ProfileData copyWith({
    PersonalizationData? personalization,
    bool clearPersonalization = false,
    String? accountId,
    int? cloudVersion,
    String? name,
    String? job,
    String? company,
    String? email,
    String? phone,
    String? avatar,
    bool clearAvatar = false,
    String? language,
    String? appearance,
    bool? sessionActive,
    bool? hapticFeedback,
    bool? backgroundNotifications,
  }) => ProfileData(
    personalization: clearPersonalization
        ? null
        : personalization ?? this.personalization,
    accountId: accountId ?? this.accountId,
    cloudVersion: cloudVersion ?? this.cloudVersion,
    name: name ?? this.name,
    job: job ?? this.job,
    company: company ?? this.company,
    email: email ?? this.email,
    phone: phone ?? this.phone,
    avatar: clearAvatar ? null : avatar ?? this.avatar,
    language: language ?? this.language,
    appearance: appearance ?? this.appearance,
    sessionActive: sessionActive ?? this.sessionActive,
    hapticFeedback: hapticFeedback ?? this.hapticFeedback,
    backgroundNotifications:
        backgroundNotifications ?? this.backgroundNotifications,
  );
  Map<String, dynamic> toJson() => {
    'schema': 1,
    'personalization': personalization?.toJson(),
    'cloudVersion': cloudVersion,
    'accountId': accountId,
    'name': name,
    'job': job,
    'company': company,
    'email': email,
    'phone': phone,
    'avatar': avatar,
    'language': language,
    'appearance': appearance,
    'sessionActive': sessionActive,
    'hapticFeedback': hapticFeedback,
    'backgroundNotifications': backgroundNotifications,
  };
  factory ProfileData.fromJson(Map<String, dynamic> j) {
    if (j['schema'] != 1 ||
        !['zh', 'en', 'system'].contains(j['language']) ||
        !['light', 'dark', 'system'].contains(j['appearance'])) {
      throw const FormatException('设置格式无法读取');
    }
    return ProfileData(
      personalization: j['personalization'] is Map
          ? PersonalizationData.fromJson(j['personalization'])
          : null,
      accountId: j['accountId'],
      cloudVersion: j['cloudVersion'] is int ? j['cloudVersion'] : 0,
      name: j['name'],
      job: j['job'],
      company: j['company'],
      email: j['email'],
      phone: j['phone'],
      avatar: j['avatar'],
      language: j['language'],
      appearance: j['appearance'],
      sessionActive: j['sessionActive'] == true,
      hapticFeedback: j['hapticFeedback'] != false,
      backgroundNotifications: j['backgroundNotifications'] == true,
    );
  }
}
