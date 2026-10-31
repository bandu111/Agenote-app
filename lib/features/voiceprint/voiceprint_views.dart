part of 'voiceprint_page.dart';

// The Readdy voiceprint flow, backed by the existing account-scoped enrollment.
// Prototype-only toggles, noise readings and simulated matches are excluded.
class _VoiceprintView extends StatelessWidget {
  const _VoiceprintView({required this.state});
  final _VoiceprintPageState state;

  @override
  Widget build(BuildContext context) {
    final s = state;
    final title = switch (s._stage) {
      _VoiceStage.home => s._registered ? '你的声纹' : '先注册你的声纹',
      _VoiceStage.prepare => '录音前检查',
      _VoiceStage.record => '录 3 段声音',
      _VoiceStage.verify => '独立验证',
      _VoiceStage.success => '你的声纹',
    };
    final subtitle = switch (s._stage) {
      _VoiceStage.home =>
        s._registered ? '关闭、重录或删除都在这里管理。' : '把本人声音与会议里的匿名发言人关联起来。',
      _VoiceStage.prepare => '确认设备与环境，再开始采集。',
      _VoiceStage.record => '前一段通过才会解锁下一段。',
      _VoiceStage.verify => '用一段全新的声音，完成独立声音验证。',
      _VoiceStage.success => '三段采集与独立验证已完成。',
    };
    return Scaffold(
      backgroundColor: _vpBackground(context),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 20, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          IconButton(
                            key: const ValueKey('voiceprint-back'),
                            tooltip: '返回',
                            onPressed: s._busy || s._recording || s._stopping
                                ? null
                                : s._back,
                            style: IconButton.styleFrom(
                              backgroundColor: _vpSurface(context),
                              side: BorderSide(color: _vpLine(context)),
                            ),
                            icon: const Icon(
                              Icons.chevron_left_rounded,
                              size: 23,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _VpText(
                                  '我的声纹',
                                  size: 10,
                                  muted: true,
                                  spacing: 1.6,
                                ),
                                const SizedBox(height: 5),
                                Text(
                                  title,
                                  style: TextStyle(
                                    fontSize: 21,
                                    height: 1.2,
                                    letterSpacing: -.6,
                                    fontWeight: FontWeight.w500,
                                    color: _vpInk(context),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 6),
                          _VpTag(
                            s._registered
                                ? '已注册'
                                : s._acceptedCount > 0
                                ? '已通过 ${s._acceptedCount}/3'
                                : '未注册',
                            active: s._registered,
                          ),
                        ],
                      ),
                      const SizedBox(height: 7),
                      _VpText(subtitle, size: 12, muted: true),
                    ],
                  ),
                ),
                Expanded(
                  child: s._data == null && s._error == null
                      ? const ContentSkeleton(
                          layout: SkeletonLayout.detail,
                          label: '正在加载声纹状态',
                        )
                      : ListView(
                          key: ValueKey('voiceprint-scroll-${s._stage.name}'),
                          padding: const EdgeInsets.fromLTRB(20, 14, 20, 28),
                          children: [
                            if (s._error != null) ...[
                              _VpPanel(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      s._error!,
                                      style: TextStyle(
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.error,
                                        fontSize: 13,
                                        height: 1.5,
                                      ),
                                    ),
                                    TextButton(
                                      key: const ValueKey('voiceprint-refresh'),
                                      onPressed:
                                          s._busy || s._recording || s._stopping
                                          ? null
                                          : s._refresh,
                                      child: const Text('重新检查状态'),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 12),
                            ],
                            if (s._data != null)
                              _VpEntrance(
                                key: ValueKey(s._stage),
                                child: switch (s._stage) {
                                  _VoiceStage.home => _home(context),
                                  _VoiceStage.prepare => _prepare(context),
                                  _VoiceStage.record => _recorder(
                                    context,
                                    s._activeIndex,
                                  ),
                                  _VoiceStage.verify => _recorder(context, 3),
                                  _VoiceStage.success => _success(context),
                                },
                              ),
                          ],
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _home(BuildContext context) {
    final s = state;
    final registered = s._registered;
    final enabled = s._data?['enabled'] == true;
    return _VpStack(
      children: [
        _VpPanel(
          radius: 22,
          tinted: registered && enabled,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _VpIcon(
                    Icons.fingerprint_rounded,
                    large: true,
                    filled: registered && enabled,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            _VpText(
                              registered
                                  ? enabled
                                        ? '声纹已启用'
                                        : '声纹已关闭'
                                  : '尚未注册声纹',
                              size: 18,
                              weight: FontWeight.w500,
                            ),
                            _VpTag(
                              registered
                                  ? enabled
                                        ? '已验证'
                                        : '模板保留'
                                  : '未注册',
                              active: enabled,
                            ),
                          ],
                        ),
                        const SizedBox(height: 7),
                        _VpText(
                          registered
                              ? enabled
                                    ? '三段采集与独立验证已完成，可在这里管理你的声音模板。'
                                    : '模板还在，只是暂时停用。重新打开不用重录。'
                              : '注册自己的声音模板，为本人声音与会议匿名发言人的关联做好准备。',
                          size: 12,
                          muted: true,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              if (registered) ...[
                Row(
                  children: [
                    Expanded(
                      child: _VpMetric(
                        '最近验证时间',
                        _formatVoiceDate(s._data?['verifiedAt']),
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Expanded(child: _VpMetric('声纹模板', '3 段 · 已生成')),
                  ],
                ),
                const SizedBox(height: 10),
                _VpText(
                  '模板版本 ${s._data?['version'] ?? '—'} · 手机内置麦克风采集',
                  size: 10,
                  muted: true,
                ),
              ] else
                const Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    _VpTag('约 3 分钟'),
                    _VpTag('3 段声音 + 1 次验证'),
                    _VpTag('可随时撤回'),
                  ],
                ),
            ],
          ),
        ),
        if (s._data?['available'] != true)
          _VpPanel(
            child: _VpStack(
              gap: 8,
              children: [
                const _VpText('声纹服务暂不可用', size: 14, weight: FontWeight.w500),
                const _VpText('请稍后重试，已有声纹不会被覆盖。', muted: true),
                _VpButton(
                  '重新检查',
                  onPressed: s._blocked ? null : s._refresh,
                  outlined: true,
                ),
              ],
            ),
          ),
        if (s._enrollment != null)
          _VpPanel(
            tinted: true,
            child: _VpStack(
              gap: 10,
              children: [
                const _VpText('有一份未完成的注册', size: 14, weight: FontWeight.w500),
                _VpText(
                  '已通过 ${s._acceptedCount}/3 段。注册进度保留至 ${_formatVoiceDate(s._enrollment?['expiresAt'])}。',
                  muted: true,
                ),
                _VpButton(
                  s._enrollment?['status'] == 'ready' ? '去完成独立验证' : '继续未完成的注册',
                  key: const ValueKey('voiceprint-resume'),
                  outlined: true,
                  onPressed: s._blocked
                      ? null
                      : () => s._showStage(
                          s._enrollment?['status'] == 'ready'
                              ? _VoiceStage.verify
                              : _VoiceStage.prepare,
                        ),
                ),
              ],
            ),
          ),
        if (!registered) ...[
          _VpPanel(
            child: _VpStack(
              gap: 12,
              children: [
                const _VpText('注册前请准备好', size: 11, muted: true, spacing: 1.2),
                ..._voiceRules.map(
                  (r) => _VpInfoRow(icon: r.$1, title: r.$2, note: r.$3),
                ),
              ],
            ),
          ),
          if (s._enrollment == null)
            _VpButton(
              '开始注册声纹',
              icon: Icons.mic_none_rounded,
              onPressed: s._blocked || s._data?['available'] != true
                  ? null
                  : s._begin,
            ),
        ] else
          _VpPanel(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                _VpSetting(
                  icon: Icons.verified_user_outlined,
                  title: '启用声纹比对',
                  note: '关闭只停用并取消未完成的注册，模板保留',
                  trailing: Switch.adaptive(
                    value: enabled,
                    onChanged: s._blocked
                        ? null
                        : (v) => s._run(
                            () => s.widget.repository.post('/enabled', {
                              'enabled': v,
                            }),
                          ),
                  ),
                ),
                Divider(height: 1, color: _vpLine(context)),
                _VpSetting(
                  icon: Icons.mic_none_rounded,
                  title: '重新录制声纹',
                  note: '重新走三段采集 + 独立验证，验证通过后更新模板',
                  onTap:
                      s._blocked ||
                          s._enrollment != null ||
                          s._data?['available'] != true
                      ? null
                      : () async {
                          if (await s._confirm(
                                '重新录制声纹？',
                                '需要重新完成三段采集和独立验证。新模板验证通过后才会替换现有模板。',
                                '重新录制',
                              ) &&
                              s.mounted) {
                            await s._begin();
                          }
                        },
                ),
                Divider(height: 1, color: _vpLine(context)),
                _VpSetting(
                  icon: Icons.delete_outline_rounded,
                  title: '撤回同意并删除声纹',
                  note: '删除模板和未完成的数据，回到未注册状态',
                  danger: true,
                  onTap: s._blocked ? null : s._deleteVoiceprint,
                ),
              ],
            ),
          ),
        _VpPanel(
          quiet: true,
          child: _VpStack(
            gap: 7,
            children: [
              const _VpText('关于你的声纹', size: 11, muted: true, spacing: 1.2),
              _VpText(
                s._data?['realtimeIdentificationAvailable'] == true
                    ? '声纹仅用于本人声音与匿名发言人的关联，不用于实名或操作授权。'
                    : '本阶段已支持声纹注册与验证，尚未接入会议实时本人识别。不注册也可正常使用会议。',
                size: 11,
                muted: true,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _prepare(BuildContext context) {
    final s = state;
    final denied = s._permission != null && !s._permission!.isGranted;
    final meeting = s.widget.isMeetingRecording();
    return _VpStack(
      children: [
        if (meeting)
          const _VpPanel(
            child: _VpStack(
              gap: 8,
              children: [
                _VpInfoRow(
                  icon: Icons.mic_off_outlined,
                  title: '现在正在录音，不能注册声纹',
                  note: '请先结束当前会议，再回来独自录制。会议音频不会用于本次声纹注册。',
                ),
              ],
            ),
          )
        else ...[
          if (denied)
            _VpPanel(
              child: _VpStack(
                gap: 8,
                children: [
                  const _VpInfoRow(
                    icon: Icons.mic_off_outlined,
                    title: '麦克风权限未开启',
                    note: '请允许 Agenote 使用麦克风，再继续录制。',
                  ),
                  _VpButton(
                    '去系统设置',
                    outlined: true,
                    onPressed: () async {
                      await openAppSettings();
                    },
                  ),
                ],
              ),
            ),
          _VpPanel(
            child: _VpStack(
              gap: 12,
              children: [
                const _VpText('录音前检查', size: 11, muted: true, spacing: 1.2),
                const _VpInfoRow(
                  icon: Icons.phone_iphone_rounded,
                  title: '当前采音设备',
                  note: '手机内置麦克风 · 开始录制后核实实际采音路线',
                  filled: true,
                ),
                const _VpInfoRow(
                  icon: Icons.volume_off_outlined,
                  title: '环境噪声',
                  note: '请在安静环境下录制，声音质量由服务端检查',
                ),
                const _VpInfoRow(
                  icon: Icons.graphic_eq_rounded,
                  title: '会议录音状态',
                  note: '当前未在录音 · 录音期间不能注册声纹',
                ),
                _VpInfoRow(
                  icon: Icons.checklist_rounded,
                  title: '片段进度',
                  note: s._acceptedCount == 0
                      ? '还没有通过的片段 · 从第 1 段开始'
                      : '已通过 ${s._acceptedCount}/3 段 · 通过的片段会保留',
                ),
              ],
            ),
          ),
          _VpPanel(
            quiet: true,
            child: _VpStack(
              gap: 10,
              children: [
                const _VpText('录制时会要求', size: 11, muted: true, spacing: 1.2),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: _voiceRules.map((r) => _VpTag(r.$2)).toList(),
                ),
              ],
            ),
          ),
          _VpButton(
            denied
                ? '重新检查并继续'
                : s._acceptedCount > 0
                ? '接着录第 ${s._nextIndex + 1} 段'
                : '检查麦克风并继续',
            key: const ValueKey('voiceprint-prepare'),
            loading: s._busy,
            onPressed: s._blocked ? null : s._prepareRecording,
          ),
          const _VpText(
            '每段 8～20 秒，建议 10～15 秒；到 20 秒会自动停止。',
            size: 11,
            muted: true,
            center: true,
          ),
        ],
      ],
    );
  }

  Widget _recorder(BuildContext context, int index) {
    final s = state;
    final verification = index == 3;
    final slot = verification ? 'verification' : '$index';
    final sample = s._samples[slot] as Map?;
    final current = s._slot == slot;
    final phase = current && s._stopping
        ? 'saving'
        : current && s._recording
        ? 'recording'
        : s._uploadingSlot == slot
        ? 'uploading'
        : current && s._path != null
        ? 'pending'
        : sample?['status'] ?? 'missing';
    final accepted = phase == 'accepted';
    final waiting = ['saving', 'uploading', 'processing'].contains(phase);
    final prompts = s._enrollment?['prompts'] as List? ?? [];
    final speech = (sample?['quality'] as Map?)?['speechSeconds'];
    final attempts = (s._enrollment?['attempts'] as num?)?.toInt() ?? 0;
    final canRecord =
        !s._blocked &&
        (!verification || attempts < 3) &&
        (s._path == null || current);
    final status = switch (phase) {
      'recording' => '正在录音',
      'saving' => '正在保存录音',
      'uploading' => '录音已保存 · 正在上传',
      'pending' => '录音已保存 · 待重试上传',
      'processing' => '上传成功 · 正在检查',
      'accepted' => '已通过 · 已保存',
      'rejected' => '未通过检查 · 需要重录',
      _ => '待录制',
    };
    return _VpStack(
      children: [
        if (!verification)
          _VpPanel(
            child: _VpStack(
              gap: 10,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const _VpText('三段录制', size: 11, muted: true, spacing: 1.2),
                    _VpText('${s._acceptedCount}/3 已通过', size: 11, muted: true),
                  ],
                ),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: List.generate(
                    3,
                    (i) => Expanded(
                      child: Padding(
                        padding: EdgeInsets.only(right: i == 2 ? 0 : 6),
                        child: Semantics(
                          selected: i == index,
                          child: InkWell(
                            key: ValueKey('voiceprint-select-$i'),
                            borderRadius: BorderRadius.circular(6),
                            onTap:
                                s._blocked ||
                                    s._path != null ||
                                    (!s._accepted(i) && i != s._nextIndex)
                                ? null
                                : () => s._selectSample(i),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Container(
                                    height: 3,
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(3),
                                      color: s._accepted(i)
                                          ? Theme.of(
                                              context,
                                            ).colorScheme.primary
                                          : i == index
                                          ? Theme.of(context)
                                                .colorScheme
                                                .primary
                                                .withValues(alpha: .35)
                                          : _vpLine(context),
                                    ),
                                  ),
                                  const SizedBox(height: 7),
                                  _VpText(
                                    '第 ${i + 1} 段 · ${s._accepted(i)
                                        ? '已通过'
                                        : i == index
                                        ? '进行中'
                                        : '待录制'}',
                                    size: 10,
                                    muted: !s._accepted(i),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        _VpPanel(
          tinted: verification,
          child: _VpStack(
            gap: 12,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _VpText(
                    verification ? '独立验证' : '第 ${index + 1} 段',
                    size: 11,
                    muted: true,
                    spacing: 1.2,
                  ),
                  if (verification)
                    _VpTag('第 ${attempts + 1} 次')
                  else if (accepted)
                    const _VpTag('已通过', active: true),
                ],
              ),
              if (prompts.length > index)
                _VpText(
                  '${prompts[index]}',
                  size: verification ? 17 : 18,
                  height: 1.85,
                ),
              _VpText(
                verification
                    ? '这是全新的内容，不参与前三段模板生成，只用于独立比对。'
                    : '自然朗读，不需要刻意改变音色；请保持距离和正常音量。',
                size: 11,
                muted: true,
              ),
            ],
          ),
        ),
        _VpPanel(
          key: ValueKey('voiceprint-step-$slot'),
          tinted: accepted,
          child: _VpStack(
            gap: 12,
            children: [
              _VpText(
                status,
                key: ValueKey('voiceprint-state-$slot'),
                size: 13,
                weight: FontWeight.w500,
              ),
              if (waiting) ...[
                _VpText(
                  verification ? '正在与声纹比对' : '正在检查声音质量',
                  size: 12,
                  muted: true,
                ),
                LinearProgressIndicator(
                  minHeight: 3,
                  value: MediaQuery.disableAnimationsOf(context) ? 0 : null,
                  borderRadius: BorderRadius.circular(3),
                ),
                const _VpText('通过检查后会明确提示下一步，请稍候。', size: 11, muted: true),
              ] else if (accepted) ...[
                Row(
                  children: [
                    Expanded(
                      child: _VpMetric(
                        '有效语音时长',
                        speech is num
                            ? '${speech.toStringAsFixed(1)} 秒'
                            : '已通过检查',
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Expanded(child: _VpMetric('检查结果', '已通过')),
                  ],
                ),
                if (s._acceptedCount == 3)
                  _VpButton(
                    '生成声纹并进入验证',
                    key: const ValueKey('voiceprint-build'),
                    loading: s._busy,
                    onPressed: s._blocked ? null : s._buildTemplate,
                  )
                else
                  _VpButton(
                    '录第 ${s._nextIndex + 1} 段',
                    key: const ValueKey('voiceprint-next'),
                    onPressed: s._blocked
                        ? null
                        : () => s._selectSample(s._nextIndex),
                  ),
                _VpButton(
                  '重录第 ${index + 1} 段',
                  key: ValueKey('voiceprint-record-$slot'),
                  outlined: true,
                  onPressed: canRecord ? () => s._start(slot) : null,
                ),
              ] else ...[
                if (phase == 'rejected')
                  _VpText(s._reason(sample?['reason']), size: 12, muted: true),
                if (verification && attempts >= 3) ...[
                  const _VpText('独立验证已达本次尝试上限，请取消本次注册，检查设备后重新开始。', muted: true),
                ] else if (phase == 'pending') ...[
                  const _VpText(
                    '这段录音尚未上传成功，本地文件已保留。请先重试保存，再录下一段。',
                    size: 12,
                    muted: true,
                  ),
                  _VpButton(
                    '重试上传',
                    key: ValueKey('voiceprint-retry-$slot'),
                    onPressed: s._blocked ? null : s._upload,
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: _VpButton(
                          '试听',
                          icon: Icons.play_circle_outline,
                          outlined: true,
                          onPressed: s._blocked
                              ? null
                              : () => s._run(() => s._capture.play(s._path!)),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _VpButton(
                          '重新录制',
                          key: ValueKey('voiceprint-record-$slot'),
                          outlined: true,
                          onPressed: canRecord ? () => s._start(slot) : null,
                        ),
                      ),
                    ],
                  ),
                ] else ...[
                  Wrap(
                    spacing: 18,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      _VpText(
                        '00:${(current ? s._seconds : 0).toString().padLeft(2, '0')}',
                        size: 32,
                        height: 1,
                        spacing: -1,
                      ),
                      _VpTag(
                        s._recording ? '麦克风采集中' : '待开始采音',
                        active: s._recording,
                      ),
                    ],
                  ),
                  _VpText(
                    s._recording ? '正在录制 · 到 20 秒自动停止' : '建议 10～15 秒 · 最短 8 秒',
                    size: 11,
                    muted: true,
                  ),
                  ExcludeSemantics(
                    child: SizedBox(
                      height: 46,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: List.generate(27, (i) {
                          final offset = i - (27 - s._levels.length);
                          final value = current && s._recording && offset >= 0
                              ? ((s._levels[offset] + 60) / 60).clamp(0.0, 1.0)
                              : 0.0;
                          return Expanded(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 1.5,
                              ),
                              child: Container(
                                height: 4 + 42 * value,
                                decoration: BoxDecoration(
                                  color: s._recording
                                      ? Theme.of(context).colorScheme.primary
                                            .withValues(alpha: .65)
                                      : _vpLine(context),
                                  borderRadius: BorderRadius.circular(5),
                                ),
                              ),
                            ),
                          );
                        }),
                      ),
                    ),
                  ),
                  if (phase == 'recording') ...[
                    _VpText(s._device, size: 11, muted: true),
                    _VpButton(
                      verification ? '停止并验证' : '停止并保存',
                      key: ValueKey('voiceprint-stop-$slot'),
                      icon: Icons.stop_circle_outlined,
                      onPressed: s._stopping ? null : () => s._stop(),
                    ),
                  ] else
                    _VpButton(
                      verification
                          ? '开始验证录音'
                          : phase == 'rejected'
                          ? '重新录制这一段'
                          : '开始录制',
                      key: ValueKey('voiceprint-record-$slot'),
                      icon: Icons.mic_none_rounded,
                      onPressed: canRecord ? () => s._start(slot) : null,
                    ),
                ],
              ],
            ],
          ),
        ),
        TextButton(
          onPressed: s._blocked ? null : s._cancelEnrollment,
          child: const Text('取消本次注册'),
        ),
      ],
    );
  }

  Widget _success(BuildContext context) => _VpPanel(
    tinted: true,
    radius: 22,
    child: _VpStack(
      gap: 14,
      children: [
        const Align(
          alignment: Alignment.centerLeft,
          child: _VpIcon(
            Icons.check_circle_outline_rounded,
            large: true,
            filled: true,
          ),
        ),
        const _VpText('验证通过 · 声纹已启用', size: 20, weight: FontWeight.w500),
        const _VpText('新录制的声音已通过服务端独立比对。你可以随时关闭、重新录制或删除模板。', muted: true),
        const Row(
          children: [
            Expanded(child: _VpMetric('采集结果', '3 段已通过')),
            SizedBox(width: 8),
            Expanded(child: _VpMetric('独立验证', '已通过')),
          ],
        ),
        _VpButton(
          '进入声纹管理',
          onPressed: () => state._showStage(_VoiceStage.home),
        ),
      ],
    ),
  );
}

const _voiceRules = [
  (Icons.person_outline_rounded, '一个人录制', '请独自朗读，避免其他人同时说话'),
  (Icons.volume_off_outlined, '保持环境安静', '避开音乐、电视与持续背景声'),
  (Icons.phone_iphone_rounded, '只用手机内置麦克风', '不使用蓝牙耳机或录音卡采集声纹'),
  (Icons.timer_outlined, '每段 8～20 秒', '建议 10～15 秒，保持正常语速和音量'),
];

Color _vpBackground(BuildContext c) => Theme.of(c).brightness == Brightness.dark
    ? Theme.of(c).scaffoldBackgroundColor
    : const Color(0xFFF3F6FD);
Color _vpSurface(BuildContext c) => Theme.of(c).brightness == Brightness.dark
    ? Theme.of(c).colorScheme.surfaceContainerLow
    : const Color(0xFFFCFDFF);
Color _vpLine(BuildContext c) => Theme.of(c).brightness == Brightness.dark
    ? Theme.of(c).colorScheme.outlineVariant.withValues(alpha: .45)
    : const Color(0xFFE0E8F7);
Color _vpInk(BuildContext c) => Theme.of(c).brightness == Brightness.dark
    ? Theme.of(c).colorScheme.onSurface
    : const Color(0xFF101937);
Color _vpMuted(BuildContext c) => Theme.of(c).brightness == Brightness.dark
    ? Theme.of(c).colorScheme.onSurfaceVariant
    : const Color(0xFF7986A4);

String _formatVoiceDate(Object? value) {
  final time = DateTime.tryParse('$value')?.toLocal();
  if (time == null) return '暂无记录';
  return '${time.month} 月 ${time.day} 日 ${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
}

class _VpText extends StatelessWidget {
  const _VpText(
    this.text, {
    super.key,
    this.size = 13,
    this.height = 1.55,
    this.muted = false,
    this.center = false,
    this.weight = FontWeight.w400,
    this.spacing = 0,
  });
  final String text;
  final double size, height, spacing;
  final bool muted, center;
  final FontWeight weight;
  @override
  Widget build(BuildContext context) => Text(
    text,
    textAlign: center ? TextAlign.center : null,
    style: TextStyle(
      fontSize: size,
      height: height,
      fontWeight: weight,
      letterSpacing: spacing,
      color: muted ? _vpMuted(context) : _vpInk(context),
    ),
  );
}

class _VpStack extends StatelessWidget {
  const _VpStack({required this.children, this.gap = 14});
  final List<Widget> children;
  final double gap;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (var i = 0; i < children.length; i++) ...[
        if (i > 0) SizedBox(height: gap),
        children[i],
      ],
    ],
  );
}

