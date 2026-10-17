/// 追番更新检测：动漫更新了新一集，k酱 要能识别到，并给得出最新一集
///
/// 【v2.1.0 新增】
///
/// ## 为什么自己写
///
/// 翻遍 Kazumi 源码（lib 下所有含 update/latest/refresh/new 的文件），它
/// **没有**追番更新检测：追番卡片 `collect_library_card.dart` 只渲染评分和
/// 状态，没有任何集数快照或红点。Kazumi 之所以"总能看到最新一集"，是因为
/// `source_sheet.dart:131` 每次打开番剧都实时 `plugin.queryChapterRoads()`——
/// 是**实时查询**，不是**后台比对**。
///
/// 所以这里没有现成实现可抄，按「存基线 → 定时扫 → 比对」自己实现。
///
/// ## 做法（对齐 Kazumi 规则更新的思路）
///
///   1. 本地存每部追番的「已知最新集数」快照（基线），见 `FollowUpdateEntry`；
///   2. 启动 / 刷新时扫一遍「在看 + 想看」的番，取源站当前最新集数；
///   3. 比基线大 → 标记「有更新」，追番页显示红点 + 「更新至第 N 集」；
///   4. 点进去看 → 走 `DetailPage` 的实时聚合，拿到的就是最新集。
///
/// ## 性能：全源并发 + 取最大集数（v2.1.1 修正）
///
/// v2.1.0 曾用「竞速」——谁先给出非空剧集列表就用谁。实测这是**错的**：
/// 快源（7sefun 等）1~2 秒返回**旧集数**就赢了竞速，慢源（DM84 单请求
/// 6~7s）虽然已有最新一集，结果却被直接丢弃 —— 表现为「明明 DM84 更新
/// 了新一集，软件却同步不上」。
///
/// 现改为对齐 Kazumi/囧次元的聚合语义：**所有源并发探测，取各源最大
/// 集数**，并记下是哪家有最新集。为了不把扫描拖成「等最慢的源」，
/// 设总时限 [_probeDeadline]，超时就用已到手的最好结果（慢源的后台
/// 请求自带 12s 超时，不会泄漏）。
///
/// ## 容错
///
/// 任何一步失败都只写日志，绝不外抛，也不动已有数据——
/// 检测挂了，追番列表和历史进度照常可用。
library;

import 'dart:async';

import '../models.dart';
import 'diag_log.dart';
import 'video_sources.dart';

/// 读取某部番的快照（返回 null = 还没扫过）
typedef FollowSnapshotReader = FollowUpdateEntry? Function(int subjectId);

/// 写入某部番的快照
/// 写入某部番的快照
///
/// **直接存 entry，不要在 writer 里重算 `newSince`**——
/// 新集发现时间由 `scan` 统一判定（见 `_scanOne` 里的 `newSince` 计算），
/// 两处各算一遍必然不一致（实测：比对报了 3 部更新，红点数却是 0）。
typedef FollowSnapshotWriter = void Function(FollowUpdateEntry entry);

/// 提供待检测的番剧列表（默认：在看 + 想看）
typedef FollowSubjectsProvider = List<Subject> Function();

/// 扫描结果
class FollowScanReport {
  /// 实际扫描的番数
  final int scanned;

  /// 因节流而跳过的番数
  final int skipped;

  /// 检测到有新集的番数
  final int updated;

  /// 扫描失败（全部源都没结果）的番数
  final int failed;

  /// 本次耗时
  final Duration elapsed;

  final DateTime at;

  const FollowScanReport({
    this.scanned = 0,
    this.skipped = 0,
    this.updated = 0,
    this.failed = 0,
    this.elapsed = Duration.zero,
    required this.at,
  });

  @override
  String toString() =>
      'FollowScanReport(scanned: $scanned, skipped: $skipped, '
      'updated: $updated, failed: $failed, elapsed: ${elapsed.inMilliseconds}ms)';
}

/// 一部番的检测结果
class FollowUpdateResult {
  final int subjectId;

  /// 源站当前最新集数（null = 没扫到）
  final double? latestSort;

  /// 基线里记录的上次集数（null = 首次扫描）
  final double? previousSort;

  /// 扫出结果的源名（诊断用）
  final String sourceName;

  /// 是否发现了新集
  final bool hasNewEpisode;

