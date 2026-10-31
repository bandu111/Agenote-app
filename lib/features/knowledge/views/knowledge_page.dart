import '../../../shared/widgets/delete_confirmation.dart';
import 'dart:async';
import '../../../shared/widgets/content_skeleton.dart';
import '../../../app/l10n/app_strings.dart';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../../home/views/home_style.dart';
import '../../progress/widgets/progress_components.dart' show ProgressPills;
import '../models/knowledge_models.dart';
import '../repositories/knowledge_importer.dart';
import '../viewmodels/knowledge_view_model.dart';
import '../widgets/knowledge_components.dart';
import 'knowledge_forms.dart';

class KnowledgeDrag {
  const KnowledgeDrag(this.id, {this.folder = false});
  final String id;
  final bool folder;
}

class KnowledgePage extends StatefulWidget {
  const KnowledgePage({super.key});
  @override
  State<KnowledgePage> createState() => _KnowledgePageState();
}

class _KnowledgePageState extends State<KnowledgePage>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final _search = TextEditingController(), _scroll = ScrollController();
  final _focus = FocusNode(), _viewport = GlobalKey();
  late final Ticker _ticker;
  bool _searchOpen = false, _dragging = false;
  Offset? _pointer;
  Duration _lastTick = Duration.zero;
  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_tick);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!TickerMode.valuesOf(context).enabled) _stopDrag();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _stopDrag();
  }

  void _stopDrag() {
    _pointer = null;
    _lastTick = Duration.zero;
    _ticker.stop();
  }

  void _dragPosition(Offset value) {
    _pointer = value;
    if (!_ticker.isActive) {
      _lastTick = Duration.zero;
      _ticker.start();
    }
  }

  void _tick(Duration elapsed) {
    if (_pointer == null || !_scroll.hasClients) return;
    final box = _viewport.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final y = box.globalToLocal(_pointer!).dy;
    final velocity = y < 64
        ? -240 * (1 - y / 64).clamp(0, 1)
        : y > box.size.height - 64
        ? 240 * ((y - box.size.height + 64) / 64).clamp(0, 1)
        : 0.0;
    final dt = _lastTick == Duration.zero
        ? 0.016
        : (elapsed - _lastTick).inMicroseconds / 1000000;
    _lastTick = elapsed;
    if (velocity != 0) {
      _scroll.jumpTo(
        (_scroll.offset + velocity * dt.clamp(0, .04)).clamp(
          0,
          _scroll.position.maxScrollExtent,
        ),
      );
    }
  }

  void _dragState(bool active) {
    if (!active) _stopDrag();
    if (mounted && _dragging != active) setState(() => _dragging = active);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker.dispose();
    _search.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _quickInput() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      useRootNavigator: true,
      useSafeArea: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('添加资料'.tr(context), style: HomeStyle.text(20, bold: true)),
              const SizedBox(height: 18),
              Material(
                color: HomeStyle.surface(context),
                borderRadius: BorderRadius.circular(16),
                child: InkWell(
                  key: const ValueKey('knowledge-add-file'),
                  borderRadius: BorderRadius.circular(16),
                  onTap: () => Navigator.pop(context, 'file'),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Row(
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: HomeStyle.tintColor(
                              context,
                              const Color(0xFFEAF1FF),
                            ),
                            borderRadius: BorderRadius.circular(13),
                          ),
                          child: const Icon(
                            Icons.upload_file,
                            color: HomeStyle.blue,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            '导入文件'.tr(context),
                            style: HomeStyle.text(
                              14,
                              color: HomeStyle.foreground(context),
                            ),
                          ),
                        ),
                        Icon(
                          Icons.chevron_right,
                          size: 20,
                          color: HomeStyle.secondary(context),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                '支持导入文档。文档上限 20 MB，文本上限 2 MB。',
                style: HomeStyle.text(12, color: HomeStyle.secondary(context)),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || choice == null) return;
    if (choice == 'file') {
      try {
        final file = await context.read<KnowledgeImporter>().pick();
        if (mounted && file != null) {
          await showKnowledgeInput(context, imported: file);
        }
      } on FormatException catch (e) {
        if (mounted) knowledgeFeedback(context, e.message);
      } catch (_) {
        if (mounted) knowledgeFeedback(context, '文件读取失败，请重新选择文件');
      }
    }
  }

  Widget _rootDrop(KnowledgeViewModel vm) => DragTarget<KnowledgeDrag>(
    onWillAcceptWithDetails: (_) => !vm.saving,
    onAcceptWithDetails: (details) async {
      final data = details.data;
      final ok = data.folder
          ? await vm.moveFolder(data.id, null)
          : await vm.moveDocument(data.id, 'inbox');
      if (mounted && !ok) knowledgeFeedback(context, vm.actionError ?? '移动未完成');
    },
    builder: (context, candidates, _) => AnimatedContainer(
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 180),
      height: _dragging ? 48 : 0,
      width: double.infinity,
      margin: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        color: HomeStyle.blue.withValues(
          alpha: candidates.isNotEmpty ? .12 : .05,
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: ClipRect(
        child: Center(
          child: Text(
            '拖到这里：文件夹移到最外层，资料移入未归档',
            style: HomeStyle.text(12, color: HomeStyle.blue),
          ),
        ),
      ),
    ),
  );
  @override
  Widget build(BuildContext context) {
    final vm = context.watch<KnowledgeViewModel>();
    return Scaffold(
      backgroundColor: HomeStyle.canvas(context),
      appBar: AppBar(
        title: Text('知识库'.tr(context), style: HomeStyle.text(22, bold: true)),
        actions: [
          IconButton(
            key: const ValueKey('knowledge-add'),
            tooltip: '添加资料'.tr(context),
            onPressed: vm.loading || vm.error != null ? null : _quickInput,
            icon: const Icon(Icons.add),
          ),
          IconButton(
            key: const ValueKey('knowledge-search-toggle'),
            tooltip: _searchOpen ? '收起搜索'.tr(context) : '搜索资料'.tr(context),
            onPressed: () {
              setState(() => _searchOpen = !_searchOpen);
              if (_searchOpen) {
                _focus.requestFocus();
              } else {
                _search.clear();
                _focus.unfocus();
                vm.search('');
              }
            },
            icon: Icon(
              _searchOpen ? Icons.search_off : Icons.search,
              color: _searchOpen
                  ? HomeStyle.blue
                  : HomeStyle.secondary(context),
            ),
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: SafeArea(
        top: false,
        bottom: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_searchOpen)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                    child: TextField(
                      key: const ValueKey('knowledge-search'),
                      controller: _search,
                      focusNode: _focus,
                      onChanged: vm.search,
                      style: HomeStyle.text(14),
                      decoration: InputDecoration(
                        hintText: '标题、标签或可检索正文'.tr(context),
                        prefixIcon: const Icon(Icons.search, size: 20),
                        filled: true,
                        fillColor: HomeStyle.surface(context),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(28),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 16, 6),
                  child: Row(
                    children: [
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: SizedBox(
                            width: 220,
                            child: ProgressPills(
                              keyPrefix: 'knowledge-tab',
                              solid: false,
                              dense: true,
                              labels: ['全部'.tr(context), '已归档'.tr(context)],
                              counts: [vm.documentCount, vm.archivedCount],
                              selected: vm.archivedOnly ? 1 : 0,
                              onSelected: (i) => vm.filterArchived(i == 1),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                _rootDrop(vm),
                Expanded(
                  child: SizedBox(
                    key: _viewport,
                    width: double.infinity,
                    child:
                        (vm.loading && vm.data.documents.isEmpty) || vm.deleting
                        ? ContentSkeleton(
                            label: vm.deleting ? '正在删除资料' : '正在加载知识库资料',
                          )
                        : vm.error != null || vm.searchError != null
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    vm.searchError ?? vm.error!,
                                    textAlign: TextAlign.center,
                                    style: HomeStyle.text(14),
                                  ),
                                  TextButton(
                                    onPressed: vm.searchError != null
                                        ? () => vm.search(vm.query)
                                        : vm.load,
                                    child: Text('重试'.tr(context)),
                                  ),
                                ],
                              ),
                            ),
                          )
                        : RefreshIndicator(
                            onRefresh: vm.load,
                            child: ListView(
                              key: const PageStorageKey('knowledge-scroll'),
                              controller: _scroll,
                              physics: const AlwaysScrollableScrollPhysics(),
                              padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
                              children: [
                                if (vm.children(null).isEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 60),
                                    child: Text(
                                      '没有找到符合条件的资料',
                                      textAlign: TextAlign.center,
                                      style: HomeStyle.text(
                                        14,
                                        color: HomeStyle.secondary(context),
                                      ),
                                    ),
                                  ),
                                if (vm.query.isNotEmpty)
                                  ...vm.searchHits.map(
                                    (hit) => Padding(
                                      padding: const EdgeInsets.only(
                                        bottom: 12,
                                      ),
                                      child: KnowledgeSurface(
                                        onTap: () => context.push(
                                          Uri(
                                            path:
                                                '/knowledge/documents/${hit.documentId}',
                                            queryParameters: {
                                              'version': hit.versionId,
                                              if (hit.end > hit.start)
                                                'start': '${hit.start}',
                                              if (hit.end > hit.start)
                                                'end': '${hit.end}',
                                              'hash': hit.hash,
                                            },
                                          ).toString(),
                                        ),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              '正文命中 · v${hit.number} · ${hit.span}',
                                              style: HomeStyle.text(
                                                12,
                                                color: HomeStyle.blue,
                                                bold: true,
                                              ),
                                            ),
                                            const SizedBox(height: 6),
                                            Text(
                                              hit.text,
                                              maxLines: 3,
                                              overflow: TextOverflow.ellipsis,
                                              style: HomeStyle.text(13),
                                            ),
                                            const SizedBox(height: 6),
                                            Text(
                                              '查看原文位置 ›',
                                              style: HomeStyle.text(
                                                12,
                                                color: HomeStyle.blue,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ...vm
                                    .children(null)
                                    .map(
                                      (f) => _KnowledgeFolderBlock(
                                        key: ValueKey('folder-${f.id}'),
                                        folder: f,
                                        onDragPosition: _dragPosition,
                                        onDragState: _dragState,
                                      ),
                                    ),
                                const SizedBox(height: 20),
                              ],
                            ),
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _KnowledgeFolderBlock extends StatefulWidget {
  const _KnowledgeFolderBlock({
    super.key,
    required this.folder,
    required this.onDragPosition,
    required this.onDragState,
    this.depth = 0,
  });
  final KnowledgeFolder folder;
  final int depth;
  final ValueChanged<Offset> onDragPosition;
  final ValueChanged<bool> onDragState;
  @override
  State<_KnowledgeFolderBlock> createState() => _KnowledgeFolderBlockState();
}

class _KnowledgeFolderBlockState extends State<_KnowledgeFolderBlock> {
  final _name = TextEditingController();
  final _nameFocus = FocusNode();
  bool _editing = false, _renaming = false;
  KnowledgeFolder get folder => widget.folder;
  int get depth => widget.depth;
  ValueChanged<Offset> get onDragPosition => widget.onDragPosition;
  ValueChanged<bool> get onDragState => widget.onDragState;

  @override
  void dispose() {
    _name.dispose();
    _nameFocus.dispose();
    super.dispose();
  }

  void _edit() {
    _name.text = folder.name;
    _name.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _name.text.length,
    );
    setState(() => _editing = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _editing) _nameFocus.requestFocus();
    });
  }

  Future<void> _rename() async {
    if (_renaming) return;
    if (_name.text.trim().isEmpty) {
      knowledgeFeedback(context, '请输入文件夹名称');
      return;
    }
    setState(() => _renaming = true);
    final vm = context.read<KnowledgeViewModel>();
    final ok = await vm.renameFolder(folder.id, _name.text);
    if (!mounted) return;
    setState(() {
      _renaming = false;
      if (ok) _editing = false;
    });
    if (!ok) knowledgeFeedback(context, vm.actionError ?? '重命名未完成');
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<KnowledgeViewModel>();
    final docs = vm.documentsIn(folder.id);
    final children = vm.children(folder.id),
        expanded = vm.isExpanded(folder.id);
    final reduce = MediaQuery.disableAnimationsOf(context);
    final content = Column(
      children: [
        ...children.map(
          (f) => _KnowledgeFolderBlock(
            key: ValueKey('folder-${f.id}'),
            folder: f,
            depth: depth + 1,
            onDragPosition: onDragPosition,
            onDragState: onDragState,
          ),
        ),
        ...docs.map(
          (d) => Padding(
            key: ValueKey('knowledge-document-${d.id}'),
            padding: const EdgeInsets.only(left: 24, bottom: 14),
            child: _KnowledgeDraggableCard(
              document: d,
              onDragPosition: onDragPosition,
              onDragState: onDragState,
            ),
          ),
        ),
        if (docs.isEmpty && children.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(28, 0, 0, 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '暂无资料，可导入或拖放到这里',
                style: HomeStyle.text(12, color: HomeStyle.secondary(context)),
              ),
            ),
          ),
      ],
    );
    final header = Row(
      children: [
        Expanded(
          child: InkWell(
            key: ValueKey('knowledge-folder-toggle-${folder.id}'),
            onTap: _editing ? null : () => vm.toggleFolder(folder.id),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Row(
                children: [
                  AnimatedRotation(
                    turns: expanded ? .25 : 0,
                    duration: reduce
                        ? Duration.zero
                        : const Duration(milliseconds: 180),
                    child: Icon(
                      Icons.keyboard_arrow_right,
                      size: 18,
                      color: HomeStyle.secondary(context),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Icon(
                    depth == 0 ? Icons.folder : Icons.folder_copy_outlined,
                    size: 20,
                    color: HomeStyle.blue,
                  ),
                  const SizedBox(width: 9),
                  if (_editing)
                    Expanded(
                      child: TextField(
                        key: ValueKey('knowledge-folder-name-${folder.id}'),
                        controller: _name,
                        focusNode: _nameFocus,
                        enabled: !_renaming,
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => _rename(),
                        style: HomeStyle.text(14, bold: true),
                        decoration: const InputDecoration(
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(vertical: 6),
                          enabledBorder: UnderlineInputBorder(
                            borderSide: BorderSide(color: HomeStyle.blue),
                          ),
                          focusedBorder: UnderlineInputBorder(
                            borderSide: BorderSide(
                              color: HomeStyle.blue,
                              width: 2,
                            ),
                          ),
                        ),
                      ),
                    )
                  else ...[
                    Flexible(
                      child: Text(
                        folder.name,
                        style: HomeStyle.text(14, bold: true),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '${docs.length} 篇',
                      style: HomeStyle.text(
                        11,
                        color: HomeStyle.secondary(context),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
        if (_editing) ...[
          IconButton(
            key: ValueKey('knowledge-folder-save-${folder.id}'),
            tooltip: '保存名称'.tr(context),
            onPressed: _renaming ? null : _rename,
            icon: const Icon(Icons.check, size: 20, color: HomeStyle.blue),
          ),
          IconButton(
            tooltip: '取消修改'.tr(context),
            onPressed: _renaming
                ? null
                : () => setState(() => _editing = false),
            icon: Icon(
              Icons.close,
              size: 18,
              color: HomeStyle.secondary(context),
            ),
          ),
        ] else if (folder.id != 'inbox')
          IconButton(
            key: ValueKey('knowledge-folder-edit-${folder.id}'),
            tooltip: '修改文件夹名称'.tr(context),
            onPressed: vm.saving ? null : _edit,
            icon: Icon(
              Icons.edit_note_outlined,
              size: 20,
              color: HomeStyle.secondary(context),
            ),
          ),
      ],
    );
    return DragTarget<KnowledgeDrag>(
      onWillAcceptWithDetails: (details) =>
          !vm.saving &&
          (!details.data.folder ||
              vm.canMoveFolder(details.data.id, folder.id)),
      onAcceptWithDetails: (details) async {
        final value = details.data;
        final ok = value.folder
            ? await vm.moveFolder(value.id, folder.id)
            : await vm.moveDocument(value.id, folder.id);
        if (ok) {
          vm.expandFolder(folder.id);
        } else if (context.mounted) {
          knowledgeFeedback(context, vm.actionError ?? '移动未完成');
        }
      },
      builder: (context, candidates, _) => Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: EdgeInsets.only(
          left: depth > 0 && depth < 4 ? 8 : 0,
          right: 0,
        ),
        decoration: BoxDecoration(
          color: candidates.isNotEmpty
              ? HomeStyle.blue.withValues(alpha: .055)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (folder.id == 'inbox' || _editing)
              header
            else
              LongPressDraggable<KnowledgeDrag>(
                data: KnowledgeDrag(folder.id, folder: true),
                onDragStarted: () => onDragState(true),
                onDragUpdate: (d) => onDragPosition(d.globalPosition),
                onDragEnd: (_) => onDragState(false),
                feedback: Material(
                  color: Colors.transparent,
                  child: KnowledgeSurface(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.folder, color: HomeStyle.blue),
                        const SizedBox(width: 8),
                        Text(
                          folder.name,
                          style: HomeStyle.text(14, bold: true),
                        ),
                      ],
                    ),
                  ),
                ),
                childWhenDragging: Opacity(opacity: .3, child: header),
                child: header,
              ),
            if (reduce)
              expanded ? content : const SizedBox.shrink()
            else
              AnimatedSize(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOutCubic,
                alignment: Alignment.topCenter,
                child: expanded
                    ? content
                    : const SizedBox(width: double.infinity),
              ),
          ],
        ),
      ),
    );
  }
}

class _KnowledgeDraggableCard extends StatelessWidget {
  const _KnowledgeDraggableCard({
    required this.document,
    required this.onDragPosition,
    required this.onDragState,
  });
  final KnowledgeDocument document;
  final ValueChanged<Offset> onDragPosition;
  final ValueChanged<bool> onDragState;
  @override
  Widget build(BuildContext context) {
    final vm = context.watch<KnowledgeViewModel>();
    final d = document;
    final card = KnowledgeDocumentCard(
      document: d,
      projectName: vm.project(d.projectId).name,
      retrievalLabel: vm.retrievalLabel(d),
      onTap: () => context.push('/knowledge/documents/${d.id}'),
      onRename: (title) async {
        final ok = await vm.renameDocument(d.id, title);
        if (!ok && context.mounted) knowledgeFeedback(context, vm.actionError ?? '名称保存未完成');
        return ok;
      },
    );
    return Dismissible(
      key: ValueKey('knowledge-dismiss-${d.id}'),
      direction: DismissDirection.startToEnd,
      background: Container(
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.only(left: 20),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.error,
          borderRadius: BorderRadius.circular(16),
        ),
        child: const Icon(Icons.delete_outline, color: Colors.white),
      ),
      confirmDismiss: (_) async {
        await _delete(context, vm, d);
        return false;
      },
      child: LongPressDraggable<KnowledgeDrag>(
        data: KnowledgeDrag(d.id),
        onDragStarted: () => onDragState(true),
        onDragUpdate: (value) => onDragPosition(value.globalPosition),
        onDragEnd: (_) => onDragState(false),
        feedback: Material(
          color: Colors.transparent,
          child: Transform.rotate(
            angle: -.035,
            child: SizedBox(
              width: math.min(MediaQuery.sizeOf(context).width * .82, 440),
              child: KnowledgeDocumentCard(
                document: d,
                projectName: vm.project(d.projectId).name,
                retrievalLabel: vm.retrievalLabel(d),
              ),
            ),
          ),
        ),
        childWhenDragging: Opacity(opacity: .3, child: card),
        child: card,
      ),
    );
  }
}

Future<void> _delete(
  BuildContext context,
  KnowledgeViewModel vm,
  KnowledgeDocument d,
) async {
  if (!await showDeleteConfirmation(
    context,
    title: '移除这份资料？',
    message: '将移除该资料及其检索引用，并同步云端知识库；设备原文件和会议记录会保留。',
    action: '移除'.tr(context),
  )) {
    return;
  }
  final ok = await vm.delete(d.id);
  if (context.mounted) {
    knowledgeFeedback(context, ok ? '已从言枢移除' : vm.actionError ?? '移除未完成');
  }
}