class _VpPanel extends StatelessWidget {
  const _VpPanel({
    super.key,
    required this.child,
    this.radius = 20,
    this.padding = const EdgeInsets.all(16),
    this.tinted = false,
    this.quiet = false,
  });
  final Widget child;
  final double radius;
  final EdgeInsets padding;
  final bool tinted, quiet;
  @override
  Widget build(BuildContext context) => Container(
    padding: padding,
    decoration: BoxDecoration(
      color: tinted
          ? Color.alphaBlend(
              Theme.of(context).colorScheme.primary.withValues(alpha: .035),
              _vpSurface(context),
            )
          : quiet
          ? _vpBackground(context)
          : _vpSurface(context),
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(
        color: tinted
            ? Theme.of(context).colorScheme.primary.withValues(alpha: .18)
            : _vpLine(context),
      ),
    ),
    clipBehavior: Clip.antiAlias,
    child: child,
  );
}

class _VpTag extends StatelessWidget {
  const _VpTag(this.text, {this.active = false});
  final String text;
  final bool active;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: active
          ? Theme.of(context).colorScheme.primary.withValues(alpha: .055)
          : _vpBackground(context),
      border: Border.all(
        color: active
            ? Theme.of(context).colorScheme.primary.withValues(alpha: .16)
            : _vpLine(context),
      ),
      borderRadius: BorderRadius.circular(30),
    ),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 10,
        height: 1.2,
        color: active
            ? Theme.of(context).colorScheme.primary
            : _vpMuted(context),
      ),
    ),
  );
}

