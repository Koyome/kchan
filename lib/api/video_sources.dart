/// 播放源聚合层（Kazumi 规则驱动）
///
/// ## 设计
///
/// 不再是「一个源硬编码一套逻辑」，而是**完全对齐 Kazumi**：
/// 每个源就是一条 [KazumiRule]（JSON + XPath / JSONPath），由统一的
/// [RuleVideoSource] 驱动「搜索 → 详情/分集 → 取直链」三步。
///
/// 好处：
///  1. 想加源只需加一条规则，不用写代码
///  2. 规则格式与 KazumiRules 完全一致，可以直接用官方规则库
///  3. 界面里的源列表就是规则列表，天然支持「多个接口」并存
///
/// ## v1.9.1 性能改造（本次重点）
///
/// 旧版的搜索是**串行试 5 个关键词变体、每个都等超时，再退避重试 4 次
/// （每次 1.2s）**。实测日志里 AGE 一条源就要 7.4～8.2 秒，而且它还是
/// 「详情页首屏」的关键路径 —— 这是「点动漫进入很慢」的主因之一。
///
/// 现在：
///  1. **变体并发竞速**：前 N 个变体同时发（谁先有命中用谁），
///     而不是一个失败再试下一个；
///  2. **变体数量收敛**：默认只试 2 个最可能命中的变体（原名 + 去符号版），
///     其余按需追加 —— 大部分番剧原名就能命中，不必空跑 5 次；
///  3. **超时下调**：单请求 12s → 8s（实测国内源正常 0.3～2s，
///     8s 还没回基本就是站点挂了，早失败早换下一个）；
///  4. **退避重试收敛**：4 次 × 1.2s → 1 次 × 0.6s，且只在「确实一个变体
///     都没发出有效请求」时才做。
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'kazumi_rules.dart';
import 'diag_log.dart' show kLog;
import 'play_resolver.dart' show gateAwareGet, jsGateHook;
import 'source_groups.dart';

/// 【v1.8.0】浏览器渲染钩子：直接复用 JS 闸门那套内核（Windows 无头 Edge CDP /
/// Android 离屏 WebView）。纯 Dart 环境（vfy）为 null，自动退化为直连解析。
Future<String?> Function(String url, {String referer})? get _renderHook => jsGateHook;

/// 统一的搜索命中项
class SourceSearchItem {
  final String title;
  final String url;
  final int? episodeSort;
  final int? categoryId;
  final int? postId;
  const SourceSearchItem({
    required this.title,
    required this.url,
    this.episodeSort,
    this.categoryId,
    this.postId,
  });
}

/// 一个番剧（源站维度）
class SourceBangumi {
  final String title;
  final int? categoryId;
  final List<SourceEpisode> episodes;

  /// 线路（对齐 Kazumi 的多线路概念，界面里可作为「线路切换」）
  final List<SourceRoad> roads;

  const SourceBangumi({
    required this.title,
    this.categoryId,
    this.episodes = const [],
    this.roads = const [],
  });

  /// 至少有一条线路含剧集
  bool get hasPlayableLine =>
      roads.any((r) => r.episodes.isNotEmpty) || episodes.isNotEmpty;
}

/// 一条线路
class SourceRoad {
  final String name;
  final List<SourceEpisode> episodes;
  const SourceRoad({required this.name, this.episodes = const []});
}

/// 一集（源站维度）
class SourceEpisode {
  final String title;
  final int sort;
  final String pageUrl; // 播放页
  const SourceEpisode({required this.title, required this.sort, required this.pageUrl});
}

/// 解析出的可播地址
class PlayInfo {
  final String url;
  final String type; // video/mp4 | application/x-mpegURL
  final Map<String, String> headers;

  /// CDN 中途注入的**独立广告分片块**区间（毫秒）。
  /// 这些块是被两个 #EXT-X-DISCONTINUITY 夹住的独立内容（实测片段时长整齐划一），
  /// 播放时整块跨过即可 —— 不会吃掉正片。
  final List<({int startMs, int endMs})> adRanges;

  const PlayInfo({
    required this.url,
    this.type = 'video/mp4',
    this.headers = const {},
    this.adRanges = const [],
  });

  bool get isHls => type.contains('mpegURL') || url.contains('.m3u8');
}

// ───────────────────────── 抽象接口 ─────────────────────────

abstract class VideoSource {
  String get id;
  String get name;
  String get homepage;

  /// 是否启用（设置里可开关）
  bool get enabled;
  set enabled(bool v);

