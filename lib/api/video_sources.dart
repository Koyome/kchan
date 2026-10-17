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

/// 【v2.1.3 · 季数校验】搜索命中重排（对齐 Kazumi 的人工挑结果，但自动化）
///
/// ## 为什么必须有这个
///
/// 站点搜索顺序不可靠：搜「转生就是剑 第二季」，7sefun 把**第一季**排第一
/// （实测返回 12 集 = S1 的集数），旧实现直接取第一条 → 详情页/更新检测
/// 全部用错条目 —— 用户看到的「更新」其实是上一季的集数。
/// Kazumi 的做法是把搜索结果全部列出来**让用户人工挑**（`source_sheet`）；
/// kchan 自动取首条，就必须把「挑」这一步补上：季数一致 > 标题相似 > 原顺序。
class SourceMatch {
  /// 把 [seeds] 按「与 [target] 的匹配度」从高到低重排（稳定：同分保持原序）
  static List<SourceSearchItem> rank(List<SourceSearchItem> seeds, String target) {
    final t = target.trim();
    if (seeds.length <= 1 || t.isEmpty) return seeds;
    final tNorm = normalizeTitle(t);
    final tSeason = seasonNumberOf(t);

    int score(SourceSearchItem s) {
      final hNorm = normalizeTitle(s.title);
      var sc = 0;
      if (hNorm == tNorm) {
        sc += 1000;
      } else if (hNorm.contains(tNorm) || tNorm.contains(hNorm)) {
        sc += 500;
      }
      final hSeason = seasonNumberOf(s.title);
      if (tSeason != null) {
        // 目标有季数：命中季数一致最好；没标季数的（多半是第一季/总集篇）降权
        sc += hSeason == tSeason ? 300 : (hSeason == null ? -150 : -300);
      } else {
        // 目标本身没标季数：命中也带季数的（如第三季）不加分不减分
        sc += hSeason == null ? 50 : 0;
      }
      sc += (bigramJaccard(tNorm, hNorm) * 100).round();
      return sc;
    }

    // 稳定排序（同分保持站点原顺序）
    final keyed = <(int, SourceSearchItem, int)>[
      for (var i = 0; i < seeds.length; i++) (i, seeds[i], score(seeds[i])),
    ];
    keyed.sort((a, b) {
      final d = b.$3.compareTo(a.$3);
      return d != 0 ? d : a.$1.compareTo(b.$1);
    });
    return [for (final k in keyed) k.$2];
  }

  /// 从标题里提取季数；null = 没有季数标记
  static int? seasonNumberOf(String raw) {
    final t = raw.replaceAll(RegExp(r'\s+'), '').toLowerCase();
    // 第N季/期/部（阿拉伯或中文数字）
    final m = RegExp(r'第([0-9一二三四五六七八九十]+)[季期部]').firstMatch(t);
    if (m != null) return _cnToInt(m.group(1)!);
    // 「N期」（日文习惯：第3期 常写作 3期）
    final m2 = RegExp(r'([0-9]{1,2})[季期]').firstMatch(t);
    if (m2 != null) {
      final v = int.tryParse(m2.group(1)!);
      if (v != null && v >= 1 && v <= 30) return v;
    }
    // Season 2 / S2（词边界，避免误伤普通英文）
    final m3 = RegExp(r'(?:season|s)([0-9]{1,2})(?![0-9])').firstMatch(t);
    if (m3 != null) {
      final v = int.tryParse(m3.group(1)!);
      if (v != null && v >= 1 && v <= 30) return v;
    }
    // 罗马数字：Unicode Ⅱ Ⅲ Ⅳ / 字母 II III IV（词边界）
    const unicode = {'ⅱ': 2, 'ⅲ': 3, 'ⅳ': 4, 'ⅴ': 5, 'ⅵ': 6};
    for (final e in unicode.entries) {
      if (t.contains(e.key)) return e.value;
    }
    final m4 = RegExp(r'(?:^|[^a-z0-9])(ii|iii|iv)(?:[^a-z0-9]|$)').firstMatch(t);
    if (m4 != null) return {'ii': 2, 'iii': 3, 'iv': 4}[m4.group(1)!];
    // 续/続 结尾（续作）→ 2（保守）
    if (RegExp(r'(続|续)(編|篇)?$').hasMatch(t)) return 2;
    return null;
  }

