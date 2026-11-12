import '../version/version_vector.dart';
import 'models.dart';

/// 单条笔记的同步动作（变更 6.3）。
enum SyncAction {
  /// 双方一致（版本向量 equal 且 contentHash 相同）——跳过。
  skip,

  /// 对端更新 → 拉取全量。
  pull,

  /// 本地更新且对端未动（基线 == 对端版本）且体积小 → 发增量 patch。
  patch,

  /// 本地更新 → 推送全量。
  push,

  /// 本地删除且更新 → 传播删除。
  pushDelete,

  /// 双方并发编辑 → 生成冲突副本（两份都保留）。
  conflict,

  /// 本地更新且体积 ≥256KB → 块级差异同步。
  blockSync,
}

/// 一条同步决策。
class SyncDecision {
  const SyncDecision({
    required this.noteId,
    required this.action,
    this.reason = '',
    this.relation,
  });

  final String noteId;
  final SyncAction action;

  /// 判定依据（便于日志与测试断言，不含敏感内容）。
  final String reason;

  final VersionRelation? relation;

  @override
  String toString() => 'SyncDecision($noteId, $action${reason.isEmpty ? '' : ': $reason'})';
}

/// 同步规划：按版本向量分类（替换第一版的 updatedAt LWW）。
class SyncPlanner {
  SyncPlanner._();

  /// 块级同步阈值：≥256KB 启用（变更 6.2 / 6.3）。
  static const int blockSyncThresholdBytes = 256 * 1024;

  /// patch 体积超过全量的该比例时，直接改发全量（变更 6.4）。
  static const double patchSizeRatioLimit = 0.7;

  /// UTF-8 字节长度（用于体积判定）。
  static int byteLength(String text) => _utf8Length(text);

  static int _utf8Length(String s) {
    var n = 0;
    for (final rune in s.runes) {
      if (rune <= 0x7f) {
        n += 1;
      } else if (rune <= 0x7ff) {
        n += 2;
      } else if (rune <= 0xffff) {
        n += 3;
      } else {
        n += 4;
      }
    }
    return n;
  }

