import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';

final _knowledgeIntegrity = Expando<bool>('knowledge-integrity');

String knowledgeId() =>
    '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-${Random.secure().nextInt(1 << 32).toRadixString(36)}';
String knowledgeHash(String text) =>
    sha256.convert(utf8.encode(text)).toString();

enum KnowledgeKind {
  audio('录音'),
  markdown('MD'),
  text('TXT'),
  pdf('PDF'),
  word('WORD'),
  spreadsheet('EXCEL'),
  presentation('PPT'),
  office('文档'),
  note('笔记'),
  link('链接');

  const KnowledgeKind(this.label);
  final String label;
  bool get isBinary =>
      this == pdf ||
      this == word ||
      this == spreadsheet ||
      this == presentation ||
      this == office;
}

enum KnowledgeValidity {
  current('当前版本'),
  review('待确认'),
  stale('已过期'),
  conflicted('有冲突'),
  retracted('已撤回'),
  unknown('来源待核对');

  const KnowledgeValidity(this.label);
  final String label;
}

class KnowledgeProject {
  const KnowledgeProject({
    required this.id,
    required this.name,
    this.allowed = true,
  });
  final String id, name;
  // Legacy snapshot field retained for older clients; retrieval ignores it.
  final bool allowed;
  KnowledgeProject withAllowed(bool value) =>
      KnowledgeProject(id: id, name: name, allowed: true);
  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'allowed': true};
  factory KnowledgeProject.fromJson(Map<String, dynamic> j) =>
      KnowledgeProject(id: j['id'], name: j['name'], allowed: true);
}

class KnowledgeFolder {
  const KnowledgeFolder({required this.id, required this.name, this.parentId});
  final String id, name;
  final String? parentId;
  KnowledgeFolder renamed(String value) =>
      KnowledgeFolder(id: id, name: value, parentId: parentId);
  KnowledgeFolder moved(String? target) =>
      KnowledgeFolder(id: id, name: name, parentId: target);
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'parentId': parentId,
  };
  factory KnowledgeFolder.fromJson(Map<String, dynamic> j) =>
      KnowledgeFolder(id: j['id'], name: j['name'], parentId: j['parentId']);
}

enum KnowledgeSourceKind { document, voice }

/// A version-bound reference. Body/transcript text is resolved live, never copied here.
class KnowledgeSourceLink {
  const KnowledgeSourceLink({
    required this.kind,
    required this.targetId,
    required this.versionId,
    required this.hash,
  });
  final KnowledgeSourceKind kind;
  final String targetId, versionId, hash;
  String get key => '${kind.name}:$targetId:$versionId';
  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    'targetId': targetId,
    'versionId': versionId,
    'hash': hash,
  };
  factory KnowledgeSourceLink.fromJson(Map<String, dynamic> j) =>
      KnowledgeSourceLink(
        kind: KnowledgeSourceKind.values.byName(j['kind']),
        targetId: j['targetId'],
        versionId: j['versionId'],
        hash: j['hash'],
      );
}

