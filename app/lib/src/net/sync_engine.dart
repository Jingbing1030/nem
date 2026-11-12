import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:notepad_core/notepad_core.dart';
import 'package:path/path.dart' as p;

import '../db/note_repository.dart';
import '../db/paths.dart';
import '../images/image_vault.dart';
import '../log.dart';
import 'peer_session.dart';

/// 同步进度（UI 展示用）。
class SyncProgress {
  const SyncProgress({
    this.notesTotal = 0,
    this.notesDone = 0,
    this.imagesTotal = 0,
    this.imagesDone = 0,
    this.running = false,
    this.lastSyncedAt,
    this.error,
  });

  final int notesTotal;
  final int notesDone;
  final int imagesTotal;
  final int imagesDone;
  final bool running;
  final DateTime? lastSyncedAt;
  final String? error;

  bool get isIdle => !running;

  SyncProgress copyWith({
    int? notesTotal,
    int? notesDone,
    int? imagesTotal,
    int? imagesDone,
    bool? running,
    DateTime? lastSyncedAt,
    String? error,
    bool clearError = false,
  }) =>
      SyncProgress(
        notesTotal: notesTotal ?? this.notesTotal,
        notesDone: notesDone ?? this.notesDone,
        imagesTotal: imagesTotal ?? this.imagesTotal,
        imagesDone: imagesDone ?? this.imagesDone,
        running: running ?? this.running,
        lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
        error: clearError ? null : (error ?? this.error),
      );
}

/// 同步引擎：把 [PeerSession] 上的消息翻译成仓库操作，并驱动同步流程。
///
/// 最终版架构（变更 3 / 6）：
/// - 正文以 drift/SQLite 为唯一真相源（[NoteRepository2]），md 只是导出产物；
/// - 文本同步按**版本向量**决策（[SyncPlanner]），不再用 updatedAt LWW；
/// - 增量 `note_patch`、冲突副本 `conflict`、大文件块级同步 `blockSync` 都要处理；
/// - 与每个对端的同步基线存库（`SyncBaselines` 表），patch 的基线正文从这里读；
/// - 图片仍走清单 + 分块 + SHA-256 校验（逻辑不变）。
class SyncEngine {
  SyncEngine({
    required this.repo,
    required this.paths,
    required this.imageVault,
    required this.onProgress,
    required this.onPeerAuthenticated,
  });

  final NoteRepository2 repo;
  final VaultPaths2 paths;
  final ImageVault imageVault;
  final void Function(SyncProgress) onProgress;
  final void Function(PeerSession session) onPeerAuthenticated;

  final StreamController<SyncProgress> _progress =
      StreamController<SyncProgress>.broadcast();
  Stream<SyncProgress> get progressStream => _progress.stream;

  SyncProgress _current = const SyncProgress();
  SyncProgress get current => _current;

  /// 块级同步的块大小（64KB；启用阈值见 [SyncPlanner.blockSyncThresholdBytes]）。
  static const int noteChunkSize = 64 * 1024;

  void _report(SyncProgress p) {
    _current = p;
    if (!_progress.isClosed) _progress.add(p);
    onProgress(p);
  }

  /// 未完成的图片接收缓冲：hash -> 分块上下文。
  final Map<String, _IncomingImage> _incoming = <String, _IncomingImage>{};

  /// 未完成的笔记块接收缓冲：noteId -> 组装上下文。
  final Map<String, _NoteChunkInbox> _noteChunks = <String, _NoteChunkInbox>{};

  /// 本机作为发送方时，缓存最近一次清单对应的块内容（供 note_chunk_request 取用）。
  final Map<String, Map<String, _OutChunk>> _outgoingChunks =
      <String, Map<String, _OutChunk>>{};

  /// 已发出、等待 ack 的 patch 上下文（noteId → 发送时的目标正文与版本向量）。
  ///
  /// 收到 ack 后据此把基线推进到「对端当前持有的版本」。不这么做的话，
  /// 基线会一直停在 patch 之前，下一轮会被判为「对端已动」而退化成全量推送。
  final Map<String, _PendingPatch> _pendingPatches = <String, _PendingPatch>{};