  /// 底层规则（WebView 解析时需要）
  KazumiRule get rule;

  /// 规则备注（UI 上说明为什么默认关）
  String get note;

  /// 该源是否被本客户端支持（api level 过高 / 缺必备字段时为 false）
  bool get supported;

  /// 第一步：按关键词搜索
  Future<List<SourceSearchItem>> search(String keyword, {int? categoryId});

  /// 第二步：列出整部番的分集
  Future<SourceBangumi> bangumiDetail({
    int? categoryId,
    String? fallbackTitle,
    List<SourceSearchItem> seeds = const [],
  });

  /// 第三步：从播放页解析直链（老接口，保留兼容；实际播放走 PlayResolver）
  Future<PlayInfo?> resolve(String pageUrl);
}

// ───────────────────────── 规则驱动的通用源 ─────────────────────────

const _uaDesktop =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';
const _uaMobile =
    'Mozilla/5.0 (Linux; Android 13; Pixel 6) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36';

/// 单次 HTTP 请求超时。实测国内源正常 0.3～2s；8s 未回视为站点不可用。
const _kRequestTimeout = Duration(seconds: 8);

/// 默认并发竞速的关键词变体个数
const _kVariantRace = 2;

/// 通用源实现：一条 Kazumi 规则 → 一个可以搜索/取分集的源
class RuleVideoSource implements VideoSource {
  @override
  final KazumiRule rule;

  @override
  bool enabled;

  final http.Client _c = http.Client();

  RuleVideoSource(this.rule, {bool? enabled})
      : enabled = enabled ?? RuleRegistry.defaultEnabledNames.contains(rule.name);

  @override
  String get id => rule.name;

  @override
  String get name => rule.name;

  @override
  String get homepage => rule.baseURL;

  @override
  String get note => rule.note;

  @override
  bool get supported =>
      !rule.requiresNewerClient &&
      (rule.searchURL.trim().isNotEmpty ||
          (rule.usesApiSearch && !rule.searchApiConfig.request.isEmpty));

  /// UA：Kazumi 的规则引擎用随机桌面 Chrome UA（getRandomUA），这里对齐桌面 UA。
  String get _ua => rule.userAgent.isNotEmpty ? rule.userAgent : _uaDesktop;

  /// 【对齐 Kazumi】规则请求恒带 `Referer: baseURL/`（Kazumi 引擎对每个
  /// 规则请求都发送 referer，站点常以此做防盗链——缺失时搜索可能被拦成空页）。
  Map<String, String> get _headers => {
        'User-Agent': _ua,
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
        'Referer': rule.referer.isNotEmpty ? rule.referer : '${rule.baseURL}/',
        // 站点 Cookie：过人机验证后把 Cookie 写进规则即可复用会话
        if (rule.cookie.isNotEmpty) 'Cookie': rule.cookie,
      };

  Future<String> _get(String url) async {
    return gateAwareGet(url, (headers) async {
      final res = await _c
          .get(Uri.parse(url), headers: headers)
          .timeout(_kRequestTimeout);
      return _decodeBody(res);
    }, _headers);
  }

  /// 按规则发起 JSON 接口请求（api level 8 的 `searchMode: api`）
  Future<String> _apiRequest(ApiRequestConfig cfg, Map<String, Object?> vars) async {
    final url = renderTemplate(cfg.url.trim(), vars, encode: true);
    final query = <String, String>{};
    cfg.query.forEach((k, v) {
      query[renderTemplate(k, vars)] = renderTemplate('$v', vars);
    });
    var uri = Uri.parse(url);
    if (query.isNotEmpty) {
      uri = uri.replace(queryParameters: {...uri.queryParameters, ...query});
    }

    final headers = <String, String>{
      ..._headers,
      'Accept': 'application/json, text/plain, */*',
      for (final e in cfg.headers.entries)
        e.key.toLowerCase(): renderTemplate('${e.value}', vars),
    };

    final method = cfg.method.toUpperCase();
    http.Response res;
    if (method == 'POST') {
      var body = cfg.body;
      // 只在 body 是字符串时才做模板渲染（结构化 body 原样送）
      if (body is String) body = renderTemplate(body, vars);
      final payload = body == null
          ? ''
          : (body is String ? body : jsonEncode(body));
      if (cfg.bodyType == ApiBodyType.json) {
        headers.putIfAbsent('Content-Type', () => 'application/json');
      } else if (cfg.bodyType == ApiBodyType.form) {
        headers.putIfAbsent(
            'Content-Type', () => 'application/x-www-form-urlencoded');
      }
      res = await _c
          .post(uri, headers: headers, body: payload)
          .timeout(_kRequestTimeout);
    } else {
      res = await _c.get(uri, headers: headers).timeout(_kRequestTimeout);
    }
    return _decodeBody(res);
  }