class KnowledgeVersion {
  const KnowledgeVersion({
    required this.id,
    required this.number,
    required this.title,
    required this.content,
    required this.hash,
    required this.createdAt,
    required this.state,
    this.reason = '',
    this.origin = '',
    this.sources = const [],
    this.validUntil,
  });
  final String id, title, content, hash, reason, origin;
  final int number;
  final DateTime createdAt;
  final DateTime? validUntil;
  final KnowledgeValidity state;
  final List<KnowledgeSourceLink> sources;
  bool get integrityOk =>
      _knowledgeIntegrity[this] ??= knowledgeHash(content) == hash;
  bool usableAt(DateTime now) =>
      state == KnowledgeValidity.current &&
      integrityOk &&
      (validUntil == null || now.isBefore(validUntil!));
  KnowledgeVersion withState(
    KnowledgeValidity value,
    String note, {
    DateTime? validUntil,
    bool clearExpiry = false,
  }) => KnowledgeVersion(
    id: id,
    number: number,
    title: title,
    content: content,
    hash: hash,
    createdAt: createdAt,
    state: value,
    reason: note,
    origin: origin,
    sources: sources,
    validUntil: clearExpiry ? null : validUntil ?? this.validUntil,
  );
  KnowledgeVersion withSources(List<KnowledgeSourceLink> links) =>
      KnowledgeVersion(
        id: id,
        number: number,
        title: title,
        content: content,
        hash: hash,
        createdAt: createdAt,
        state: state,
        reason: reason,
        origin: origin,
        validUntil: validUntil,
        sources: List.unmodifiable(links),
      );
  Map<String, dynamic> toJson() => {
    'id': id,
    'number': number,
    'title': title,
    'content': content,
    'hash': hash,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'state': state.name,
    'reason': reason,
    'origin': origin,
    'sources': sources.map((s) => s.toJson()).toList(),
    'validUntil': validUntil?.toUtc().toIso8601String(),
  };
  factory KnowledgeVersion.fromJson(Map<String, dynamic> j) => KnowledgeVersion(
    id: j['id'],
    number: j['number'],
    title: j['title'],
    content: j['content'],
    hash: j['hash'],
    createdAt: DateTime.parse(j['createdAt']),
    state: KnowledgeValidity.values.byName(j['state']),
    reason: j['reason'] ?? '',
    origin: j['origin'] ?? '',
    sources: List.unmodifiable(
      (j['sources'] as List? ?? []).map(
        (s) => KnowledgeSourceLink.fromJson(Map<String, dynamic>.from(s)),
      ),
    ),
    validUntil: DateTime.tryParse(j['validUntil'] ?? ''),
  );
}

class KnowledgeDocument {
  const KnowledgeDocument({
    required this.id,
    required this.folderId,
    required this.projectId,
    required this.kind,
    required this.source,
    required this.createdAt,
    required this.versions,
    required this.selectedVersionId,
    this.filename,
    this.url,
    this.fileData,
    this.fileHash,
    this.tags = const [],
    this.allowed = true,
    this.archived = false,
    this.demo = false,
    this.ownerUserId,
    this.audioRefs = const [],
  });
  final String id, folderId, projectId, source, selectedVersionId;
  final String? filename, url, fileData, fileHash;
  final String? ownerUserId;
  final List<Map<String, dynamic>> audioRefs;
  String get displayType =>
      filename == null ? kind.label : extension.toUpperCase();
  String get extension =>
      filename?.split('.').last.toLowerCase() ??
      (kind == KnowledgeKind.markdown ? 'md' : 'txt');
  final KnowledgeKind kind;
  final DateTime createdAt;
  final List<KnowledgeVersion> versions;
  final List<String> tags;
  final bool allowed, archived, demo;
  KnowledgeVersion get selected =>
      versions.firstWhere((v) => v.id == selectedVersionId);
  KnowledgeVersion? get effective {
    for (final v in versions.reversed) {
      if (v.state == KnowledgeValidity.current) return v;
    }
    return null;
  }

  KnowledgeDocument copyWith({
    String? folderId,
    String? projectId,
    List<KnowledgeVersion>? versions,
    String? selectedVersionId,
    bool? allowed,
    bool? archived,
  }) => KnowledgeDocument(
    id: id,
    folderId: folderId ?? this.folderId,
    projectId: projectId ?? this.projectId,
    kind: kind,
    source: source,
    filename: filename,
    url: url,
    fileData: fileData,
    fileHash: fileHash,
    createdAt: createdAt,
    versions: versions ?? this.versions,
    selectedVersionId: selectedVersionId ?? this.selectedVersionId,
    tags: tags,
    allowed: true,
    archived: archived ?? this.archived,
    demo: demo,
    ownerUserId: ownerUserId,
    audioRefs: audioRefs,
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'folderId': folderId,
    'projectId': projectId,
    'kind': kind.name,
    'source': source,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'versions': versions.map((v) => v.toJson()).toList(),
    'selectedVersionId': selectedVersionId,
    'fileData': fileData,
    'fileHash': fileHash,
    'filename': filename,
    'url': url,
    'tags': tags,
    'allowed': true,
    'archived': archived,
    'demo': demo,
    'ownerUserId': ownerUserId,
    'audioRefs': audioRefs,
  };
  factory KnowledgeDocument.fromJson(Map<String, dynamic> j) =>
      KnowledgeDocument(
        id: j['id'],
        folderId: j['folderId'],
        projectId: j['projectId'],
        kind: KnowledgeKind.values.byName(j['kind']),
        source: j['source'],
        createdAt: DateTime.parse(j['createdAt']),
        versions: List.unmodifiable(
          (j['versions'] as List).map(
            (v) => KnowledgeVersion.fromJson(Map<String, dynamic>.from(v)),
          ),
        ),
        selectedVersionId: j['selectedVersionId'],
        fileData: j['fileData'],
        fileHash: j['fileHash'],
        filename: j['filename'],
        url: j['url'],
        tags: List<String>.from(j['tags']),
        allowed: true,
        archived: j['archived'] == true,
        demo: j['demo'] == true,
        ownerUserId: j['ownerUserId'],
        audioRefs: [
          for (final r in j['audioRefs'] ?? []) Map<String, dynamic>.from(r),
        ],
      );
}