  /// 图片传输任务的 Future（用于不阻塞文本消息的前提下跟踪完成度）。
  final List<Future<void>> _imageTasks = <Future<void>>[];

  /// 记录每个会话的同步状态。
  final Map<PeerSession, _SyncState> _states = <PeerSession, _SyncState>{};

  _SyncState _stateOf(PeerSession s) =>
      _states.putIfAbsent(s, () => _SyncState());

  /// 同步基线的键：优先用对端设备 id（协议保证唯一），取不到时退回连接标签。
  String _peerId(PeerSession s) => s.remoteDeviceId ?? s.remoteLabel;

  // ---------------------------------------------------------------- 入口

  /// 收到一条已解密的消息。
  void onMessage(PeerSession session, String type, Map<String, dynamic> body) {
    switch (type) {
      case MsgType.ping:
        session.send(MsgType.pong, <String, dynamic>{
          Field.ts: body[Field.ts] ?? DateTime.now().toUtc().toIso8601String(),
        });
      case MsgType.pong:
        break;

      case MsgType.noteSummary:
        unawaited(_onNoteSummary(session, body));
      case MsgType.notePull:
        unawaited(_onNotePull(session, body));
      case MsgType.notePush:
        unawaited(_onNotePush(session, body));
      case MsgType.noteDelete:
        unawaited(_onNoteDelete(session, body));

      case MsgType.notePatch:
        unawaited(_onNotePatch(session, body));
      case MsgType.notePatchAck:
        unawaited(_onNotePatchAck(session, body));
      case MsgType.notePatchNack:
        unawaited(_onNotePatchNack(session, body));

      case MsgType.noteChunkManifest:
        unawaited(_onChunkManifest(session, body));
      case MsgType.noteChunkRequest:
        unawaited(_onChunkRequest(session, body));
      case MsgType.noteChunkPush:
        unawaited(_onChunkPush(session, body));

      case MsgType.imageManifest:
        unawaited(_onImageManifest(session, body));
      case MsgType.imageRequest:
        unawaited(_onImageRequest(session, body));
      case MsgType.imageChunk:
        _onImageChunk(session, body);
      case MsgType.imageComplete:
        unawaited(_onImageComplete(session, body));

      default:
        Log.debug('忽略未知消息类型 $type');
    }
  }

  void onSessionClosed(PeerSession session) {
    _states.remove(session);
    _incoming.clear();
    _noteChunks.clear();
    _imageTasks.clear();
    _report(const SyncProgress());
  }

  /// 已认证：启动全量对比。
  Future<void> startSync(PeerSession session) async {
    onPeerAuthenticated(session);
    _report(const SyncProgress(running: true));
    await _sendSummary(session);
    session.send(MsgType.imageManifest, <String, dynamic>{
      Field.hashes: paths.listImageHashes().toList(),
    });
  }

  /// 本地变更后触发增量同步（由 500ms 防抖调用）。
  Future<void> notifyLocalChange(PeerSession session) async {
    if (!session.isAuthenticated) return;
    await _sendSummary(session);
  }

  /// 发送**摘要清单**（变更 6.2：`note_summary`，不含正文）。
  Future<void> _sendSummary(PeerSession session) async {
    session.send(MsgType.noteSummary, <String, dynamic>{
      Field.notes: await _localSummaries(),
    });
  }

  Future<List<Map<String, dynamic>>> _localSummaries() async {
    final notes = await repo.all();
    return notes
        .map(NoteRepository2.toMeta)
        .map((m) => m.toSummary())
        .toList();
  }

  /// 读一条笔记的同步模型（取不到返回 null）。
  Future<NoteMeta?> _metaOf(String noteId) async {
    final row = await repo.db.noteById(noteId);
    return row == null ? null : NoteRepository2.toMeta(row);
  }

  /// 读本地全部笔记（noteId → [NoteMeta]）。
  Future<Map<String, NoteMeta>> _localMetas() async {
    final notes = await repo.all();
    return <String, NoteMeta>{
      for (final n in notes) n.noteId: NoteRepository2.toMeta(n),
    };
  }

  /// 读与该对端的同步基线（noteId → 上次同步版本向量）。
  Future<Map<String, VersionVector>> _baselines(PeerSession s) async {
    final raw = await repo.db.baselinesForPeer(_peerId(s));
    return <String, VersionVector>{
      for (final e in raw.entries) e.key: VersionVector.decode(e.value),
    };
  }

