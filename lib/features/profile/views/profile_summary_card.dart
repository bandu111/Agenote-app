import 'package:flutter/material.dart';
import '../../../app/l10n/app_strings.dart';
import '../models/profile_data.dart';
import 'profile_components.dart';

/// Four fields editable in the existing profile form; no invented signup/plan data.
List<String> missingProfileFields(ProfileData data) => [
  if (data.name.trim().isEmpty) '昵称',
  if (data.job.trim().isEmpty) '岗位',
  if (data.company.trim().isEmpty) '公司或组织',
  if (data.email.trim().isEmpty && data.phone.trim().isEmpty) '联系方式',
];

class ProfileSummaryCard extends StatelessWidget {
  const ProfileSummaryCard({
    super.key,
    required this.data,
    required this.enabled,
    required this.onEdit,
  });
  final ProfileData data;
  final bool enabled;
  final VoidCallback onEdit;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final missing = missingProfileFields(data);
    final complete = 4 - missing.length;
    return ProfileSurface(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              key: const ValueKey('profile-edit'),
              onTap: enabled ? onEdit : null,
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Stack(
                      children: [
                        ProfileAvatar(data: data.avatar, size: 56),
                        Positioned(
                          right: 0,
                          bottom: 0,
                          child: Container(
                            padding: const EdgeInsets.all(3),
                            decoration: BoxDecoration(
                              color: colors.surfaceContainerLowest,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: colors.primary.withValues(alpha: .12),
                              ),
                            ),
                            child: Icon(
                              Icons.edit_outlined,
                              size: 10,
                              color: colors.primary,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            data.name.trim().isEmpty ? 'Agenote 用户' : data.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 20,
                              height: 1.35,
                              fontWeight: FontWeight.w500,
                              color: colors.onSurface,
                            ),
                          ),
                          if (data.email.trim().isNotEmpty) ...[
                            const SizedBox(height: 5),
                            Text(
                              data.email,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                height: 1.45,
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Container(
              key: const ValueKey('profile-completeness'),
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
              decoration: BoxDecoration(
                color: colors.surfaceContainerLowest,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: colors.primary.withValues(alpha: .08),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: double.infinity,
                    child: Wrap(
                      alignment: WrapAlignment.spaceBetween,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 8,
                      children: [
                        Text(
                          '${'资料完整度'.tr(context)} $complete/4',
                          style: TextStyle(
                            fontSize: 11,
                            height: 1.5,
                            color: colors.onSurface,
                          ),
                        ),
                        TextButton(
                          key: const ValueKey('profile-complete'),
                          onPressed: enabled ? onEdit : null,
                          style: TextButton.styleFrom(
                            foregroundColor: colors.primary,
                            minimumSize: const Size(64, 40),
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            shape: const StadiumBorder(
                              side: BorderSide(color: Color(0xFFE0E8FA)),
                            ),
                          ),
                          child: Text(
                            (missing.isEmpty ? '编辑资料' : '完善资料').tr(context),
                            style: const TextStyle(fontSize: 11),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Semantics(
                    label: '${'资料完整度'.tr(context)} $complete/4',
                    child: Row(
                      children: [
                        for (var i = 0; i < 4; i++)
                          Expanded(
                            child: Padding(
                              padding: EdgeInsets.only(right: i == 3 ? 0 : 3),
                              child: Container(
                                height: 3,
                                decoration: BoxDecoration(
                                  color: i < complete
                                      ? colors.primary
                                      : colors.primary.withValues(alpha: .12),
                                  borderRadius: BorderRadius.circular(3),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    (missing.isEmpty
                            ? '资料已完善，可以随时调整。'
                            : '还差${missing.join('、')}，补全后更便于整理与跟进。')
                        .tr(context),
                    style: TextStyle(
                      fontSize: 11,
                      height: 1.5,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
