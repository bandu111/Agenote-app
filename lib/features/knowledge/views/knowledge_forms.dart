import '../../../app/l10n/app_strings.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../home/views/home_style.dart';
import '../models/knowledge_models.dart';
import '../repositories/knowledge_importer.dart';
import '../viewmodels/knowledge_view_model.dart';
import '../widgets/knowledge_components.dart';

Future<void> showKnowledgeInput(
  BuildContext context, {
  KnowledgeImport? imported,
  KnowledgeKind kind = KnowledgeKind.note,
  KnowledgeDocument? editing,
}) => showModalBottomSheet<void>(
  context: context,
  useRootNavigator: true,
  useSafeArea: true,
  isScrollControlled: true,
  backgroundColor: HomeStyle.surface(context),
  constraints: const BoxConstraints(maxWidth: 640),
  shape: const RoundedRectangleBorder(
    borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
  ),
  builder: (_) => RepaintBoundary(
    key: const ValueKey('knowledge-input-capture'),
    child: Material(
      color: HomeStyle.surface(context),
      borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      clipBehavior: Clip.antiAlias,
      child: _KnowledgeInput(
        imported: imported,
        kind: imported?.kind ?? kind,
        editing: editing,
      ),
    ),
  ),
);

class _KnowledgeInput extends StatefulWidget {
  const _KnowledgeInput({required this.kind, this.imported, this.editing});
  final KnowledgeKind kind;
  final KnowledgeImport? imported;
  final KnowledgeDocument? editing;
  @override
  State<_KnowledgeInput> createState() => _KnowledgeInputState();
}