  // ---------------------------------------------------------------- 文本

  Future<void> _onNoteSummary(PeerSession s, Map<String, dynamic> body) async {
    final rawList = (body[Field.notes] as List?) ?? <dynamic>[];
    final remote = <String, NoteMeta>{};
    for (final raw in rawList) {
      try {
        final m = NoteMeta.fromSummary((raw as Map).cast<String, dynamic>());
        remote[m.noteId] = m;
      } catch (e) {
        Log.error('note_summary 条目解析失败', e);
      }
    }

    final local = await _localMetas();
    final baselines = await _baselines(s);

    final decisions = SyncPlanner.plan(
      local: local,
      remote: remote,
      baselines: baselines,
    );
    _report(_current.copyWith(
      running: true,
      notesTotal: decisions.where((d) => d.action != SyncAction.skip).length,
      notesDone: 0,
    ));

    var done = 0;
    for (final d in decisions) {
      switch (d.action) {
        case SyncAction.skip:
          continue;
        case SyncAction.pull:
          s.send(MsgType.notePull, <String, dynamic>{Field.noteId: d.noteId});
        case SyncAction.push:
          await _pushNote(s, d.noteId);
        case SyncAction.patch:
          await _pushPatch(s, d.noteId);
        case SyncAction.pushDelete:
          await _pushDelete(s, d.noteId);
        case SyncAction.blockSync:
          await _pushChunks(s, d.noteId);
        case SyncAction.conflict:
          await _resolveConflict(s, local[d.noteId], remote[d.noteId]);
      }
      done++;
    }
    _report(_current.copyWith(running: true, notesDone: done));
    await _awaitImages();
    _report(_current.copyWith(
      running: false,
      lastSyncedAt: DateTime.now(),
      clearError: true,
    ));
  }

  /// 全量推送一条笔记（含正文）。
  ///
  /// 推送后即记录基线：若对端此后未动，下次本地编辑就能走增量 patch。
  Future<void> _pushNote(PeerSession s, String noteId) async {
    final meta = await _metaOf(noteId);
    if (meta == null) return;
    s.send(MsgType.notePush, meta.toPushPayload());
    await repo.db.saveBaseline(
      noteId: noteId,
      peerDeviceId: _peerId(s),
      versionVector: meta.versionVector.encode(),
      baseText: meta.content,
    );
  }

  /// 增量推送：基线正文 → 当前正文的 patch（变更 6.3 / 6.4）。
  ///
  /// 无基线或 patch 体积超过全量的 [SyncPlanner.patchSizeRatioLimit] 时，
  /// 直接降级为全量推送，避免「patch 比正文还大」。
  Future<void> _pushPatch(PeerSession s, String noteId) async {
    final meta = await _metaOf(noteId);
    if (meta == null) return;
    final baseline = await repo.db.baselineFor(noteId, _peerId(s));
    if (baseline == null) {
      await _pushNote(s, noteId);
      return;
    }
    final patch = PatchUtil.makePatch(baseline.baseText, meta.content);
    if (!PatchUtil.shouldSendPatch(
      baseline.baseText,
      patch,
      limit: SyncPlanner.patchSizeRatioLimit,
    )) {
      await _pushNote(s, noteId);
      return;
    }
    s.send(MsgType.notePatch, <String, dynamic>{
      Field.noteId: noteId,
      Field.patch: patch,
      Field.fromVersionVector:
          VersionVector.decode(baseline.versionVector).counters,
      Field.toVersionVector: meta.versionVector.counters,
      Field.contentHash: meta.contentHash,
      Field.title: meta.title,
      Field.imageHashes: meta.imageHashes,
      Field.updatedAt: meta.updatedAt.toUtc().millisecondsSinceEpoch,
    });
    // 记下发送时的目标状态：收到 ack 才能把基线推进（见 _onNotePatchAck）。
    _pendingPatches[noteId] = _PendingPatch(
      content: meta.content,
      versionVector: meta.versionVector,
    );
  }

