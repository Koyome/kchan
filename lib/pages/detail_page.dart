/// 番剧详情页：Bangumi 元数据 + 分集 + 播放源聚合
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../api/bangumi_api.dart';
import '../api/diag_log.dart' show kLog;
import '../api/episode_union.dart';
import '../api/follow_updates.dart';
import '../api/kazumi_rules.dart' show RuleRegistry;
import '../api/source_groups.dart';
import '../api/source_health.dart';
import '../api/video_sources.dart';
import '../models.dart';
import '../store/local_store.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'player_page.dart';

class DetailPage extends StatefulWidget {
  final int subjectId;
  final Subject? initial;

  /// 【E2E 自动化】源聚合完成后自动播放第一集（测试脚本用）
  final bool autoPlay;
  const DetailPage({super.key, required this.subjectId, this.initial, this.autoPlay = false});

  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> with WidgetsBindingObserver {
  SubjectDetail? _detail;
  List<Episode> _episodes = [];
  List<BgmCharacter> _chars = [];
  List<RelatedSubject> _related = [];

  bool _loading = true;
  String? _error;

  // 播放源聚合
  final Map<String, AggregatedSource> _sources = {};
  bool _sourceLoading = false;
  bool _sourceTried = false;

  /// 用户选中的播放源（线路）。空 = 自动取第一个可用源
  String _selectedSourceId = '';

  /// 当前生效的源：优先用户选择，其次「集数最多」的可用源
  ///
  /// 【v2.1.1】默认源从「第一个可用」改为「集数最多」：
  /// 各源更新速度不一，新番更新时常常只有个别源（如 DM84）有最新一集，
  /// 取第一个可用源会把最新一集藏在卡片后面。集数并列时保持原顺序
  /// （即仍为第一个可用源），不改变无更新时的体感。
  AggregatedSource? get _currentSource {
    final sel = _sources[_selectedSourceId];
    if (sel != null && sel.error == null && sel.bangumi.hasPlayableLine) {
      return sel;
    }
    AggregatedSource? best;
    var bestSort = -1.0;
    for (final a in _sources.values) {
      if (a.error != null || !a.bangumi.hasPlayableLine) continue;
      final sort = _maxEpisodeSort(a.bangumi);
      if (sort > bestSort) {
        best = a;
        bestSort = sort;
      }
    }
    return best;
  }

  /// 一部番（含各线路）的最大集数；无剧集时为 0
  static double _maxEpisodeSort(SourceBangumi b) {
    var max = 0.0;
    for (final r in b.roads) {
      for (final e in r.episodes) {
        if (e.sort > max) max = e.sort.toDouble();
      }
    }
    for (final e in b.episodes) {
      if (e.sort > max) max = e.sort.toDouble();
    }
    return max;
  }

  int _tab = 0; // 0 分集 1 详情/简介 2 角色 3 相关

  /// 上次聚合成功的时间戳（用于「回到详情页时自动检测新一集」）
  DateTime? _sourcesFetchedAt;

  /// 聚合结果保鲜期：超过这个时长再回到详情页就自动重新聚合一次。
  ///
  /// 【v2.1.0】新番周更时，用户经常是「应用一直开着 / 从后台切回来」。
  /// 这时详情页里缓存的剧集列表还停在几小时前，看不到新出的一集。
  /// 设成 10 分钟：既不会在短时间内反复刷（引发用户反馈的「变卡」），
  /// 也能保证切回前台时拿到最新一集的可用资源。
  static const Duration _sourcesTtl = Duration(minutes: 10);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 【v2.1.0】切回前台时自动检测新一集。
  ///
  /// 只在「页面可见 + 数据已过期 + 空闲中」时才重新聚合，
  /// 不阻塞 UI、不叠加并发（刷新中的请求由 `_sourceLoading` 挡住）。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    if (!mounted || _sourceLoading) return;
    final at = _sourcesFetchedAt;
    if (at == null) return;
    if (DateTime.now().difference(at) < _sourcesTtl) return;
    final s = _detail ?? widget.initial;
    if (s == null) return;
    kLog('[详情] 恢复前台：聚合结果已过期（${DateTime.now().difference(at).inMinutes} 分钟）→ 自动刷新线路');
    _loadSources(s);
  }