class KnowledgeAudit {
  const KnowledgeAudit(this.documentId, this.action, this.at);
  final String documentId, action;
  final DateTime at;
  Map<String, dynamic> toJson() => {
    'documentId': documentId,
    'action': action,
    'at': at.toUtc().toIso8601String(),
  };
  factory KnowledgeAudit.fromJson(Map<String, dynamic> j) =>
      KnowledgeAudit(j['documentId'], j['action'], DateTime.parse(j['at']));
}

class KnowledgeSnapshot {
  const KnowledgeSnapshot({
    required this.folders,
    required this.projects,
    required this.documents,
    this.audit = const [],
  });
  final List<KnowledgeFolder> folders;
  final List<KnowledgeProject> projects;
  final List<KnowledgeDocument> documents;
  final List<KnowledgeAudit> audit;
  KnowledgeSnapshot copyWith({
    List<KnowledgeFolder>? folders,
    List<KnowledgeProject>? projects,
    List<KnowledgeDocument>? documents,
    List<KnowledgeAudit>? audit,
  }) => KnowledgeSnapshot(
    folders: folders ?? this.folders,
    projects: projects ?? this.projects,
    documents: documents ?? this.documents,
    audit: audit ?? this.audit,
  );
  Map<String, dynamic> toJson() => {
    'schema': 1,
    'folders': folders.map((f) => f.toJson()).toList(),
    'projects': projects.map((p) => p.toJson()).toList(),
    'documents': documents.map((d) => d.toJson()).toList(),
    'audit': audit.map((a) => a.toJson()).toList(),
  };
  factory KnowledgeSnapshot.fromJson(Map<String, dynamic> j) {
    if (j['schema'] != 1) throw const FormatException('资料库版本无法读取');
    return KnowledgeSnapshot(
      folders: List.unmodifiable(
        (j['folders'] as List).map(
          (f) => KnowledgeFolder.fromJson(Map<String, dynamic>.from(f)),
        ),
      ),
      projects: List.unmodifiable(
        (j['projects'] as List).map(
          (p) => KnowledgeProject.fromJson(Map<String, dynamic>.from(p)),
        ),
      ),
      documents: List.unmodifiable(
        (j['documents'] as List).map(
          (d) => KnowledgeDocument.fromJson(Map<String, dynamic>.from(d)),
        ),
      ),
      audit: List.unmodifiable(
        (j['audit'] as List).map(
          (a) => KnowledgeAudit.fromJson(Map<String, dynamic>.from(a)),
        ),
      ),
    );
  }
}

class KnowledgeHit {
  const KnowledgeHit({
    required this.documentId,
    required this.versionId,
    required this.number,
    required this.projectId,
    required this.source,
    required this.hash,
    required this.text,
    required this.start,
    required this.end,
    this.nodeId,
    this.page,
    this.matchPercent,
  });
  final String documentId, versionId, projectId, source, hash, text;
  final int number, start, end;
  final String? nodeId, page;
  final int? matchPercent;
  String get span => nodeId != null && end <= start
      ? (page == null ? '来源片段' : '第 $page 页')
      : '字符 ${start + 1}–$end';
}

String knowledgePreview(String markdown) => markdown
    .replaceFirst(RegExp(r'^---\s*\r?\n[\s\S]*?\r?\n---\s*\r?\n'), '')
    .replaceAllMapped(RegExp(r'\[([^\]]+)\]\([^)]*\)'), (m) => m[1]!)
    .replaceAll(RegExp(r'[#*`>]'), '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

String knowledgeDate(DateTime date) {
  final d = date.toLocal();
  return '${d.year}/${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')}';
}