class _KnowledgeInputState extends State<_KnowledgeInput> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _title, _content;
  final _url = TextEditingController(),
      _tags = TextEditingController(),
      _reason = TextEditingController();
  String? _folder, _project, _error;
  bool _busy = false;
  bool _advanced = false;
  @override
  void initState() {
    super.initState();
    final filename = widget.imported?.filename;
    _title = TextEditingController(
      text:
          widget.editing?.selected.title ??
          (filename == null
              ? ''
              : filename.substring(
                  0,
                  filename.lastIndexOf('.') > 0
                      ? filename.lastIndexOf('.')
                      : filename.length,
                )),
    );
    _content = TextEditingController(
      text: widget.editing?.selected.content ?? widget.imported?.content ?? '',
    );
  }

  @override
  void dispose() {
    for (final c in [_title, _content, _url, _tags, _reason]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final vm = context.read<KnowledgeViewModel>();
    setState(() {
      _busy = true;
      _error = null;
    });
    final bool success;
    if (widget.editing != null) {
      success = await vm.addVersion(
        widget.editing!.id,
        _title.text,
        _content.text,
        _reason.text,
      );
    } else {
      success =
          await vm.addDocument(
            title: _title.text,
            content: _content.text,
            folderId: _folder ?? 'inbox',
            projectId: _project ?? vm.data.projects.first.id,
            kind: widget.kind,
            filename: widget.imported?.filename,
            fileData: widget.imported?.fileData,
            fileHash: widget.imported?.fileHash,
            url: widget.kind == KnowledgeKind.link ? _url.text.trim() : null,
            tags: _tags.text.split(RegExp(r'[,，]')),
          ) !=
          null;
    }
    if (!mounted) return;
    if (success) {
      Navigator.pop(context);
    } else {
      setState(() {
        _busy = false;
        _error = vm.actionError ?? '保存未完成';
      });
    }
  }

  Future<void> _chooseProject(KnowledgeViewModel vm) async {
    if (_busy || vm.data.projects.isEmpty) return;
    FocusScope.of(context).unfocus();
    final projects = List.of(vm.data.projects);
    final selected = _project ?? projects.first.id;
    final result = await showModalBottomSheet<String>(
      context: context,
      useRootNavigator: true,
      useSafeArea: true,
      isScrollControlled: true,
      backgroundColor: HomeStyle.surface(context),
      constraints: const BoxConstraints(maxWidth: 640),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (sheet) => RepaintBoundary(
        key: const ValueKey('knowledge-project-menu-capture'),
        child: Material(
          color: HomeStyle.surface(sheet),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          clipBehavior: Clip.antiAlias,
          child: SafeArea(
            top: false,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(sheet).height * .65,
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 18, 24, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '关联项目',
                            style: HomeStyle.text(21, bold: true),
                          ),
                        ),
                        IconButton(
                          tooltip: '关闭项目选择',
                          onPressed: () => Navigator.pop(sheet),
                          icon: const Icon(
                            Icons.close_rounded,
                            color: HomeStyle.blue,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '选择这份资料所属的项目',
                      style: HomeStyle.text(
                        12,
                        color: HomeStyle.secondary(sheet),
                      ),
                    ),
                    const SizedBox(height: 18),
                    Flexible(
                      child: ListView.separated(
                        shrinkWrap: true,
                        primary: false,
                        itemCount: projects.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 8),
                        itemBuilder: (_, index) {
                          final project = projects[index];
                          final active = project.id == selected;
                          return Semantics(
                            selected: active,
                            child: Material(
                              color: active
                                  ? HomeStyle.tintColor(
                                      sheet,
                                      const Color(0xFFE8F0FF),
                                    )
                                  : HomeStyle.tint(sheet),
                              borderRadius: BorderRadius.circular(14),
                              clipBehavior: Clip.antiAlias,
                              child: ListTile(
                                key: ValueKey(
                                  'knowledge-project-option-${project.id}',
                                ),
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 6,
                                ),
                                leading: Icon(
                                  Icons.work_outline_rounded,
                                  size: 21,
                                  color: active
                                      ? HomeStyle.blue
                                      : HomeStyle.secondary(sheet),
                                ),
                                title: Text(
                                  project.name,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: HomeStyle.text(
                                    14,
                                    bold: active,
                                    color: active ? HomeStyle.blue : null,
                                  ),
                                ),
                                trailing: active
                                    ? const Icon(
                                        Icons.check_rounded,
                                        color: HomeStyle.blue,
                                        size: 21,
                                      )
                                    : null,
                                onTap: () => Navigator.pop(sheet, project.id),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    if (!mounted ||
        result == null ||
        !vm.data.projects.any((p) => p.id == result)) {
      return;
    }
    setState(() => _project = result);
  }

  InputDecoration _input(
    BuildContext context,
    String hint, {
    bool body = false,
  }) {
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(body ? 18 : 12),
      borderSide: BorderSide.none,
    );
    return InputDecoration(
      hintText: hint,
      hintStyle: HomeStyle.text(
        14,
        color: HomeStyle.secondary(context).withValues(alpha: .65),
      ),
      filled: true,
      fillColor: HomeStyle.tint(context),
      border: border,
      enabledBorder: border,
      disabledBorder: border,
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(body ? 18 : 12),
        borderSide: const BorderSide(color: HomeStyle.blue, width: 1),
      ),
      contentPadding: EdgeInsets.all(body ? 20 : 14),
      counterText: '',
    );
  }

  Widget _submit() => FilledButton.icon(
    key: const ValueKey('knowledge-input-save'),
    onPressed: _busy ? null : _save,
    style: FilledButton.styleFrom(
      backgroundColor: HomeStyle.blue,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 15),
      minimumSize: const Size(120, 50),
      shape: const StadiumBorder(),
    ),
    icon: _busy
        ? const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : const Icon(Icons.upload_file_outlined, size: 19),
    label: Text(
      _busy
          ? '保存中…'
          : widget.editing != null
          ? '保存新版本'
          : '提交',
      style: const TextStyle(fontWeight: FontWeight.w600),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<KnowledgeViewModel>();
    final folder = _folder ?? 'inbox';
    final helper = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(
          Icons.auto_awesome_outlined,
          size: 16,
          color: HomeStyle.blue,
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            widget.editing != null ? '原版本保留，更新内容待确认' : '保存后可检索并用于 AI 引用',
            style: HomeStyle.text(11, color: HomeStyle.secondary(context)),
          ),
        ),
      ],
    );
    return SafeArea(
      top: false,
      child: AnimatedPadding(
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SingleChildScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          child: Padding(
            key: const ValueKey('knowledge-quick-input-sheet'),
            padding: const EdgeInsets.fromLTRB(24, 22, 24, 20),
            child: Form(
              key: _form,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          widget.editing != null
                              ? '保存新版本'
                              : widget.imported != null
                              ? '导入资料'
                              : '快速录入',
                          style: HomeStyle.text(22, bold: true),
                        ),
                      ),
                      IconButton(
                        tooltip: '关闭'.tr(context),
                        onPressed: _busy ? null : () => Navigator.pop(context),
                        icon: const Icon(
                          Icons.close_rounded,
                          color: HomeStyle.blue,
                          size: 24,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  TextFormField(
                    key: const ValueKey('knowledge-input-title'),
                    controller: _title,
                    enabled: !_busy,
                    textInputAction: TextInputAction.next,
                    maxLength: 100,
                    style: HomeStyle.text(15, bold: true),
                    decoration: _input(context, '资料标题'),
                    validator: (v) =>
                        v == null || v.trim().isEmpty ? '请填写标题' : null,
                  ),
                  const SizedBox(height: 12),
                  if (widget.kind == KnowledgeKind.link &&
                      widget.editing == null) ...[
                    TextFormField(
                      key: const ValueKey('knowledge-input-url'),
                      controller: _url,
                      enabled: !_busy,
                      keyboardType: TextInputType.url,
                      decoration: _input(context, '网页链接（http / https）'),
                      validator: (v) {
                        final uri = Uri.tryParse(v?.trim() ?? '');
                        return uri == null ||
                                !['http', 'https'].contains(uri.scheme) ||
                                uri.host.isEmpty
                            ? '请输入完整链接'
                            : null;
                      },
                    ),
                    const SizedBox(height: 12),
                  ],
                  TextFormField(
                    key: const ValueKey('knowledge-input-content'),
                    controller: _content,
                    enabled: !_busy,
                    minLines: 5,
                    maxLines: 8,
                    style: HomeStyle.text(15).copyWith(height: 1.65),
                    decoration: _input(
                      context,
                      widget.kind.isBinary
                          ? '添加文本摘要或摘录（可选）…'
                          : widget.kind == KnowledgeKind.link
                          ? '输入说明或粘贴网页摘录（可选）…'
                          : '输入笔记或粘贴文本内容…',
                      body: true,
                    ),
                    validator: (v) =>
                        widget.kind != KnowledgeKind.link &&
                            !widget.kind.isBinary &&
                            (v == null || v.trim().isEmpty)
                        ? '请输入正文'
                        : null,
                  ),
                  if (widget.imported != null) ...[
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Icon(
                          widget.kind == KnowledgeKind.pdf
                              ? Icons.picture_as_pdf_outlined
                              : Icons.description_outlined,
                          size: 16,
                          color: HomeStyle.secondary(context),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            widget.imported!.filename,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: HomeStyle.text(
                              11,
                              color: HomeStyle.secondary(context),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 22),
                  if (widget.editing == null) ...[
                    Row(
                      children: [
                        const Icon(
                          Icons.folder_outlined,
                          size: 19,
                          color: HomeStyle.blue,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '归类到文件夹',
                          style: HomeStyle.text(
                            13,
                            bold: true,
                            color: HomeStyle.secondary(context),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    SingleChildScrollView(
                      key: const ValueKey('knowledge-input-folder'),
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (final f in [
                            ...vm.data.folders.where((f) => f.id == 'inbox'),
                            ...vm.data.folders.where((f) => f.id != 'inbox'),
                          ])
                            Padding(
                              padding: const EdgeInsetsDirectional.only(end: 8),
                              child: ChoiceChip(
                                key: ValueKey(
                                  'knowledge-folder-choice-${f.id}',
                                ),
                                label: ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    maxWidth: 190,
                                  ),
                                  child: Text(
                                    f.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                selected: folder == f.id,
                                showCheckmark: false,
                                avatar: Icon(
                                  Icons.folder_outlined,
                                  size: 17,
                                  color: folder == f.id
                                      ? HomeStyle.blue
                                      : HomeStyle.secondary(context),
                                ),
                                backgroundColor: HomeStyle.tint(context),
                                selectedColor: HomeStyle.tintColor(
                                  context,
                                  const Color(0xFFE8F0FF),
                                ),
                                side: BorderSide(
                                  color: folder == f.id
                                      ? HomeStyle.blue.withValues(alpha: .3)
                                      : Colors.transparent,
                                ),
                                shape: const StadiumBorder(),
                                labelStyle: HomeStyle.text(
                                  13,
                                  bold: folder == f.id,
                                  color: folder == f.id
                                      ? HomeStyle.blue
                                      : HomeStyle.secondary(context),
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 9,
                                ),
                                onSelected: _busy
                                    ? null
                                    : (_) => setState(() => _folder = f.id),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 4),
                    TextButton(
                      key: const ValueKey('knowledge-input-more'),
                      onPressed: _busy
                          ? null
                          : () => setState(() => _advanced = !_advanced),
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.zero,
                        foregroundColor: HomeStyle.secondary(context),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _advanced ? '收起设置' : '更多设置',
                            style: HomeStyle.text(12),
                          ),
                          Icon(
                            _advanced
                                ? Icons.keyboard_arrow_up
                                : Icons.keyboard_arrow_down,
                            size: 17,
                          ),
                        ],
                      ),
                    ),
                    if (_advanced) ...[
                      Text(
                        '关联项目',
                        style: HomeStyle.text(
                          12,
                          color: HomeStyle.secondary(context),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Material(
                        color: HomeStyle.tint(context),
                        borderRadius: BorderRadius.circular(12),
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          key: const ValueKey('knowledge-input-project'),
                          onTap: _busy || vm.data.projects.isEmpty
                              ? null
                              : () => _chooseProject(vm),
                          child: Padding(
                            padding: const EdgeInsets.all(14),
                            child: Row(
                              children: [
                                const Icon(
                                  Icons.work_outline_rounded,
                                  size: 19,
                                  color: HomeStyle.blue,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    vm.data.projects
                                            .where((p) => p.id == _project)
                                            .firstOrNull
                                            ?.name ??
                                        vm.data.projects.firstOrNull?.name ??
                                        '暂无项目',
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: HomeStyle.text(14, bold: true),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Icon(
                                  Icons.keyboard_arrow_down_rounded,
                                  size: 20,
                                  color: HomeStyle.secondary(context),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _tags,
                        enabled: !_busy,
                        decoration: _input(context, '标签（用逗号分隔，可选）'),
                      ),
                      const SizedBox(height: 12),
                    ],
                  ] else ...[
                    TextFormField(
                      key: const ValueKey('knowledge-change-reason'),
                      controller: _reason,
                      enabled: !_busy,
                      decoration: _input(context, '变更说明'),
                      validator: (v) =>
                          v == null || v.trim().isEmpty ? '请填写变更说明' : null,
                    ),
                  ],
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        _error!,
                        style: HomeStyle.text(
                          13,
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  const SizedBox(height: 20),
                  LayoutBuilder(
                    builder: (context, constraints) =>
                        constraints.maxWidth < 330 ||
                            MediaQuery.textScalerOf(context).scale(14) > 19
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              helper,
                              const SizedBox(height: 14),
                              _submit(),
                            ],
                          )
                        : Row(
                            children: [
                              Expanded(child: helper),
                              const SizedBox(width: 12),
                              _submit(),
                            ],
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> knowledgeFolderEditor(
  BuildContext context, {
  KnowledgeFolder? folder,
  String? parent,
}) => showDialog<void>(
  context: context,
  useRootNavigator: true,
  builder: (_) => _FolderEditor(folder: folder, parent: parent),
);

class _FolderEditor extends StatefulWidget {
  const _FolderEditor({this.folder, this.parent});
  final KnowledgeFolder? folder;
  final String? parent;
  @override
  State<_FolderEditor> createState() => _FolderEditorState();
}

class _FolderEditorState extends State<_FolderEditor> {
  late final TextEditingController _name = TextEditingController(
    text: widget.folder?.name,
  );
  String? _error;
  bool _busy = false;
  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.folder == null ? '新建文件夹' : '重命名文件夹'),
    content: TextField(
      key: const ValueKey('knowledge-folder-name'),
      controller: _name,
      autofocus: true,
      maxLength: 30,
      decoration: InputDecoration(labelText: '文件夹名称', errorText: _error),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text('取消'.tr(context)),
      ),
      TextButton(
        onPressed: _busy
            ? null
            : () async {
                final vm = context.read<KnowledgeViewModel>();
                setState(() => _busy = true);
                final ok = widget.folder == null
                    ? await vm.createFolder(_name.text, parent: widget.parent)
                    : await vm.renameFolder(widget.folder!.id, _name.text);
                if (!context.mounted) return;
                if (ok) {
                  Navigator.pop(context);
                } else {
                  setState(() {
                    _busy = false;
                    _error = vm.actionError;
                  });
                }
              },
        child: Text('保存'.tr(context)),
      ),
    ],
  );
}

Future<void> moveKnowledgeItem(
  BuildContext context, {
  String? documentId,
  String? folderId,
}) => showModalBottomSheet<void>(
  context: context,
  useRootNavigator: true,
  useSafeArea: true,
  isScrollControlled: true,
  builder: (context) {
    final vm = context.watch<KnowledgeViewModel>();
    Future<void> move(String? target) async {
      final ok = documentId != null
          ? await vm.moveDocument(documentId, target!)
          : await vm.moveFolder(folderId!, target);
      if (!context.mounted) return;
      if (ok) {
        Navigator.pop(context);
      } else {
        knowledgeFeedback(context, vm.actionError ?? '移动未完成');
      }
    }

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .7,
        ),
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.all(20),
              child: Text('移动到', style: HomeStyle.text(20, bold: true)),
            ),
            if (folderId != null)
              ListTile(
                leading: const Icon(Icons.drive_file_move_outline),
                title: const Text('最外层'),
                onTap: vm.saving ? null : () => move(null),
              ),
            ...vm.data.folders
                .where(
                  (f) => folderId == null || vm.canMoveFolder(folderId, f.id),
                )
                .map(
                  (f) => ListTile(
                    leading: const Icon(
                      Icons.folder_outlined,
                      color: HomeStyle.blue,
                    ),
                    title: Text(f.name),
                    onTap: vm.saving ? null : () => move(f.id),
                  ),
                ),
          ],
        ),
      ),
    );
  },
);