  Future<void> _load() async {
    kLog('[详情] 开始加载 subject=${widget.subjectId} autoPlay=${widget.autoPlay}');
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // 【v2.1.6 首屏拆分】关键路径只留 subject + episodes：
      //
      // v1.9.1 曾把 4 个请求一起 `Future.wait`——但**等全部完成才渲染**，
      // 「角色 / 相关」这两个没人首屏看的 tab 数据也会拖住首屏最坏 6 秒，
      // 还把 `_loadSources`（播放源聚合，真正决定「能不能看」的）一起拖住。
      // Kazumi 的做法就是角色/相关分 tab 懒加载。
      //
      // 现在：subject + episodes 完成 → 立即渲染并**同时启动源聚合**；
      // 角色/相关转后台，完成后单独 setState 补上（不阻塞任何东西）。
      kLog('[详情] 拉取条目元数据 + 分集（首屏关键路径）…');

      final detailF = BangumiApiHolder.api.subject(widget.subjectId);
      final epsF = BangumiApiHolder.api
          .episodes(widget.subjectId)
          .then((v) => v.toList())
          .catchError((_) => <Episode>[]);

      // 后台补：角色 / 相关（各自失败只留空，不碰首屏）
      unawaited(BangumiApiHolder.api
          .characters(widget.subjectId)
          .then((v) => v.toList())
          .then((chars) {
        if (!mounted) return;
        setState(() => _chars = chars);
      }).catchError((_) {}));
      unawaited(BangumiApiHolder.api
          .relations(widget.subjectId)
          .then((v) => v.toList())
          .then((rel) {
        if (!mounted) return;
        setState(() => _related = rel);
      }).catchError((_) {}));
      // 【v2.1.10 · 逐项等待 + 分段日志】
      // 原来用 `Future.wait([detailF, epsF])`：任一项抛错就整体失败，
      // 而且外层 catch 不打日志 → 详情页会「静默卡死」，无法定位。
      // 现在分开等、各带日志，谁出问题一眼可见。
      final SubjectDetail detail;
      List<Episode> eps;
      try {
        detail = await detailF;
        kLog('[详情] ① 条目元数据到位: ${detail.displayName}');
      } catch (e, st) {
        kLog('[详情] ① 条目元数据失败: $e\n$st');
        rethrow;
      }
      try {
        eps = await epsF;
        kLog('[详情] ② 分集到位: ${eps.length} 集');
      } catch (e, st) {
        // 分集失败不该拖死整页 —— 用空列表兜底，详情仍可浏览
        kLog('[详情] ② 分集失败（用空列表兜底，不阻塞详情）: $e');
        eps = const <Episode>[];
      }
      kLog('[详情] 元数据 OK: ${detail.displayName}（分集 ${eps.length}）');
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _episodes = eps.where((e) => e.type == 0).toList();
        if (_episodes.isEmpty) _episodes = eps;
        _loading = false;
      });
      _loadSources(detail);
    } catch (e) {
      // 【v2.1.10】必须打日志：原来这里只 setState 不打日志，
      // 导致「详情页加载失败」在诊断日志里完全静默 ——
      // 排查时看不到是谁抛的错，只能盲猜。
      kLog('[详情] 加载失败: $e');
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceFirst('ApiException: ', '');
        _loading = false;
      });
      if (widget.initial != null) {
        _loadSources(SubjectDetail(
            id: widget.initial!.id,
            name: widget.initial!.name,
            nameCn: widget.initial!.nameCn));
      }
    }
  }

  /// 聚合各播放源
  ///
  /// 【v1.9.1】从「等全部」改为「来一个显示一个」。
  ///
  /// 【v1.9.3 · 快车道】默认开启的源从 2 条增加到 6 条后，
  /// 若全部一起并发，首屏仍要等**最慢那条**（体检数据里 TvTFun 近 6s）。
  /// 所以按实测耗时排序，先跑最快的 [RuleRegistry.fastLaneCount] 条，
  /// 它们出结果后**立刻渲染**，剩余源在下一帧再补 ——
  /// 用户体感是「点进去就有剧集」，而不是等最慢的源。
  Future<void> _loadSources(Subject subject) async {
    setState(() {
      _sourceLoading = true;
      _sourceTried = true;
    });
    _bangumiLookups = 0; // 每轮聚合重新计数（反查 Bangumi 限 3 次）
    final title = subject.displayName.isNotEmpty ? subject.displayName : subject.name;
    _sourceTitle = title;
    // 【v2.1.0】备用名：Bangumi 的中文名与日文名都记下。
    // 新番最常见「中文名搜不到、日文名能搜到」（或反过来）——
    // 实测 FQDM 搜「转生就是剑 第二季」0 条、搜「転生したら剣でしたII」命中。
    // 主名无结果时单源会自动用备用名重试（见 _runOneSource）。
    final alt = (title == subject.nameCn) ? subject.name : subject.nameCn;
    _sourceAltTitle = alt.trim();

    // 排序：离线分类打底 + **被动健康记录**微调
    //
    // 被动记录的意思是：只在用户真实搜索时记一笔成败，**不发任何额外请求**。
    // 连续失败 2 次的源排到最后（但仍会尝试），成功过的按实测耗时排。
    // 30 分钟自动过期，所以源站恢复后会自动回到前面。
    //
    // 为什么不做启动探测：曾经试过并发探 86 个源，结果启动瞬间抢带宽，
    // 把数据源请求拖成不稳定 —— 用户反馈「所有数据源不可达」。已撤回。
    final sources = SourceRegistry.active.toList()
      ..sort((a, b) {
        final ca = SourceClassifier.classify(a.rule);
        final cb = SourceClassifier.classify(b.rule);
        final la = SourceHealth.sortScore(a.rule.name,
            staticFallback: ca.latencyMs);
        final lb = SourceHealth.sortScore(b.rule.name,
            staticFallback: cb.latencyMs);
        if (la != lb) return la.compareTo(lb);
        return ca.kind.index.compareTo(cb.kind.index);
      });

    final fast = sources.take(RuleRegistry.fastLaneCount).toList();
    final rest = sources.skip(RuleRegistry.fastLaneCount).toList();
    kLog('[聚合] 共 ${sources.length} 条线路：快车道 ${fast.length} 条 '
        '(${fast.map((s) => s.name).join(",")})，补充 '
        '${rest.length} 条 (${rest.map((s) => s.name).join(",")})');

    // 快车道：先跑，出结果立即渲染
    final fastPending = [for (final s in fast) _runOneSource(s, title)];

    // 补充车道：等快车道全部有结论后再发（避免抢带宽把首屏拖慢）
    unawaited(() async {
      await Future.wait(fastPending);
      if (!mounted) return;
      final restPending = [for (final s in rest) _runOneSource(s, title)];
      await Future.wait(restPending);
      if (mounted) setState(() => _sourceLoading = false);
      // 记录聚合完成时间，供「切回前台自动检测新一集」判断新鲜度
      _sourcesFetchedAt = DateTime.now();
      _recordFollowLatest();
    }());

    // 【E2E 自动化】等第一条可用线路出来就自动播放（测试专用）
    if (widget.autoPlay) {
      await Future.wait(fastPending);
      if (!mounted) return;
      var usable = _currentSource;
      if (usable == null || usable.bangumi.episodes.isEmpty) {
        // 快车道没出结果：等补充车道
        await Future.wait([for (final s in rest) _runOneSource(s, title)]);
        if (!mounted) return;
        usable = _currentSource;
      }
      if (usable != null && usable.bangumi.hasPlayableLine) {
        final subject2 = _detail ?? widget.initial;
        kLog('[E2E] 自动播放 ${usable.source.name} 第 1 集');
        await Future<void>.delayed(const Duration(milliseconds: 300));
        if (mounted) {
          final hit = _firstPlayableOf(usable);
          if (hit != null) {
            await _playFromSource(usable, hit.episode, subject2,
                lineIndex: hit.lineIndex);
          }
        }
      } else {
        kLog('[E2E] 无可用源可自动播放');
      }
    }
  }

  /// 当前聚合用的番名（单源刷新时复用）
  String _sourceTitle = '';

  /// 备用番名（日文/中文中的另一个；主名搜不到时兜底用）
  String _sourceAltTitle = '';

  /// 正在单独刷新中的源（卡片上显示转圈）
  final Set<String> _refreshingSources = {};

  /// 单源聚合：搜索 → 分集。
  ///
  /// 【v2.1.0 · 新番修复】两处实测驱动的调整：
  ///   1. 超时 10s → 15s：DM84 这类「慢但没死」的源在新番高峰期
  ///      单请求就要 6~7s，10s 外层超时把它整源误判成「连接失败」；
  ///   2. 主名无命中/异常时，用**备用名**（日文 ↔ 中文）重试一次：
  ///      实测 FQDM 用中文名搜不到「转生就是剑 第二季」，换日文名即命中。
  ///
  /// 超时只对慢源生效；各源并发聚合，快车道的首屏不受影响。
  Future<void> _runOneSource(VideoSource s, String title, {bool isManualRefresh = false}) async {
    if (isManualRefresh) {
      setState(() => _refreshingSources.add(s.id));
    }
    final sw = Stopwatch()..start();
    try {
      final hits = await s.search(title).timeout(const Duration(seconds: 15));
      if (hits.isEmpty) {
        // 主名未收录 → 备用名兜底（只多一次搜索，命中即换备用名展示）
        final alt = _sourceAltTitle;
        if (alt.isNotEmpty && alt != title) {
          final altHits = await s
              .search(alt)
              .timeout(const Duration(seconds: 15))
              .catchError((_) => const <SourceSearchItem>[]);
          if (altHits.isNotEmpty) {
            kLog('[聚合] ${s.name} 主名「$title」未命中，备用名「$alt」命中 ${altHits.length} 条');
            await _fillSource(s, alt, altHits, sw);
            return;
          }
        }
      }
      await _fillSource(s, title, hits, sw);
    } catch (e) {
      // 主名抛错（超时/连接失败）也试一次备用名：有的源只是对某个词不响应
      final alt = _sourceAltTitle;
      if (alt.isNotEmpty && alt != title) {
        try {
          final altHits = await s.search(alt).timeout(const Duration(seconds: 15));
          if (altHits.isNotEmpty) {
            kLog('[聚合] ${s.name} 主名「$title」异常，备用名「$alt」命中 ${altHits.length} 条');
            await _fillSource(s, alt, altHits, sw);
            return;
          }
        } catch (_) {/* 备用名也失败，落回原错误 */}
      }
      // 被动健康：这个源这次真的连不上，记一笔（连续 2 次才降权）
      SourceHealth.reportFailure(s.name);
      _sources[s.id] = AggregatedSource(
          source: s, bangumi: SourceBangumi(title: title), error: '连接失败');
      kLog('[聚合] ${s.name} kw="$title" 失败(${sw.elapsedMilliseconds}ms): '
          '${e.toString().split('\n').first}');
    } finally {
      if (isManualRefresh) _refreshingSources.remove(s.id);
    }
    if (mounted) setState(() {});
  }

  Future<void> _fillSource(VideoSource s, String title, List<SourceSearchItem> hits, Stopwatch sw) async {
    // 被动健康：搜索有命中就说明这个源此刻是通的，记下耗时。
    // （放在方法开头，避免下面候选校验的 return 绕过统计。）
    if (hits.isNotEmpty) {
      SourceHealth.reportSuccess(s.name, sw.elapsedMilliseconds);
    }
    // 【v2.1.3】候选三重校验（目标 = 搜索关键词，即「用户想要的番」）：
    //   ① 季数不符（候选是上一季/基础名条目）→ 拒；
    //   ② 表面重合（归一化相等/包含/Jaccard）→ 过；
    //   ③ 表面不过（典型：站内译名与 Bangumi 不同，如「转生成为魔剑」vs
    //      「转生就是剑」）→ 用 **Bangumi 搜索反查**候选标题：能搜到本番
    //      （前 3 条含 subject id）= 同一部番的另一种译名 → 过；否则拒。
    // 实测：DM84 搜日文返回 28 条垃圾（首选「乙女游戏 第二季」，季数相同
    // 骗过打分）→ 反查指向 264089 ≠ 本番 → 拒；moonci/FQDM 的正确条目
    // 「转生成为魔剑(了)第二季」→ 反查命中 412008 → 保留。
    final ranked = SourceMatch.rank(hits, title);
    if (ranked.isNotEmpty) {
      final best = ranked.first;
      final mismatch = SourceMatch.seasonMismatch(title, best);
      final plausible = mismatch ? false : await _candidatePlausible(title, best);
      if (mismatch || !plausible) {
        _sources[s.id] = AggregatedSource(
            source: s,
            bangumi: SourceBangumi(title: title),
            error: mismatch ? '未收录（仅找到同名旧季）' : '未收录（候选与目标不符）');
        kLog('[聚合] ${s.name} kw="$title" 弃用候选「${best.title}」'
            '（${mismatch ? "季数不符" : "反查非本番"}）${sw.elapsedMilliseconds}ms');
        return;
      }
    }
    if (hits.isEmpty) {
      _sources[s.id] = AggregatedSource(
          source: s, bangumi: SourceBangumi(title: title), error: '未收录');
    } else {
      // 【v2.1.3】用搜索关键词（而非首条命中的标题）做季数校验的目标：
      // 关键词才是「用户想要的番」，命中条目由 SourceMatch.rank 重排后择优
      final b = await s
          .bangumiDetail(fallbackTitle: title, seeds: hits)
          .timeout(const Duration(seconds: 15));
      _sources[s.id] = AggregatedSource(
          source: s, bangumi: b, error: b.episodes.isEmpty ? '未收录可播放剧集' : null);
    }
    kLog('[聚合] ${s.name} kw="$title" ok ${sw.elapsedMilliseconds}ms');
  }

  /// 本页反查 Bangumi 的次数（每次聚合最多 3 次，防止多源垃圾各查一遍）
  int _bangumiLookups = 0;

  /// 候选可信性：先表面重合（免网络），不行就 Bangumi 搜索反查（译名词典）
  Future<bool> _candidatePlausible(String target, SourceSearchItem best) async {
    if (SourceMatch.surfacePlausible(target, best)) return true;
    final s = _detail ?? widget.initial;
    final sid = s?.id ?? 0;
    if (sid <= 0) return false;
    if (++_bangumiLookups > 3) return false;
    try {
      final r = await BangumiApiHolder.api.searchSubjects(best.title, limit: 5)
          .timeout(const Duration(seconds: 10));
      final hit = r.items.take(3).any((x) => x.id == sid);
      if (hit) {
        kLog('[聚合] 候选「${best.title}」反查 Bangumi 命中本番（id=$sid），判定为同番异译名');
      }
      return hit;
    } catch (_) {
      return false; // 反查失败按不可信处理（宁缺勿滥）
    }
  }

  /// 聚合出结果后，把「扫到的最新集数」回写给追番检测。
  ///
  /// 不回写会误报：用户在详情页刷新看到第 25 集，后台快照还停在 24，
  /// 下一轮定时扫描拿 25 比 24，又亮一次红点——可用户早看过了。
  /// 回写后基线跟着走，红点只在**真的**出新集时才亮。
  ///
  /// 【v2.1.1】取**所有源**的最大集数，而不是只看当前生效源：
  /// 新番更新时常常只有个别源（如 DM84）有最新一集，只看当前源
  /// 会把基线记低，下一轮后台扫描又会误报一次红点。
  void _recordFollowLatest() {
    var max = 0.0;
    var maxSource = '';
    for (final a in _sources.values) {
      if (a.error != null || !a.bangumi.hasPlayableLine) continue;
      final v = _maxEpisodeSort(a.bangumi);
      if (v > max) {
        max = v;
        maxSource = a.source.name;
      }
    }
    // 【v2.1.3】并集选集的体检日志：一眼看出「有几集可播、每集来自谁」，
    // 排查「源更新了但点不了」时直接看这行。
    try {
      final grid = _buildEpisodeGrid();
      final playable = grid.where((g) => g.choices.isNotEmpty).length;
      final bySource = <String, int>{};
      for (final g in grid) {
        final b = g.best;
        if (b == null) continue;
        bySource[b.tag.source.name] = (bySource[b.tag.source.name] ?? 0) + 1;
      }
      kLog('[选集] 并集共 ${grid.length} 格：可播 $playable 格'
          '${grid.length > playable ? "（${grid.length - playable} 格所有源都没有）" : ""}'
          '，最优来源分布 $bySource');
    } catch (e) {
      kLog('[选集] 并集统计失败：$e');
    }
    if (max <= 0) return;
    final s = _detail ?? widget.initial;
    if (s == null) return;
    FollowUpdateService.instance.recordLatest(s.id, max, sourceName: maxSource);
  }

  /// 手动刷新单条线路（卡片上的刷新按钮）
  Future<void> _refreshSource(AggregatedSource agg) async {
    if (_refreshingSources.contains(agg.source.id)) return;
    final title = _sourceTitle.isNotEmpty
        ? _sourceTitle
        : ((_detail ?? widget.initial)?.displayName ?? '');
    if (title.isEmpty) return;
    await _runOneSource(agg.source, title, isManualRefresh: true);
  }

  /// 手动刷新全部线路（分区标题栏的刷新按钮）
  Future<void> _refreshAllSources() async {
    if (_sourceLoading) return;
    final title = _sourceTitle.isNotEmpty
        ? _sourceTitle
        : ((_detail ?? widget.initial)?.displayName ?? '');
    if (title.isEmpty) return;
    setState(() => _sourceLoading = true);
    await Future.wait([
      for (final s in SourceRegistry.active) _runOneSource(s, title, isManualRefresh: true),
    ]);
    if (mounted) setState(() => _sourceLoading = false);
  }

  static String _stripBracket(String t) => t.replaceAll(RegExp(r'\s*\[[^\]]*\]\s*$'), '').trim();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _loading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : CustomScrollView(
              slivers: [
                _header(),
                if (_error != null) SliverToBoxAdapter(child: ErrorBar(message: _error!, onRetry: _load)),
                SliverToBoxAdapter(child: _tabBar()),
                if (_tab == 0) ..._episodeSlivers(),
                if (_tab == 1) SliverToBoxAdapter(child: _infoTab()),
                if (_tab == 2) SliverToBoxAdapter(child: _charTab()),
                if (_tab == 3) SliverToBoxAdapter(child: _relatedTab()),
                const SliverToBoxAdapter(child: SizedBox(height: 40)),
              ],
            ),
    );
  }

  // ---- 顶部 ----
  Widget _header() {
    final s = _detail ?? widget.initial;
    if (s == null) return const SliverToBoxAdapter(child: SizedBox.shrink());
    final cs = Theme.of(context).colorScheme;
    final cover = s.images.cover;
    return SliverAppBar(
      expandedHeight: 232,
      pinned: true,
      backgroundColor: cs.surface,
      flexibleSpace: FlexibleSpaceBar(
        collapseMode: CollapseMode.parallax,
        background: Stack(
          fit: StackFit.expand,
          children: [
            if (cover.isNotEmpty)
              Image(
                  // 【v1.6.0 移动端】头图按屏幕实际像素解码：手机上原来一律 800px 宽
                  // 解码，低性能机首屏要多吃几 MB 内存、滚动掉帧。
                  image: ResizeImage(
                    NetworkImage(ImageProxy.candidates(cover, subjectId: s.id).first),
                    width: (MediaQuery.sizeOf(context).width *
                            MediaQuery.of(context).devicePixelRatio)
                        .clamp(240.0, 720.0)
                        .round(),
                  ),
                  fit: BoxFit.cover,
                  filterQuality: FilterQuality.medium,
                  errorBuilder: (_, __, ___) => const SizedBox.shrink()),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [cs.surface.withValues(alpha: .35), cs.surface.withValues(alpha: .92), cs.surface],
                  stops: const [0, .72, 1],
                ),
              ),
            ),
            Positioned(
              left: 16,
              right: 16,
              bottom: 14,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  KCover(url: cover, width: 84, height: 118, radius: 9, subjectId: s.id),
                  const SizedBox(width: 13),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(s.displayName, maxLines: 2, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontSize: 17.5)),
                        if (s.name.isNotEmpty && s.displayName != s.name)
                          Padding(
                            padding: const EdgeInsets.only(top: 3),
                            child: Text(s.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.labelSmall?.copyWith(fontSize: 10.5, letterSpacing: .2)),
                          ),
                        const SizedBox(height: 7),
                        Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            if (s.score > 0) ScoreBadge(score: s.score),
                            if (s.airDate.isNotEmpty) Text(s.airDate, style: Theme.of(context).textTheme.labelSmall?.copyWith(fontSize: 10.5)),
                            if (s.totalEpisodes > 0 || s.eps > 0)
                              Text('全 ${s.totalEpisodes > 0 ? s.totalEpisodes : s.eps} 话',
                                  style: Theme.of(context).textTheme.labelSmall?.copyWith(fontSize: 10.5)),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tabBar() {
    const tabs = ['剧集', '详情', '角色', '相关'];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
      child: SizedBox(
        height: 38,
        child: Row(
          children: [
            for (int i = 0; i < tabs.length; i++)
              Padding(
                padding: const EdgeInsets.only(right: 20),
                child: GestureDetector(
                  onTap: () => setState(() => _tab = i),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Text(
                        tabs[i],
                        style: TextStyle(
                          fontFamily: K.monoFamily, fontFamilyFallback: K.monoFallback,
                          fontSize: 13,
                          letterSpacing: 1,
                          fontWeight: _tab == i ? FontWeight.w700 : FontWeight.w400,
                          color: _tab == i ? K.accent : Theme.of(context).colorScheme.onSurface.withValues(alpha: .55),
                        ),
                      ),
                      const SizedBox(height: 5),
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 160),
                        height: 2,
                        width: _tab == i ? 22 : 0,
                        color: K.accent,
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ---- 剧集 tab ----
  List<Widget> _episodeSlivers() {
    return [
      SliverToBoxAdapter(child: _favBar()),
      SliverToBoxAdapter(child: _sourceSection()),
      _episodeGrid(),
    ];
  }

  Widget _favBar() {
    final s = _detail ?? widget.initial;
    if (s == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('追番状态', style: Theme.of(context).textTheme.labelSmall?.copyWith(fontSize: 10.5, letterSpacing: 1.2)),
          const SizedBox(height: 8),
          FavStatusBar(subject: s),
        ],
      ),
    );
  }

  /// 「播放资源」区：一个「开始观看」主按钮 + 各源卡片。
  ///
  /// 【v1.9.2 · 对齐 Kazumi 的「开始观看 → 播放来源」流程】
  /// Kazumi 是：详情页点「开始观看」→ 弹出来源面板（列出每个源 + 它的搜索结果）
  /// → 点某条结果 → 进入播放页，播放页顶部显示番剧名，下面可选「播放线路1/2…」。
  ///
  /// 这里把同样的流程做出来，但**保留 K酱 原有的并发预取优势**：
  /// 各源在你还在看详情页时就已经搜好了（`_sources` 缓存），
  /// 所以「开始观看」面板是**打开即出结果**，不像 Kazumi 还要现场检索。
  Widget _sourceSection() {
    final cs = Theme.of(context).colorScheme;
    final playable = _playableSources;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: Row(
            children: [
              Expanded(child: K.sectionLabel('播放资源', cs.onSurface)),
              // 手动刷新全部线路（对齐 Kazumi 顶栏刷新的体验）
              IconButton(
                onPressed: _sourceLoading ? null : _refreshAllSources,
                icon: _sourceLoading
                    ? const SizedBox(
                        width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.6))
                    : const Icon(Icons.refresh, size: 17),
                tooltip: '刷新全部线路',
                visualDensity: VisualDensity.compact,
                color: cs.onSurface.withValues(alpha: .65),
              ),
            ],
          ),
        ),
        if (_sources.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Column(
              children: [
                for (final agg in _sources.values) _sourceCard(agg),
              ],
            ),
          ),
        if (_sourceLoading)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Row(
              children: [
                SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.6)),
                SizedBox(width: 10),
                Text('正在聚合播放源…', style: TextStyle(fontSize: 12.5)),
              ],
            ),
          )
        else if (_sources.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              _sourceTried ? '暂无可用播放源' : '等待加载',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        // ── 开始观看 / 播放来源 主按钮 ──
        if (playable.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 2),
            child: Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () => _startWatching(playable.first),
                    icon: const Icon(Icons.play_arrow_rounded, size: 20),
                    label: Text(
                      _episodes.isEmpty ? '开始观看' : '开始观看 · 第 ${_episodes.first.sortLabel} 集',
                      style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
                    ),
                    style: FilledButton.styleFrom(
                      backgroundColor: K.accent,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(K.radiusSm)),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: () => _showPlaySourcesSheet(),
                  icon: const Icon(Icons.list_alt_rounded, size: 18),
                  label: Text('播放来源 (${playable.length})',
                      style: const TextStyle(fontSize: 12.5)),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(K.radiusSm)),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  /// 可播放的源（有线路且有剧集）
  List<AggregatedSource> get _playableSources {
    final list = _sources.values
        .where((a) => a.error == null && a.bangumi.hasPlayableLine)
        .toList();
    // 用户选中的源排最前，方便「开始观看」直接用它的默认剧集
    final sel = _selectedSourceId;
    if (sel.isNotEmpty) {
      list.sort((a, b) {
        if (a.source.id == sel) return -1;
        if (b.source.id == sel) return 1;
        return 0;
      });
    }
    return list;
  }

  /// 「开始观看」：用当前选中源（或第一条可用源）的第一集起播
  Future<void> _startWatching(AggregatedSource agg) async {
    final s = _detail ?? widget.initial;
    final hit = _firstPlayableOf(agg);
    if (hit == null) {
      _showPlaySourcesSheet();
      return;
    }
    // 优先用 Bangumi 的集号/集名（收藏与进度记录以 Bangumi 为准）
    Episode? bgm;
    for (final e in _episodes) {
      if (e.sort == hit.episode.sort) {
        bgm = e;
        break;
      }
    }
    await _playFromSource(agg, hit.episode, s,
        bgmEpisode: bgm, lineIndex: hit.lineIndex);
  }

  /// 某个源的第一条可播线路的第一集
  static ({SourceEpisode episode, int lineIndex})? _firstPlayableOf(
      AggregatedSource agg) {
    final roads = agg.bangumi.roads.where((r) => r.episodes.isNotEmpty).toList();
    if (roads.isNotEmpty) {
      return (episode: roads.first.episodes.first, lineIndex: 0);
    }
    if (agg.bangumi.episodes.isNotEmpty) {
      return (episode: agg.bangumi.episodes.first, lineIndex: 0);
    }
    return null;
  }

  /// 每个源的线路数
  static int _lineCountOf(AggregatedSource agg) =>
      agg.bangumi.roads.where((r) => r.episodes.isNotEmpty).length;

  /// 【对齐 Kazumi `_SourceSheetView`】播放来源面板。
  ///
  /// 结构：顶部「播放来源」标题 + 概况；下面每个源一组
  /// （源名 + 状态 + 展开箭头），展开后列出该源的搜索结果（番剧条目），
  /// 点条目即进入播放页。默认展开第一个有结果的源。
  void _showPlaySourcesSheet() {
    final groups = _sources.values.toList();
    if (groups.isEmpty) return;
    final firstOk =
        groups.where((g) => g.error == null && g.bangumi.hasPlayableLine).toList();
    final autoExpand = firstOk.isNotEmpty ? firstOk.first.source.id : null;

    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      isScrollControlled: true,
      showDragHandle: true,
      constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.82),
      builder: (ctx) => _PlaySourcesSheet(
        subject: _detail ?? widget.initial,
        groups: groups,
        autoExpandId: autoExpand,
        lineCountOf: _lineCountOf,
        onPick: (agg, hit) {
          Navigator.pop(ctx);
          _startFromPick(agg, hit);
        },
        onRetry: (agg) {
          Navigator.pop(ctx);
          _refreshSource(agg);
        },
      ),
    );
  }

  Future<void> _startFromPick(
      AggregatedSource agg, ({SourceEpisode episode, int lineIndex}) hit) async {
    final s = _detail ?? widget.initial;
    Episode? bgm;
    for (final e in _episodes) {
      if (e.sort == hit.episode.sort) {
        bgm = e;
        break;
      }
    }
    await _playFromSource(agg, hit.episode, s,
        bgmEpisode: bgm, lineIndex: hit.lineIndex);
  }

  Widget _sourceCard(AggregatedSource agg) {
    final cs = Theme.of(context).colorScheme;
    final ok = agg.error == null && agg.bangumi.hasPlayableLine;
    final selected = ok && _currentSource?.source.id == agg.source.id;
    final lines = _lineCountOf(agg);
    final eps = agg.bangumi.episodes.length;
    return GestureDetector(
      // 可用源点击即选中为「当前线路」，剧集列表跟随切换；
      // 不可用源点击 = 手动刷新（很多「不可用」是站点抽风，刷新即恢复）
      onTap: ok
          ? () => setState(() => _selectedSourceId = agg.source.id)
          : () => _refreshSource(agg),
      child: Container(
        margin: const EdgeInsets.only(bottom: 9),
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
        decoration: BoxDecoration(
          border: Border.all(
              color: selected
                  ? K.accent
                  : (ok ? K.accent.withValues(alpha: .3) : cs.outlineVariant),
              width: selected ? 1.4 : .9),
          borderRadius: BorderRadius.circular(K.radiusSm),
          color: selected ? K.accent.withValues(alpha: .08) : (ok ? K.accent.withValues(alpha: .04) : null),
        ),
        child: Row(
          children: [
            Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
              size: 16,
              color: selected ? K.accent : (ok ? cs.onSurface.withValues(alpha: .4) : cs.outline),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(agg.source.name,
                            style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                      ),
                      if (selected) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                          decoration: BoxDecoration(
                            color: K.accent,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text('当前线路',
                              style: TextStyle(fontSize: 9, color: Colors.white, height: 1.3)),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    ok
                        ? '${lines > 1 ? "$lines 条播放线路 · " : ""}收录 $eps 集 · ${agg.bangumi.title}'
                        : (agg.error ?? ''),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 11.5),
                  ),
                ],
              ),
            ),
            // 【v1.5.0】单线路手动刷新：初始「不可用」的线路很多是站点抽风，
            // 点一下即可恢复（Kazumi 同款体验）；可用线路也可刷新取最新分集。
            if (_refreshingSources.contains(agg.source.id))
              const SizedBox(
                width: 22,
                height: 22,
                child: Padding(
                  padding: EdgeInsets.all(3),
                  child: CircularProgressIndicator(strokeWidth: 1.6),
                ),
              )
            else
              IconButton(
                onPressed: () => _refreshSource(agg),
                icon: const Icon(Icons.refresh, size: 16),
                tooltip: '刷新该线路',
                visualDensity: VisualDensity.compact,
                color: cs.onSurface.withValues(alpha: .55),
              ),
            if (ok)
              Text('共 ${agg.bangumi.episodes.length} 集', style: Theme.of(context).textTheme.labelSmall?.copyWith(fontSize: 10.5))
            else
              Text('不可用', style: Theme.of(context).textTheme.labelSmall?.copyWith(fontSize: 10.5)),
          ],
        ),
      ),
    );
  }

  Widget _episodeGrid() {
    // 【v2.1.3 · 对齐 Kazumi 的「源原生分集」模型】
    //
    // 旧实现：格子只渲染 Bangumi 分集，再拿「当前选中的源」去逐集匹配 ——
    // 源没收到第 3 集时第 3 格就是「?」，用户以为软件没更新（实测 FQDM 等）。
    // Kazumi 的做法是：分集列表 = 源自己的列表，源有几集就显示几集、全部可点，
    // 用户不用理解「源」是什么。
    //
    // 现在把两者合起来：
    //   格子 = Bangumi 分集 ∪ 各源实际收录的集（并集）；
    //   每格只要能**从任意一条源**找到该集 → 可点，点击时自动挑最优源；
    //   全部源都没有 → 才显示「?」。
    final grid = _buildEpisodeGrid();
    if (grid.isEmpty) {
      return const SliverToBoxAdapter(
        child: EmptyHint(
            icon: Icons.playlist_remove,
            title: '暂无剧集信息',
            sub: 'Bangumi 与播放源都未提供分集'),
      );
    }

    final s = _detail ?? widget.initial;
    final multiSource =
        grid.any((g) => g.choices.length > 1) || _sources.length > 1;

    return SliverToBoxAdapter(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                  child: K.sectionLabel(
                      '剧集列表', Theme.of(context).colorScheme.onSurface)),
              if (multiSource)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Text(
                    '共 ${grid.length} 集 · 自动选源',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        fontSize: 10.5,
                        color: K.accent.withValues(alpha: .85)),
                  ),
                ),
            ],
          ),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 16),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 78,
              childAspectRatio: 2.2,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
            ),
            itemCount: grid.length,
            itemBuilder: (_, i) {
              final g = grid[i];
              final watched =
                  s != null && Store.progress.isWatched(s.id, g.label);
              return AnimatedBuilder(
                animation: Store.progress,
                builder: (context, _) => _epTile(g, watched, s),
              );
            },
          ),
        ],
      ),
    );
  }

  /// 判断一个聚合源是否可用于选集/播放
  static bool _usable(AggregatedSource a) =>
      a.error == null && a.bangumi.hasPlayableLine;

  /// 构建「并集」分集格子（Bangumi 集 ∪ 源集）
  ///
  /// 算法本体在 `lib/api/episode_union.dart`（纯 Dart）：
  /// 详情页与 `tool/verify_new_episode.dart` 共用同一份实现，
  /// 验证工具跑的就是本页正在跑的代码。
  List<UnionTile<AggregatedSource>> _buildEpisodeGrid() {
    final sources = <(UnionSource, AggregatedSource)>[];
    for (final agg in _sources.values) {
      if (!_usable(agg)) continue;
      sources.add((
        UnionSource(
          id: agg.source.id,
          name: agg.source.name,
          directPlay: agg.source.rule.isDirectPlay,
          latencyMs: SourceClassifier.classify(agg.source.rule).latencyMs,
          roads: [
            for (final r in agg.bangumi.roads)
              if (r.episodes.isNotEmpty) r.episodes,
          ],
          episodes: agg.bangumi.episodes,
        ),
        agg,
      ));
    }
    return buildEpisodeUnion<AggregatedSource>(
      bgmEpisodes: _episodes,
      sources: sources,
      hints: UnionRankHints(
        selectedSourceId: _selectedSourceId,
        currentSourceId: _currentSource?.source.id ?? '',
      ),
    );
  }

  /// 找「当前集之后/之前可播的下一集（可跨源）」——播放页自动连播用。
  ///
  /// 返回可以直接开播的目标；没有任何源有下一集时返回 null。
  ({AggregatedSource agg, SourceEpisode ep, int lineIndex, Episode? bgm})?
      _resolveAdjacentEpisode(double fromSort, int delta) {
    final grid = _buildEpisodeGrid();
    final target = fromSort.round();
    var idx = grid.indexWhere((g) => g.key == target);
    if (idx < 0) {
      // 当前源用了全局集号（如第二季从第 13 集起）：按绝对话数定位
      idx = grid.indexWhere((g) =>
          g.bgm?.ep == target ||
          g.choices.any((c) => c.ep.sort == target));
    }
    if (idx < 0) return null;
    final next = idx + delta;
    if (next < 0 || next >= grid.length) return null;
    final g = grid[next];
    final pick = g.best;
    if (pick == null) return null;
    return (agg: pick.tag, ep: pick.ep, lineIndex: pick.lineIndex, bgm: g.bgm);
  }

  /// 在选中源的**任意线路**里找这一集；返回剧集 + 线路序号。
  ///
  /// 相比旧版只扫合并列表，这里会优先返回「线路序号」，让播放页能直接
  /// 落到正确的播放线路上（而不是永远从线路1 开始）。
  ///
  /// 【v2.1.3】改用「并集格子」，本方法不再被格子调用（并集候选已在
  /// 构建时算好每集的候选源），保留给播放页换源等其它调用点。

  Widget _epTile(UnionTile<AggregatedSource> g, bool watched, Subject? s) {
    final cs = Theme.of(context).colorScheme;
    final pick = g.best;
    final cur = _currentSource;
    final label = g.labelText;
    // 两个「不打扰」的信息：
    //  · 这集由别的源提供（不是当前源）→ 小字标出来源，用户不用疑惑为什么能点；
    //  · 都拿不到 → 右下角「?」，点了给出解释。
    final autoFrom =
        (pick != null && cur != null && pick.tag.source.id != cur.source.id)
            ? pick.tag.source.name
            : '';
    final sub = autoFrom.isNotEmpty
        ? '来自 $autoFrom'
        : (pick?.ep.title.trim() ?? '');
    return GestureDetector(
      onTap: () {
        if (pick != null) {
          _playFromSource(pick.tag, pick.ep, s,
              bgmEpisode: g.bgm, lineIndex: pick.lineIndex);
        } else {
          _showNoSourceDialog(g);
        }
      },
      child: Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: watched ? K.accent.withValues(alpha: .1) : Colors.transparent,
          border: Border.all(color: watched ? K.accent.withValues(alpha: .45) : cs.outlineVariant, width: .9),
          borderRadius: BorderRadius.circular(K.radiusSm),
        ),
        child: Stack(
          children: [
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontFamily: K.monoFamily, fontFamilyFallback: K.monoFallback,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: watched ? K.accent : cs.onSurface,
                    ),
                  ),
                  // 源站自己的集名（很多番和 Bangumi 的集号对不上，显示出来才不会点错）；
                  // 这集来自其他源时换成「来自 X」——比集名更重要的信息
                  if (sub.isNotEmpty && sub != label)
                    Padding(
                      padding: const EdgeInsets.only(top: 1, left: 3, right: 3),
                      child: Text(
                        sub,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 8.5,
                            height: 1.1,
                            color: autoFrom.isNotEmpty
                                ? K.accent.withValues(alpha: .8)
                                : cs.onSurface.withValues(alpha: .5)),
                      ),
                    ),
                ],
              ),
            ),
            if (watched)
              const Positioned(
                right: 4,
                top: 4,
                child: Icon(Icons.check_circle, size: 11, color: K.accent),
              ),
            // 所有源都没有这一集 → 明确标出来，而不是点了才弹窗
            if (pick == null)
              Positioned(
                right: 4,
                bottom: 3,
                child: Icon(Icons.help_outline, size: 10, color: cs.outline),
              ),
          ],
        ),
      ),
    );
  }

  void _showNoSourceDialog(UnionTile<AggregatedSource> g) {
    final ep = g.bgm;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('第 ${g.labelText} 集'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text((ep?.displayName.isNotEmpty ?? false) ? ep!.displayName : g.title,
                style: const TextStyle(fontSize: 14)),
            if ((ep?.airdate ?? '').isNotEmpty) ...[
              const SizedBox(height: 6),
              Text('放送日期：${ep!.airdate}', style: Theme.of(ctx).textTheme.bodySmall),
            ],
            const SizedBox(height: 12),
            Text('所有已启用的播放源都还没有这一集。新番刚更新后源站可能延迟收录，'
                '稍等片刻再进入本页即会重新检测；也可到「设置 → 播放源」启用更多源。',
                style: Theme.of(ctx).textTheme.bodySmall?.copyWith(height: 1.6)),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
          if (ep != null)
            FilledButton(
              onPressed: () {
                Navigator.pop(ctx);
                if (_detail != null) Store.progress.markWatched(_detail!, ep.sort, epId: ep.id);
              },
              child: const Text('标记已看'),
            ),
        ],
      ),
    );
  }

  /// 播放某一集的某个源。
  ///
  /// 【v1.9.2 · 对齐 Kazumi 的线路模型】
  /// 传入 [lineIndex] 指定「进入哪一个播放线路」（0 = 线路1）。
  /// 旧实现只把 `bangumi.episodes`（各线路合并去重后的总列表）交给播放页，
  /// 于是播放页里根本没有「播放线路1 / 线路2」可选 —— 而站点其实提供了多条。
  /// 现在把该源**每条线路各自的剧集**一起传过去，播放页据此做线路切换。
  Future<void> _playFromSource(
    AggregatedSource agg,
    SourceEpisode se,
    Subject? s, {
    Episode? bgmEpisode,
    int lineIndex = 0,
  }) async {
    final route = _playerRoute(agg, se, s,
        bgmEpisode: bgmEpisode, lineIndex: lineIndex);
    if (route == null) return;
    await Navigator.of(context).push(route);
  }

  /// 【v2.1.3】播放页的跨源续播回调（见 [PlayerPage.crossEpisode]）。
  ///
  /// 当前源没有「下一集」时，从**所有源**里找紧邻的一集，用 pushReplacement
  /// 直接换一个新的播放页（承载新源的线路/备选数据），用户看到的是「播完了
  /// 自动接着播下一集」，不需要知道背后换了源。
  Future<bool> _crossEpisodeJump(double fromSort, int delta) async {
    if (!mounted) return false;
    final t = _resolveAdjacentEpisode(fromSort, delta);
    if (t == null) return false;
    final route = _playerRoute(t.agg, t.ep, _detail ?? widget.initial,
        bgmEpisode: t.bgm, lineIndex: t.lineIndex);
    if (route == null) return false;
    kLog('[选集] 跨源续播 → ${t.agg.source.name} 第 ${t.ep.sort} 集'
        '（本集来自第 $fromSort 集之后）');
    Navigator.of(context).pushReplacement(route);
    return true;
  }

  /// 构造播放页路由（含换源备选与线路数据）
  MaterialPageRoute<void>? _playerRoute(
    AggregatedSource agg,
    SourceEpisode se,
    Subject? s, {
    Episode? bgmEpisode,
    int lineIndex = 0,
  }) {
    final subject = s ?? widget.initial;
    if (subject == null) return null;
    final ep = bgmEpisode;

    // 构造「换线路」候选：同一集在其他可用源上的地址
    // 【Kazumi 对齐】直链源排最前：Windows 上 jx 源无法内置解析，
    // 自动切换时应优先落到能直接播的源。
    final others = _sources.values
        .where((o) =>
            o.source.id != agg.source.id &&
            o.error == null &&
            o.bangumi.hasPlayableLine)
        .toList();
    others.sort((a, b) {
      final ad = a.source.rule.isDirectPlay ? 0 : 1;
      final bd = b.source.rule.isDirectPlay ? 0 : 1;
      return ad.compareTo(bd);
    });
    final alts = <PlayerAlternative>[];
    for (final other in others) {
      final hit =
          _matchInAnyLine(other, se.sort.toDouble(), absolute: ep?.ep);
      if (hit == null) continue;
      alts.add(PlayerAlternative(
        sourceName: other.source.name,
        rule: other.source.rule,
        pageUrl: hit.episode.pageUrl,
        episodeTitle: hit.episode.title,
        episodeSort: hit.episode.sort.toDouble(),
        lineIndex: hit.lineIndex,
      ));
    }

    return MaterialPageRoute(
      builder: (_) => PlayerPage(
        subject: subject,
        rule: agg.source.rule,
        pageUrl: se.pageUrl,
        episodeTitle: se.title,
        episodeSort: se.sort.toDouble(),
        episodeId: ep?.id ?? 0,
        episodeDesc: ep?.displayName ?? '',
        startLineIndex: lineIndex,
        alternatives: alts,
        lines: _playerLinesOf(agg),
        crossEpisode: _crossEpisodeJump,
      ),
    );
  }

  /// 把某个聚合源的线路转成播放页用的模型
  static List<PlayerLine> _playerLinesOf(AggregatedSource agg) {
    final roads = agg.bangumi.roads.where((r) => r.episodes.isNotEmpty).toList();
    if (roads.isEmpty) {
      if (agg.bangumi.episodes.isEmpty) return const [];
      return [
        PlayerLine(
          name: '播放线路1',
          episodes: [
            for (final e in agg.bangumi.episodes)
              PlayerEpisodeOption(sort: e.sort, title: e.title, pageUrl: e.pageUrl),
          ],
        )
      ];
    }
    return [
      for (var i = 0; i < roads.length; i++)
        PlayerLine(
          name: roads[i].name.trim().isEmpty
              ? '播放线路${i + 1}'
              : roads[i].name,
          episodes: [
            for (final e in roads[i].episodes)
              PlayerEpisodeOption(sort: e.sort, title: e.title, pageUrl: e.pageUrl),
          ],
        ),
    ];
  }

  /// 在某个源的**任意线路**里找指定集数（换源时用；顺带记住是第几条线路）
  ///
  /// 【v2.1.2】支持多候选集号：先按 Bangumi 的 `sort`（本季内编号）匹配，
  /// 再按 `ep`（绝对话数）兜底 —— 有些源用全局编号（第二季从第 13 集起），
  /// 只匹配 sort 会整季对不上。
  static ({SourceEpisode episode, int lineIndex})? _matchInAnyLine(
      AggregatedSource agg, double sort, {int? absolute}) {
    final targets = <int>{sort.round()};
    if (absolute != null && absolute > 0) targets.add(absolute);
    final roads = agg.bangumi.roads.where((r) => r.episodes.isNotEmpty).toList();
    for (final target in targets) {
      if (roads.isNotEmpty) {
        for (var i = 0; i < roads.length; i++) {
          for (final e in roads[i].episodes) {
            if (e.sort == target) return (episode: e, lineIndex: i);
          }
        }
      }
      for (final e in agg.bangumi.episodes) {
        if (e.sort == target) return (episode: e, lineIndex: 0);
      }
    }
    return null;
  }

  // ---- 详情 tab ----
  Widget _infoTab() {
    final d = _detail;
    if (d == null) return const Padding(padding: EdgeInsets.all(16), child: Text('暂无详情'));
    final entries = d.infobox.entries.toList();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (d.summary.isNotEmpty) ...[
            Text('简介', style: Theme.of(context).textTheme.labelSmall?.copyWith(fontSize: 10.5, letterSpacing: 1.2)),
            const SizedBox(height: 8),
            Text(d.summary, style: Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.75)),
            const SizedBox(height: 18),
          ],
          if (d.score > 0) ...[
            _statRow(d),
            const SizedBox(height: 18),
          ],
          Text('详细信息', style: Theme.of(context).textTheme.labelSmall?.copyWith(fontSize: 10.5, letterSpacing: 1.2)),
          const SizedBox(height: 8),
          Container(
            decoration: BoxDecoration(
              border: Border.all(color: Theme.of(context).colorScheme.outlineVariant, width: .8),
              borderRadius: BorderRadius.circular(K.radiusSm),
            ),
            child: Column(
              children: [
                for (int i = 0; i < entries.length; i++) ...[
                  if (i > 0) const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 68,
                          child: Text(entries[i].key, style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 12)),
                        ),
                        Expanded(
                          child: Text(entries[i].value, style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontSize: 12.8, height: 1.5)),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _statRow(SubjectDetail d) {
    final items = [
      ('想看', d.wishCount),
      ('在看', d.doingCount),
      ('看过', d.collectCount),
      ('搁置', d.onHoldCount),
      ('抛弃', d.droppedCount),
    ];
    return Row(
      children: [
        for (final it in items)
          Expanded(
            child: Column(
              children: [
                Text('${it.$2}', style: const TextStyle(fontFamily: K.monoFamily, fontFamilyFallback: K.monoFallback, fontSize: 15, fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(it.$1, style: Theme.of(context).textTheme.labelSmall?.copyWith(fontSize: 10)),
              ],
            ),
          ),
      ],
    );
  }

  // ---- 角色 tab ----
  Widget _charTab() {
    if (_chars.isEmpty) return const EmptyHint(icon: Icons.people_outline, title: '暂无角色数据');
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 168,
          childAspectRatio: 2.35,
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
        ),
        itemCount: _chars.length,
        itemBuilder: (_, i) {
          final c = _chars[i];
          final cs = Theme.of(context).colorScheme;
          return Container(
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              border: Border.all(color: cs.outlineVariant, width: .8),
              borderRadius: BorderRadius.circular(K.radiusSm),
            ),
            child: Row(
              children: [
                KCover(url: c.image, width: 38, height: 56, radius: 6),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5)),
                      const SizedBox(height: 2),
                      Text(c.relation, style: Theme.of(context).textTheme.labelSmall?.copyWith(fontSize: 9.5, color: K.accent.withValues(alpha: .7))),
                      if (c.actors.isNotEmpty)
                        Text('CV ${c.actors.first}',
                            maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.labelSmall?.copyWith(fontSize: 9.5)),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  // ---- 相关 tab ----
  Widget _relatedTab() {
    if (_related.isEmpty) return const EmptyHint(icon: Icons.link_off, title: '暂无关联条目');
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Column(
        children: [
          for (final r in _related)
            GestureDetector(
              onTap: () => Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => DetailPage(subjectId: r.id))),
              child: Container(
                margin: const EdgeInsets.only(bottom: 9),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  border: Border.all(color: Theme.of(context).colorScheme.outlineVariant, width: .8),
                  borderRadius: BorderRadius.circular(K.radiusSm),
                ),
                child: Row(
                  children: [
                    KCover(url: r.image, width: 40, height: 56, radius: 6, subjectId: r.id),
                    const SizedBox(width: 11),
                    Expanded(
                      child: Text(r.displayName, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5)),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                      decoration: BoxDecoration(
                        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant, width: .8),
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: Text(r.relation, style: Theme.of(context).textTheme.labelSmall?.copyWith(fontSize: 10)),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ═══════════════════════ 播放来源面板（对齐 Kazumi `_SourceSheetView`） ═══════════════════════

/// 每个源一组：源名 + 状态 + 展开箭头；展开后列出该源的**播放线路**。
///
/// 为什么默认只展开「第一条可用源」而不是全部展开：
/// 站点搜索会返回一堆同名/相关条目，全展开会让面板长得没法用。
/// Kazumi 的做法就是默认只展示第一条 +「展开全部 N 个结果」，这里沿用，
/// 但把「结果条目」换成了**播放线路**（K酱 的聚合已经替用户选好了条目，
/// 用户真正要选的是线路）。
class _PlaySourcesSheet extends StatefulWidget {  final Subject? subject;
  final List<AggregatedSource> groups;
  final String? autoExpandId;
  final int Function(AggregatedSource) lineCountOf;
  final void Function(AggregatedSource, ({SourceEpisode episode, int lineIndex}))
      onPick;
  final void Function(AggregatedSource) onRetry;

  const _PlaySourcesSheet({
    required this.subject,
    required this.groups,
    required this.autoExpandId,
    required this.lineCountOf,
    required this.onPick,
    required this.onRetry,
  });

  @override
  State<_PlaySourcesSheet> createState() => _PlaySourcesSheetState();
}

class _PlaySourcesSheetState extends State<_PlaySourcesSheet> {
  /// 每个源展开到哪一档：0 = 收起，1 = 只显示第一条线路，2 = 全部线路
  final Map<String, int> _expand = {};
  late final String _title;

  @override
  void initState() {
    super.initState();
    final id = widget.autoExpandId;
    if (id != null) _expand[id] = 1;
    final s = widget.subject;
    _title = s == null
        ? '播放来源'
        : (s.displayName.isNotEmpty ? s.displayName : s.name);
  }

  /// 该源的所有（非空）线路
  List<SourceRoad> _roadsOf(AggregatedSource agg) =>
      agg.bangumi.roads.where((r) => r.episodes.isNotEmpty).toList();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final playable = widget.groups
        .where((g) => g.error == null && g.bangumi.hasPlayableLine)
        .length;
    final totalLines = widget.groups
        .where((g) => g.error == null)
        .fold<int>(0, (a, g) => a + widget.lineCountOf(g));

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleLarge
                      ?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 3),
              Text(
                '$playable 个可用来源 · $totalLines 条播放线路',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: cs.onSurfaceVariant),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Flexible(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 16),
            itemCount: widget.groups.length,
            itemBuilder: (_, i) => _group(widget.groups[i]),
          ),
        ),
      ],
    );
  }

  Widget _group(AggregatedSource agg) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final level = _expand[agg.source.id] ?? 0;
    final collapsed = level == 0;
    final ok = agg.error == null && agg.bangumi.hasPlayableLine;
    final status = ok
        ? '${widget.lineCountOf(agg)} 线路 · ${agg.bangumi.episodes.length} 集'
        : (agg.error ?? '无结果');

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: ok
                ? () =>
                    setState(() => _expand[agg.source.id] = collapsed ? 1 : 0)
                : () => widget.onRetry(agg),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 10, 4, 10),
              child: Row(
                children: [
                  Icon(
                    collapsed
                        ? Icons.keyboard_arrow_right_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    size: 20,
                    color: cs.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(agg.source.name,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: cs.onSurface,
                          fontWeight: FontWeight.w600,
                        )),
                  ),
                  const SizedBox(width: 8),
                  Text(status,
                      style: theme.textTheme.labelMedium?.copyWith(
                          color: ok ? cs.onSurfaceVariant : cs.error)),
                  if (!ok)
                    IconButton(
                      onPressed: () => widget.onRetry(agg),
                      icon: const Icon(Icons.refresh, size: 17),
                      visualDensity: VisualDensity.compact,
                      tooltip: '重新检索',
                    ),
                ],
              ),
            ),
          ),
          if (!collapsed && ok) _body(agg, showAll: level >= 2),
        ],
      ),
    );
  }

  Widget _body(AggregatedSource agg, {required bool showAll}) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final roads = _roadsOf(agg);
    if (roads.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(34, 0, 12, 10),
        child: Text('这个源没有可播放的剧集',
            style:
                theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
      );
    }

    final shown = showAll ? roads : roads.take(1).toList();

    return Padding(
      padding: const EdgeInsets.fromLTRB(34, 0, 2, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < shown.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Material(
                color: cs.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(10),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  // 点某条线路 → 从该线路第 1 集开始播
                  onTap: () => widget.onPick(
                      agg, (episode: shown[i].episodes.first, lineIndex: i)),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                shown[i].name.trim().isEmpty
                                    ? '播放线路${i + 1}'
                                    : shown[i].name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodyLarge
                                    ?.copyWith(fontWeight: FontWeight.w500),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '${shown[i].episodes.length} 集 · 从「${shown[i].episodes.first.title}」开始',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall
                                    ?.copyWith(color: cs.onSurfaceVariant),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 10),
                        Icon(Icons.play_arrow_rounded,
                            color: K.accent, size: 22),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          if (roads.length > 1)
            TextButton(
              onPressed: () =>
                  setState(() => _expand[agg.source.id] = showAll ? 1 : 2),
              child: Text(
                  showAll ? '收起线路' : '展开全部 ${roads.length} 条线路'),
            ),
        ],
      ),
    );
  }
}
