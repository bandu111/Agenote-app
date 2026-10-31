import 'dart:convert';
import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/knowledge_models.dart';
import '../repositories/knowledge_importer.dart';
import '../repositories/knowledge_file_access.dart';
import '../repositories/knowledge_repository.dart';
import '../repositories/dio_knowledge_repository.dart';
import '../../../core/network/api_config.dart';

class KnowledgeViewModel extends ChangeNotifier {
  KnowledgeViewModel(this.repository, {this.accountId});
  final KnowledgeRepository repository;
  final String? Function()? accountId;
  Timer? _searchTimer;
  Timer? _indexTimer;
  bool _pollingIndex = false;
  void _watchIndex() {
    _indexTimer?.cancel();
    final remote = repository;
    if (_disposed ||
        remote is! DioKnowledgeRepository ||
        !remote.hasPendingIndex) {
      return;
    }
    _indexTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      if (_disposed || !remote.hasPendingIndex) {
        _indexTimer?.cancel();
        return;
      }
      if (_pollingIndex || loading || saving) return;
      _pollingIndex = true;
      final revision = _revision;
      try {
        final changed = await remote.refreshIndexStatus();
        if (changed && !_disposed && revision == _revision) {
          ++_revision;
          _referenceCache.clear();
          if (query.isNotEmpty) _scheduleSearch();
          _emit();
        }
      } catch (_) {
        // 断网不冒充解析完成；恢复后继续读取真实队列状态。
      } finally {
        _pollingIndex = false;
      }
    });
  }

  int _searchGeneration = 0;
  bool searching = false;
  String? searchError;
  List<KnowledgeHit> _remoteHits = [];
  final _referenceCache = <Object, Future<List<KnowledgeHit>>>{};
  KnowledgeSnapshot _data = const KnowledgeSnapshot(
    folders: [],
    projects: [],
    documents: [],
  );
  bool _accessible(KnowledgeDocument d) =>
      accountId == null ||
      (repository is DioKnowledgeRepository
          ? d.ownerUserId == accountId!()
          : d.demo ||
                !d.source.startsWith('meeting:') ||
                (d.ownerUserId != null && d.ownerUserId == accountId!()));
  String? _observedOwner;

  /// 资料变化会生成新快照，来源检索应按业务版本而非临时对象地址失效。
  (int, String?) get sourceRevision => (_revision, accountId?.call());
  void refreshAccount() {
    if (repository is! DioKnowledgeRepository ||
        _observedOwner == accountId?.call()) {
      return;
    }
    _observedOwner = accountId?.call();
    _remoteHits = [];
    _referenceCache.clear();
    _searchTimer?.cancel();
    ++_searchGeneration;
    searching = false;
    ++_revision;
    _data = const KnowledgeSnapshot(folders: [], projects: [], documents: []);
    saving = false;
    deleting = false;
    expandedFolders.clear();
    _initialized = false;
    Future.microtask(() {
      if (!_disposed) load();
    });
  }

  KnowledgeSnapshot get data {
    if (accountId == null) return _data;
    final documents = _data.documents.where(_accessible).toList();
    final ids = documents.map((d) => d.id).toSet();
    return _data.copyWith(
      documents: documents,
      audit: _data.audit.where((a) => ids.contains(a.documentId)).toList(),
    );
  }

  bool loading = true, saving = false, archivedOnly = false;
  bool deleting = false;
  String query = '';
  String? projectFilter, error, actionError;
  final expandedFolders = <String>{};
  bool _disposed = false, _initialized = false;
  int _revision = 0;
  Future<void> load() async {
    if (saving || _disposed) return;
    final revision = ++_revision;
    final owner = accountId?.call();
    loading = true;
    error = null;
    _emit();
    try {
      final result = await repository.load();
      if (_disposed || revision != _revision || owner != accountId?.call()) {
        return;
      }
      _data = result;
      _referenceCache.clear();
      if (query.isNotEmpty) _scheduleSearch();
      if (!_initialized) {
        expandedFolders.addAll(_data.documents.map((d) => d.folderId));
        _initialized = true;
      }
    } catch (_) {
      if (!_disposed && revision == _revision) error = '资料库读取失败，原有本地资料未被覆盖，请重试';
    }
    if (!_disposed && revision == _revision) {
      loading = false;
      _watchIndex();
      _emit();
    }
  }

  Future<bool> _change(
    KnowledgeSnapshot Function(KnowledgeSnapshot) update, {
    String? deletingId,
    String? expectedDocument,
  }) async {
    if (saving || loading || _disposed) return false;
    saving = true;
    deleting = deletingId != null;
    final owner = accountId?.call();
    actionError = null;
    final revision = ++_revision;
    _emit();
    try {
      final result = update(_data);
      try {
        await repository.save(result);
      } on ApiFailure catch (failure) {
        if (deletingId == null ||
            repository is! DioKnowledgeRepository ||
            failure.status != 409 ||
            failure.code != 'knowledge_revision_conflict') {
          rethrow;
        }
        // Another meeting/device may have updated the library. Reload once;
        // only reapply this deletion if the document itself is unchanged.
        final latest = await repository.load();
        if (_disposed || revision != _revision || owner != accountId?.call()) {
          return false;
        }
        final matches = latest.documents.where((d) => d.id == deletingId);
        if (matches.isNotEmpty &&
            jsonEncode(matches.single.toJson()) != expectedDocument) {
          _data = latest;
          throw const FormatException('这份资料已更新，请核对后重新删除');
        }
        if (matches.isNotEmpty) await repository.save(update(latest));
      }
      final saved = await repository.load();
      if (_disposed || revision != _revision || owner != accountId?.call()) {
        return false;
      }
      _data = saved;
      _referenceCache.clear();
      if (query.isNotEmpty) _scheduleSearch();
      if (deletingId != null &&
          saved.documents.any((d) => d.id == deletingId)) {
        actionError = '服务器尚未确认删除，请重试';
        return false;
      }
      return true;
    } on FormatException catch (e) {
      if (!_disposed && revision == _revision) actionError = e.message;
      return false;
    } catch (_) {
      if (!_disposed && revision == _revision) {
        actionError = '保存未完成，请重试。未确认写入的变化不会显示为成功';
      }
      return false;
    } finally {
      if (!_disposed && revision == _revision) {
        saving = false;
        deleting = false;
        _watchIndex();
        _emit();
      }
    }
  }

  KnowledgeDocument? document(String id) {
    for (final d in _data.documents) {
      if (d.id == id && _accessible(d)) return d;
    }
    return null;
  }

  KnowledgeFolder folder(String id) =>
      _data.folders.firstWhere((f) => f.id == id);
  KnowledgeProject project(String id) =>
      _data.projects.firstWhere((p) => p.id == id);
  bool retrievable(KnowledgeDocument d, {DateTime? now}) =>
      _accessible(d) &&
      !d.versions.any((v) => v.state == KnowledgeValidity.conflicted) &&
      _data.projects.any((p) => p.id == d.projectId) &&
      d.effective?.usableAt(now ?? DateTime.now()) == true &&
      (d.effective!.content.trim().isNotEmpty ||
          (repository is DioKnowledgeRepository &&
              (repository as DioKnowledgeRepository).indexStatus(
                    d.id,
                    d.effective!.id,
                  ) ==
                  'indexed'));
  String retrievalLabel(KnowledgeDocument d) {
    if (d.versions.any((v) => v.state == KnowledgeValidity.conflicted)) {
      return '存在待核对冲突';
    }
    if (d.effective == null) return '无当前可用版本';
    if (!d.effective!.integrityOk) return '内容校验异常';
    if (!d.effective!.usableAt(DateTime.now())) return '版本已失效';
    if (d.effective!.content.trim().isEmpty) {
      if (repository is DioKnowledgeRepository) {
        return switch ((repository as DioKnowledgeRepository).indexStatus(
          d.id,
          d.effective!.id,
        )) {
          'indexed' => '允许检索',
          'queued' => '原文件解析中',
          'parse_unavailable' => '原文件已保存，解析暂不可用',
          _ => '未提取到可检索正文',
        };
      }
      return '未提供正文';
    }
    return '允许检索';
  }

  List<KnowledgeHit> retrieve(String text, {String? projectId}) {
    final term = text.trim().toLowerCase();
    if (term.isEmpty) return [];
    final hits = <KnowledgeHit>[];
    // Scope and authorization are checked before content is inspected.
    for (final d in _data.documents) {
      if (projectId != null && d.projectId != projectId || !retrievable(d)) {
        continue;
      }
      final v = d.effective!;
      final at = v.content.toLowerCase().indexOf(term);
      if (at < 0) continue;
      final start = (at - 40).clamp(0, v.content.length);
      final end = (at + term.length + 100).clamp(start, v.content.length);
      hits.add(
        KnowledgeHit(
          documentId: d.id,
          versionId: v.id,
          number: v.number,
          projectId: d.projectId,
          source: v.origin.isEmpty ? d.source : v.origin,
          hash: v.hash,
          text: v.content.substring(start, end),
          start: start,
          end: end,
        ),
      );
    }
    return hits;
  }

  KnowledgeHit? resolveHit(KnowledgeHit hit) {
    final d = document(hit.documentId);
    if (d == null || !retrievable(d) || d.projectId != hit.projectId) {
      return null;
    }
    final v = d.effective!;
    if (hit.nodeId != null) {
      return v.id == hit.versionId &&
              v.hash == hit.hash &&
              _remoteHits.any((h) => identical(h, hit))
          ? hit
          : null;
    }
    if (v.id != hit.versionId ||
        v.hash != hit.hash ||
        hit.start < 0 ||
        hit.end > v.content.length ||
        hit.end <= hit.start) {
      return null;
    }
    if (v.content.substring(hit.start, hit.end) != hit.text) return null;
    return hit;
  }

  List<KnowledgeHit> get searchHits =>
      (repository is DioKnowledgeRepository
              ? _remoteHits.where((h) {
                  final d = document(h.documentId);
                  return d != null &&
                      (projectFilter == null || d.projectId == projectFilter) &&
                      retrievable(d) &&
                      d.effective?.id == h.versionId &&
                      d.effective?.hash == h.hash;
                }).toList()
              : retrieve(query, projectId: projectFilter))
          .where(
            (hit) =>
                !archivedOnly || document(hit.documentId)?.archived == true,
          )
          .toList();

  /// 会议录音文档仅承载原声与转写引用；已有正式纪要时列表只保留纪要。
  bool _shadowedAudio(KnowledgeDocument d, List<KnowledgeDocument> all) =>
      d.kind == KnowledgeKind.audio &&
      d.source.startsWith('meeting:') &&
      all.any((o) => o.kind != KnowledgeKind.audio && o.source == d.source);

  List<KnowledgeDocument> get visibleDocuments {
    final term = query.trim().toLowerCase();
    final contentIds = searchHits.map((h) => h.documentId).toSet();
    final all = data.documents;
    final result = all.where((d) {
      if (_shadowedAudio(d, all)) return false;
      if (archivedOnly && !d.archived ||
          projectFilter != null && d.projectId != projectFilter) {
        return false;
      }
      if (term.isEmpty) return true;
      return '${d.selected.title} ${d.tags.join(' ')} ${d.filename ?? ''} ${project(d.projectId).name}'
              .toLowerCase()
              .contains(term) ||
          contentIds.contains(d.id);
    }).toList();
    result.sort((a, b) => b.selected.createdAt.compareTo(a.selected.createdAt));
    return result;
  }

  int get documentCount {
    final all = data.documents;
    return all.where((d) => !_shadowedAudio(d, all)).length;
  }

  int get archivedCount {
    final all = data.documents;
    return all.where((d) => d.archived && !_shadowedAudio(d, all)).length;
  }

  List<KnowledgeDocument> documentsIn(String folderId) =>
      visibleDocuments.where((d) => d.folderId == folderId).toList();
  List<KnowledgeFolder> children(String? parent) => _data.folders
      .where(
        (f) =>
            f.parentId == parent &&
            (query.isEmpty && !archivedOnly && projectFilter == null ||
                _hasResults(f.id)),
      )
      .toList();
  bool _hasResults(String folderId) =>
      visibleDocuments.any((d) => d.folderId == folderId) ||
      _data.folders
          .where((f) => f.parentId == folderId)
          .any((f) => _hasResults(f.id));
  void search(String value) {
    query = value.trim();
    _scheduleSearch();
    _emit();
  }

  Future<List<KnowledgeHit>> findReferences(String text, {String? projectId}) {
    if (repository is! DioKnowledgeRepository) {
      return Future.value(retrieve(text, projectId: projectId));
    }
    final key = (sourceRevision, text, projectId);
    if (_referenceCache.length > 24) _referenceCache.clear();
    return _referenceCache.putIfAbsent(
      key,
      () => _findReferences(text, projectId)
          .then((hits) {
            if (hits.isEmpty) _referenceCache.remove(key);
            return hits;
          })
          .catchError((Object e, StackTrace st) {
            _referenceCache.remove(key);
            Error.throwWithStackTrace(e, st);
          }),
    );
  }

  Future<List<KnowledgeHit>> _findReferences(
    String text,
    String? projectId,
  ) async {
    final repo = repository as DioKnowledgeRepository;
    final scope = sourceRevision;
    final owner = repo.accountId;
    final results = <KnowledgeHit>[];
    final hits = await repo
        .search(text, projectId: projectId)
        .timeout(const Duration(seconds: 30));
    for (final hit in hits) {
      if (sourceRevision != scope || repo.accountId != owner) return [];
      if (!await repo.resolve(hit)) continue;
      final d = document(hit['documentId']);
      final v = d?.effective;
      if (d == null ||
          v == null ||
          !retrievable(d) ||
          v.id != hit['versionId'] ||
          v.hash != hit['hash'] ||
          sourceRevision != scope ||
          owner != repo.accountId) {
        continue;
      }
      final excerpt = hit['text'] as String;
      final at = v.content.indexOf(excerpt);
      results.add(
        KnowledgeHit(
          documentId: d.id,
          versionId: v.id,
          number: v.number,
          projectId: d.projectId,
          source: hit['source'] as String? ?? d.source,
          hash: v.hash,
          text: excerpt,
          start: at < 0 ? 0 : at,
          end: at < 0 ? 0 : at + excerpt.length,
          nodeId: hit['nodeId'] as String?,
          matchPercent: hit['matchPercent'] is int
              ? hit['matchPercent'] as int
              : null,
          page: hit['page']?.toString(),
        ),
      );
    }
    return results;
  }

  void _scheduleSearch() {
    _searchTimer?.cancel();
    final generation = ++_searchGeneration;
    if (query.isEmpty) _remoteHits = [];
    searchError = null;
    searching = repository is DioKnowledgeRepository && query.isNotEmpty;
    if (!searching) return;
    _searchTimer = Timer(const Duration(milliseconds: 300), () async {
      try {
        final hits = await findReferences(query, projectId: projectFilter);
        if (!_disposed && generation == _searchGeneration) _remoteHits = hits;
      } catch (_) {
        if (!_disposed && generation == _searchGeneration) {
          searchError = '资料检索失败，请重试';
        }
      } finally {
        if (!_disposed && generation == _searchGeneration) {
          searching = false;
          _emit();
        }
      }
    });
  }

  void filterArchived(bool value) {
    archivedOnly = value;
    _emit();
  }

  void filterProject(String? value) {
    projectFilter = value;
    _scheduleSearch();
    _emit();
  }

  void expandFolder(String id) {
    if (expandedFolders.add(id)) _emit();
  }

  bool isExpanded(String id) =>
      query.isNotEmpty ||
      archivedOnly ||
      projectFilter != null ||
      expandedFolders.contains(id);
  void toggleFolder(String id) {
    if (!expandedFolders.remove(id)) expandedFolders.add(id);
    _emit();
  }

  KnowledgeSnapshot _audit(KnowledgeSnapshot value, String id, String action) =>
      value.copyWith(
        audit: [
          ...value.audit,
          KnowledgeAudit(id, action, DateTime.now()),
        ].takeLast(200),
      );
  KnowledgeSnapshot _replace(
    KnowledgeSnapshot value,
    KnowledgeDocument updated,
  ) => value.copyWith(
    documents: value.documents
        .map((d) => d.id == updated.id ? updated : d)
        .toList(),
  );

  Future<bool> updateSource(
    String documentId,
    String versionId,
    KnowledgeSourceLink link, {
    bool remove = false,
  }) => _change((data) {
    final d = document(documentId);
    if (d == null) throw const FormatException('资料已移除');
    final versions = d.versions.map((v) {
      if (v.id != versionId) return v;
      final links = v.sources.where((s) => s.key != link.key).toList();
      if (!remove) {
        if (link.targetId == documentId &&
            link.kind == KnowledgeSourceKind.document) {
          throw const FormatException('不能将资料自身关联为外部来源');
        }
        if (links.length >= 32) throw const FormatException('单个版本最多关联 32 份来源');
        links.add(link);
      }
      return v.withSources(links);
    }).toList();
    if (!versions.any((v) => v.id == versionId)) {
      throw const FormatException('版本已移除');
    }
    return _audit(
      _replace(data, d.copyWith(versions: versions)),
      d.id,
      remove ? '移除来源关联' : '关联来源',
    );
  });

  /// Idempotent meeting archive; effective versions are available for retrieval.
  Future<String?> archiveMeeting({
    required String meetingId,
    required String title,
    required String content,
    required bool demo,
    bool refreshExisting = false,
    String? ownerUserId,
  }) async {
    final id = 'meeting-$meetingId';
    if (!demo &&
        accountId != null &&
        (ownerUserId == null || ownerUserId != accountId!())) {
      actionError = '会议不属于当前账户，已保留原记录';
      return null;
    }
    final existing = document(id);
    if (existing == null && _data.documents.any((d) => d.id == id)) {
      actionError = '会议资料属于其他账户，不能覆盖';
      return null;
    }
    if (existing != null) {
      if (!refreshExisting || existing.selected.content == content) return id;
      final success = await _change((data) {
        final version = KnowledgeVersion(
          id: knowledgeId(),
          number: existing.versions.last.number + 1,
          title: title,
          content: content,
          hash: knowledgeHash(content),
          createdAt: DateTime.now(),
          state: KnowledgeValidity.current,
          origin: 'meeting:$meetingId',
        );
        return _audit(
          _replace(
            data,
            existing.copyWith(
              versions: [
                for (final old in existing.versions)
                  old.state == KnowledgeValidity.current
                      ? old.withState(KnowledgeValidity.stale, '已由同步纪要更新')
                      : old,
                version,
              ],
              selectedVersionId: version.id,
            ),
          ),
          id,
          '同步会议纪要',
        );
      });
      return success ? id : null;
    }
    final success = await _change((data) {
      final now = DateTime.now();
      final version = KnowledgeVersion(
        id: '$id-v1',
        number: 1,
        title: title,
        content: content,
        hash: knowledgeHash(content),
        createdAt: now,
        state: KnowledgeValidity.current,
        origin: 'meeting:$meetingId',
      );
      return _audit(
        data.copyWith(
          folders: [
            ...data.folders,
            if (!data.folders.any((f) => f.id == 'meeting-records'))
              const KnowledgeFolder(id: 'meeting-records', name: '会议纪要'),
          ],
          projects: [
            ...data.projects,
            if (!data.projects.any((p) => p.id == 'personal-meetings'))
              const KnowledgeProject(id: 'personal-meetings', name: '个人会议'),
          ],
          documents: [
            ...data.documents,
            KnowledgeDocument(
              id: id,
              folderId: 'meeting-records',
              projectId: 'personal-meetings',
              kind: KnowledgeKind.markdown,
              source: 'meeting:$meetingId',
              createdAt: now,
              versions: [version],
              selectedVersionId: version.id,
              archived: true,
              demo: demo,
              ownerUserId: ownerUserId,
              tags: ['会议纪要', if (demo) '演示'],
            ),
          ],
        ),
        id,
        '归档会议纪要',
      );
    });
    if (success) expandedFolders.add('meeting-records');
    return success ? id : null;
  }

  Future<String?> addDocument({
    required String title,
    required String content,
    required String folderId,
    required String projectId,
    required KnowledgeKind kind,
    bool allowed = true,
    String? filename,
    String? fileData,
    String? fileHash,
    String? url,
    List<String> tags = const [],
  }) async {
    final id = knowledgeId();
    final success = await _change((data) {
      if (title.trim().isEmpty) throw const FormatException('请填写资料标题');
      if (utf8.encode(content).length > maxKnowledgeBytes) {
        throw const FormatException('资料正文请控制在 2 MB 以内');
      }
      if (kind != KnowledgeKind.link &&
          !kind.isBinary &&
          content.trim().isEmpty) {
        throw const FormatException('请输入资料正文');
      }
      if (kind == KnowledgeKind.link) {
        final uri = Uri.tryParse(url ?? '');
        if (uri == null ||
            !['http', 'https'].contains(uri.scheme) ||
            uri.host.isEmpty) {
          throw const FormatException('请输入完整的 http / https 链接');
        }
      }
      if (kind.isBinary && (fileData == null || fileHash == null)) {
        throw const FormatException('未能保存原文件，请重新导入');
      }
      final hash = knowledgeHash(content);
      if (filename != null &&
          data.documents.any(
            (d) =>
                d.projectId == projectId &&
                (fileHash != null
                    ? d.fileHash == fileHash
                    : d.fileData == null &&
                          d.versions.any((v) => v.hash == hash)),
          )) {
        throw const FormatException('这个项目中已有相同内容的资料，无需重复导入');
      }
      final now = DateTime.now();
      final version = KnowledgeVersion(
        id: knowledgeId(),
        number: 1,
        title: title.trim(),
        content: content,
        hash: hash,
        createdAt: now,
        state: KnowledgeValidity.current,
      );
      final document = KnowledgeDocument(
        id: id,
        folderId: folderId,
        projectId: projectId,
        kind: kind,
        source: filename != null
            ? '本地文件导入'
            : kind == KnowledgeKind.link
            ? '用户保存的链接'
            : '用户手动录入',
        filename: filename,
        fileData: fileData,
        fileHash: fileHash,
        url: url,
        createdAt: now,
        versions: [version],
        selectedVersionId: version.id,
        tags: tags
            .where((t) => t.trim().isNotEmpty)
            .map((t) => t.trim())
            .toSet()
            .toList(),
        allowed: true,
      );
      return _audit(
        data.copyWith(documents: [...data.documents, document]),
        id,
        '资料已保存',
      );
    });
    if (success) {
      expandedFolders.add(folderId);
      _emit();
      return id;
    }
    return null;
  }

  Future<bool> renameDocument(String id, String title) async {
    final clean = title.trim();
    if (clean.isEmpty || clean.length > 100 || clean.contains(RegExp(r'[\r\n]'))) {
      actionError = '资料名称请填写 1–100 个字';
      return false;
    }
    final target = document(id);
    if (target == null || saving || loading) return false;
    if (repository is! DioKnowledgeRepository) {
      return _change((data) => _replace(data, target.copyWith(versions: [
        for (final v in target.versions)
          if (v.id == target.selectedVersionId)
            KnowledgeVersion.fromJson({...v.toJson(), 'title': clean})
          else v,
      ])));
    }
    saving = true;
    actionError = null;
    final owner = accountId?.call();
    final revision = ++_revision;
    _emit();
    try {
      await (repository as DioKnowledgeRepository).renameDocument(target, clean);
      final saved = await repository.load();
      if (_disposed || revision != _revision || owner != accountId?.call()) return false;
      _data = saved;
      _referenceCache.clear();
      if (query.isNotEmpty) _scheduleSearch();
      return document(id)?.selected.title == clean;
    } catch (_) {
      if (!_disposed && revision == _revision) actionError = '名称保存未完成，请刷新后重试';
      return false;
    } finally {
      if (!_disposed && revision == _revision) { saving = false; _emit(); }
    }
  }

  Future<bool> addVersion(
    String id,
    String title,
    String content,
    String reason,
  ) => _change((data) {
    if (title.trim().isEmpty ||
        content.trim().isEmpty ||
        reason.trim().isEmpty) {
      throw const FormatException('请填写标题、正文及变更说明');
    }
    if (utf8.encode(content).length > maxKnowledgeBytes) {
      throw const FormatException('资料正文请控制在 2 MB 以内');
    }
    final d = document(id)!;
    final v = KnowledgeVersion(
      id: knowledgeId(),
      number: d.versions.last.number + 1,
      title: title.trim(),
      content: content,
      hash: knowledgeHash(content),
      createdAt: DateTime.now(),
      state: KnowledgeValidity.review,
      origin: '用户编辑副本',
      reason: reason.trim(),
    );
    return _audit(
      _replace(
        data,
        d.copyWith(versions: [...d.versions, v], selectedVersionId: v.id),
      ),
      id,
      '新增待确认版本 v${v.number}',
    );
  });
  Future<bool> setValidity(
    String id,
    String versionId,
    KnowledgeValidity state,
    String note, {
    DateTime? validUntil,
    bool clearExpiry = false,
  }) => _change((data) {
    if (note.trim().isEmpty) throw const FormatException('请记录核对或变更原因');
    final d = document(id)!;
    final target = d.versions.firstWhere((v) => v.id == versionId);
    if (!target.integrityOk) throw const FormatException('内容校验异常，不能设为当前版本');
    final versions = d.versions.map((v) {
      if (v.id == versionId) {
        return v.withState(
          state,
          note.trim(),
          validUntil: validUntil,
          clearExpiry: clearExpiry,
        );
      }
      if (state == KnowledgeValidity.current &&
          v.state == KnowledgeValidity.current) {
        return v.withState(KnowledgeValidity.stale, '由 v${target.number} 替代');
      }
      return v;
    }).toList();
    return _audit(
      _replace(data, d.copyWith(versions: versions)),
      id,
      'v${target.number} 标记为${state.label}',
    );
  });
  Future<bool> archive(String id, bool value) => _change(
    (data) => _audit(
      _replace(data, document(id)!.copyWith(archived: value)),
      id,
      value ? '资料归档' : '取消归档',
    ),
  );
  Future<bool> delete(String id) async {
    final original = document(id);
    if (original == null) {
      actionError = '资料不存在或当前账户无权删除';
      _emit();
      return false;
    }
    final deleted = await _change(
      (data) => _audit(
        data.copyWith(
          documents: data.documents.where((d) => d.id != id).toList(),
        ),
        id,
        '资料及其本地检索内容已移除',
      ),
      deletingId: id,
      expectedDocument: jsonEncode(original.toJson()),
    );
    if (deleted &&
        (repository.store is LocalKnowledgeStore ||
            repository is DioKnowledgeRepository)) {
      try {
        await const KnowledgeFileAccess().purge(id);
      } catch (_) {
        // OS cache cleanup is best-effort; owned original bytes are already deleted.
      }
    }
    return deleted;
  }

  Future<bool> moveDocument(String id, String target) => _change((data) {
    if (!data.folders.any((f) => f.id == target)) {
      throw const FormatException('目标文件夹不存在');
    }
    return _audit(
      _replace(data, document(id)!.copyWith(folderId: target)),
      id,
      '移动资料',
    );
  });
  Future<bool> createFolder(String name, {String? parent}) => _change((data) {
    final clean = name.trim();
    if (clean.isEmpty || clean.length > 30) {
      throw const FormatException('文件夹名称请填写 1–30 个字');
    }
    if (data.folders.any((f) => f.parentId == parent && f.name == clean)) {
      throw const FormatException('当前层级已有同名文件夹');
    }
    return data.copyWith(
      folders: [
        ...data.folders,
        KnowledgeFolder(id: knowledgeId(), name: clean, parentId: parent),
      ],
    );
  });
  Future<bool> renameFolder(String id, String name) => _change((data) {
    if (id == 'inbox') throw const FormatException('未归档文件夹保留为默认入口');
    final clean = name.trim();
    if (clean.isEmpty || clean.length > 30) {
      throw const FormatException('文件夹名称请填写 1–30 个字');
    }
    if (data.folders.any(
      (f) => f.id != id && f.parentId == folder(id).parentId && f.name == clean,
    )) {
      throw const FormatException('当前层级已有同名文件夹');
    }
    return data.copyWith(
      folders: data.folders
          .map((f) => f.id == id ? f.renamed(clean) : f)
          .toList(),
    );
  });
  bool canMoveFolder(String id, String? target) {
    if (id == 'inbox' || id == target) return false;
    var parent = target;
    while (parent != null) {
      if (parent == id) return false;
      parent = folder(parent).parentId;
    }
    return true;
  }

  Future<bool> moveFolder(String id, String? target) => _change((data) {
    if (!canMoveFolder(id, target)) throw const FormatException('不能移动到自身或子文件夹');
    return data.copyWith(
      folders: data.folders
          .map((f) => f.id == id ? f.moved(target) : f)
          .toList(),
    );
  });
  Future<bool> deleteFolder(String id) => _change((data) {
    if (id == 'inbox') throw const FormatException('默认文件夹不能删除');
    final parent = folder(id).parentId;
    return data.copyWith(
      folders: data.folders
          .where((f) => f.id != id)
          .map((f) => f.parentId == id ? f.moved(parent) : f)
          .toList(),
      documents: data.documents
          .map((d) => d.folderId == id ? d.copyWith(folderId: 'inbox') : d)
          .toList(),
    );
  });
  void _emit() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _searchTimer?.cancel();
    _indexTimer?.cancel();
    ++_searchGeneration;
    ++_revision;
    super.dispose();
  }
}

extension<T> on List<T> {
  List<T> takeLast(int count) =>
      length <= count ? this : sublist(length - count);
}