  /// 标题归一化：去空白/括号字符/标点，转小写
  static String normalizeTitle(String raw) => raw
      .replaceAll(RegExp(r'[\s（）()\[\]【】「」『』・:：,，.。!！?？~～\-—_×x/|]'), '')
      .toLowerCase();

  /// 去掉季数后缀后的「基础名」（「转生就是剑 第二季」→「转生就是剑」）
  static String baseTitleOf(String raw) {
    var t = normalizeTitle(raw);
    t = t
        .replaceAll(RegExp(r'第[0-9一二三四五六七八九十]+[季期部]'), '')
        .replaceAll(RegExp(r'[0-9]{1,2}[季期]'), '')
        .replaceAll(RegExp(r'season[0-9]{1,2}'), '')
        .replaceAll(RegExp(r'ⅱ|ⅲ|ⅳ|ⅴ|ⅵ'), '')
        .replaceAll(RegExp(r'(?<![a-z0-9])(ii|iii|iv)(?![a-z0-9])'), '')
        .replaceAll(RegExp(r'(続編?|续(篇)?)$'), '');
    return t;
  }

  /// 【表面可信】候选标题与目标是否有表面重合（归一化相等/包含/Jaccard≥0.25）。
  /// 不发网络请求；跨语言译名（日文目标 vs 中文候选）会落空——那一步交给
  /// 「Bangumi 反查」（见 detail_page 的候选校验）。
  static bool surfacePlausible(String target, SourceSearchItem best) {
    final t = normalizeTitle(target);
    final h = normalizeTitle(best.title);
    if (t.isEmpty || h.isEmpty) return false;
    if (t.contains(h) || h.contains(t)) return true;
    return bigramJaccard(t, h) >= 0.25;
  }

  /// 【季数不符判定】目标明确是第 [tSeason] 季，而最佳候选要么季数不符、
  /// 要么「标题 == 去季数的基础名」（= 大概率就是上一季/合集条目）。
  /// 返回 true = 这条候选不该用（宁缺勿滥：S1 的 12 集污染并集，
  /// 用户会点到第一季的内容）。
  static bool seasonMismatch(String target, SourceSearchItem best) {
    final tSeason = seasonNumberOf(target);
    if (tSeason == null) return false;
    final hSeason = seasonNumberOf(best.title);
    if (hSeason == tSeason) return false;
    if (hSeason != null) return true; // 季数明确不同
    // 候选没标季数：标题恰等于基础名 → 就是上一季的条目
    final base = baseTitleOf(target);
    return base.isNotEmpty && normalizeTitle(best.title) == base;
  }

  /// 字符二元组 Jaccard 相似度（0~1，中日文标题够用）
  static double bigramJaccard(String a, String b) {
    if (a.isEmpty || b.isEmpty) return 0;
    Set<String> grams(String s) {
      if (s.length == 1) return {s};
      return {for (var i = 0; i + 2 <= s.length; i++) s.substring(i, i + 2)};
    }

    final ga = grams(a);
    final gb = grams(b);
    final inter = ga.intersection(gb).length;
    final union = ga.union(gb).length;
    return union == 0 ? 0 : inter / union;
  }

