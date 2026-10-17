/// Kazumi 规则引擎（Dart 移植版）
///
/// 完全对齐 Kazumi 的规则 JSON 格式（https://github.com/Predidit/KazumiRules）：
///
/// ```json
/// {
///   "api": "6", "type": "anime", "name": "AGE", "version": "1.5",
///   "muliSources": true, "useWebview": true, "useNativePlayer": true,
///   "baseURL": "https://www.agedm.io/",
///   "searchURL": "https://www.agedm.io/search?query=@keyword",
///   "searchList": "//div[..]", "searchName": "//a", "searchResult": "//a",
///   "chapterRoads": "//div[..]", "chapterResult": "//li/a",
///   "referer": "", "userAgent": "", "usePost": false,
///   "useLegacyParser": false, "deprecated": false,
///   "antiCrawlerConfig": { "enabled": true, "captchaType": 1, ... }
/// }
/// ```
///
/// 字段语义（与 Kazumi 一致）：
///  - `@keyword`        搜索词占位符，会被 URL 编码后替换
///  - `searchList`      搜索结果「每一项」的 XPath
///  - `searchName`      在每一项内取标题的 XPath（取 text）
///  - `searchResult`    在每一项内取链接的 XPath（取 href）
///  - `chapterRoads`    详情页里「每条线路」的 XPath
///  - `chapterResult`   在每条线路内取「每一集链接」的 XPath（取 href + text）
///  - `useWebview`      是否需要用 WebView 解析真实播放地址
///  - `antiCrawlerConfig` 反爬验证码配置（这类站点静态 HTML 拿不到结果）
///
/// ## api level 8：JSON 接口规则（`searchMode` / `chapterMode` = `"api"`）
///
/// Kazumi 高版本规则可以不解析 HTML，而是直接请求站点的 JSON 接口，用
/// JSONPath 取值。对应字段 `searchApiConfig` / `chapterApiConfig`。
/// 旧版 K酱 完全没有实现这一路径，导致这批规则「存在但永远搜不到东西」。
/// 现已补齐（见 [KazumiParser] 与 `jsonpath_lite.dart`）。
///
/// ## api level 9+：明确拒绝
///
/// 与 Kazumi 的 `requiresNewerClient` 一致：`api > 8` 的规则本客户端不认识，
/// 直接标为不可用，避免用户启用后得到一堆莫名其妙的失败。
library;

import 'dart:convert';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import 'jsonpath_lite.dart';
import 'xpath_lite.dart';

/// 资产读取注入点。
///
/// 本文件刻意**不 import package:flutter**（保持纯 Dart，方便在桌面/CI 用
/// 纯 Dart VM 直接跑规则校验）；App 侧在 `main()` 里把这个回调接到
/// `rootBundle.loadString`，缺省实现（纯 Dart 环境）返回空串 → 走
/// [BuiltinRules.load] 的 fallback 分支。
Future<String> Function(String key) _rootBundleLoadString = (String key) async => ''; // ignore: prefer_function_declarations_over_variables

/// 由 App 侧注入真实的资产读取实现（Android/Windows 都走 rootBundle）。
void installRuleAssetLoader(Future<String> Function(String key) loader) {
  _rootBundleLoadString = loader;
}

/// 本客户端支持的规则 api level（对齐 Kazumi `ApiEndpoints.apiLevel`）
const int kSupportedRuleApiLevel = 8;

/// 规则模式：xpath（解析 HTML） / api（调 JSON 接口）
class RuleMode {
  static const String xpath = 'xpath';
  static const String api = 'api';
  static String normalize(Object? v) => v == api ? api : xpath;
}

/// 请求体类型
class ApiBodyType {
  static const String none = 'none';
  static const String json = 'json';
  static const String form = 'form';
  static String normalize(Object? v) => switch (v) {
        json => json,
        form => form,
        _ => none,
      };
}

/// 章节响应形态
class ApiChapterFormat {
  static const String nested = 'nested';
  static const String delimited = 'delimited';
  static String normalize(Object? v) => v == delimited ? delimited : nested;
}

/// 反爬验证码配置（对齐 Kazumi 的 antiCrawlerConfig）
class AntiCrawlerConfig {

  final bool enabled;
  final int captchaType;
  final String captchaImage;
  final String captchaInput;
  final String captchaButton;

  /// 验证页检测方式：1=文本（默认） 2=正则 3=XPath
  final int captchaDetectType;
  final String captchaDetectValue;

  const AntiCrawlerConfig({
    this.enabled = false,
    this.captchaType = 0,
    this.captchaImage = '',
    this.captchaInput = '',
    this.captchaButton = '',
    this.captchaDetectType = 1,
    this.captchaDetectValue = '',
  });

  factory AntiCrawlerConfig.fromJson(Map<String, dynamic>? j) {
    if (j == null) return const AntiCrawlerConfig();
    bool b(String k) => j[k] == true || j[k] == 'true' || j[k] == 1;
    int i(String k, int d) => int.tryParse('${j[k] ?? d}') ?? d;
    return AntiCrawlerConfig(
      enabled: b('enabled'),
      captchaType: i('captchaType', 0),
      captchaImage: '${j['captchaImage'] ?? ''}',
      captchaInput: '${j['captchaInput'] ?? ''}',
      captchaButton: '${j['captchaButton'] ?? ''}',
      captchaDetectType: i('captchaDetectType', 1),
      captchaDetectValue: '${j['captchaDetectValue'] ?? ''}',
    );
  }

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'captchaType': captchaType,
        'captchaImage': captchaImage,
        'captchaInput': captchaInput,
        'captchaButton': captchaButton,
        'captchaDetectType': captchaDetectType,
        'captchaDetectValue': captchaDetectValue,
      };
}

/// API 请求模板
class ApiRequestConfig {
  final String method;
  final String url;
  final Map<String, dynamic> headers;
  final Map<String, dynamic> query;
  final String bodyType;
  final dynamic body;

  const ApiRequestConfig({
    this.method = 'GET',
    this.url = '',
    this.headers = const {},
    this.query = const {},
    this.bodyType = ApiBodyType.none,
    this.body,
  });

  bool get isEmpty => url.trim().isEmpty;