  const FollowUpdateResult({
    required this.subjectId,
    this.latestSort,
    this.previousSort,
    this.sourceName = '',
    this.hasNewEpisode = false,
  });
}

/// 追番更新检测服务
///
/// 用法：
/// ```dart
/// // main.dart 里注入真实存储
/// FollowUpdateService.instance.configure(
///   reader: (id) => Store.followUpdates.of(id),
///   writer: (e) => Store.followUpdates.put(e),
///   subjects: () => Store.favorites.trackedSubjects(),
/// );
/// unawaited(FollowUpdateService.instance.scan());
/// ```
class FollowUpdateService {
  FollowUpdateService();

  static final FollowUpdateService instance = FollowUpdateService();

  /// 同一部番两次扫描的最小间隔，避免频繁打扰源站
  ///
  /// 【v2.1.1】3h → 30min：用户目标「新出一集后尽快同步」。
  /// 30 分钟是客户端轮询的合理下限（再密会对源站造成压力，且新番
  /// 是周更，30 分钟粒度足够「过一会儿就能看到」）。
  /// 注意：打开详情页 / 切回前台走的是**实时聚合**（10 分钟 TTL），
  /// 不受此间隔限制——真正的「立刻看到」靠那条路径。
  static const Duration scanInterval = Duration(minutes: 30);

  /// 单个 HTTP 请求的超时（与 video_sources._kRequestTimeout 对齐）
  static const Duration probeTimeout = Duration(seconds: 12);

  /// 一部番全源探测的总时限：到点就用已到手的最好结果。
  ///
  /// 慢源（DM84 高峰期单请求 6~7s、还可能要换备用名重试）需要 20s 上下；
  /// 再久基本就是站点半死，不值得为它拖住整轮扫描。
  static const Duration probeDeadline = Duration(seconds: 28);

  /// 同时扫描的番剧数（worker pool 大小）
  static const int concurrency = 3;

  FollowSnapshotReader? _reader;
  FollowSnapshotWriter? _writer;
  FollowSubjectsProvider? _subjects;

  /// 内存兜底：注入前也能安全调用（不会写盘）
  final Map<int, FollowUpdateEntry> _memory = {};

  /// 是否正在扫描（避免启动 + 手动刷新并发跑两遍）
  bool _scanning = false;
  bool get isScanning => _scanning;

  /// 进程存活标记：退出时置 false，worker pool 不再接新活
  final bool _alive = true;

  DateTime? _lastScanAt;
  DateTime? get lastScanAt => _lastScanAt;

  /// 周期自动扫描的定时器（软件常开场景）
  Timer? _autoTimer;

  /// 启动周期自动扫描：每 [scanInterval] 扫一轮（scan 内部还有逐番节流，
  /// 到点未 ScanInterval 的番会自动跳过，不会重复打扰源站）。
  ///
  /// 【v2.1.1】此前只有「启动时 + 进追番页」两个触发点，软件一直开着
  /// 就永远不会再扫——新出一集要等用户下次重启才发现。
  void startAutoScan() {
    _autoTimer?.cancel();
    // 周期比节流间隔略长 2 分钟：扫描本身要花几秒，若周期与节流等长，
    // 下一轮 tick 的 elapsed 会差几秒不足 scanInterval 而被整体跳过
    // （表现为「隔一轮才扫一次」）。
    _autoTimer = Timer.periodic(scanInterval + const Duration(minutes: 2), (_) {
      if (_scanning) return;
      unawaited(scan());
    });
  }

  /// 停止周期自动扫描（设置里关掉「启动时自动检测」时调用）
  void stopAutoScan() {
    _autoTimer?.cancel();
    _autoTimer = null;
  }

  /// 注入存储依赖（由 main.dart 调用）
  void configure({
    FollowSnapshotReader? reader,
    FollowSnapshotWriter? writer,
    FollowSubjectsProvider? subjects,
  }) {
    _reader = reader;
    _writer = writer;
    _subjects = subjects;
  }

  FollowUpdateEntry? _read(int id) {
    final r = _reader;
    if (r != null) {
      try {
        return r(id);
      } catch (e) {
        kLog('[追番] 读取快照失败 id=$id：$e');
      }
    }
    return _memory[id];
  }