  /// 传播删除（软删，保留墓碑）。
  Future<void> _pushDelete(PeerSession s, String noteId) async {
    final meta = await _metaOf(noteId);
    if (meta == null) return;
    s.send(MsgType.noteDelete, <String, dynamic>{
      Field.noteId: noteId,
      Field.versionVector: meta.versionVector.counters,
    });
    await repo.db.saveBaseline(
      noteId: noteId,
      peerDeviceId: _peerId(s),
      versionVector: meta.versionVector.encode(),
      baseText: '',
    );
  }

  Future<void> _onNotePull(PeerSession s, Map<String, dynamic> body) async {
    final noteId = body[Field.noteId] as String?;
    if (noteId == null) return;
    await _pushNote(s, noteId);
  }

  Future<void> _onNotePush(PeerSession s, Map<String, dynamic> body) async {
    final meta = NoteMeta.fromPush(body);
    if (meta == null) {
      Log.error('note_push 载荷非法', null);
      return;
    }

    // 本地版本支配对端 → 忽略：绝不能用较旧的内容覆盖较新的本地版本。
    // （并发场景由 `conflict` 决策负责保留两份，不依赖这里。）
    final existing = await repo.db.noteById(meta.noteId);
    final localVv = VersionVector.decode(existing?.versionVector ?? '{}');
    if (existing != null &&
        localVv.compare(meta.versionVector) == VersionRelation.dominates) {
      Log.debug('忽略较旧的 note_push ${meta.noteId}');
      return;
    }

    await repo.writeFromPeer(
      noteId: meta.noteId,
      content: meta.content,
      remoteVersionVector: meta.versionVector,
      contentHash: meta.contentHash,
      imageHashes: meta.imageHashes,
      title: meta.title,
    );

    // 基线记「合并后」的版本向量，保证两端对同一基线达成一致。
    final merged = localVv.merge(meta.versionVector);
    await repo.db.saveBaseline(
      noteId: meta.noteId,
      peerDeviceId: _peerId(s),
      versionVector: merged.encode(),
      baseText: meta.content,
    );

    // 正文里引用了我这边没有的图片 → 请求
    final localImages = paths.listImageHashes();
    final missing =
        meta.imageHashes.where((h) => !localImages.contains(h)).toList();
    if (missing.isNotEmpty) {
      s.send(MsgType.imageRequest, <String, dynamic>{Field.hashes: missing});
    }
  }

  Future<void> _onNoteDelete(PeerSession s, Map<String, dynamic> body) async {
    final noteId = body[Field.noteId] as String?;
    if (noteId == null) return;
    // 对端删除也走软删，保留墓碑以便继续传播。
    final remote = _decodeVv(body[Field.versionVector]);
    await repo.applyRemoteDelete(noteId, remote);
  }

  // -------------------------------------------------------- 增量 patch

  Future<void> _onNotePatch(PeerSession s, Map<String, dynamic> body) async {
    final noteId = body[Field.noteId] as String?;
    final patchJson = body[Field.patch] as String?;
    if (noteId == null || patchJson == null) return;

    // patch 的基线正文只能从「与本对端的基线」读（正文已入库，不再读文件）。
    final baseline = await repo.db.baselineFor(noteId, _peerId(s));
    final applied = PatchUtil.applyPatch(baseline?.baseText ?? '', patchJson);
    if (applied == null) {
      // 基线不匹配（双方视图已分叉）→ 让对端降级为全量，绝不猜测性合并。
      Log.debug('patch 基线不匹配，请求全量 $noteId');
      s.send(MsgType.notePatchNack, <String, dynamic>{Field.noteId: noteId});
      return;
    }

    final vv = _decodeVv(body[Field.toVersionVector]);
    final contentHash = (body[Field.contentHash] as String?) ?? '';
    final hashes = ((body[Field.imageHashes] as List?) ?? <dynamic>[])
        .map((e) => e.toString())
        .toList();

    await repo.writeFromPeer(
      noteId: noteId,
      content: applied,
      remoteVersionVector: vv,
      contentHash: contentHash.isEmpty ? Hashing.contentHash(applied) : contentHash,
      imageHashes: hashes,
      title: body[Field.title] as String?,
    );
    final row = await repo.db.noteById(noteId);
    if (row != null) {
      await repo.db.saveBaseline(
        noteId: noteId,
        peerDeviceId: _peerId(s),
        versionVector: row.versionVector,
        baseText: applied,
      );
    }
    s.send(MsgType.notePatchAck, <String, dynamic>{
      Field.noteId: noteId,
      Field.versionVector: vv.counters,
    });

    final localImages = paths.listImageHashes();
    final missing = hashes.where((h) => !localImages.contains(h)).toList();
    if (missing.isNotEmpty) {
      s.send(MsgType.imageRequest, <String, dynamic>{Field.hashes: missing});
    }
  }