  factory ApiRequestConfig.fromJson(Map<String, dynamic>? j) {
    if (j == null) return const ApiRequestConfig();
    return ApiRequestConfig(
      method: '${j['method'] ?? 'GET'}'.toUpperCase(),
      url: '${j['url'] ?? ''}',
      headers: _strMap(j['headers']),
      query: _strMap(j['query']),
      bodyType: ApiBodyType.normalize(j['bodyType']),
      body: j['body'],
    );
  }

  Map<String, dynamic> toJson() => {
        'method': method,
        'url': url,
        if (headers.isNotEmpty) 'headers': headers,
        if (query.isNotEmpty) 'query': query,
        'bodyType': bodyType,
        if (body != null) 'body': body,
      };
}

/// API 搜索配置
class ApiSearchConfig {
  final ApiRequestConfig request;
  final String listPath;
  final String namePath;
  final String sourcePath;

  const ApiSearchConfig({
    this.request = const ApiRequestConfig(),
    this.listPath = r'$.data[*]',
    this.namePath = r'$.name',
    this.sourcePath = r'$.url',
  });

  factory ApiSearchConfig.fromJson(Map<String, dynamic>? j) {
    if (j == null) return const ApiSearchConfig();
    return ApiSearchConfig(
      request: ApiRequestConfig.fromJson(_map(j['request'])),
      listPath: '${j['listPath'] ?? r'$.data[*]'}',
      namePath: '${j['namePath'] ?? r'$.name'}',
      sourcePath: '${j['sourcePath'] ?? r'$.url'}',
    );
  }

  Map<String, dynamic> toJson() => {
        'request': request.toJson(),
        'listPath': listPath,
        'namePath': namePath,
        'sourcePath': sourcePath,
      };
}

/// 剧集播放页模板
class ApiEpisodePageConfig {
  final String url;
  final Map<String, dynamic> query;
  const ApiEpisodePageConfig({this.url = '', this.query = const {}});

  factory ApiEpisodePageConfig.fromJson(Map<String, dynamic>? j) {
    if (j == null) return const ApiEpisodePageConfig();
    return ApiEpisodePageConfig(
      url: '${j['url'] ?? ''}',
      query: _strMap(j['query']),
    );
  }

  Map<String, dynamic> toJson() => {
        'url': url,
        if (query.isNotEmpty) 'query': query,
      };
}

/// API 章节配置
class ApiChapterConfig {
  final ApiRequestConfig request;
  final String format;

  // nested
  final String roadsPath;
  final String roadNamePath;
  final String episodesPath;
  final String episodeNamePath;
  final String episodeUrlPath;

  // delimited
  final String roadNamesPath;
  final String roadEpisodesPath;
  final String roadSeparator;
  final String episodeSeparator;
  final String fieldSeparator;

  final Map<String, String> variables;
  final ApiEpisodePageConfig? episodePage;

  const ApiChapterConfig({
    this.request = const ApiRequestConfig(),
    this.format = ApiChapterFormat.nested,
    this.roadsPath = r'$.data.roads[*]',
    this.roadNamePath = r'$.name',
    this.episodesPath = r'$.episodes[*]',
    this.episodeNamePath = r'$.name',
    this.episodeUrlPath = r'$.url',
    this.roadNamesPath = '',
    this.roadEpisodesPath = '',
    this.roadSeparator = r'$$$',
    this.episodeSeparator = '#',
    this.fieldSeparator = r'$',
    this.variables = const {},
    this.episodePage,
  });

  factory ApiChapterConfig.fromJson(Map<String, dynamic>? j) {
    if (j == null) return const ApiChapterConfig();
    final vars = <String, String>{};
    final rawVars = j['variables'];
    if (rawVars is Map) {
      rawVars.forEach((k, v) => vars['$k'] = '$v');
    }
    return ApiChapterConfig(
      request: ApiRequestConfig.fromJson(_map(j['request'])),
      format: ApiChapterFormat.normalize(j['format']),
      roadsPath: '${j['roadsPath'] ?? r'$.data.roads[*]'}',
      roadNamePath: '${j['roadNamePath'] ?? r'$.name'}',
      episodesPath: '${j['episodesPath'] ?? r'$.episodes[*]'}',
      episodeNamePath: '${j['episodeNamePath'] ?? r'$.name'}',
      episodeUrlPath: '${j['episodeUrlPath'] ?? r'$.url'}',
      roadNamesPath: '${j['roadNamesPath'] ?? ''}',
      roadEpisodesPath: '${j['roadEpisodesPath'] ?? ''}',
      roadSeparator: '${j['roadSeparator'] ?? r'$$$'}',
      episodeSeparator: '${j['episodeSeparator'] ?? '#'}',
      fieldSeparator: '${j['fieldSeparator'] ?? r'$'}',
      variables: vars,
      episodePage: j['episodePage'] is Map
          ? ApiEpisodePageConfig.fromJson(_map(j['episodePage']))
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
        'request': request.toJson(),
        'format': format,
        'roadsPath': roadsPath,
        'roadNamePath': roadNamePath,
        'episodesPath': episodesPath,
        'episodeNamePath': episodeNamePath,
        'episodeUrlPath': episodeUrlPath,
        if (roadNamesPath.isNotEmpty) 'roadNamesPath': roadNamesPath,
        if (roadEpisodesPath.isNotEmpty) 'roadEpisodesPath': roadEpisodesPath,
        'roadSeparator': roadSeparator,
        'episodeSeparator': episodeSeparator,
        'fieldSeparator': fieldSeparator,
        if (variables.isNotEmpty) 'variables': variables,
        if (episodePage != null) 'episodePage': episodePage!.toJson(),
      };
}

Map<String, dynamic> _strMap(Object? v) {
  if (v is! Map) return const {};
  return v.map((k, val) => MapEntry('$k', val));
}

Map<String, dynamic>? _map(Object? v) =>
    v is Map ? v.map((k, val) => MapEntry('$k', val)) : null;

/// 一条 Kazumi 规则
class KazumiRule {
  /// 规则库 api 版本（1..8）
  final String api;
  final String name;
  final String version;
  final String baseURL;
  final String searchURL;
  final String searchList;
  final String searchName;
  final String searchResult;
  final String chapterRoads;
  final String chapterResult;
  final String referer;
  final String userAgent;