class _VpIcon extends StatelessWidget {
  const _VpIcon(this.icon, {this.large = false, this.filled = false});
  final IconData icon;
  final bool large, filled;
  @override
  Widget build(BuildContext context) => Container(
    width: large ? 44 : 30,
    height: large ? 44 : 30,
    decoration: BoxDecoration(
      color: filled
          ? Theme.of(context).colorScheme.primary
          : Theme.of(context).colorScheme.primary.withValues(alpha: .05),
      borderRadius: BorderRadius.circular(large ? 15 : 10),
    ),
    child: Icon(
      icon,
      size: large ? 25 : 17,
      color: filled ? Colors.white : _vpMuted(context),
    ),
  );
}

class _VpInfoRow extends StatelessWidget {
  const _VpInfoRow({
    required this.icon,
    required this.title,
    required this.note,
    this.filled = false,
  });
  final IconData icon;
  final String title, note;
  final bool filled;
  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _VpIcon(icon),
      const SizedBox(width: 10),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _VpText(title, size: 12),
            const SizedBox(height: 3),
            _VpText(note, size: 11, muted: true),
          ],
        ),
      ),
    ],
  );
}

class _VpMetric extends StatelessWidget {
  const _VpMetric(this.label, this.value);
  final String label, value;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    decoration: BoxDecoration(
      color: _vpBackground(context),
      borderRadius: BorderRadius.circular(13),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _VpText(label, size: 10, muted: true),
        const SizedBox(height: 3),
        _VpText(value, size: 12),
      ],
    ),
  );
}