  Future<void> _onNotePatchAck(PeerSession s, Map<String, dynamic> body) async {
    final noteId = body[Field.noteId] as String?;
    if (noteId == null) return;
    _stateOf(s).patchAcked++;
    // 对端已成功应用：此刻两端正文一致，基线推进到发送时的版本向量，
    // 这样下一轮本地再次编辑时仍然判定「对端未动」，可以继续走增量。
    final pending = _pendingPatches.remove(noteId);
    if (pending != null) {
      await repo.db.saveBaseline(
        noteId: noteId,
        peerDeviceId: _peerId(s),
        versionVector: pending.versionVector.encode(),
        baseText: pending.content,
      );
    }
    Log.debug('patch 已被对端应用 $noteId');
  }

  Future<void> _onNotePatchNack(PeerSession s, Map<String, dynamic> body) async {
    final noteId = body[Field.noteId] as String?;
    if (noteId == null) return;
    // 对端基线不匹配 → 降级为全量推送。
    Log.debug('对端基线不匹配，降级为全量推送 $noteId');
    await _pushNote(s, noteId);
  }

  // -------------------------------------------------------- 冲突副本

  /// 并发编辑：**两份都保留**，绝不直接覆盖（变更 6.1 / 变更 10）。
  ///
  /// 分工原则（保证两端结果确定且不产生重复副本）：
  /// - 版本较旧的一方把自己的正文另存为冲突副本（新 noteId），原 noteId 收敛到胜者；
  /// - 版本较新的一方保持原样并推送，让对端收敛。
  Future<void> _resolveConflict(
    PeerSession s,
    NoteMeta? localNote,
    NoteMeta? remoteNote,
  ) async {
    if (localNote == null || remoteNote == null) {
      // 一端缺失时不构成冲突，按缺失侧处理（拉或推）。
      final id = localNote?.noteId ?? remoteNote?.noteId;
      if (id == null) return;
      if (localNote == null) {
        s.send(MsgType.notePull, <String, dynamic>{Field.noteId: id});
      } else {
        await _pushNote(s, id);
      }
      return;
    }

    final res = SyncPlanner.resolveConflict(localNote, remoteNote);
    final merged = res.winner.versionVector.merge(res.loser.versionVector);

    if (identical(res.loser, localNote)) {
      // 本机是败者：先留副本，再让原 noteId 收敛到胜者内容。
      final copyId = await repo.saveConflictCopy(res.loser);
      await repo.writeFromPeer(
        noteId: res.winner.noteId,
        content: res.winner.content,
        remoteVersionVector: merged,
        contentHash: res.winner.contentHash,
        imageHashes: res.winner.imageHashes,
        title: res.winner.title,
      );
      // 副本推给对端，使两端都保留两份。
      await _pushNote(s, copyId);
      // 原 id 也推一次，让对端把版本向量收敛到合并值。
      await _pushNote(s, res.winner.noteId);
      Log.debug('冲突副本已保留：${res.loser.noteId} → $copyId');
    } else {
      // 本机是胜者：原样保留并推送，等对端生成副本后回传。
      await _pushNote(s, res.winner.noteId);
    }
  }

  // -------------------------------------------------------- 块级同步