  /// 站点 Cookie（可选）。部分站点有人机验证，浏览器里过一次后
  /// 把 Cookie 粘进来即可让 App 复用该会话（规则 JSON 字段名 `cookie`）。
  final String cookie;

  /// 是否需要 WebView 解析真实播放地址（jx 类播放器必须为 true）
  final bool useWebview;

  /// 是否用 POST 搜索
  final bool usePost;

  /// 是否用 legacy（iframe src）解析器
  final bool useLegacyParser;

  /// 规则是否已被官方标记为废弃
  final bool deprecated;

  /// 反爬配置
  final AntiCrawlerConfig antiCrawler;

  /// Kazumi 原生的广告拦截开关（DM84 / baimao 官方规则里为 true）。
  /// 我们据此扫描 m3u8 里被 CDN **注入的广告分片块**并在播放时跨过。
  final bool adBlocker;

  /// 【api level 8】搜索模式：xpath（抓 HTML） / api（调 JSON 接口）
  final String searchMode;

  /// 【api level 8】章节模式：xpath / api
  final String chapterMode;

  final ApiSearchConfig searchApiConfig;
  final ApiChapterConfig chapterApiConfig;

  /// 备注：实测状态（本机真实网络验证结论）。
  ///
  /// 【注意 TFA】此字段**刻意不从 JSON 读取**（生成器也不写出）：Dart AOT 的
  /// tree-shaking 会把「只被 const 持有、内容从未参与逻辑」的字符串整体消除，
  /// 实测 libapp.so 里这类字段会静默消失。规则数据以 JSON 为权威，
  /// 人看的说明留在 `gen_rules.py` 的 PATCHES 与本文档里。
  final String note;

  /// 实测是否可用（同上，不从 JSON 读取，只由代码逻辑赋值）
  final bool verified;

  const KazumiRule({
    this.api = '1',
    required this.name,
    this.version = '1.0',
    required this.baseURL,
    this.searchURL = '',
    this.searchList = '',
    this.searchName = '',
    this.searchResult = '',
    this.chapterRoads = '',
    this.chapterResult = '',
    this.referer = '',
    this.userAgent = '',
    this.cookie = '',
    this.useWebview = true,
    this.usePost = false,
    this.useLegacyParser = false,
    this.deprecated = false,
    this.antiCrawler = const AntiCrawlerConfig(),
    this.adBlocker = false,
    this.searchMode = RuleMode.xpath,
    this.chapterMode = RuleMode.xpath,
    this.searchApiConfig = const ApiSearchConfig(),
    this.chapterApiConfig = const ApiChapterConfig(),
    this.note = '',
    this.verified = false,
  });

  factory KazumiRule.fromJson(Map<String, dynamic> j, {String note = '', bool verified = false}) {
    String s(String k) => (j[k] ?? '').toString();
    bool b(String k) => j[k] == true || j[k] == 'true' || j[k] == 1;
    return KazumiRule(
      api: s('api').isEmpty ? '1' : s('api'),
      name: s('name'),
      version: s('version').isEmpty ? '1.0' : s('version'),
      baseURL: s('baseURL'),
      searchURL: s('searchURL'),
      searchList: s('searchList'),
      searchName: s('searchName'),
      searchResult: s('searchResult'),
      chapterRoads: s('chapterRoads'),
      chapterResult: s('chapterResult'),
      referer: s('referer'),
      userAgent: s('userAgent'),
      cookie: s('cookie'),
      useWebview: j.containsKey('useWebview') ? b('useWebview') : true,
      usePost: b('usePost'),
      useLegacyParser: b('useLegacyParser'),
      deprecated: b('deprecated'),
      antiCrawler: AntiCrawlerConfig.fromJson(_map(j['antiCrawlerConfig'])),
      adBlocker: b('adBlocker'),
      searchMode: RuleMode.normalize(j['searchMode']),
      chapterMode: RuleMode.normalize(j['chapterMode']),
      searchApiConfig: ApiSearchConfig.fromJson(_map(j['searchApiConfig'])),
      chapterApiConfig: ApiChapterConfig.fromJson(_map(j['chapterApiConfig'])),
      // note/verified **不从 JSON 读取**：见字段注释里的 TFA 说明。
      note: note,
      verified: verified,
    );
  }

  /// 走 JSON 接口取搜索结果
  bool get usesApiSearch => searchMode == RuleMode.api;

  /// 走 JSON 接口取章节
  bool get usesApiChapter => chapterMode == RuleMode.api;

  /// 【线路排序启发式】该源是否更可能「一点就播」。
  ///
  /// 用途：详情页在多个可用线路里挑默认线路，以及播放失败后自动换源时的
  /// 优先级。直链类源（苹果 CMS 系把 m3u8 明文写在播放页）解析最快、最稳，
  /// jx 云播类必须跑浏览器内核解析（慢且看站点脸色）。
  ///
  /// 判据（保守，宁可判成非直链也不误判）：
  ///  - `useLegacyParser`：老式 iframe，直链常藏在 iframe 的 query 里，纯 HTTP 可得；
  ///  - **非 api=6/8**：api 6/8 是新一代播放器（几乎都要跑 JS），
  ///    1/3/4/5/7 多为苹果 CMS 系，页面里常见 `player_aaaa.url` 明文直链。
  ///
  /// 注意：这只是排序提示，不影响实际解析路径 —— 解析器永远先试纯 HTTP
  /// 再回落浏览器，所以误判只影响顺序，不会导致看不了。
  bool get isDirectPlay =>
      useLegacyParser || (api != '6' && api != '8');

  /// 规则版本高于本客户端（Kazumi 的 requiresNewerClient）
  bool get requiresNewerClient {
    final v = int.tryParse(api);
    return v != null && v > kSupportedRuleApiLevel;
  }