  void _write(FollowUpdateEntry e) {
    final w = _writer;
    if (w != null) {
      try {
        w(e);
        return;
      } catch (err) {
        kLog('[追番] 写入快照失败 id=${e.subjectId}：$err');
      }
    }
    _memory[e.subjectId] = e;
  }

  /// 某部番是否有待看更新（红点）
  bool hasUpdate(int subjectId) => (_read(subjectId)?.newSince ?? 0) > 0;

  /// 有待看更新的番剧 id（按发现时间从新到旧）
  ///
  /// 只对「还在追」的番统计——取消收藏 / 标记抛弃后自动从这里消失。
  List<int> pendingIds() {
    final list = _targets();
    final ids = <int>[
      for (final s in list)
        if ((_read(s.id)?.newSince ?? 0) > 0) s.id,
    ];
    ids.sort((a, b) => (_read(b)?.newSince ?? 0).compareTo(_read(a)?.newSince ?? 0));
    return ids;
  }

  /// 待看更新的番数（红点数）
  int get pendingCount => pendingIds().length;

  /// 取待检测的番剧列表（已注入 provider 为准）
  List<Subject> _targets() {
    final p = _subjects;
    if (p == null) return const [];
    try {
      return p();
    } catch (e) {
      kLog('[追番] 获取追番列表失败：$e');
      return const [];
    }
  }

  /// 详情页聚合出结果后回写基线（**只推进、不新点亮红点**）
  ///
  /// 不回写会误报：用户在详情页刷新拿到第 25 集，后台快照还停在 24，
  /// 下一轮定时扫描拿 25 比 24，又报一次「有更新」——用户明明已经看过了。
  ///
  /// 只推进不回退：源站偶尔少返回几集，别把基线拉低。
  void recordLatest(int subjectId, double latestSort, {String sourceName = ''}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final old = _read(subjectId);

    // 没变新：只刷新扫描时间，保留原有红点状态
    if (old != null && latestSort <= old.latestSort) {
      _write(old.copyWith(scannedAt: now));
      return;
    }

    _write(FollowUpdateEntry(
      subjectId: subjectId,
      latestSort: latestSort,
      scannedAt: now,
      // 沿用原红点状态，**不在这里新点亮**：
      // 亮红点是后台 scan 的职责；这里是详情页刷新后的基线同步，
      // 否则用户刚点进去看过，出来又被提示一次「有更新」。
      newSince: old?.newSince ?? 0,
      sourceName: sourceName.isNotEmpty ? sourceName : (old?.sourceName ?? ''),
    ));
  }

  /// 看过最新集 → 清除红点
  void markSeen(int subjectId) {
    final e = _read(subjectId);
    if (e == null || e.newSince == 0) return;
    _write(e.copyWith(newSince: 0));
  }

  /// 扫一遍追番列表，更新快照。
  ///
  /// [force] = true 时忽略节流（手动刷新用）。
  /// [only] 只扫指定的番（详情页联动用）。
  ///
  /// **永不抛异常**：网络/解析/存储任何环节出错都只记日志。
  Future<FollowScanReport> scan({
    bool force = false,
    Iterable<Subject>? only,
    void Function(FollowUpdateResult result)? onResult,
  }) async {
    if (_scanning) {
      kLog('[追番] 上一轮扫描还没结束，跳过本次');
      return FollowScanReport(at: DateTime.now());
    }
    _scanning = true;
    final sw = Stopwatch()..start();

    var scanned = 0;
    var skipped = 0;
    var updated = 0;
    var failed = 0;

    try {
      final targets = only?.toList() ?? _targets();
      if (targets.isEmpty) {
        return FollowScanReport(at: DateTime.now());
      }

      final now = DateTime.now().millisecondsSinceEpoch;
      final pending = <Subject>[];
      for (final s in targets) {
        final base = _read(s.id);
        if (!force && base != null && now - base.scannedAt < scanInterval.inMilliseconds) {
          skipped++;
          continue;
        }
        pending.add(s);
      }

      kLog('[追番] 开始扫描：待扫 ${pending.length} 部，节流跳过 $skipped 部');

      if (pending.isNotEmpty) {
        final sources = SourceRegistry.active.toList();
        if (sources.isEmpty) {
          kLog('[追番] 没有启用的线路，无法扫描');
          failed = pending.length;
        } else {
          // worker pool：一次最多 concurrency 部，避免打爆网络
          final cursor = <int>[0];
          Future<void> worker() async {
            while (true) {
              if (!_alive) return;
              final i = cursor[0]++;
              if (i >= pending.length) return;
              final s = pending[i];
              final res = await _scanOne(s, sources);
              scanned++;
              if (res.hasNewEpisode) {
                updated++;
              } else if (res.latestSort == null) {
                failed++;
              }
              onResult?.call(res);
            }
          }

          await Future.wait([
            for (var i = 0; i < concurrency && i < pending.length; i++) worker(),
          ]);
        }
      }

      _lastScanAt = DateTime.now();
      final report = FollowScanReport(
        scanned: scanned,
        skipped: skipped,
        updated: updated,
        failed: failed,
        elapsed: sw.elapsed,
        at: _lastScanAt!,
      );
      kLog('[追番] 扫描结束：$report');
      return report;
    } catch (e, st) {
      kLog('[追番] 扫描整体失败：$e');
      kLog('[追番] $st');
      return FollowScanReport(at: DateTime.now(), elapsed: sw.elapsed);
    } finally {
      _scanning = false;
    }
  }