  /// 大文件（≥256KB）块级推送：先发块哈希清单，等对端请求缺失块。
  Future<void> _pushChunks(PeerSession s, String noteId) async {
    final meta = await _metaOf(noteId);
    if (meta == null) return;
    final chunks = _splitChunks(meta.content);
    s.send(MsgType.noteChunkManifest, <String, dynamic>{
      ...meta.toSummary(),
      Field.imageHashes: meta.imageHashes,
      Field.chunkHashes: chunks.map((c) => c.hash).toList(),
    });
    // 缓存块内容，供随后的 note_chunk_request 取用。
    _outgoingChunks[noteId] = <String, _OutChunk>{
      for (final c in chunks) c.hash: c,
    };
    await repo.db.saveBaseline(
      noteId: noteId,
      peerDeviceId: _peerId(s),
      versionVector: meta.versionVector.encode(),
      baseText: meta.content,
    );
  }

  /// 对端请求缺失块 → 逐块推送（base64）。
  Future<void> _onChunkRequest(PeerSession s, Map<String, dynamic> body) async {
    final noteId = body[Field.noteId] as String?;
    if (noteId == null) return;
    final wanted = ((body[Field.chunkHashes] as List?) ?? <dynamic>[])
        .map((e) => e.toString())
        .toList();
    final available = _outgoingChunks[noteId];
    if (available == null) {
      Log.debug('对端请求块但本机无清单缓存 $noteId，降级全量');
      await _pushNote(s, noteId);
      return;
    }
    for (final h in wanted) {
      final c = available[h];
      if (c == null) continue;
      s.send(MsgType.noteChunkPush, <String, dynamic>{
        Field.noteId: noteId,
        Field.chunkHash: h,
        Field.data: base64.encode(c.data),
      });
    }
  }

  /// 收到块哈希清单：算出本地缺失的块并请求。
  Future<void> _onChunkManifest(PeerSession s, Map<String, dynamic> body) async {
    final meta = NoteMeta.fromSummary(body);
    final order = ((body[Field.chunkHashes] as List?) ?? <dynamic>[])
        .map((e) => e.toString())
        .toList();
    if (order.isEmpty) return;

    final inbox = _NoteChunkInbox(
      order: order,
      meta: meta.copyWith(
        imageHashes: ((body[Field.imageHashes] as List?) ?? <dynamic>[])
            .map((e) => e.toString())
            .toList(),
      ),
    );

    // 本地已有的块（当前正文按相同分块规则切分）不必重传 —— 这正是块级同步的价值所在。
    final existing = await repo.db.noteById(meta.noteId);
    if (existing != null) {
      for (final c in _splitChunks(existing.content)) {
        inbox.have.add(c.hash);
      }
    }
    _noteChunks[meta.noteId] = inbox;

    s.send(MsgType.noteChunkRequest, <String, dynamic>{
      Field.noteId: meta.noteId,
      Field.chunkHashes: inbox.missing,
    });
    if (inbox.missing.isEmpty) {
      await _finishChunkInbox(s, meta.noteId);
    }
  }

  Future<void> _onChunkPush(PeerSession s, Map<String, dynamic> body) async {
    final noteId = body[Field.noteId] as String?;
    final chunkHash = body[Field.chunkHash] as String?;
    final data = body[Field.data] as String?;
    if (noteId == null || chunkHash == null || data == null) return;

    final inbox = _noteChunks[noteId];
    if (inbox == null) return;

    // 传输校验：块内容必须与清单里的哈希一致，否则丢弃（防投毒）。
    final bytes = base64.decode(data);
    if (!Hashing.matchesSha256(bytes, chunkHash)) {
      Log.error('笔记块校验失败，已丢弃 $chunkHash', null);
      return;
    }
    inbox.chunks[chunkHash] = bytes;
    if (inbox.isComplete) {
      await _finishChunkInbox(s, noteId);
    }
  }