class _VpButton extends StatelessWidget {
  const _VpButton(
    this.label, {
    super.key,
    this.onPressed,
    this.icon,
    this.outlined = false,
    this.loading = false,
    this.danger = false,
  });
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool outlined, loading, danger;
  @override
  Widget build(BuildContext context) {
    final child = Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (icon != null) ...[Icon(icon, size: 18), const SizedBox(width: 7)],
        Flexible(
          child: Text(loading ? '请稍候…' : label, textAlign: TextAlign.center),
        ),
      ],
    );
    final style = ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(Size.fromHeight(48)),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
      textStyle: const WidgetStatePropertyAll(
        TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
      ),
      shape: WidgetStatePropertyAll(
        StadiumBorder(
          side: outlined
              ? BorderSide(color: _vpLine(context))
              : BorderSide.none,
        ),
      ),
    );
    return outlined
        ? OutlinedButton(onPressed: onPressed, style: style, child: child)
        : FilledButton(
            onPressed: onPressed,
            style: danger
                ? style.copyWith(
                    backgroundColor: WidgetStatePropertyAll(
                      Theme.of(context).colorScheme.error,
                    ),
                  )
                : style,
            child: child,
          );
  }
}

class _VpSetting extends StatelessWidget {
  const _VpSetting({
    required this.icon,
    required this.title,
    required this.note,
    this.trailing,
    this.onTap,
    this.danger = false,
  });
  final IconData icon;
  final String title, note;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool danger;
  @override
  Widget build(BuildContext context) => Material(
    color: Colors.transparent,
    child: InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        child: Row(
          children: [
            _VpIcon(icon),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 13,
                      color: danger
                          ? Theme.of(context).colorScheme.error
                          : _vpInk(context),
                    ),
                  ),
                  const SizedBox(height: 4),
                  _VpText(note, size: 10, muted: true),
                ],
              ),
            ),
            const SizedBox(width: 7),
            trailing ??
                Icon(
                  Icons.chevron_right_rounded,
                  size: 18,
                  color: _vpMuted(context),
                ),
          ],
        ),
      ),
    ),
  );
}