  /// 规划本地相对对端需要执行的动作。
  ///
  /// [baselines] 是 (noteId → 上次与本对端同步时的版本向量)，
  /// 用于判断「对端自上次同步后有没有动过」从而决定能否安全发 patch。
  static List<SyncDecision> plan({
    required Map<String, NoteMeta> local,
    required Map<String, NoteMeta> remote,
    Map<String, VersionVector> baselines = const <String, VersionVector>{},
  }) {
    final decisions = <SyncDecision>[];
    final ids = <String>{...local.keys, ...remote.keys};

    for (final id in ids) {
      final l = local[id];
      final r = remote[id];

      // 对端有、本地无
      if (l == null && r != null) {
        if (r.isDeleted) continue; // 墓碑且本地从未见过 → 不必拉
        decisions.add(SyncDecision(
          noteId: id,
          action: SyncAction.pull,
          reason: '本地缺失',
        ));
        continue;
      }

      // 本地有、对端无
      if (l != null && r == null) {
        decisions.add(SyncDecision(
          noteId: id,
          action: l.isDeleted ? SyncAction.pushDelete : SyncAction.push,
          reason: '对端缺失',
        ));
        continue;
      }

      if (l == null || r == null) continue;

      final relation = l.versionVector.compare(r.versionVector);

      switch (relation) {
        case VersionRelation.equal:
          // 版本相同：再用 contentHash 确认内容真的一致。
          if (l.contentHash == r.contentHash && !l.isDeleted && !r.isDeleted) {
            decisions.add(SyncDecision(
              noteId: id,
              action: SyncAction.skip,
              reason: '版本与内容均一致',
              relation: relation,
            ));
          } else if (l.isDeleted == r.isDeleted && l.contentHash == r.contentHash) {
            decisions.add(SyncDecision(
              noteId: id,
              action: SyncAction.skip,
              reason: '版本与内容均一致（含墓碑）',
              relation: relation,
            ));
          } else if (l.isDeleted != r.isDeleted) {
            // 版本相同但删除状态不同 → 收敛到「不删除」（确定性，避免抖动）
            if (!l.isDeleted) {
              decisions.add(SyncDecision(
                noteId: id,
                action: SyncAction.push,
                reason: '同版本但删除状态冲突，保留未删除的一份',
                relation: relation,
              ));
            } else {
              decisions.add(SyncDecision(
                noteId: id,
                action: SyncAction.pull,
                reason: '同版本但删除状态冲突，保留未删除的一份',
                relation: relation,
              ));
            }
          } else {
            // 版本相同、hash 不同（极端异常）→ 用 updatedAt 兜底
            final lw = l.updatedAt.toUtc().compareTo(r.updatedAt.toUtc());
            decisions.add(SyncDecision(
              noteId: id,
              action: lw >= 0 ? SyncAction.push : SyncAction.pull,
              reason: '同版本但内容哈希不一致，按 updatedAt 兜底',
              relation: relation,
            ));
          }

        case VersionRelation.dominates:
          // 本地更新：判断对端是否自基线以来没动过 → 可发增量 patch。
          final baseline = baselines[id];
          // 文档 6.3：仅当「基线版本 == 对端版本」即对端自上次同步后确实没动过时，
          // 才允许发增量 patch（此时基线正文就是双方共同祖先，patch 一定能应用）。
          // 没有基线记录时无法确认，保守走全量。
          final peerUntouched = baseline != null &&
              r.versionVector.compare(baseline) == VersionRelation.equal;

          if (l.isDeleted) {
            decisions.add(SyncDecision(
              noteId: id,
              action: SyncAction.pushDelete,
              reason: '本地删除且更新',
              relation: relation,
            ));
          } else if (byteLength(l.content) >= blockSyncThresholdBytes) {
            decisions.add(SyncDecision(
              noteId: id,
              action: SyncAction.blockSync,
              reason: '体积 ≥256KB，走块级差异同步',
              relation: relation,
            ));
          } else if (peerUntouched) {
            decisions.add(SyncDecision(
              noteId: id,
              action: SyncAction.patch,
              reason: '本地更新且对端未动，可发增量 patch',
              relation: relation,
            ));
          } else {
            decisions.add(SyncDecision(
              noteId: id,
              action: SyncAction.push,
              reason: '本地更新但对端已动，发全量',
              relation: relation,
            ));
          }

        case VersionRelation.dominated:
          decisions.add(SyncDecision(
            noteId: id,
            action: SyncAction.pull,
            reason: '对端更新',
            relation: relation,
          ));

        case VersionRelation.concurrent:
          // 并发编辑 → 冲突副本，两份都保留（变更 9：不得直接覆盖）。
          decisions.add(SyncDecision(
            noteId: id,
            action: SyncAction.conflict,
            reason: '双方并发编辑，生成冲突副本',
            relation: relation,
          ));
      }
    }

    decisions.sort((a, b) => a.noteId.compareTo(b.noteId));
    return decisions;
  }

  /// 解决冲突：决定谁是「原 noteId」的胜者、谁退居冲突副本。
  ///
  /// 规则（变更 6.1）：较新者占原 noteId，较旧者改为新 noteId 并加标题后缀。
  /// 判定优先看 updatedAt；相同则按 contentHash 字典序（保证两端结果一致）。
  static ConflictResolution resolveConflict(NoteMeta a, NoteMeta b) {
    final cmp = a.updatedAt.toUtc().compareTo(b.updatedAt.toUtc());
    if (cmp > 0) return ConflictResolution(winner: a, loser: b);
    if (cmp < 0) return ConflictResolution(winner: b, loser: a);
    // 时间相同：用 contentHash 打破平局，保证两端选择一致（确定性）
    return a.contentHash.compareTo(b.contentHash) >= 0
        ? ConflictResolution(winner: a, loser: b)
        : ConflictResolution(winner: b, loser: a);
  }

  /// 计算待推送图片（第一版逻辑不变）。
  static Set<String> missingImages({
    required Set<String> peerHashes,
    required Set<String> localHashes,
  }) =>
      localHashes.difference(peerHashes);
}

/// 冲突解决结果。
class ConflictResolution {
  const ConflictResolution({required this.winner, required this.loser});

  /// 保留原 noteId 的一方。
  final NoteMeta winner;

  /// 退居冲突副本的一方（需要分配新 noteId）。
  final NoteMeta loser;
}