  /// 块级同步收尾：整篇重组 → 内容哈希校验 → 入库。
  Future<void> _finishChunkInbox(PeerSession s, String noteId) async {
    final inbox = _noteChunks.remove(noteId);
    if (inbox == null) return;

    final assembled = inbox.assemble();
    // 整篇内容哈希必须匹配（清单里带的是权威 contentHash）。
    final expected = inbox.meta.contentHash;
    if (expected.isNotEmpty && !Hashing.matchesSha256(assembled, expected)) {
      Log.error('块级重组后内容哈希不匹配，已丢弃 $noteId', null);
      _report(_current.copyWith(error: '内容校验失败：$noteId'));
      return;
    }

    final text = utf8.decode(assembled, allowMalformed: true);
    final existing = await repo.db.noteById(noteId);
    final localVv = VersionVector.decode(existing?.versionVector ?? '{}');
    if (existing != null &&
        localVv.compare(inbox.meta.versionVector) ==
            VersionRelation.dominates) {
      Log.debug('忽略较旧的块级同步 $noteId');
      return;
    }

    await repo.writeFromPeer(
      noteId: noteId,
      content: text,
      remoteVersionVector: inbox.meta.versionVector,
      contentHash: expected,
      imageHashes: inbox.meta.imageHashes,
      title: inbox.meta.title,
    );
    await repo.db.saveBaseline(
      noteId: noteId,
      peerDeviceId: _peerId(s),
      versionVector: localVv.merge(inbox.meta.versionVector).encode(),
      baseText: text,
    );
    _report(_current.copyWith(
      running: true,
      notesDone: _current.notesDone + 1,
      clearError: true,
    ));
  }

  /// 固定块大小切分（块哈希 = SHA-256(块字节)）。
  List<_OutChunk> _splitChunks(String content) {
    final bytes = utf8.encode(content);
    final out = <_OutChunk>[];
    for (var start = 0; start < bytes.length; start += noteChunkSize) {
      final end = (start + noteChunkSize).clamp(0, bytes.length);
      final slice = Uint8List.fromList(bytes.sublist(start, end));
      out.add(_OutChunk(hash: Hashing.sha256Hex(slice), data: slice));
    }
    return out;
  }

  // ---------------------------------------------------------------- 图片

  Future<void> _onImageManifest(PeerSession s, Map<String, dynamic> body) async {
    final peerHashes = ((body[Field.hashes] as List?) ?? <dynamic>[])
        .map((e) => e.toString())
        .toSet();
    final localHashes = paths.listImageHashes();
    // 我缺的 → 向对端请求。
    final iNeed = peerHashes.difference(localHashes);
    if (iNeed.isNotEmpty) {
      _report(_current.copyWith(imagesTotal: iNeed.length, imagesDone: 0));
      s.send(MsgType.imageRequest, <String, dynamic>{
        Field.hashes: iNeed.toList(),
      });
    }
  }

  Future<void> _onImageRequest(PeerSession s, Map<String, dynamic> body) async {
    final hashes = ((body[Field.hashes] as List?) ?? <dynamic>[])
        .map((e) => e.toString())
        .toList();
    for (final h in hashes) {
      // 每个哈希一个独立 Future，互不阻塞，也不阻塞文本消息。
      final task = _sendImage(s, h);
      _imageTasks.add(task);
    }
  }

  Future<void> _sendImage(PeerSession s, String hash) async {
    try {
      final file = _findImageFile(hash);
      if (file == null) {
        Log.error('请求的图片不存在 $hash', null);
        return;
      }
      final bytes = await file.readAsBytes();
      final ext = file.path.split('.').last;
      final total =
          (bytes.length / ProtocolConst.imageChunkSize).ceil().clamp(1, 1 << 30);

      for (var seq = 0; seq < total; seq++) {
        final start = seq * ProtocolConst.imageChunkSize;
        final end = (start + ProtocolConst.imageChunkSize).clamp(0, bytes.length);
        s.send(MsgType.imageChunk, <String, dynamic>{
          Field.hash: hash,
          Field.seq: seq,
          Field.total: total,
          Field.data: base64.encode(bytes.sublist(start, end)),
          'ext': ext,
        });
      }
      s.send(MsgType.imageComplete, <String, dynamic>{
        Field.hash: hash,
        'sha256': hash,
      });
    } catch (e) {
      Log.error('发送图片失败 $hash', e);
    }
  }