  /// 扫一部番：各源竞速，取第一个非空结果的最新集数
  Future<FollowUpdateResult> _scanOne(Subject s, List<VideoSource> sources) async {
    final baseline = _read(s.id);
    final keywords = _keywordCandidates(s);

    try {
      final found = await _probeAllSources(sources, keywords);
      final now = DateTime.now().millisecondsSinceEpoch;

      if (found == null) {
        // 全都没扫到：保留原快照，只更新扫描时间，避免"明明有第 5 集却显示未更新"
        if (baseline != null) {
          _write(baseline.copyWith(scannedAt: now));
        }
        kLog('[追番] ${s.displayName}：所有线路都没扫到，保留基线'
            '${baseline != null ? " 第 ${_fmtSort(baseline.latestSort)} 集" : ""}');
        return FollowUpdateResult(
          subjectId: s.id,
          previousSort: baseline?.latestSort,
        );
      }

      final latest = found.sort;
      final previous = baseline?.latestSort;

      // 首次扫描：只记基线，不提示（否则一装上就整页红点）。
      // 同时判 baseline，让下面的 baseline/previous 都被提升为非空。
      if (baseline == null || previous == null) {
        _write(FollowUpdateEntry(
          subjectId: s.id,
          latestSort: latest,
          scannedAt: now,
          newSince: 0,
          sourceName: found.source,
        ));
        kLog('[追番] ${s.displayName}：首次扫描，记基线 第 ${_fmtSort(latest)} 集'
            '（源 ${found.source}）');
        return FollowUpdateResult(
          subjectId: s.id,
          latestSort: latest,
          sourceName: found.source,
        );
      }

      final hasNew = latest > previous;
      final entry = FollowUpdateEntry(
        subjectId: s.id,
        latestSort: latest > previous ? latest : previous,
        scannedAt: now,
        // 已有红点时保留最早的发现时间，别每次扫描都刷新
        newSince: hasNew ? ((baseline.newSince > 0) ? baseline.newSince : now) : 0,
        sourceName: found.source,
      );
      _write(entry);

      if (hasNew) {
        kLog('[追番] ${s.displayName}：更新了！第 ${_fmtSort(previous)} → '
            '${_fmtSort(latest)} 集（源 ${found.source}）');
      }
      return FollowUpdateResult(
        subjectId: s.id,
        latestSort: latest,
        previousSort: previous,
        sourceName: found.source,
        hasNewEpisode: hasNew,
      );
    } catch (e) {
      kLog('[追番] ${s.displayName} 扫描异常：$e');
      return FollowUpdateResult(subjectId: s.id, previousSort: baseline?.latestSort);
    }
  }