class _VpEntrance extends StatelessWidget {
  const _VpEntrance({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(
      begin: MediaQuery.disableAnimationsOf(context) ? 1 : 0,
      end: 1,
    ),
    duration: MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 220),
    curve: Curves.easeOutCubic,
    builder: (_, v, content) => Opacity(
      opacity: v,
      child: Transform.translate(
        offset: Offset(0, (1 - v) * 7),
        child: content,
      ),
    ),
    child: child,
  );
}

Future<bool> _showVoiceConfirmation(
  BuildContext context, {
  required String title,
  required String text,
  required String button,
}) async =>
    await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: _vpBackground(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) => _VpSheet(
        title: title,
        children: [
          _VpText(text, size: 13, muted: true),
          const SizedBox(height: 20),
          _VpButton(
            button,
            danger: button.contains('删除') || button.contains('丢弃'),
            onPressed: () => Navigator.pop(context, true),
          ),
          const SizedBox(height: 5),
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
        ],
      ),
    ) ??
    false;

Future<bool> _showVoiceConsent(
  BuildContext context, {
  required bool realtimeAvailable,
}) async {
  var checked = false;
  return await showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        backgroundColor: _vpBackground(context),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        builder: (context) => StatefulBuilder(
          builder: (context, update) => _VpSheet(
            title: '声纹采集与使用说明',
            eyebrow: '单独授权',
            children: [
              _VpStack(
                gap: 10,
                children: [
                  _VpPanel(
                    quiet: true,
                    child: _VpInfoRow(
                      icon: Icons.shield_outlined,
                      title: '声纹属于敏感个人信息',
                      note: realtimeAvailable
                          ? '用于生成和验证你的声音模板。启用后，在会议实时转写中尝试识别你的发言；结果可能出错，不用于实名或操作授权。不注册也能正常使用会议功能。'
                          : '用于生成和验证你的声音模板，不用于实名或操作授权。本阶段尚未接入会议实时本人识别。不注册也能正常使用会议功能。',
                    ),
                  ),
                  _VpPanel(
                    quiet: true,
                    child: _VpInfoRow(
                      icon: Icons.folder_outlined,
                      title: '录音、特征与临时数据怎么存',
                      note:
                          '录音上传至当前 Agenote 后端，在内存中检查、提取特征，不持久保存原始录音。特征加密保存在你的账户下，验证完成即清理临时特征；未完成注册最多保留 24 小时。手机临时片段在上传成功或退出后清理。',
                    ),
                  ),
                  _VpPanel(
                    quiet: true,
                    child: _VpInfoRow(
                      icon: Icons.undo_rounded,
                      title: '你可以随时撤回',
                      note:
                          '可以关闭、重录，或撤回同意并删除在线模板和未完成数据。历史备份遵循其保留与恢复清理策略。请独自录制，声音检查不保证检测所有重叠说话。',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              CheckboxListTile(
                key: const ValueKey('voiceprint-consent-checkbox'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: checked,
                onChanged: (v) => update(() => checked = v == true),
                title: _VpText(
                  realtimeAvailable
                      ? '我已阅读并单独同意采集我的声音用于生成、验证声纹及启用后的会议本人声音比对。'
                      : '我已阅读并单独同意采集我的声音用于生成和验证声纹。',
                  size: 12,
                  muted: true,
                ),
              ),
              const SizedBox(height: 8),
              _VpButton(
                '单独同意并开始',
                onPressed: checked ? () => Navigator.pop(context, true) : null,
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('先不注册'),
              ),
            ],
          ),
        ),
      ) ??
      false;
}

class _VpSheet extends StatelessWidget {
  const _VpSheet({required this.title, required this.children, this.eyebrow});
  final String title;
  final String? eyebrow;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .9,
      ),
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          20,
          10,
          20,
          16 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: _vpLine(context),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (eyebrow != null)
                        _VpText(eyebrow!, size: 10, muted: true, spacing: 1.6),
                      _VpText(title, size: 18, weight: FontWeight.w500),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '关闭',
                  onPressed: () => Navigator.pop(context, false),
                  style: IconButton.styleFrom(
                    backgroundColor: _vpLine(context).withValues(alpha: .5),
                  ),
                  icon: const Icon(Icons.close_rounded, size: 18),
                ),
              ],
            ),
            const SizedBox(height: 14),
            ...children,
          ],
        ),
      ),
    ),
  );
}