  /// 按哈希在图片目录里找到实际文件（扩展名由落盘时决定，故不能靠猜）。
  File? _findImageFile(String hash) {
    if (!paths.imagesDir.existsSync()) return null;
    for (final entity in paths.imagesDir.listSync()) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (name.startsWith('$hash.')) return entity;
    }
    return null;
  }

  void _onImageChunk(PeerSession s, Map<String, dynamic> body) {
    final hash = body[Field.hash] as String?;
    final seq = body[Field.seq] as int?;
    final total = body[Field.total] as int?;
    final data = body[Field.data] as String?;
    if (hash == null || seq == null || total == null || data == null) return;

    final buf = _incoming.putIfAbsent(
      hash,
      () => _IncomingImage(total: total, ext: (body['ext'] as String?) ?? 'jpg'),
    );
    buf.add(seq, base64.decode(data));
  }

  Future<void> _onImageComplete(PeerSession s, Map<String, dynamic> body) async {
    final hash = body[Field.hash] as String?;
    if (hash == null) return;
    final buf = _incoming.remove(hash);
    if (buf == null) return;

    final bytes = buf.assemble();
    // 接收端必须校验 SHA-256；不匹配则丢弃（需求 5.7）。
    final ok = await imageVault.storeReceived(hash, buf.ext, bytes);
    if (!ok) {
      Log.error('图片校验失败，已丢弃 $hash', null);
      _report(_current.copyWith(error: '图片校验失败：$hash'));
      return;
    }
    _report(_current.copyWith(
      imagesDone: _current.imagesDone + 1,
      running: true,
    ));
  }

  /// 等待所有图片任务结束（同步收尾用，不影响期间文本消息的收发）。
  Future<void> _awaitImages() async {
    if (_imageTasks.isEmpty) return;
    final tasks = List<Future<void>>.from(_imageTasks);
    _imageTasks.clear();
    await Future.wait(tasks);
  }

  /// 把 `versionVector` 载荷字段解成版本向量（兼容 Map 与 JSON 字符串两种形态）。
  static VersionVector _decodeVv(Object? raw) {
    if (raw is Map) {
      return VersionVector(<String, int>{
        for (final e in raw.entries)
          e.key.toString():
              e.value is int ? e.value as int : int.tryParse('${e.value}') ?? 0,
      });
    }
    if (raw is String && raw.isNotEmpty) return VersionVector.decode(raw);
    return VersionVector.empty();
  }

  void dispose() {
    _progress.close();
    _incoming.clear();
    _noteChunks.clear();
    _outgoingChunks.clear();
    _pendingPatches.clear();
  }
}

/// 接收中的图片分块缓冲。
class _IncomingImage {
  _IncomingImage({required this.total, required this.ext});

  final int total;
  final String ext;
  final Map<int, Uint8List> _chunks = <int, Uint8List>{};

  void add(int seq, Uint8List data) => _chunks[seq] = data;

  bool get isComplete => _chunks.length >= total;

  Uint8List assemble() {
    final builder = BytesBuilder();
    for (var i = 0; i < total; i++) {
      final c = _chunks[i];
      if (c != null) builder.add(c);
    }
    return builder.takeBytes();
  }
}

/// 已发出、等待 ack 的 patch。
class _PendingPatch {
  const _PendingPatch({required this.content, required this.versionVector});

  /// 发送时的目标正文（对端应用成功后即为双方共同正文）。
  final String content;

  /// 发送时的目标版本向量。
  final VersionVector versionVector;
}

/// 发送侧的一个块。
class _OutChunk {
  const _OutChunk({required this.hash, required this.data});
  final String hash;
  final Uint8List data;
}

/// 接收侧的块组装上下文。
class _NoteChunkInbox {
  _NoteChunkInbox({required this.order, required this.meta});

  /// 清单给出的块顺序（组装必须按此顺序）。
  final List<String> order;

  /// 清单携带的元数据。
  final NoteMeta meta;

  /// 本地已存在的块哈希（无需传输）。
  final Set<String> have = <String>{};

  /// 已收到的块。
  final Map<String, Uint8List> chunks = <String, Uint8List>{};

  List<String> get missing =>
      order.where((h) => !have.contains(h) && !chunks.containsKey(h)).toList();

  bool get isComplete => missing.isEmpty;

  Uint8List assemble() {
    final builder = BytesBuilder();
    for (final h in order) {
      final c = chunks[h];
      if (c != null) builder.add(c);
    }
    return builder.takeBytes();
  }
}

/// 每个会话的同步状态。
class _SyncState {
  bool summaryReceived = false;
  bool manifestReceived = false;

  /// 对端成功应用 patch 的次数（观测用）。
  int patchAcked = 0;
}
