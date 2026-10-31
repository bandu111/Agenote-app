import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../home/views/home_style.dart';
import '../knowledge/repositories/knowledge_importer.dart';
import '../recording_device/recorder_device_view_model.dart';
import '../recording_device/recorder_device_widgets.dart';
import '../../shared/widgets/content_skeleton.dart';
import 'offline_recordings_model.dart';

const transferCategories = ['会议录音', '项目资料', '报价与合同', '培训素材', '未分类'];

class TransferSpacePage extends StatefulWidget {
  const TransferSpacePage({super.key});
  @override
  State<TransferSpacePage> createState() => _TransferSpacePageState();
}

class _TransferSpacePageState extends State<TransferSpacePage> {
  String _query = '', _status = '全部', _type = '全部类型';
  final _selected = <String>{};
  bool _selecting = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_refresh());
    });
  }

  Future<void> _refresh() async {
    final model = context.read<OfflineRecordingsModel>();
    await model.refreshLocal();
    await model.refreshCard();
  }

  void _feedback(Object error) {
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$error')));
    }
  }

  Future<void> _upload() async {
    final model = context.read<OfflineRecordingsModel>();
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['wav', ...knowledgeFileExtensions],
        withData: false,
        allowMultiple: true,
      );
      if (result == null || !mounted) return;
      for (final file in result.files) {
        if (file.path == null) throw const FormatException('无法读取所选文件');
        if (file.name.toLowerCase().endsWith('.wav')) {
          await model.importWav(File(file.path!), file.name);
        } else {
          await model.importDocument(File(file.path!), file.name);
        }
      }
    } catch (e) {
      _feedback(e);
    }
  }

  Future<void> _deviceOptions() async {
    final model = context.read<OfflineRecordingsModel>();
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: HomeStyle.surface(context),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) => SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: const Text('设备与传输'),
                trailing: IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(ctx),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.mic_none),
                title: const Text('我的设备'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Navigator.pop(ctx);
                  context.push('/profile/recording-device');
                },
              ),
              SwitchListTile(
                title: const Text('连接后自动同步'),
                value: model.autoSync,
                onChanged: model.running
                    ? null
                    : (v) async {
                        try {
                          await model.setAutoSync(v);
                          if (ctx.mounted) update(() {});
                        } catch (e) {
                          _feedback(e);
                        }
                      },
              ),
              ListTile(
                leading: const Icon(Icons.visibility_off_outlined),
                title: const Text('隐藏卡内现有录音'),
                subtitle: const Text('只隐藏当前列表记录，不删除卡内原文件'),
                enabled: !model.running && !model.loading,
                onTap: () async {
                  try {
                    await model.ignoreExistingCardRecordings();
                    if (ctx.mounted) Navigator.pop(ctx);
                  } catch (e) {
                    _feedback(e);
                  }
                },
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final model = context.watch<OfflineRecordingsModel>();
    final device = context.watch<RecorderDeviceViewModel>();
    final all = model.items.where((r) => !r.hidden).toList();
    final active = all
        .where(
          (r) => ['downloading', 'uploading', 'decoding'].contains(r.state),
        )
        .length;
    final waiting = all
        .where(
          (r) =>
              !r.complete &&
              !['downloading', 'uploading', 'decoding'].contains(r.state),
        )
        .length;
    final complete = all.where((r) => r.complete).length;
    final rows = all
        .where(
          (r) =>
              (_type == '全部类型' || r.fileType == _type) &&
              (_status == '全部' ||
                  (_status == '已完成'
                      ? r.complete
                      : _status == '传输中'
                      ? [
                          'downloading',
                          'uploading',
                          'decoding',
                        ].contains(r.state)
                      : !r.complete &&
                            ![
                              'downloading',
                              'uploading',
                              'decoding',
                            ].contains(r.state))) &&
              '${r.displayName} ${r.category} ${r.note}'.toLowerCase().contains(
                _query.trim().toLowerCase(),
              ),
        )
        .toList();
    final muted = HomeStyle.secondary(context),
        ink = HomeStyle.foreground(context);
    return Scaffold(
      backgroundColor: HomeStyle.canvas(context),
      appBar: AppBar(
        backgroundColor: HomeStyle.canvas(context),
        surfaceTintColor: Colors.transparent,
        leading: Center(
          child: SizedBox(
            width: 32,
            height: 32,
            child: IconButton.outlined(
              padding: EdgeInsets.zero,
              onPressed: () => context.pop(),
              icon: const Icon(Icons.chevron_left, size: 20),
              tooltip: '返回',
              style: IconButton.styleFrom(
                side: BorderSide(color: HomeStyle.blue.withValues(alpha: .12)),
                backgroundColor: HomeStyle.surface(context),
              ),
            ),
          ),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('文件传输', style: HomeStyle.text(10, color: muted)),
            Text('传输空间', style: HomeStyle.text(18, bold: true, color: ink)),
          ],
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: FilledButton.icon(
              onPressed: model.importing || model.running ? null : _upload,
              icon: const Icon(Icons.file_upload_outlined, size: 17),
              label: const Text('上传', style: TextStyle(fontSize: 11)),
              style: FilledButton.styleFrom(
                backgroundColor: HomeStyle.blue,
                minimumSize: const Size(62, 32),
                padding: const EdgeInsets.symmetric(horizontal: 14),
                shape: const StadiumBorder(),
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: RefreshIndicator(
              onRefresh: _refresh,
              child: CustomScrollView(
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    sliver: SliverList.list(
                      children: [
                        Text(
                          '手机、知识库、录音卡之间来回走的文件，都在这里管。',
                          style: HomeStyle.text(10, color: muted),
                        ),
                        const SizedBox(height: 14),
                        GestureDetector(
                          onTap: _deviceOptions,
                          child: _surface(
                            context,
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        '录音卡${device.info.totalKb == null ? '' : ' · ${deviceCapacity(device.info.totalKb)}'}',
                                        style: HomeStyle.text(
                                          12,
                                          bold: true,
                                          color: ink,
                                        ),
                                      ),
                                    ),
                                    Text(
                                      device.info.usedKb == null
                                          ? '容量未读取'
                                          : '已用 ${deviceCapacity(device.info.usedKb)}',
                                      style: HomeStyle.text(10, color: muted),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 9),
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(5),
                                  child: LinearProgressIndicator(
                                    minHeight: 5,
                                    value:
                                        device.info.totalKb != null &&
                                            device.info.totalKb! > 0 &&
                                            device.info.usedKb != null
                                        ? (device.info.usedKb! /
                                                  device.info.totalKb!)
                                              .clamp(0, 1)
                                        : 0,
                                    color: const Color(0xFF60639C),
                                    backgroundColor: HomeStyle.tint(context),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                Row(
                                  children: [
                                    for (final pair in [
                                      (active, '传输中'),
                                      (waiting, '等待传输'),
                                      (complete, '已完成'),
                                    ])
                                      Expanded(
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 3,
                                          ),
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 10,
                                              vertical: 5,
                                            ),
                                            decoration: BoxDecoration(
                                              color: HomeStyle.tint(context),
                                              borderRadius:
                                                  BorderRadius.circular(12),
                                            ),
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  '${pair.$1}',
                                                  style: HomeStyle.text(
                                                    14,
                                                    color: HomeStyle.blue,
                                                  ),
                                                ),
                                                Text(
                                                  pair.$2,
                                                  style: HomeStyle.text(
                                                    9,
                                                    color: muted,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                                const SizedBox(height: 7),
                                Text(
                                  '待传输 ${_size(all.where((r) => !r.complete).fold<int>(0, (v, r) => v + r.size))}',
                                  style: HomeStyle.text(9, color: muted),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          onChanged: (v) => setState(() => _query = v),
                          style: HomeStyle.text(13, color: ink),
                          decoration: InputDecoration(
                            hintText: '查文件名、分类或备注',
                            hintStyle: HomeStyle.text(11, color: muted),
                            prefixIcon: Icon(
                              Icons.search,
                              size: 19,
                              color: muted,
                            ),
                            filled: true,
                            fillColor: HomeStyle.surface(context),
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 9,
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(22),
                              borderSide: BorderSide(
                                color: HomeStyle.blue.withValues(alpha: .10),
                              ),
                            ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(22),
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        _filters(
                          ['全部', '传输中', '等待传输', '已完成'],
                          _status,
                          (v) => setState(() => _status = v),
                        ),
                        const SizedBox(height: 7),
                        _filters(
                          ['全部类型', '录音', '文档', '图片', '视频'],
                          _type,
                          (v) => setState(() => _type = v),
                        ),
                        const SizedBox(height: 7),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '${rows.length} 个文件 · 共 ${_size(rows.fold<int>(0, (v, r) => v + r.size))}',
                                style: HomeStyle.text(10, color: muted),
                              ),
                            ),
                            TextButton(
                              onPressed: () => setState(() {
                                _selecting = !_selecting;
                                _selected.clear();
                                if (_selecting) {
                                  _selected.addAll(
                                    rows
                                        .where((r) => !r.complete)
                                        .map((r) => r.id),
                                  );
                                }
                              }),
                              style: TextButton.styleFrom(
                                minimumSize: const Size(0, 26),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                ),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                textStyle: const TextStyle(fontSize: 10),
                              ),
                              child: Text(_selecting ? '取消选择' : '选择'),
                            ),
                          ],
                        ),
                        if (model.error != null)
                          _surface(
                            context,
                            Text(
                              model.error!,
                              style: HomeStyle.text(
                                12,
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ),
                        if (model.importing || (model.loading && all.isEmpty))
                          const ContentSkeleton(rows: 2),
                        if (rows.isEmpty && !model.loading && !model.importing)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 50),
                            child: Center(
                              child: Text(
                                _query.isEmpty
                                    ? '暂无${_type == '全部类型' ? '' : _type}传输记录'
                                    : '没有找到匹配的文件',
                                style: HomeStyle.text(13, color: muted),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    sliver: SliverList.builder(
                      itemCount: rows.length,
                      itemBuilder: (context, i) => Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: _file(context, model, rows[i]),
                      ),
                    ),
                  ),
                  const SliverToBoxAdapter(child: SizedBox(height: 25)),
                ],
              ),
            ),
          ),
        ),
      ),
      bottomNavigationBar:
          (!_selecting && !model.running) || (waiting == 0 && !model.running)
          ? null
          : SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
                child: FilledButton(
                  onPressed: model.running
                      ? () => unawaited(model.pause())
                      : _selecting && _selected.isEmpty
                      ? null
                      : () => unawaited(
                          model.sync(selected: _selecting ? _selected : null),
                        ),
                  style: FilledButton.styleFrom(
                    backgroundColor: HomeStyle.blue,
                    minimumSize: const Size.fromHeight(46),
                    shape: const StadiumBorder(),
                  ),
                  child: Text(
                    model.running
                        ? '暂停传输'
                        : _selecting
                        ? '开始传输 ${_selected.length} 个文件'
                        : '传输全部待处理文件',
                  ),
                ),
              ),
            ),
    );
  }

  Widget _filters(
    List<String> values,
    String selected,
    ValueChanged<String> change,
  ) {
    final types = values.first == '全部类型';
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final value in values)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Semantics(
                button: true,
                selected: selected == value,
                child: InkWell(
                  onTap: () => change(value),
                  borderRadius: BorderRadius.circular(20),
                  child: Container(
                    height: types ? 22 : 26,
                    alignment: Alignment.center,
                    padding: EdgeInsets.symmetric(horizontal: types ? 9 : 11),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(20),
                      color: !types && selected == value
                          ? HomeStyle.blue
                          : HomeStyle.surface(context),
                      border: Border.all(
                        color: selected == value
                            ? HomeStyle.blue
                            : HomeStyle.blue.withValues(alpha: .12),
                      ),
                    ),
                    child: Text(
                      value,
                      style: HomeStyle.text(
                        types ? 9 : 10,
                        color: selected == value
                            ? (types ? HomeStyle.blue : Colors.white)
                            : HomeStyle.secondary(context),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _file(
    BuildContext context,
    OfflineRecordingsModel model,
    OfflineRecording item,
  ) {
    final muted = HomeStyle.secondary(context);
    return _surface(
      context,
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_selecting)
                Checkbox(
                  value: _selected.contains(item.id),
                  onChanged: model.running || item.complete
                      ? null
                      : (v) => setState(() {
                          v == true
                              ? _selected.add(item.id)
                              : _selected.remove(item.id);
                        }),
                ),
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: HomeStyle.tint(context),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  item.fileType == '录音'
                      ? Icons.mic_none
                      : Icons.description_outlined,
                  size: 18,
                  color: HomeStyle.blue,
                ),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: HomeStyle.text(
                        11,
                        bold: true,
                        color: HomeStyle.foreground(context),
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${item.fileType} · ${_size(item.size)} · ${item.category}',
                      style: HomeStyle.text(9, color: muted),
                    ),
                  ],
                ),
              ),
              _action(
                Icons.edit_outlined,
                '编辑文件信息',
                model.running ? null : () => showTransferEditor(context, item),
              ),
              _action(
                Icons.delete_outline,
                '删除传输记录',
                model.running ? null : () => showTransferDelete(context, item),
              ),
            ],
          ),
          const SizedBox(height: 7),
          Wrap(
            spacing: 7,
            runSpacing: 5,
            children: [
              _badge(context, '去知识库', Icons.cloud_outlined, true),
              _badge(
                context,
                model.label(item),
                item.complete ? Icons.check_circle_outline : Icons.schedule,
                false,
              ),
            ],
          ),
          if (item.complete) ...[
            const SizedBox(height: 6),
            Text(
              '已上传 · ${item.startedAt.month}月${item.startedAt.day}日的录音或文件',
              style: HomeStyle.text(10, color: HomeStyle.blue),
            ),
          ],
          const SizedBox(height: 7),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: HomeStyle.tint(context),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    item.error ??
                        (item.note.isNotEmpty
                            ? item.note
                            : item.deviceId == 'phone'
                            ? '保留原文件，可上传到知识库'
                            : '录音卡本地录音，连接后可同步'),
                    style: HomeStyle.text(
                      9,
                      color: item.error == null
                          ? muted
                          : Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
                if (!item.complete && !model.running)
                  TextButton(
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      textStyle: const TextStyle(fontSize: 9),
                      minimumSize: const Size(0, 24),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                    ),
                    onPressed: () => unawaited(model.sync(selected: {item.id})),
                    child: Text(item.state == 'failed' ? '重试传输' : '立即传输'),
                  ),
              ],
            ),
          ),
          if (item.state == 'downloading')
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: LinearProgressIndicator(value: item.progress),
            ),
          if (item.state == 'uploading' || item.state == 'decoding')
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: LinearProgressIndicator(),
            ),
        ],
      ),
    );
  }

  Widget _action(IconData icon, String tooltip, VoidCallback? tap) => SizedBox(
    width: 28,
    height: 28,
    child: IconButton.filledTonal(
      style: IconButton.styleFrom(backgroundColor: HomeStyle.tint(context)),
      tooltip: tooltip,
      padding: EdgeInsets.zero,
      onPressed: tap,
      icon: Icon(icon, size: 14, color: HomeStyle.secondary(context)),
    ),
  );
}