  static String _decodeBody(http.Response res) {
    final ct = res.headers['content-type'] ?? '';
    if (ct.contains('gbk') || ct.contains('gb2312')) {
      return _decodeGbk(res.bodyBytes);
    }
    return utf8.decode(res.bodyBytes, allowMalformed: true);
  }

  /// 【关键修复 · 解决「未收录」覆盖面最广的一招】
  ///
  /// 站点收录的番名常常与 Bangumi 的中文/日文名**不完全一致**：
  ///   - 特殊符号：Bangumi 是 `CLANNAD 〜AFTER STORY〜`，站点搜不到；
  ///     去掉符号后仍搜不到，但只搜 `CLANNAD` 就有 3 条（实测）；
  ///   - 译名差异：Bangumi `团子大家族` / 站点 `CLANNAD`；
  ///   - 季数后缀：Bangumi 带「第二季」，站点标题不带。
  ///
  /// 返回**按命中概率排序**的变体列表：越靠前越可能是站点实际用的写法。
  List<String> searchVariants(String keyword) {
    final out = <String>[];
    void add(String? s) {
      if (s == null) return;
      final v = s.trim();
      if (v.isEmpty) return;
      if (!out.contains(v)) out.add(v);
    }

    add(keyword);
    // 去符号版：〜～！？·、,:;"'（）()【】[] 以及多余空格
    final cleaned = keyword
        .replaceAll(RegExp(r'''[〜～~!！?？·、,，:：;；"“”'’()（）\[\]【】《》_-]'''), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    add(cleaned);
    // 去季数后缀：xx 第二季 / 第2季 / S2 / 2nd Season
    final noSeason = cleaned
        .replaceAll(RegExp(r'\s*(第\s*\d+\s*[期季部章]|S\d{1,2}|\d+(?:st|nd|rd|th)\s+season)', caseSensitive: false), '')
        .trim();
    add(noSeason);
    // 首段（空格前的主体）：CLANNAD 〜AFTER STORY〜 → CLANNAD
    final firstSeg = cleaned.split(' ').first;
    if (firstSeg.length >= 2 && firstSeg != cleaned) add(firstSeg);
    // 中日文片段：若含日文假名，试日文部分；若含中文，试中文部分
    add(RegExp(r'[\u4e00-\u9fff]{2,}').firstMatch(noSeason)?.group(0));
    add(RegExp(r'[\u3040-\u30ff]{2,}').firstMatch(noSeason)?.group(0));
    return out;
  }

  /// 标题相似度打分（越大越像）：命中数 + 连续包含加权
  static int _score(String query, String title) {
    final q = query.toLowerCase().replaceAll(RegExp(r'\s+'), '');
    final t = title.toLowerCase().replaceAll(RegExp(r'\s+'), '');
    if (q.isEmpty || t.isEmpty) return 0;
    if (t == q) return 100;
    if (t.contains(q)) return 80;
    if (q.contains(t)) return 70;
    var s = 0;
    // 逐 2-gram 覆盖率
    for (var i = 0; i + 2 <= q.length; i++) {
      if (t.contains(q.substring(i, i + 2))) s += 3;
    }
    return s;
  }

  /// 对单个关键词变体做一次搜索。返回命中列表 + 实际使用的变体。
  Future<({List<RuleSearchItem> hits, String kw})> _searchOne(String kw) async {
    if (rule.usesApiSearch) {
      final raw = await _apiRequest(rule.searchApiConfig.request, {'keyword': kw});
      return (hits: KazumiParser(rule).parseSearchJson(raw), kw: kw);
    }
    final html = await _get(rule.buildSearchUrl(kw));
    return (hits: KazumiParser(rule).parseSearch(html), kw: kw);
  }

  @override
  Future<List<SourceSearchItem>> search(String keyword, {int? categoryId}) async {
    if (!supported) {
      kLog('[源搜索] ${rule.name} 跳过：规则 api=${rule.api} 超出本客户端支持');
      return const [];
    }
    final sw = Stopwatch()..start();
    final variants = searchVariants(keyword);
    List<RuleSearchItem> hits = const [];
    String usedKw = keyword;

    // ① 并发竞速最可能命中的前 N 个变体（谁先给出非空结果就采用谁）
    final race = variants.take(_kVariantRace).toList();
    var r = await _raceFirstNonEmpty(race);
    if (r != null) {
      hits = r.hits;
      usedKw = r.kw;
    }

    // ② 都没命中才补试剩余变体（同样并发，只在必要时发生）
    if (hits.isEmpty && variants.length > race.length) {
      r = await _raceFirstNonEmpty(variants.skip(_kVariantRace).toList());
      if (r != null) {
        hits = r.hits;
        usedKw = r.kw;
      }
    }

    if (hits.isEmpty) {
      kLog('[源搜索] ${rule.name} kw="$keyword" 全部变体无命中（${sw.elapsedMilliseconds}ms）');
      return const [];
    }

    kLog('[源搜索] ${rule.name} kw="$usedKw"（原: "$keyword"）命中 ${hits.length} 条 '
        '${sw.elapsedMilliseconds}ms');

    // 命中排序：与「搜索用词」最像的排前面，方便详情页取第一条
    final sorted = hits.toList()
      ..sort((a, b) => _score(usedKw, b.title).compareTo(_score(usedKw, a.title)));
    return sorted
        .map((h) => SourceSearchItem(
              title: h.title,
              url: h.url,
              episodeSort: h.episodeHint,
            ))
        .toList();
  }

  /// 并发跑一组变体，返回**第一个非空命中**；全部为空则返回 null。
  ///
  /// 与「串行依次试」的差别：串行总耗时 = 各变体之和（最坏 5 × 8s = 40s），
  /// 并发 = 最快给出命中的那个变体的耗时（通常 0.3～2s）。
  Future<({List<RuleSearchItem> hits, String kw})?> _raceFirstNonEmpty(
      List<String> kws) async {
    if (kws.isEmpty) return null;
    final completer = Completer<({List<RuleSearchItem> hits, String kw})?>();
    var remaining = kws.length;
    for (final kw in kws) {
      unawaited(() async {
        try {
          final r = await _searchOne(kw);
          if (r.hits.isNotEmpty && !completer.isCompleted) {
            completer.complete(r);
            return;
          }
        } catch (e) {
          kLog('[源搜索] ${rule.name} kw="$kw" 异常: ${e.toString().split('\n').first}');
        } finally {
          remaining--;
          if (remaining == 0 && !completer.isCompleted) completer.complete(null);
        }
      }());
    }
    return completer.future;
  }

  @override
  Future<SourceBangumi> bangumiDetail({
    int? categoryId,
    String? fallbackTitle,
    List<SourceSearchItem> seeds = const [],
  }) async {
    // 取第一个命中项的链接作为详情页
    final detailUrl = seeds.isNotEmpty
        ? seeds.first.url
        : (categoryId != null ? '${rule.baseURL}$categoryId' : '');
    if (detailUrl.isEmpty) {
      return SourceBangumi(title: fallbackTitle ?? '');
    }

    final parser = KazumiParser(rule);
    RuleBangumiDetail detail;
    if (rule.usesApiChapter) {
      // api 模式：detailUrl 实际是 searchApiConfig 取到的「源标识」（如视频 id）
      final raw = await _apiRequest(rule.chapterApiConfig.request, {'source': detailUrl});
      detail = parser.parseDetailJson(raw, source: detailUrl);
    } else {
      final html = await _get(detailUrl);
      detail = parser.parseDetail(html);
    }

    final roads = <SourceRoad>[];
    for (final r in detail.roads) {
      roads.add(SourceRoad(
        name: r.name,
        episodes: r.episodes
            .map((e) => SourceEpisode(title: e.title, sort: e.sort, pageUrl: e.url))
            .toList(),
      ));
    }

    // 合并去重（所有线路的集数合集，UI 默认展示这个）
    final seen = <String>{};
    final eps = <SourceEpisode>[];
    for (final e in detail.allEpisodes) {
      final key = '${e.sort}|${e.title}';
      if (seen.add(key)) {
        eps.add(SourceEpisode(title: e.title, sort: e.sort, pageUrl: e.url));
      }
    }

    if (eps.isEmpty && seeds.isNotEmpty) {
      // 兜底：搜索命中本身可能就是分集列表
      for (var i = 0; i < seeds.length; i++) {
        final s = seeds[i];
        eps.add(SourceEpisode(
          title: s.title,
          sort: s.episodeSort ?? (i + 1),
          pageUrl: s.url,
        ));
      }
    }
    eps.sort((a, b) => a.sort.compareTo(b.sort));

    return SourceBangumi(
      title: fallbackTitle ?? (seeds.isNotEmpty ? seeds.first.title : ''),
      episodes: eps,
      roads: roads.isEmpty && eps.isNotEmpty
          ? [SourceRoad(name: '播放线路1', episodes: eps)]
          : roads,
    );
  }

  @override
  Future<PlayInfo?> resolve(String pageUrl) async {
    // 兼容老接口：只做纯 HTTP 尝试，真正解析由 PlayResolver + WebView 负责
    try {
      final html = await _get(pageUrl);
      final m = RegExp(r'''https?://[^\s"'<>\\]+?\.(?:m3u8|mp4|flv)''')
          .firstMatch(html);
      if (m != null) {
        final u = m.group(0)!;
        return PlayInfo(
          url: u,
          type: u.contains('.m3u8') ? 'application/x-mpegURL' : 'video/mp4',
          headers: {'User-Agent': _ua, if (rule.referer.isNotEmpty) 'Referer': rule.referer},
        );
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}

String _decodeGbk(List<int> bytes) {
  // 不引入额外依赖：GBK 解码靠 http 包给的 latin1 兜底会乱码，
  // 这里用一个最小映射——直接交给 utf8 容错（中文站现在基本 UTF-8）。
  // 如果真遇到 GBK 站点，标题会显示为替换字符，不影响链接解析。
  return utf8.decode(bytes, allowMalformed: true);
}

// ───────────────────────── 注册表 ─────────────────────────

/// 源注册表：直接由 [BuiltinRules] 生成，规则库 = 源列表
class SourceRegistry {
  /// 用户开关持久化在本地设置里（键 = 源名）
  static final Map<String, bool> _enabledOverride = {};

  /// 【v1.9.3】线路大类偏好（直链/云播/接口/人机验证 × 国内/海外）。
  ///
  /// 由设置页写入；`active` 会同时应用「单源开关」与「大类开关」。
  /// 这样用户既能「一键只留直链解析换速度」，也能单独开某一条源。
  static SourceGroupPrefs groupPrefs = SourceGroupPrefs();

  static List<VideoSource>? _cache;

  static List<VideoSource> get sources {
    if (_cache == null) {
      _cache = BuiltinRules.all
          .map((r) => RuleVideoSource(r, enabled: _isEnabled(r)))
          .toList();
    }
    return _cache!;
  }

  /// 规则资产重新加载后调用：让源列表按新规则重建。
  static void invalidate() => _cache = null;

  static bool _isEnabled(KazumiRule r) {
    if (_enabledOverride.containsKey(r.name)) return _enabledOverride[r.name]!;
    return RuleRegistry.defaultEnabledNames.contains(r.name);
  }

  static void setEnabled(String name, bool v) {
    _enabledOverride[name] = v;
    for (final s in sources) {
      if (s.name == name) s.enabled = v;
    }
  }

  /// 设置某个「线路大类」的开关（同时作用于该类下所有源）
  static void setKindEnabled(SourceKind kind, bool v) {
    groupPrefs.kindEnabled[kind] = v;
  }

  static void setRegionEnabled(SourceRegion region, bool v) {
    groupPrefs.regionEnabled[region] = v;
  }

  /// 批量启用/关闭一组源（UI 上的「全开 / 全关 / 只留实测可用」）
  static void setManyEnabled(Iterable<String> names, bool v) {
    for (final n in names) {
      setEnabled(n, v);
    }
  }

  /// 当前启用的源（单源开关 + 大类开关都通过，且本客户端支持）
  static List<VideoSource> get active => sources
      .where((s) =>
          s.enabled && s.supported && groupPrefs.allowsRule(s.rule))
      .toList();

  /// 已启用但因「大类被关掉」而被过滤掉的源数（UI 上提示用）
  static int get suppressedByGroup => sources
      .where((s) =>
          s.enabled && s.supported && !groupPrefs.allowsRule(s.rule))
      .length;

  static VideoSource? byName(String name) {
    for (final s in sources) {
      if (s.name == name) return s;
    }
    return null;
  }
}

/// 聚合结果：一个源上的一个番
class AggregatedSource {
  final VideoSource source;
  final SourceBangumi bangumi;
  final String? error;
  const AggregatedSource({required this.source, required this.bangumi, this.error});
}