  static int _cnToInt(String s) {
    const digits = {
      '一': 1, '二': 2, '三': 3, '四': 4, '五': 5,
      '六': 6, '七': 7, '八': 8, '九': 9,
    };
    if (int.tryParse(s) != null) return int.parse(s);
    if (s == '十') return 10;
    final m = RegExp(r'^([一二三四五六七八九])?十([一二三四五六七八九])?$').firstMatch(s);
    if (m != null) {
      final a = m.group(1) != null ? digits[m.group(1)!]! : 1;
      final b = m.group(2) != null ? digits[m.group(2)!]! : 0;
      return a * 10 + b;
    }
    return digits[s] ?? 0;
  }
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

/// 单次 HTTP 请求超时。
///
/// 【v2.1.0 调整】旧值 8s 是「实测国内源正常 0.3～2s」时定的。
/// 但 2026-10-14 用本季新番实测（tool/probe_newanime.dart）发现：
/// DM84 在新番高峰期单次请求要 2.6~6.8s、gugu3 整站每个请求都 >8s，
/// 8s 超时把这些「慢但没死」的源误判成「连接失败」——
/// 这正是「新番经常解析失败（线路问题）」的主要表象。
/// 调到 12s：慢源有机会完成；真正死掉的源仍然失败，只是多等 4s，
/// 而详情页各源是并发聚合的，不会拖慢快车道的首屏。
const _kRequestTimeout = Duration(seconds: 12);

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
    // 【v2.1.0】首条命中未必是目标条目：
    // 新番常有同名旧作/总集篇/真人版/上一季，搜索排第一的可能是它们。
    // 【v2.1.3】先按「标题相似度 + 季数一致」重排（SourceMatch.rank）——
    // 实测 7sefun 搜「转生就是剑 第二季」把第一季排第一（12 集），
    // 不重排会把第一季的分集当成第二季的更新。
    final ranked = SourceMatch.rank(seeds, fallbackTitle ?? '');
    final candidates = <String>[
      for (final s in ranked.take(3))
        if (s.url.trim().isNotEmpty) s.url,
      if (seeds.isEmpty && categoryId != null) '${rule.baseURL}$categoryId',
    ];
    if (candidates.isEmpty) {
      return SourceBangumi(title: fallbackTitle ?? '');
    }
    if (candidates.length > 1 || ranked.first.title != (fallbackTitle ?? '')) {
      kLog('[源详情] ${rule.name} 候选重排后首选「${ranked.first.title}」'
          '${ranked.length > 1 ? "（共 ${ranked.length} 条候选）" : ""}');
    }

    final parser = KazumiParser(rule);
    RuleBangumiDetail detail = const RuleBangumiDetail(roads: []);
    Object? lastError;
    var attempts = 0, failures = 0;
    for (final detailUrl in candidates) {
      attempts++;
      try {
        if (rule.usesApiChapter) {
          // api 模式：detailUrl 实际是 searchApiConfig 取到的「源标识」（如视频 id）
          final raw = await _apiRequest(
              rule.chapterApiConfig.request, {'source': detailUrl});
          detail = parser.parseDetailJson(raw, source: detailUrl);
        } else {
          final html = await _get(detailUrl);
          detail = parser.parseDetail(html);
        }
      } catch (e) {
        failures++;
        lastError = e;
        kLog('[源详情] ${rule.name} 抓取失败 $detailUrl: '
            '${e.toString().split('\n').first}');
        continue;
      }
      if (detail.allEpisodes.isNotEmpty) break; // 拿到分集即停
    }
    // 所有候选都抛了异常 → 抛回最后一个错误，让上层显示「连接失败」
    // 而不是被误判成「未收录」（两者 UI 提示不同）。
    if (detail.allEpisodes.isEmpty &&
        attempts > 0 &&
        failures == attempts &&
        lastError != null) {
      throw lastError;
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
    //
    // 【v2.1.2】去重逻辑上移到 `RuleBangumiDetail.allEpisodes`（按集号去重、
    // 优先保留标题真解析出集号的条目）。这里曾按 `sort|标题` 去重，导致同一
    // 集号的不同写法（「第2集」/「第02集」）被算成两集 —— 卡片显示「收录 3
    // 集」，格子里却只有 2 个集号能点（实测 FQDM）。
    final eps = <SourceEpisode>[
      for (final e in detail.allEpisodes)
        SourceEpisode(title: e.title, sort: e.sort, pageUrl: e.url),
    ];

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