Widget _surface(BuildContext context, Widget child) => Container(
  padding: const EdgeInsets.all(12),
  decoration: BoxDecoration(
    color: HomeStyle.surface(context),
    borderRadius: BorderRadius.circular(16),
    border: Border.all(color: HomeStyle.blue.withValues(alpha: .10)),
  ),
  child: child,
);
Widget _badge(BuildContext context, String label, IconData icon, bool blue) =>
    Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: HomeStyle.tint(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: HomeStyle.blue.withValues(alpha: .12)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 11,
            color: blue ? HomeStyle.blue : HomeStyle.secondary(context),
          ),
          const SizedBox(width: 4),
          Text(
            label,
            style: HomeStyle.text(
              9,
              color: blue ? HomeStyle.blue : HomeStyle.secondary(context),
            ),
          ),
        ],
      ),
    );
String _size(int value) => value < 1024 * 1024
    ? (value < 1024 ? '$value B' : '${(value / 1024).toStringAsFixed(0)} KB')
    : '${(value / 1024 / 1024).toStringAsFixed(1)} MB';

Future<void> showTransferDelete(
  BuildContext context,
  OfflineRecording item,
) async {
  final model = context.read<OfflineRecordingsModel>();
  final remove = await showModalBottomSheet<bool>(
    context: context,
    useSafeArea: true,
    backgroundColor: HomeStyle.surface(context),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (ctx) => SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.delete_outline,
                  color: Color(0xFFD82532),
                  size: 20,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '删除这条传输记录？',
                        style: HomeStyle.text(
                          15,
                          bold: true,
                          color: HomeStyle.foreground(ctx),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '“${item.displayName}”会从列表里消失。卡内原文件及已经放进知识库的资料不会被删除。',
                        style: HomeStyle.text(
                          12,
                          color: HomeStyle.secondary(ctx),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('先留着'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFD82532),
                    ),
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('确认删除'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
  if (remove == true) {
    try {
      await model.removeRecord(item);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }
}

Future<void> showTransferEditor(BuildContext context, OfflineRecording item) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: HomeStyle.canvas(context),
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(25)),
      ),
      builder: (_) => ChangeNotifierProvider.value(
        value: context.read<OfflineRecordingsModel>(),
        child: _TransferEditor(item: item),
      ),
    );

class _TransferEditor extends StatefulWidget {
  const _TransferEditor({required this.item});
  final OfflineRecording item;
  @override
  State<_TransferEditor> createState() => _TransferEditorState();
}

class _TransferEditorState extends State<_TransferEditor> {
  late final _name = TextEditingController(text: widget.item.displayName);
  late final _note = TextEditingController(text: widget.item.note);
  late String _category = widget.item.category;
  bool _saving = false;
  String? _error;
  bool get changed =>
      _name.text.trim() != widget.item.displayName ||
      _note.text != widget.item.note ||
      _category != widget.item.category;
  @override
  void dispose() {
    _name.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await context.read<OfflineRecordingsModel>().updateInfo(
        widget.item,
        _name.text,
        _category,
        _note.text,
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _saving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final muted = HomeStyle.secondary(context),
        ink = HomeStyle.foreground(context);
    InputDecoration input(String hint) => InputDecoration(
      hintText: hint,
      isDense: true,
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(13),
        borderSide: const BorderSide(color: HomeStyle.blue, width: 1.2),
      ),
      filled: true,
      fillColor: HomeStyle.surface(context),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: HomeStyle.blue.withValues(alpha: .12)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: HomeStyle.blue.withValues(alpha: .12)),
      ),
    );
    Widget label(String text) => Padding(
      padding: const EdgeInsets.only(top: 15, bottom: 7),
      child: Text(text, style: HomeStyle.text(10, color: muted)),
    );
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * .54,
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SafeArea(
          top: false,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 12, 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '文件信息',
                        style: HomeStyle.text(16, bold: true, color: ink),
                      ),
                    ),
                    IconButton.filledTonal(
                      style: IconButton.styleFrom(
                        backgroundColor: HomeStyle.tint(context),
                        foregroundColor: muted,
                        fixedSize: const Size(34, 34),
                      ),
                      tooltip: '关闭',
                      onPressed: _saving ? null : () => Navigator.pop(context),
                      icon: const Icon(Icons.close, size: 18),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  key: const ValueKey('transfer-editor-scroll'),
                  padding: const EdgeInsets.fromLTRB(20, 6, 20, 20),
                  children: [
                    ListTile(
                      dense: true,
                      visualDensity: VisualDensity.compact,
                      minVerticalPadding: 4,
                      contentPadding: EdgeInsets.zero,
                      leading: CircleAvatar(
                        radius: 17,
                        backgroundColor: HomeStyle.tint(context),
                        child: Icon(
                          widget.item.fileType == '录音'
                              ? Icons.mic_none
                              : Icons.description_outlined,
                          color: HomeStyle.blue,
                        ),
                      ),
                      title: Text(
                        '${_size(widget.item.size)} · ${widget.item.fileType}',
                        style: HomeStyle.text(12, color: ink),
                      ),
                      subtitle: Text(
                        context.read<OfflineRecordingsModel>().label(
                          widget.item,
                        ),
                        style: HomeStyle.text(10, color: muted),
                      ),
                    ),
                    label('文件名'),
                    TextField(
                      controller: _name,
                      style: HomeStyle.text(13, color: ink),
                      enabled: !_saving,
                      maxLength: 120,
                      onChanged: (_) => setState(() {}),
                      decoration: input('输入文件名').copyWith(counterText: ''),
                    ),
                    label('送到哪里'),
                    Wrap(
                      spacing: 8,
                      children: [
                        ChoiceChip(
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          labelPadding: const EdgeInsets.symmetric(
                            horizontal: 7,
                          ),
                          shape: const StadiumBorder(),
                          label: const Text('知识库'),
                          selected: true,
                          showCheckmark: false,
                          selectedColor: HomeStyle.blue,
                          labelStyle: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                          ),
                          onSelected: (_) {},
                        ),
                        const Tooltip(
                          message: '当前录音卡 SDK 尚未确认支持写入文件',
                          child: Chip(
                            label: Text(
                              '录音卡 · 暂不支持',
                              style: TextStyle(fontSize: 11),
                            ),
                            shape: StadiumBorder(),
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                      ],
                    ),
                    label('分类'),
                    Wrap(
                      spacing: 7,
                      runSpacing: 6,
                      children: [
                        for (final c in transferCategories)
                          ChoiceChip(
                            padding: const EdgeInsets.symmetric(horizontal: 3),
                            labelPadding: const EdgeInsets.symmetric(
                              horizontal: 6,
                            ),
                            visualDensity: VisualDensity.compact,
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                            label: Text(c),
                            selected: _category == c,
                            showCheckmark: false,
                            onSelected: _saving
                                ? null
                                : (_) => setState(() => _category = c),
                            selectedColor: const Color(0xFF60639C),
                            labelStyle: HomeStyle.text(
                              11,
                              color: _category == c ? Colors.white : muted,
                            ),
                            shape: const StadiumBorder(),
                          ),
                      ],
                    ),
                    label('备注（可选）'),
                    TextField(
                      controller: _note,
                      style: HomeStyle.text(13, color: ink),
                      enabled: !_saving,
                      maxLength: 200,
                      minLines: 3,
                      maxLines: 5,
                      onChanged: (_) => setState(() {}),
                      decoration: input('添加备注'),
                    ),
                    if (_error != null)
                      Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed:
                          changed && !_saving && _name.text.trim().isNotEmpty
                          ? _save
                          : null,
                      style: FilledButton.styleFrom(
                        backgroundColor: HomeStyle.blue,
                        minimumSize: const Size.fromHeight(46),
                        shape: const StadiumBorder(),
                      ),
                      child: Text(
                        _saving
                            ? '正在保存'
                            : changed
                            ? '保存修改'
                            : '还没有改动',
                      ),
                    ),
                    TextButton(
                      onPressed: _saving
                          ? null
                          : () async {
                              await showTransferDelete(context, widget.item);
                              if (context.mounted && widget.item.hidden) {
                                Navigator.pop(context);
                              }
                            },
                      child: const Text(
                        '删除这个文件',
                        style: TextStyle(color: Color(0xFFD82532)),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