  /// 全源并发探测：取**各源最大集数**，返回 (最大集数, 该集数所在源)。
  ///
  /// 【v2.1.1】取代 v2.1.0 的「竞速取第一个」——快源先回来但集数可能滞后，
  /// 必须等所有源（或总时限到）再取最大，才不会漏掉「只有慢源更新了新一集」
  /// 的情况（实测：新番更新时一度只有 DM84 有最新一集）。
  ///
  /// 到 [probeDeadline] 仍有源没回来，就用已到手的最好结果；没回来的源
  /// 请求自带超时，会在后台自然收尾，不会泄漏。
  Future<({double sort, String source})?> _probeAllSources(
    List<VideoSource> sources,
    List<String> keywords,
  ) async {
    if (sources.isEmpty) return null;
    final results = <({double sort, String source})>[];

    final pending = <Future<void>>[
      for (final src in sources)
        _probeOne(src, keywords).then((sort) {
          if (sort != null && sort > 0) {
            results.add((sort: sort, source: src.name));
          }
        }, onError: (_) {/* 单源失败只跳过，不拖垮整轮 */}),
    ];

    await Future.wait(pending).timeout(
      probeDeadline,
      onTimeout: () {
        kLog('[追番] 全源探测到达总时限 ${probeDeadline.inSeconds}s，'
            '采用已到手的 ${results.length} 条结果');
        return const <void>[];
      },
    );

    if (results.isEmpty) return null;
    results.sort((a, b) => b.sort.compareTo(a.sort));
    return results.first;
  }

  /// 单个源：按关键词顺序试，取到非空剧集列表就返回最大集数
  Future<double?> _probeOne(VideoSource src, List<String> keywords) async {
    // 关键词收敛到前 3 个（主名 + 另一语言名 + 去括号版）：
    // 检测只需集数，主名基本都命中；全试一遍会白白拖慢整源。
    for (final kw in keywords.take(3)) {
      try {
        final hits = await src.search(kw).timeout(probeTimeout);
        if (hits.isEmpty) continue;
        // 【v2.1.3】候选校验（扫描场景只做免网络的表面校验，不做反查——
        // 宁可漏检也不把第一季/无关番的集数当成更新）：
        final ranked = SourceMatch.rank(hits, kw);
        if (ranked.isEmpty) continue;
        if (SourceMatch.seasonMismatch(kw, ranked.first)) continue;
        if (!SourceMatch.surfacePlausible(kw, ranked.first)) continue;
        // 【v2.1.3】季数校验：fallbackTitle 用关键词（用户想要的番），
        // bangumiDetail 内部会按「标题相似 + 季数一致」重排候选，
        // 避免把第一季的集数当成第二季的更新（实测 7sefun 转生就是剑）
        final detail = await src
            .bangumiDetail(fallbackTitle: kw, seeds: hits)
            .timeout(probeTimeout);
        final maxSort = _maxSortOf(detail);
        if (maxSort != null && maxSort > 0) return maxSort;
      } catch (_) {
        continue; // 换下一个关键词
      }
    }
    return null;
  }

  /// 一部番在当前源站的最大集数
  double? _maxSortOf(SourceBangumi b) {
    double? max;
    void consider(int sort) {
      final v = sort.toDouble();
      if (max == null || v > max!) max = v;
    }

    for (final r in b.roads) {
      for (final e in r.episodes) {
        consider(e.sort);
      }
    }
    for (final e in b.episodes) {
      consider(e.sort);
    }
    return max;
  }

  /// 检索关键词候选：中文名 → 日文名 → 去括号后缀
  ///
  /// 【v2.1.0 · 新番修复】实测新番最容易挂在译名不匹配上：
  /// FQDM 搜「转生就是剑 第二季」0 条、搜「転生したら剣でしたII」命中。
  /// 这里把两种名字都排上队，逐个试。
  static List<String> _keywordCandidates(Subject s) {
    final out = <String>[];
    void add(String? v) {
      final t = (v ?? '').trim();
      if (t.isNotEmpty && !out.contains(t)) out.add(t);
    }

    add(s.displayName);
    add(s.nameCn);
    add(s.name);

    // 去括号： 「葬送的芙莉莲（第二季）」→「葬送的芙莉莲」
    for (final t in out.toList()) {
      final stripped = _stripBracket(t);
      if (stripped.isNotEmpty && stripped != t) add(stripped);
    }
    return out;
  }

  /// 去掉标题里的括号后缀与常见杂质
  static String _stripBracket(String t) {
    var s = t.replaceAll(RegExp(r'[（(\[【][^）)\]】]*[）)\]】]'), '');
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return s;
  }

  static String _fmtSort(double v) =>
      v == v.roundToDouble() ? '${v.toInt()}' : v.toString();
}
