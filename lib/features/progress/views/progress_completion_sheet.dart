import 'package:flutter/material.dart';
import '../../home/views/home_style.dart';
import '../models/progress_models.dart';
import '../viewmodels/progress_view_model.dart';

Future<bool?> showProgressCompletion(
  BuildContext context,
  ProgressViewModel model,
  PendingProgressItem item,
) => showModalBottomSheet<bool>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  backgroundColor: HomeStyle.surface(context),
  shape: const RoundedRectangleBorder(
    borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
  ),
  builder: (_) => ProgressCompletionSheet(model: model, item: item),
);

/// 只补缺失的履约方或日期，不新增具体人员身份要求。
class ProgressCompletionSheet extends StatefulWidget {
  const ProgressCompletionSheet({
    super.key,
    required this.model,
    required this.item,
  });
  final ProgressViewModel model;
  final PendingProgressItem item;
  @override
  State<ProgressCompletionSheet> createState() =>
      _ProgressCompletionSheetState();
}

class _ProgressCompletionSheetState extends State<ProgressCompletionSheet> {
  CommitmentSide? side;
  DateTime? deadline;
  bool saving = false;
  String? error;
  late final scope = widget.model.accountScopeRevision;
  @override
  void initState() {
    super.initState();
    widget.model.addListener(_changed);
  }

  void _changed() {
    if (mounted && widget.model.accountScopeRevision != scope) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.pop(context, false);
      });
      setState(() {});
    }
  }

  @override
  void dispose() {
    widget.model.removeListener(_changed);
    super.dispose();
  }

  Future<void> _save() async {
    if (saving) return;
    if ((widget.item.needsSide && side == null) ||
        (widget.item.needsDeadline && deadline == null)) {
      setState(() => error = '请补全履约方和交期中的缺失项');
      return;
    }
    setState(() {
      saving = true;
      error = null;
    });
    final success = await widget.model.completeMissing(
      widget.item,
      side: side,
      deadline: deadline,
    );
    if (!mounted) return;
    if (success) {
      Navigator.pop(context, true);
    } else {
      setState(() {
        saving = false;
        error = widget.model.actionError ?? '记录已更新，请刷新后重试';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (scope != widget.model.accountScopeRevision) {
      return const SizedBox.shrink();
    }
    return SingleChildScrollView(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          20,
          20,
          20 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('补全履约信息', style: HomeStyle.text(20, bold: true)),
            const SizedBox(height: 8),
            Text(
              widget.item.title,
              style: HomeStyle.text(14, color: HomeStyle.secondary(context)),
            ),
            if (widget.item.needsSide) ...[
              const SizedBox(height: 20),
              Text('履约方', style: HomeStyle.text(14, bold: true)),
              const SizedBox(height: 10),
              Wrap(
                spacing: 10,
                runSpacing: 8,
                children: [
                  for (final value in CommitmentSide.values)
                    ChoiceChip(
                      key: ValueKey('complete-side-${value.name}'),
                      label: Text(value.itemLabel),
                      selected: side == value,
                      onSelected: saving
                          ? null
                          : (_) => setState(() => side = value),
                      selectedColor: HomeStyle.blue.withValues(alpha: .1),
                      labelStyle: HomeStyle.text(
                        14,
                        color: side == value
                            ? HomeStyle.blue
                            : HomeStyle.foreground(context),
                      ),
                    ),
                ],
              ),
            ],
            if (widget.item.needsDeadline) ...[
              const SizedBox(height: 20),
              Text('交期', style: HomeStyle.text(14, bold: true)),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                key: const ValueKey('complete-deadline'),
                icon: const Icon(Icons.calendar_today_outlined, size: 18),
                label: Text(
                  deadline == null ? '选择日期' : progressDate(deadline!),
                ),
                onPressed: saving
                    ? null
                    : () async {
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: deadline ?? DateTime.now(),
                          firstDate: DateTime(2000),
                          lastDate: DateTime(2100),
                        );
                        if (mounted && picked != null) {
                          setState(
                            () => deadline = DateTime(
                              picked.year,
                              picked.month,
                              picked.day,
                              23,
                              59,
                            ),
                          );
                        }
                      },
              ),
            ],
            if (error != null) ...[
              const SizedBox(height: 12),
              Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: saving
                        ? null
                        : () => Navigator.pop(context, false),
                    child: const Text('稍后'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    key: const ValueKey('complete-save'),
                    onPressed: saving ? null : _save,
                    child: Text(saving ? '保存中…' : '保存'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