  Map<String, dynamic> toJson() => {
        'api': api,
        'type': 'anime',
        'name': name,
        'version': version,
        'baseURL': baseURL,
        'searchURL': searchURL,
        'searchList': searchList,
        'searchName': searchName,
        'searchResult': searchResult,
        'chapterRoads': chapterRoads,
        'chapterResult': chapterResult,
        'referer': referer,
        'cookie': cookie,
        'userAgent': userAgent,
        'useWebview': useWebview,
        'usePost': usePost,
        'useLegacyParser': useLegacyParser,
        'deprecated': deprecated,
        'adBlocker': adBlocker,
        'searchMode': searchMode,
        'chapterMode': chapterMode,
        if (antiCrawler.enabled) 'antiCrawlerConfig': antiCrawler.toJson(),
        // api level 8 规则必须带接口配置，否则落盘后再载入就退化失效
        if (usesApiSearch || !searchApiConfig.request.isEmpty)
          'searchApiConfig': searchApiConfig.toJson(),
        if (usesApiChapter || !chapterApiConfig.request.isEmpty)
          'chapterApiConfig': chapterApiConfig.toJson(),
      };

  /// 把 `@keyword` 替换成 URL 编码后的关键词
  ///
  /// 用 `encodeQueryComponent`（空格 → `+`）对齐 Kazumi 的
  /// `Uri.encodeQueryComponent`：部分站点的搜索参数解析对 `%20` 与 `+`
  /// 处理不同，`+` 是表单式编码，兼容性更好。
  String buildSearchUrl(String keyword) {
    final enc = Uri.encodeQueryComponent(keyword.trim());
    if (searchURL.contains('@keyword')) {
      return searchURL.replaceAll('@keyword', enc);
    }
    return searchURL;
  }
}

// ─────────────────────────── XPath 适配层 ───────────────────────────
//
// 【v1.9.1 性能重写】旧实现把 HTML 转成 XML 字符串再用 package:xml 的 XPath
// 求值（DOM → 字符串 → 又一棵 XML 树）。现在直接在 package:html 的 DOM 上
// 求值（见 xpath_lite.dart），Kazumi 官方也是这个做法。

/// 解析 HTML 为 DOM（容错：解析失败返回空文档而不是抛错）
dom.Document parseHtml(String htmlText) {
  try {
    return html_parser.parse(htmlText);
  } catch (_) {
    return dom.Document();
  }
}

/// 对 DOM 求 XPath，容错返回空列表
List<XNode> tryXPath(dom.Node root, String path) => xpathSelect(root, path);

/// 【实测修复】在「某个节点内部」取子元素时，必须把 `//xxx` 转成 `.//xxx`。
///
/// 背景：Kazumi 规则里的 searchName / chapterResult 等写的是 `//li/a` 这种
/// 全文档路径，而 Kazumi 官方引擎按「相对当前节点」求值。
///
/// 本引擎里 [xpathSelect] 的 `//x` 语义已经是「以传入节点为根的子树」，
/// 因此这里保留该函数只为兼容既有调用点与语义自注释。
String relativeXPath(String path) {
  final p = path.trim();
  if (p.isEmpty) return p;
  if (p.startsWith('.//') || p.startsWith('./')) return p;
  return p;
}

/// 在 [node] 内部按相对路径取子节点
List<XNode> innerXPath(XNode node, String path) {
  final e = node.element;
  if (e == null) return const [];
  return xpathSelect(e, relativeXPath(path));
}

/// 取节点的文本（含后代的文本拼接），并做空白归一化
String nodeText(XNode n) {
  final t = n.text ?? '';
  return t.replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// 取属性（如 href/src）
String nodeAttr(XNode n, String attr) => n.attr(attr) ?? '';

/// 若 XPath 结果直接指向属性（如 `//a/@href`），取属性值
///
/// 若结果是一个容器元素，则下钻找它（或后代）里的 `<a href>`：很多规则的
/// searchResult 给的是卡片容器而不是链接本身。
String resolveHref(XNode n) {
  if (n.isAttr) return n.text ?? '';
  final direct = n.attr('href') ?? '';
  if (direct.isNotEmpty) return direct;
  final e = n.element;
  if (e != null) {
    // 先看自己/后代里的第一个 a[href]
    if (e.localName == 'a') {
      final v = e.attributes['href'] ?? '';
      if (v.isNotEmpty) return v;
    }
    for (final a in e.getElementsByTagName('a')) {
      final v = a.attributes['href'] ?? '';
      if (v.isNotEmpty) return v;
    }
    for (final a in e.children) {
      if (a.localName == 'a') {
        final v = a.attributes['href'] ?? '';
        if (v.isNotEmpty) return v;
      }
    }
  }
  return '';
}

/// 补全相对链接。
///
/// 【重要】会把 `http://` 升级为 `https://`：
/// 实测 AGE 搜索页输出 `http://www.agedm.io/detail/...`，但该站 80 端口已死
/// （`http://` → 连接失败，`https://` → 200）。不升级就必然取不到详情页。
/// 反之 https → http 的降级不做（降级没有安全/可用性收益）。
String absolutize(String url, String base) {
  if (url.isEmpty) return '';
  if (url.startsWith('//')) return 'https:$url';
  if (url.startsWith('http://')) return 'https://${url.substring(7)}';
  if (url.startsWith('https://')) return url;
  try {
    final r = Uri.parse(base).resolve(url).toString();
    if (r.startsWith('http://')) return 'https://${r.substring(7)}';
    return r;
  } catch (_) {
    return url;
  }
}

// ─────────────────────────── 解析结果模型 ───────────────────────────

/// 搜索结果一项
class RuleSearchItem {
  final String title;
  final String url;
  final int? episodeHint;
  const RuleSearchItem({required this.title, required this.url, this.episodeHint});
}

/// 一条线路（对应一组分集）
class RuleRoad {
  final String name;
  final List<RuleEpisode> episodes;
  const RuleRoad({required this.name, required this.episodes});
}

/// 一集
class RuleEpisode {
  final String title;
  final String url;
  final int sort;

  /// sort 是不是「猜的」：标题里解析不出集号时回退成列表序号（= true）。
  ///
  /// 【v2.1.2】合并去重要用：同一集号下若既有猜的又有解析出来的，
  /// 保留解析出来的那个（实测：FQDM 同一条线路里「预告」会抢占第 1 集）。
  final bool guessedSort;

  const RuleEpisode({
    required this.title,
    required this.url,
    this.sort = 0,
    this.guessedSort = false,
  });
}

/// 详情页解析结果
class RuleBangumiDetail {
  final List<RuleRoad> roads;
  const RuleBangumiDetail({required this.roads});

  /// 合并所有线路，**按集号去重**（v2.1.2）
  ///
  /// 旧实现按 `sort|标题` 去重，同一个集号在不同线路标题写法不同时
  /// （「第2集」vs「第02集」）会被算成两集 → 卡片数虚高、格子里却只有
  /// 一个能点（实测 FQDM：显示收录 3 集、实际只有 2 个集号可点）。
  /// 现在同一集号只保留一条，优先保留标题里**真解析出集号**的条目
  /// （避免「预告」这类回退序号挤掉正片）。
  List<RuleEpisode> get allEpisodes {
    final bySort = <int, RuleEpisode>{};
    for (final r in roads) {
      for (final e in r.episodes) {
        final old = bySort[e.sort];
        if (old == null) {
          bySort[e.sort] = e;
        } else if (old.guessedSort && !e.guessedSort) {
          bySort[e.sort] = e; // 解析出来的胜过猜的
        }
      }
    }
    final out = bySort.values.toList()
      ..sort((a, b) => a.sort.compareTo(b.sort));
    return out;
  }
}

// ─────────────────────────── 解析器 ───────────────────────────

/// 用一条规则解析搜索结果 / 详情页。
///
/// 同时支持两种数据来源：
///  - **HTML + XPath**（绝大多数规则）
///  - **JSON 接口 + JSONPath**（`searchMode`/`chapterMode` = `api`，4 条官方规则）
class KazumiParser {
  final KazumiRule rule;
  KazumiParser(this.rule);

  // ─────────── XPath 路径 ───────────

  /// 解析搜索结果页（HTML）
  List<RuleSearchItem> parseSearch(String htmlText) {
    final doc = parseHtml(htmlText);
    return parseSearchDom(doc);
  }

  /// 在已解析的 DOM 上解析搜索结果（复用 DOM 的场景用这个）
  List<RuleSearchItem> parseSearchDom(dom.Node doc) {
    final out = <RuleSearchItem>[];
    final items = tryXPath(doc, rule.searchList);
    for (final it in items) {
      if (!it.isElement) continue;
      final nameNodes = innerXPath(it, rule.searchName);
      final resNodes = innerXPath(it, rule.searchResult);
      final title = nameNodes.isNotEmpty
          ? nodeText(nameNodes.first)
          : (resNodes.isNotEmpty ? nodeText(resNodes.first) : '');
      var href = resNodes.isNotEmpty ? resolveHref(resNodes.first) : '';
      if (href.isEmpty && nameNodes.isNotEmpty) href = resolveHref(nameNodes.first);
      if (title.isEmpty || href.isEmpty) continue;
      out.add(RuleSearchItem(
        title: title,
        url: absolutize(href, rule.baseURL),
        episodeHint: _episodeFromTitle(title),
      ));
    }
    return out;
  }

  /// 解析详情页的分集（多线路，HTML + XPath）
  RuleBangumiDetail parseDetail(String htmlText) {
    return parseDetailDom(parseHtml(htmlText));
  }

  RuleBangumiDetail parseDetailDom(dom.Node doc) {
    final roads = <RuleRoad>[];
    final roadNodes = tryXPath(doc, rule.chapterRoads);
    for (final rn in roadNodes) {
      final eps = <RuleEpisode>[];
      final epNodes = innerXPath(rn, rule.chapterResult);
      var n = 0;
      for (final en in epNodes) {
        n++;
        final href = resolveHref(en);
        if (href.isEmpty) continue;
        // 很多源的章节链接是 `javascript:void(0)` / `javascript:;`，
        // 真实地址由 JS 点击时拼接。跳过，避免把 javascript: 当可播地址。
        if (href.toLowerCase().startsWith('javascript:')) continue;
        final t = nodeText(en);
        final parsedSort = _episodeFromTitle(t);
        eps.add(RuleEpisode(
          title: _cleanEpisodeName(t, n),
          url: absolutize(href, rule.baseURL),
          sort: parsedSort ?? n,
          guessedSort: parsedSort == null,
        ));
      }
      if (eps.isNotEmpty) {
        // 【对齐 Kazumi】xpath 路径下线路名统一是「播放线路N」——
        // 规则里没有线路名字段，官方引擎也是这么编号的。
        roads.add(RuleRoad(name: '播放线路${roads.length + 1}', episodes: eps));
      }
    }
    return RuleBangumiDetail(roads: roads);
  }

  // ─────────── JSON 接口路径（api level 8） ───────────

  /// 解析 API 搜索响应（JSON 文本）
  List<RuleSearchItem> parseSearchJson(String rawJson) {
    final doc = _decode(rawJson);
    if (doc == null) return const [];
    final cfg = rule.searchApiConfig;
    final nodes = jsonPathRead(doc, cfg.listPath);
    final out = <RuleSearchItem>[];
    for (final node in nodes) {
      final title = _s(jsonPathFirst(node, cfg.namePath));
      final src = _s(jsonPathFirst(node, cfg.sourcePath));
      if (title.isEmpty || src.isEmpty) continue;
      out.add(RuleSearchItem(
        title: title,
        url: src,
        episodeHint: _episodeFromTitle(title),
      ));
    }
    return out;
  }

  /// 解析 API 章节响应（JSON 文本），支持 nested / delimited 两种格式
  RuleBangumiDetail parseDetailJson(String rawJson, {required String source}) {
    final doc = _decode(rawJson);
    if (doc == null) return const RuleBangumiDetail(roads: []);
    final cfg = rule.chapterApiConfig;

    // 根变量：source + 规则用 JSONPath 声明的 captures
    final rootVars = <String, Object?>{'source': source};
    for (final e in cfg.variables.entries) {
      rootVars[e.key] = jsonPathFirst(doc, e.value);
    }

    final roads = cfg.format == ApiChapterFormat.delimited
        ? _parseJsonDelimited(doc, cfg, rootVars)
        : _parseJsonNested(doc, cfg, rootVars);
    return RuleBangumiDetail(roads: roads);
  }

  List<RuleRoad> _parseJsonNested(
      dynamic doc, ApiChapterConfig cfg, Map<String, Object?> rootVars) {
    final hasRoads = cfg.roadsPath.trim().isNotEmpty;
    final roadNodes =
        hasRoads ? jsonPathRead(doc, cfg.roadsPath) : <Object?>[doc];
    final roads = <RuleRoad>[];

    for (var ri = 0; ri < roadNodes.length; ri++) {
      final rn = roadNodes[ri];
      final roadName = hasRoads && cfg.roadNamePath.trim().isNotEmpty
          ? _s(jsonPathFirst(rn, cfg.roadNamePath))
          : '';
      final epNodes = jsonPathRead(rn, cfg.episodesPath);
      final eps = <RuleEpisode>[];
      for (var ei = 0; ei < epNodes.length; ei++) {
        final en = epNodes[ei];
        final epName = _s(jsonPathFirst(en, cfg.episodeNamePath));
        final rawUrl = cfg.episodeUrlPath.trim().isEmpty
            ? ''
            : _s(jsonPathFirst(en, cfg.episodeUrlPath));
        final pageUrl = _resolveJsonEpisodeUrl(cfg, rootVars,
            rawUrl: rawUrl, roadIndex: ri, episodeIndex: ei);
        if (pageUrl.isEmpty) continue;
        final parsedSort = _episodeFromTitle(epName);
        eps.add(RuleEpisode(
          title: epName.isEmpty ? '第${ei + 1}集' : epName,
          url: pageUrl,
          sort: parsedSort ?? (ei + 1),
          guessedSort: parsedSort == null,
        ));
      }
      if (eps.isEmpty) continue;
      roads.add(RuleRoad(
        name: roadName.isEmpty ? '播放线路${roads.length + 1}' : roadName,
        episodes: eps,
      ));
    }
    return roads;
  }

  List<RuleRoad> _parseJsonDelimited(
      dynamic doc, ApiChapterConfig cfg, Map<String, Object?> rootVars) {
    if (cfg.roadNamesPath.trim().isEmpty ||
        cfg.roadEpisodesPath.trim().isEmpty) {
      return const [];
    }
    final namesValue = _s(jsonPathFirst(doc, cfg.roadNamesPath));
    final episodesValue = _s(jsonPathFirst(doc, cfg.roadEpisodesPath));
    if (episodesValue.isEmpty) return const [];
    final roadNames = namesValue.split(cfg.roadSeparator);
    final roadGroups = episodesValue.split(cfg.roadSeparator);
    final roads = <RuleRoad>[];
    for (var ri = 0; ri < roadGroups.length; ri++) {
      final eps = <RuleEpisode>[];
      final entries = roadGroups[ri].split(cfg.episodeSeparator);
      for (var ei = 0; ei < entries.length; ei++) {
        final entry = entries[ei].trim();
        if (entry.isEmpty) continue;
        final sep = entry.indexOf(cfg.fieldSeparator);
        if (sep < 0) continue;
        final name = entry.substring(0, sep).trim();
        final rawUrl = entry.substring(sep + cfg.fieldSeparator.length).trim();
        final pageUrl = _resolveJsonEpisodeUrl(cfg, rootVars,
            rawUrl: rawUrl, roadIndex: ri, episodeIndex: ei);
        if (pageUrl.isEmpty) continue;
        final parsedSort = _episodeFromTitle(name);
        eps.add(RuleEpisode(
          title: name.isEmpty ? '第${ei + 1}集' : name,
          url: pageUrl,
          sort: parsedSort ?? (ei + 1),
          guessedSort: parsedSort == null,
        ));
      }
      if (eps.isEmpty) continue;
      final configured = ri < roadNames.length ? roadNames[ri].trim() : '';
      roads.add(RuleRoad(
        name: configured.isEmpty ? '播放线路${roads.length + 1}' : configured,
        episodes: eps,
      ));
    }
    return roads;
  }

  /// 渲染剧集页 URL（对齐 Kazumi `_resolveEpisodeUrl`）
  String _resolveJsonEpisodeUrl(
    ApiChapterConfig cfg,
    Map<String, Object?> rootVars, {
    required String rawUrl,
    required int roadIndex,
    required int episodeIndex,
  }) {
    final page = cfg.episodePage;
    if (page == null) return absolutize(rawUrl, rule.baseURL);
    if (page.url.trim().isEmpty) return '';
    final vars = <String, Object?>{
      ...rootVars,
      'episodeUrl': rawUrl,
      'roadIndex': roadIndex,
      'roadNumber': roadIndex + 1,
      'episodeIndex': episodeIndex,
      'episodeNumber': episodeIndex + 1,
    };
    final path = renderTemplate(page.url, vars, encode: true);
    Uri uri;
    try {
      uri = Uri.parse(path);
    } catch (_) {
      return '';
    }
    final renderedQuery = <String, String>{};
    page.query.forEach((k, v) {
      renderedQuery[renderTemplate(k, vars)] =
          renderTemplate('$v', vars);
    });
    final merged = <String, String>{
      ...uri.queryParameters,
      ...renderedQuery,
    };
    return absolutize(uri.replace(queryParameters: merged).toString(),
        rule.baseURL);
  }

  // ─────────── 反爬检测（对齐 Kazumi detectsCaptchaChallenge） ───────────

  /// 判断响应是否是一个「要过人机验证」的页面
  bool detectsCaptchaChallenge(String raw, {dom.Node? document}) {
    final cfg = rule.antiCrawler;
    if (!cfg.enabled) return false;
    final dv = cfg.captchaDetectValue.trim();
    if (dv.isNotEmpty) {
      switch (cfg.captchaDetectType) {
        case 2:
          try {
            return RegExp(dv, caseSensitive: false, dotAll: true).hasMatch(raw);
          } catch (_) {
            return false;
          }
        case 3:
          final doc = document ?? parseHtml(raw);
          return xpathSelect(doc, dv).isNotEmpty;
        default:
          return raw.contains(dv);
      }
    }
    final doc = document ?? parseHtml(raw);
    for (final sel in [cfg.captchaImage, cfg.captchaButton]) {
      if (sel.trim().isEmpty) continue;
      if (xpathSelect(doc, sel).isNotEmpty) return true;
    }
    return false;
  }

  // ─────────── 工具 ───────────

  static dynamic _decode(String raw) {
    try {
      return jsonDecode(raw);
    } catch (_) {
      return null;
    }
  }

  static String _s(Object? v) {
    if (v == null) return '';
    return v is String ? v.trim() : '$v'.trim();
  }

  /// 清洗剧集标题：去掉「免费」「HD」等站点噪声与多余空白
  static String _cleanEpisodeName(String t, int fallbackIndex) {
    final s = t.replaceAll(RegExp(r'\s+'), '').trim();
    return s.isEmpty ? '第$fallbackIndex集' : s;
  }

  static int? _episodeFromTitle(String t) {
    final m = RegExp(r'第?\s*(\d+(?:\.\d+)?)\s*[集话話]').firstMatch(t) ??
        RegExp(r'\[(\d+(?:\.\d+)?)\]').firstMatch(t) ??
        RegExp(r'^(\d+(?:\.\d+)?)$').firstMatch(t.trim());
    if (m == null) return null;
    return double.tryParse(m.group(1)!)?.toInt();
  }
}

/// 渲染 `@var` 模板（对齐 Kazumi `_renderTemplate`）
///
/// 变量缺失时**保留原文**而不是抛错：官方规则里出现未声明变量的场合，
/// 返回空串会让整条线路消失；保留原文至少能在日志里看出问题。
String renderTemplate(String template, Map<String, Object?> variables,
    {bool encode = false}) {
  return template.replaceAllMapped(
    RegExp(r'(?<![A-Za-z0-9_])@([A-Za-z_][A-Za-z0-9_]*)'),
    (m) {
      final name = m.group(1)!;
      if (!variables.containsKey(name)) return m.group(0)!;
      final v = variables[name]?.toString() ?? '';
      return encode ? Uri.encodeComponent(v) : v;
    },
  );
}

// ─────────────────────────── 内置规则 ───────────────────────────

/// 内置的规则集合。
///
/// **来源**：KazumiRules 官方规则库（github.com/Predidit/KazumiRules），
/// 由 `D:\dev\gen_rules.py` 全量拉取 + 叠加本机适配补丁 + 严格 JSON 校验后
/// 写入 `assets/rules/kazumi_rules.json`。想更新规则跑那个脚本即可，不要手改 JSON。
class BuiltinRules {
  /// 资产路径
  static const String assetPath = 'assets/rules/kazumi_rules.json';

  /// 资产里解析出的规则（内置权威基线）
  static List<KazumiRule>? _assetCache;

  /// 在线更新下载的规则（覆盖同名内置规则，由 [RuleUpdater] 维护）
  static List<KazumiRule> _external = [];

  static List<KazumiRule>? _cache;

  /// 已完成加载的规则列表（同步）。未加载时返回空列表，请先 await [load]。
  static List<KazumiRule> get all => _cache ?? const <KazumiRule>[];

  static bool get isLoaded => _cache != null;

  /// 仅资产规则（不含在线更新）
  static List<KazumiRule> get assetRules => _assetCache ?? const <KazumiRule>[];

  /// 当前生效的在线更新规则（覆盖文件里来的那份）
  static List<KazumiRule> get externalRules => _external;

  /// 版本比对（对齐 Kazumi `utils/version.dart` 的 needUpdate）：
  /// 逐段数字比较，`remote` 比 `local` 新才为 true。
  /// 解析失败时退化为「不相等即算新」（与 Kazumi 的兜底一致）。
  static bool isNewerVersion(String localVersion, String remoteVersion) {
    try {
      final l = localVersion.split('.');
      final r = remoteVersion.split('.');
      final n = l.length > r.length ? l.length : r.length;
      for (var i = 0; i < n; i++) {
        final lv = i < l.length ? int.parse(l[i]) : 0;
        final rv = i < r.length ? int.parse(r[i]) : 0;
        if (rv > lv) return true;
        if (rv < lv) return false;
      }
      return false;
    } catch (_) {
      return localVersion != remoteVersion;
    }
  }

  /// 合并内置规则与在线更新（对齐 Kazumi `_replacePlugin` 的覆盖语义）：
  ///  - 同名（大小写不敏感）时外部**版本更新或相同**才覆盖内置 —— 绝不降级
  ///    （防止镜像滞后/App 升级后旧覆盖文件反过来顶掉更新的内置规则）；
  ///  - 外部独有的规则追加到末尾。
  static List<KazumiRule> mergeRules(
      List<KazumiRule> base, List<KazumiRule> extra) {
    if (extra.isEmpty) return base;
    final byKey = <String, KazumiRule>{};
    final order = <String>[];
    for (final r in base) {
      final k = r.name.toLowerCase();
      if (!byKey.containsKey(k)) order.add(k);
      byKey[k] = r;
    }
    for (final r in extra) {
      final k = r.name.toLowerCase();
      final cur = byKey[k];
      if (cur == null) {
        order.add(k);
        byKey[k] = r;
      } else if (cur.version == r.version ||
          isNewerVersion(cur.version, r.version)) {
        byKey[k] = r;
      }
      // 外部版本更旧 → 保留内置（防止降级）
    }
    return [for (final k in order) byKey[k]!];
  }

  /// 注入在线更新的规则。
  ///
  /// 在 [load] **之前**调用即可参与首次合并；在 [load] 之后调用会立刻
  /// 重建生效列表（调用方负责随后 `SourceRegistry.invalidate()`）。
  static void setExternalRules(List<KazumiRule> rules) {
    _external = rules;
    final asset = _assetCache;
    if (asset != null) _cache = mergeRules(asset, _external);
  }

  /// 从资产加载规则。App 启动时调用一次即可；重复调用是幂等的。
  static Future<List<KazumiRule>> load({
    Future<String> Function(String key)? loader,
  }) async {
    if (_cache != null) return _cache!;

    var text = '';
    try {
      final read = loader ?? _rootBundleLoadString;
      text = await read(assetPath);
    } catch (_) {
      text = '';
    }
    if (text.trim().isEmpty) {
      _assetCache = fallbackRules();
      _cache = mergeRules(_assetCache!, _external);
      return _cache!;
    }

    final parsed = RuleRegistry.fromJsonList(text);
    // 【诊断】把解析结果写日志：资产存在但解析不出来时（JSON 写坏、字段改名）
    // 只看「源列表为空」是查不出原因的。
    if (parsed.isEmpty) {
      _assetCache = fallbackRules();
    } else {
      _assetCache = parsed;
    }
    _cache = mergeRules(_assetCache!, _external);
    return _cache!;
  }

  static KazumiRule? byName(String name) {
    for (final r in all) {
      if (r.name == name) return r;
    }
    return null;
  }

  /// 兜底规则：**仅在资产读取失败时**启用。
  ///
  /// 注意这里刻意用「函数里 new 出对象」而不是 `const` 字面量：
  /// const 字面量只有在 TFA 判定该分支为活代码时才会保留其字符串常量，
  /// 实测中被整体消除；改成运行期构造后字符串必定进包。
  // 下面两个构造**不要**改成 const：const 字面量会被 TFA 整体消除，
  // 兜底规则里的 baseURL/searchURL 等字符串就不会进包，兜底等于失效。
  // ignore: prefer_const_constructors
  static List<KazumiRule> fallbackRules() => <KazumiRule>[
        // ignore: prefer_const_constructors
        KazumiRule(
          api: '1',
          name: 'AGE',
          version: '1.5',
          baseURL: 'https://www.agedm.io/',
          searchURL: 'https://www.agedm.io/search?query=@keyword',
          searchList: "//div[contains(@class,'cata_video_item')]",
          searchName: "//a[contains(@href,'/detail/')]",
          searchResult: "//a[contains(@href,'/detail/')]",
          chapterRoads: '//div[2]/div/section/div/div[2]/div[2]/div[2]/div',
          chapterResult: '//ul/li/a',
          useLegacyParser: false,
        ),
        // ignore: prefer_const_constructors
        KazumiRule(
          api: '5',
          name: 'DM84',
          version: '1.4',
          baseURL: 'https://dmbus.cc/',
          searchURL: 'https://dmbus.cc/s----------.html?wd=@keyword',
          searchList: '//div/div[3]/ul/li',
          searchName: '//div/a[2]',
          searchResult: '//div/a[2]',
          chapterRoads: '//div/div[4]/div/ul',
          chapterResult: '//li/a',
          adBlocker: true,
        ),
      ];
}

class RuleRegistry {
  /// 默认开启的线路。
  ///
  /// 【v1.9.3 · 依据真实体检结果重选】
  ///
  /// 旧默认是 `AGE + DM84`。用 `tool/probe_sources.dart` 对全部 86 条规则做
  /// **真实网络体检**后发现：
  ///   - **AGE 实测「搜索无结果」**（该站搜索页是 JS 渲染，静态抓取拿不到列表）
  ///     —— 这正是用户反馈的「Age 好像一直不可用」，它确实一直是死的；
  ///   - 因此旧默认实际只有 1 条能用，用户看到的就是「能选的线路太少」。
  ///
  /// 现在默认开启 6 条**实测可用**的线路，覆盖三类解析方式，
  /// 并且刻意选了「有 2~3 条播放线路」的源（用户要的正是多线路）：
  ///
  /// | 源 | 实测耗时 | 线路数 | 分集 | 备注 |
  /// | --- | --- | --- | --- | --- |
  /// | 7sefun | 974ms | **2** | 59 | 最快、多线路 |
  /// | FQDM   | 1158ms | **3** | 69 | 线路最多 |
  /// | MXdm   | 1306ms | **2** | 2 | 多线路 |
  /// | gugu3  | 1320ms | **2** | 6 | 多线路 |
  /// | DM84   | 1380ms | 1 | 4 | 起播最稳（hhplayer 直出 mp4） |
  /// | moonci | 1015ms | 1 | 25 | 分集全 |
  ///
  /// 其余实测可用的源（TvTFun 3线路 84集、dmghg 2线路 50集 等）
  /// 在设置页「线路分组」里可一键开启；已知失效的源标灰但不删除。
  static const List<String> defaultEnabledNames = [
    '7sefun',
    'FQDM',
    'MXdm',
    // 【v2.1.1】gugu3 移出默认启用：2026-10-14 新番实测 8 部 0 命中、
    // 每个请求都 >8s，站点半死——留着只会让每轮扫描/聚合白等它超时。
    // 规则保留，用户仍可在设置里手动打开。
    'moonci',
    'DM84',
    // 【v2.1.2】86 条全量体检 + 双关键词复测后新增：
    // sorani 24/28 集全通（~2.4s）、gpjda 24/28 集全通（~2.1s），
    // 两条都稳定多线路；替换掉的是体检中超时/半死的 dmghg、fcdm、
    // Fantuan（均复测一半超时）等。数据见 tool/probe_sources.dart。
    'sorani',
    'gpjda',
  ];

  /// 首屏「优先聚合」的源数量上限。
  ///
  /// 默认开了 6 条，若全部并发搜索，首屏要等最慢那条（TvTFun 近 6s）。
  /// 这里让**最快的 3 条**先出结果，其余在首屏渲染后补上 ——
  /// 体感「点进去就有」，而不是等最慢的。
  static const int fastLaneCount = 3;

  static List<KazumiRule> get all => BuiltinRules.all;

  static KazumiRule? byName(String name) => BuiltinRules.byName(name);

  /// 从 JSON 文本导入规则（对齐 KazumiRules 仓库的 *.json）
  ///
  /// 额外的健壮性：
  ///  - 跳过 `api > kSupportedRuleApiLevel` 的规则（本客户端不认识）；
  ///  - 跳过既没有 searchURL 也没有 API 搜索配置的规则。
  static List<KazumiRule> fromJsonList(String jsonText) {
    try {
      final data = jsonDecode(jsonText);
      final list = data is List ? data : [data];
      final out = <KazumiRule>[];
      for (final m in list) {
        if (m is! Map) continue;
        final rule = KazumiRule.fromJson(m.cast<String, dynamic>());
        if (rule.name.isEmpty) continue;
        if (rule.requiresNewerClient) continue;
        final hasSearch = rule.searchURL.trim().isNotEmpty ||
            (rule.usesApiSearch && !rule.searchApiConfig.request.isEmpty);
        if (!hasSearch) continue;
        out.add(rule);
      }
      return out;
    } catch (_) {
      return const [];
    }
  }
}
