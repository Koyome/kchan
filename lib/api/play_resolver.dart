/// 播放地址解析引擎
///
/// 背景（实测结论，很重要）：
/// 国内几乎所有番剧源（AGE/libvio/aafun…）的播放页都只是**外壳**，
/// 真正地址由一个 jx 云播放器（artplayer + hls.js）在**运行时用 JS 取回**。
/// 典型证据：播放器页的内联脚本里写着 `var Vurl = '';` —— HTML 里是空的，
/// 必须由 JS 填。所以**纯 HTTP 抓取拿不到地址，必须用 WebView 跑 JS**。
/// 这正是 Kazumi 用 `useWebview: true` 的原因。
///
/// 本文件提供三层解析策略（由快到慢，逐个回退）：
///   1. [DirectHttpResolver]  纯 HTTP：部分站点把 m3u8 直接写在页面里（最省事）
///   2. [WebViewResolver]     用 WebView 加载播放页/播放器页，拦截媒体请求（主路径）
///   3. [ManualResolver]      前面都失败时，把播放器页交给用户手动播放（兜底）
///
/// 【实测已验证】用 WebView 加载 jx 播放器 URL（作为顶层文档）后，
/// 能拿到形如 `https://vip.ffzy-plays.com/.../index.m3u8` 的真实地址，
/// 且该 m3u8 与其 ts 分片均可正常下载（video/mp2t）。
library;

import 'dart:async';
import 'dart:convert';

import 'diag_log.dart';
import 'package:http/http.dart' as http;

import 'kazumi_rules.dart';

/// JS 反爬闸门钩子（由 Flutter 侧 js_gate.dart 注入）。
///
/// 纯 Dart 环境（vfy 验证工程）没有 WebView/Edge，钩子为 null，
/// 此时 [gateAwareGet] 退化为普通 HTTP + 原样返回 —— 行为与旧版一致。
Future<String?> Function(String url, {String referer})? jsGateHook;

/// 同域 cookie 供给（由 Flutter 侧 js_gate.dart 的 GateCookies 注入）
String? Function(String url)? gateCookieFor;

/// 判断响应是否 JS 反爬闸门页（与 js_gate.dart 的判定保持一致的精简版）
bool looksLikeGatePage(String html) {
  final h = html.trim();
  if (h.contains('/_guard/')) return true;
  if (h.contains('Security Check') && h.length < 4000) return true;
  if (h.length < 600 && h.contains('<script') && !h.contains('<div')) {
    return true;
  }
  return false;
}

/// 带反爬闸门的 HTML 抓取：
/// 自动带同域 cookie；命中闸门页时调用 [jsGateHook] 用浏览器内核解锁。
Future<String> gateAwareGet(
  String url,
  Future<String> Function(Map<String, String> headers) doGet,
  Map<String, String> headers,
) async {
  final h = <String, String>{...headers};
  final ck = gateCookieFor?.call(url);
  if (ck != null && ck.isNotEmpty && !h.containsKey('Cookie')) {
    h['Cookie'] = ck;
  }
  final html = await doGet(h);
  final hook = jsGateHook;
  if (hook == null || !looksLikeGatePage(html)) return html;
  kLog('[Resolver] 检测到 JS 闸门，尝试浏览器解锁: $url');
  final rendered = await hook(url, referer: h['Referer'] ?? '');
  return rendered ?? html;
}

/// 解析出的可播信息
class ResolvedStream {
  final String url;
  final String type; // application/x-mpegURL | video/mp4
  final Map<String, String> headers;

  /// 来源说明（UI 上给用户看，便于判断是否走了兜底）
  final String via;

  /// 若需要用户手动点一下（兜底路径），这里是那个播放器页地址
  final String? manualPageUrl;

  /// 【v1.8.0】CDN 注入的广告分片区间（毫秒）：(开始, 结束)
  ///
  /// 实测这些资源站会在 m3u8 里**插入一整块广告分片**（播放列表带
  /// `# ppvod-ad-injected` 标记，广告块被两个 `#EXT-X-DISCONTINUITY` 夹住，
  /// 且片段时长整齐划一）。这块是**独立内容**，跳过它不会跳过正片 ——
  /// Kazumi 规则里的 `adBlocker` 干的就是这件事。
  final List<({int startMs, int endMs})> adRanges;

  const ResolvedStream({
    required this.url,
    this.type = 'video/mp4',
    this.headers = const {},
    this.via = '',
    this.manualPageUrl,
    this.adRanges = const [],
  });

  bool get isHls =>
      type.toLowerCase().contains('mpegurl') ||
      url.toLowerCase().contains('.m3u8');

  bool get isEmpty => url.isEmpty;
}

/// 给解析结果补上「注入广告区间」（仅 HLS；是否启用由调用方判断）
Future<ResolvedStream> withAdRanges(ResolvedStream s, String referer) async {
  if (!s.isHls) return s;
  final ranges = await scanInjectedAds(s.url, {
    ...s.headers,
    if (referer.isNotEmpty && !s.headers.containsKey('Referer')) 'Referer': referer,
  });
  if (ranges.isEmpty) return s;
  return ResolvedStream(
    url: s.url,
    type: s.type,
    headers: s.headers,
    via: s.via,
    manualPageUrl: s.manualPageUrl,
    adRanges: ranges,
  );
}

/// 【v1.8.0 · 对齐 Kazumi 的 adBlocker】扫描 HLS 播放列表里的**注入广告块**。
///
/// 背景（实测）：资源站 CDN 会在原片的 m3u8 里插一整块广告分片：
///   - 播放列表里出现 `# ppvod-ad-injected` 之类的注入标记；
///   - 广告块被两个 `#EXT-X-DISCONTINUITY` 夹住；
///   - 广告块的片段时长**整齐划一**（实测全是 4.000s），而正片片段时长参差。
///
/// 返回广告块的时间区间（毫秒）。解析不了就返回空列表（不折腾、照常播）。
Future<List<({int startMs, int endMs})>> scanInjectedAds(
  String playlistUrl,
  Map<String, String> headers, {
  int depth = 0,
}) async {
  if (depth > 1) return const []; // 主列表只下钻一层，避免循环引用
  final client = http.Client();
  try {
    final res = await client
        .get(Uri.parse(playlistUrl), headers: headers)
        .timeout(const Duration(seconds: 3));
    if (res.statusCode != 200) return const [];
    final text = utf8.decode(res.bodyBytes, allowMalformed: true);

    // ① 可能是多码率主列表：取其中的子列表再扫一次（只下钻一层）
    // 主播放列表里只有 #EXT-X-STREAM-INF → 这是一个「主列表」，
    // 真正的分片列表在它指向的子 m3u8 里，递归一层去扫。
    //
    // 【v2.0.0 修】这里原来写的是 `return scanInjectedAds(...)`（漏了 await）。
    // 在 async 函数里直接 return 一个 Future 虽然语义上等价于 await，
    // 但外层包在 try/catch 里时，异常不会被这个 catch 捕获，
    // 且静态分析会报 unawaited_return_in_try_block —— 属于隐患，补上 await。
    if (!text.contains('#EXTINF') && text.contains('#EXT-X-STREAM-INF')) {
      final m = RegExp(r'^\s*([^\s#][^\s]*\.m3u8[^\s]*)', caseSensitive: false)
          .firstMatch(text);
      if (m != null) {
        final sub = Uri.parse(playlistUrl).resolve(m.group(1)!).toString();
        return await scanInjectedAds(sub, headers, depth: depth + 1);
      }
      return const [];
    }

    final lines = text
        .split(RegExp(r'\r?\n'))
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();

    // 解析成 (时长秒, 是否紧跟 DISCONTINUITY)
    final segs = <({double dur, bool disc})>[];
    var pendingDisc = false;
    for (final l in lines) {
      if (l.startsWith('#EXT-X-DISCONTINUITY')) {
        pendingDisc = true;
        continue;
      }
      if (l.startsWith('#EXTINF')) {
        final d = double.tryParse(l.split(':')[1].split(',')[0]) ?? 0;
        segs.add((dur: d, disc: pendingDisc));
        pendingDisc = false;
      }
    }
    if (segs.isEmpty) return const [];

    final injected = text.toLowerCase().contains('ad-injected') ||
        text.toLowerCase().contains('ad-insert') ||
        text.toLowerCase().contains('sponsor');

    // ② 找出「被 DISCONTINUITY 包起来的块」：从带 disc 标记的片段开始，
    //    到下一个带 disc 标记的片段之前结束。
    final marks = <int>[];
    for (var i = 0; i < segs.length; i++) {
      if (segs[i].disc) marks.add(i);
    }
    if (marks.length < 2 && !injected) return const [];

    final ranges = <({int startMs, int endMs})>[];
    var acc = 0.0;
    final startAt = <double>[];
    for (final s in segs) {
      startAt.add(acc);
      acc += s.dur;
    }
    for (var k = 0; k + 1 < marks.length; k++) {
      final a = marks[k], b = marks[k + 1];
      final chunk = segs.sublist(a, b);
      if (chunk.length < 2 || chunk.length > 40) continue;
      // 判据：时长整齐（最大值-最小值 < 0.05s）→ 典型的广告切片
      var mn = 1e9, mx = -1e9;
      for (final c in chunk) {
        if (c.dur < mn) mn = c.dur;
        if (c.dur > mx) mx = c.dur;
      }
      final uniform = (mx - mn) < 0.05;
      if (!uniform && !injected) continue;
      final st = startAt[a], en = startAt[b];
      if (en - st < 1) continue;
      ranges.add((
        startMs: (st * 1000).round(),
        endMs: (en * 1000).round(),
      ));
    }
    if (ranges.isNotEmpty) {
      kLog('[广告] 播放列表含注入广告 ${ranges.length} 段: '
          '${ranges.map((r) => '${(r.startMs / 1000).toStringAsFixed(1)}~${(r.endMs / 1000).toStringAsFixed(1)}s').join(', ')}');
    }
    return ranges;
  } catch (_) {
    return const [];
  } finally {
    client.close();
  }
}

/// 解析失败时抛这个，带可读原因
class ResolveException implements Exception {
  final String message;
  final String detail;
  const ResolveException(this.message, {this.detail = ''});
  @override
  String toString() => detail.isEmpty ? message : '$message（$detail）';
}

const _uaDesktop =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';
const _uaMobile =
    'Mozilla/5.0 (Linux; Android 13; Pixel 6) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36';

/// 媒体地址识别：命中即认为是真实播放流
///
/// 【务必用三引号 raw string】
///  单引号 raw string 里写 `\'` 不是转义（raw 会把反斜杠原样保留），
///  于是那个引号提前把字符串结束掉，剩下的片段变成一个残缺的字符类，
///  运行期直接抛 `FormatException: Unterminated character class`——
///  实测就是它导致 MXdm 等源「解析必定失败」。
final _mediaRe = RegExp(
  r'''https?://[^\s"'<>\\]+?\.(?:m3u8|mp4|flv)(?:\?[^\s"'<>\\]*)?''',
  caseSensitive: false,
);

/// 明显不是正文视频的地址（广告、统计、图片）
bool _isNoise(String u) {
  final l = u.toLowerCase();
  const bad = [
    'baidu.com',
    'hm.js',
    'google-analytics',
    'googletagmanager',
    'doubleclick',
    '.gif',
    '.png',
    '.jpg',
    '.jpeg',
    '.webp',
    '.svg',
    '.css',
    '.woff',
  ];
  for (final b in bad) {
    if (l.contains(b)) return true;
  }
  return false;
}

/// 这个地址是不是**广告视频**（而不是正片）。
///
/// 【v1.9.3 · 提升为模块级并同时用于两条路径】
/// 原先是 `resolve()` 里的局部函数，**只对「纯 HTTP 命中」做了过滤**，
/// WebView 命中的结果完全没过滤。实测后果（星际牛仔那一次）：
///   正片地址还没嗅探到，先来的 `v1.adkwai.com/.../adVideoLp/....mp4`
///   被当成命中直接返回并起播 → **用户看到的是广告**。
/// 现在两条路径共用同一个判定。
bool looksLikeAdUrl(String u) {
  final l = u.toLowerCase();
  return l.contains('adkwai') ||
      l.contains('advideo') ||
      l.contains('ad-video') ||
      l.contains('/ad/') ||
      l.contains('ggad') ||
      l.contains('advert') ||
      l.contains('admaster') ||
      l.contains('/ads/');
}

/// 从任意文本里扫出媒体地址（兜底用）
List<String> scanMedia(String text) {
  final out = <String>[];
  for (final m in _mediaRe.allMatches(text)) {
    final u = m.group(0)!;
    if (!_isNoise(u)) out.add(u);
  }
  return out;
}

/// 【对齐 Kazumi `utils/media.dart` 的 decodeVideoSource】
///
/// legacy（api=1）源的播放页里挂一个 `<iframe src="播放器页?url=真实地址">`，
/// 真实 m3u8/mp4 就藏在 **iframe 地址的 query 参数**里（URL 编码过）。
/// 例：AGE 的 `https://xxx/play/?url=https%3A%2F%2F...%2Findex.m3u8`。
///
/// 规则：URL decode 后逐个检查 query 参数值，命中 `.m3u8`/`.mp4` 即取出；
/// 没有命中则原样返回（调用方据此判断是否解出了东西）。
String decodeVideoSource(String iframeUrl) {
  final decoded = Uri.decodeFull(iframeUrl);
  final re = RegExp(
    r'(https?://.*?\.m3u8)|(https?://.*?\.mp4)',
    caseSensitive: false,
  );
  Uri? uri;
  try {
    uri = Uri.parse(decoded);
  } catch (_) {
    return iframeUrl;
  }
  var matched = iframeUrl;
  uri.queryParameters.forEach((_, value) {
    if (re.hasMatch(value)) matched = value;
  });
  return Uri.encodeFull(matched);
}

/// 判断某 URL 的 query 参数里是否藏有直链（decodeVideoSource 是否会有产出）
bool hasNestedVideoSource(String url) => decodeVideoSource(url) != url;

// ───────────────────────── 策略 1：纯 HTTP ─────────────────────────

/// 纯 HTTP 解析：适合把直链写死在页面里的源。
///
/// 【最重要的解析路径】苹果 CMS（MacCMS）系站点，播放页里有：
///
/// ```html
/// <script>var player_aaaa={"flag":"play","encrypt":0,"url":"https://.../index.m3u8",
///                          "url_next":"...","from":"dyttm3u8","id":"12271","sid":3,"nid":1}</script>
/// ```
///
/// `url` 就是**明文 m3u8**。这类源（实测：9ciyuan / FQDM / MXdm / akun…）
/// 完全不需要 WebView —— 直接正则抓 JSON 即可，最快最稳。
class DirectHttpResolver {
  final http.Client _c = http.Client();

  /// 从 HTML 里抓 `player_aaaa` / `player_xxx` 之类的播放器配置 JSON。
  /// 返回其中的直链（可能为 null）。
  static Map<String, dynamic>? extractPlayerConfig(String html) {
    // 变量名可能是 player_aaaa / player_bbb / player_1 …，统一抓
    final re = RegExp(
      r'''player_\w+\s*=\s*(\{.*?\})\s*(?:;|</script>|\n)''',
      caseSensitive: false,
      dotAll: true,
    );
    final m = re.firstMatch(html);
    if (m == null) return null;
    var raw = m.group(1)!;
    // JS 对象不是严格 JSON：单引号、转义斜杠、尾逗号都可能出现
    raw = raw.replaceAll(r'\/', '/');
    raw = raw.replaceAll("'", '"');
    raw = raw.replaceAll(RegExp(r',\s*([}\]])'), r'$1');
    try {
      final j = jsonDecode(raw);
      if (j is Map) return j.cast<String, dynamic>();
    } catch (_) {}
    // 退一步：只抠 url 字段
    final um = RegExp(r'''"?url"?\s*:\s*["']([^"']+)["']''').firstMatch(raw);
    if (um != null) return {'url': um.group(1)!.replaceAll(r'\/', '/')};
    return null;
  }

  /// 从任意 HTML 里找 `var Vurl = '...'` 这类变量（jx 播放器用，HTML 里通常是空串）
  static String? extractVurl(String html) {
    final m = RegExp(
      r'''(?:var\s+)?(?:Vurl|vurl|videoUrl)\s*=\s*["']([^"']{8,})["']''',
      caseSensitive: false,
    ).firstMatch(html);
    return m?.group(1);
  }

  /// 【实测新增】解码 `player_aaaa.url` 里被加密/编码过的真实地址。
  ///
  /// 实测案例（anime7，`anime7.top`）：
  ///   `player_aaaa.url` = `JTY4JTc0JTc0JTcwJTcz...`
  ///   ① 它是 **base64** → 解出 `%68%74%74%70%73%3A%2F%2F...`
  ///   ② 再 **percent-decode** → `https://vip.dytt-cinema.com/.../index.m3u8`
  ///
  /// 如果不做这一步，anime7 会被误判成「需要 WebView」，白白多一层解析；
  /// 解码后它是纯 HTTP 直链，可以直接播（快且稳）。
  ///
  /// 另有部分源用普通 `escape()`/`encodeURIComponent`（`%68%74...` 直接可见），
  /// 所以这里把「base64 → 百分号解码」做成最多 3 轮的幂等循环。
  static String decodePlayerUrl(String raw) {
    var v = raw.trim();
    if (v.isEmpty) return v;

    for (var round = 0; round < 3; round++) {
      // ① 看起来是 base64 就先解 base64
      if (RegExp(r'^[A-Za-z0-9+/]{16,}={0,2}$').hasMatch(v) &&
          !v.startsWith('http')) {
        try {
          final bytes = base64.decode(base64.normalize(v));
          final decoded = utf8.decode(bytes, allowMalformed: true);
          if (decoded != v && decoded.isNotEmpty) {
            v = decoded;
            continue;
          }
        } catch (_) {
          // 不是合法 base64，继续往下走
        }
      }
      // ② 百分号编码（%68%74%74%70...）
      if (v.contains('%')) {
        try {
          final d = Uri.decodeFull(v);
          if (d != v) {
            v = d;
            continue;
          }
        } catch (_) {
          try {
            final d = Uri.decodeComponent(v);
            if (d != v) {
              v = d;
              continue;
            }
          } catch (_) {}
        }
      }
      break; // 没有可再解的了
    }
    return v;
  }

  /// 判断 URL 是否像媒体流（而非 HTML 播放页）。
  ///
  /// 【实测依据】苹果CMS 的 `player_aaaa.url` 有两种形态：
  ///   A. 直链：`https://cdn…/index.m3u8?hash=…`（可直接播）
  ///   B. 二级播放页：`https://www.lmm85.com/play/6067_1_1.html`（HTML，必须再处理）
  /// 旧代码不区分，B 会被当 video/mp4 交给播放器导致初始化必败。
  static bool looksLikeMedia(String u) {
    return RegExp(r'\.(m3u8|mp4|flv|m4s|ts)(?:[?#]|$)', caseSensitive: false)
        .hasMatch(u);
  }

  /// 抓取「二级播放页」并尝试扫出直链（只下钻一层，防死循环）。
  ///
  /// 返回 null 表示该页面也没有明文直链（典型：jx 云播 iframe，需 WebView）。
  Future<ResolvedStream?> _scanNestedPlayer(String pageUrl, String referer) async {
    try {
      final html = await gateAwareGet(pageUrl, (headers) async {
        final res = await _c
            .get(Uri.parse(pageUrl), headers: headers)
            .timeout(const Duration(seconds: 12));
        return utf8.decode(res.bodyBytes, allowMalformed: true);
      }, {
        'User-Agent': _uaDesktop,
        'Accept-Language': 'zh-CN,zh;q=0.9',
        if (referer.isNotEmpty) 'Referer': referer,
      });

      // 二级页自己也可能带 player_aaaa 配置（如 lmm85：from=vxdev，url 为 token）
      final cfg = extractPlayerConfig(html);
      if (cfg != null) {
        final u2 = decodePlayerUrl((cfg['url'] ?? '').toString());
        if (u2.startsWith('http') && looksLikeMedia(u2) && !_isNoise(u2)) {
          return ResolvedStream(
            url: u2,
            type: u2.contains('.m3u8') ? 'application/x-mpegURL' : 'video/mp4',
            headers: _headersFor(u2, referer),
            via: '二级播放页配置',
          );
        }
      }

      // 页面里直接写了媒体地址
      final hits = scanMedia(html)
          .where((u) =>
              !u.contains('jx.') && !u.contains('/player') && !u.contains('_guard'))
          .toList();
      if (hits.isNotEmpty) {
        return ResolvedStream(
          url: hits.first,
          type: hits.first.contains('.m3u8') ? 'application/x-mpegURL' : 'video/mp4',
          headers: _headersFor(hits.first, referer),
          via: '二级播放页直链',
        );
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 从播放页配置里推导出 jx 云播放器的 iframe 地址。
  ///
  /// **实测证据**（2026-10，直接抓 `/static/player/<from>.js` 得到）：
  /// ```js
  /// // yunjie.js（gugu3）
  /// MacPlayer.Html = '<iframe src="https://player.gugu3.com/?url='
  ///     + MacPlayer.PlayUrl + '&next=..."></iframe>';
  ///
  /// // xigua.js（ant/蚂蚁）
  /// MacPlayer.Html = '<iframe src="https://vip.sp-flv.com:8443?url='
  ///     + MacPlayer.PlayUrl + '"></iframe>';
  /// ```
  ///
  /// 也就是说：`PlayUrl` 就是 `player_aaaa.url` 里的那串 token，
  /// 拼进播放器的 `?url=` 参数即可得到一个**能直接跑 JS 解析**的页面。
  ///
  /// 返回 null 表示这不是一个可识别的 jx 源。
  static String? buildJxPlayerUrl(Map<String, dynamic> cfg, String pageUrl) {
    final from = (cfg['from'] ?? '').toString().trim().toLowerCase();
    final token = (cfg['url'] ?? '').toString().trim();
    if (from.isEmpty || token.isEmpty) return null;
    // 已经是正常 http 地址的（苹果CMS 直链）不走这里
    if (token.startsWith('http')) return null;
    // 已知 jx 播放器模板（键为 player_aaaa.from 的值）
    const templates = <String, String>{
      'yunjie': 'https://player.gugu3.com/?url={token}',
      'xigua': 'https://vip.sp-flv.com:8443?url={token}',
    };
    final tpl = templates[from];
    if (tpl == null) return null;
    return tpl.replaceAll('{token}', token);
  }

  /// 返回 null 表示这个源用不了纯 HTTP，需要走 WebView
  Future<ResolvedStream?> tryResolve(String pageUrl, String referer, {String cookie = ''}) async {
    try {
      final html = await gateAwareGet(pageUrl, (headers) async {
        final res = await _c
            .get(Uri.parse(pageUrl), headers: headers)
            .timeout(const Duration(seconds: 12));
        return utf8.decode(res.bodyBytes, allowMalformed: true);
      }, {
        'User-Agent': _uaDesktop,
        'Accept-Language': 'zh-CN,zh;q=0.9',
        if (referer.isNotEmpty) 'Referer': referer,
      });

      // ① 【最优先】苹果CMS 的 player_aaaa JSON —— 覆盖面最广、最可靠
      final cfg = extractPlayerConfig(html);
      if (cfg != null) {
        final rawUrl = (cfg['url'] ?? '').toString();
        // 【实测修复】有些源把真实地址做了 base64 / 百分号编码，
        // 必须先解码再判断（否则 anime7 这类源会被误判成需 WebView）。
        final u = decodePlayerUrl(rawUrl);
        if (u.startsWith('http') && !_isNoise(u)) {
          final enc = cfg['encrypt'];
          final isEnc = enc == 1 || enc == '1' || enc == true;
          if (looksLikeMedia(u)) {
            return ResolvedStream(
              url: u,
              type: u.contains('.m3u8') ? 'application/x-mpegURL' : 'video/mp4',
              headers: _headersFor(u, referer),
              via: isEnc
                  ? '播放页配置（加密流，播放器自动解密）'
                  : '播放页配置',
            );
          }
          // 【实测新增 · 2026-10-12】解码出来的不是媒体地址而是**二级播放页**
          // （实测：7sefun 的 encrypt=2 解出 https://www.lmm85.com/play/xxx.html）。
          // 旧逻辑把它当 video/mp4 直接交给播放器 → 必初始化失败。
          // 正确做法：抓一次这个二级页扫直链；扫不到就把它作为
          // jx 链入口（manualPageUrl），交给 WebView 或兜底页。
          final nested = await _scanNestedPlayer(u, referer);
          if (nested != null) return nested;
          return ResolvedStream(
            url: '',
            headers: _headersFor(u, referer),
            via: 'jx 云播（需 WebView 跑 JS）',
            manualPageUrl: u,
          );
        }

        // 【实测新增】jx 云播源：url 是一个不透明 token，真实地址由
        //   `/static/player/<from>.js` 拼成**第三方播放器 iframe** 里的 JS 取回。
        //   实测（2026-10）：
        //     gugu3  from=yunjie → https://player.gugu3.com/?url=<token>
        //     ant    from=xigua  → https://vip.sp-flv.com:8443?url=<token>
        //   这类源**必须**跑 JS，所以返回一个带 jxPlayerUrl 的结果，
        //   让 WebView 直接打开这个播放器地址（比加载整页更快、更稳）。
        final jx = buildJxPlayerUrl(cfg, pageUrl);
        if (jx != null) {
          return ResolvedStream(
            url: '',
            headers: _headersFor(jx, referer),
            via: 'jx 云播（需 WebView 跑 JS）',
            manualPageUrl: jx,
          );
        }
        // 有配置但 url 为空 → 是 jx 类，需要 WebView
      }

      // ② 页面里有没有明的 m3u8/mp4
      final direct = scanMedia(html);
      // 排除 jx 播放器自身地址（那不是视频）与已知噪声
      final filtered = direct
          .where((u) =>
              !u.contains('jx.') &&
              !u.contains('/player') &&
              !u.contains('_guard'))
          .toList();
      if (filtered.isNotEmpty) {
        return ResolvedStream(
          url: filtered.first,
          type: filtered.first.contains('.m3u8') ? 'application/x-mpegURL' : 'video/mp4',
          headers: _headersFor(filtered.first, referer),
          via: '页面内直链',
        );
      }

      // ③ 兜底：Vurl 变量（jx 播放器为空串时说明要跑 JS）
      final v = extractVurl(html);
      if (v != null && v.isNotEmpty && !_isNoise(v)) {
        return ResolvedStream(
          url: v,
          type: v.contains('.m3u8') ? 'application/x-mpegURL' : 'video/mp4',
          headers: _headersFor(v, referer),
          via: '页面变量',
        );
      }
      return null;
    } catch (e) {
      kLog('[Resolver] 纯HTTP解析失败: $e');
      return null;
    }
  }

  /// 从播放页里找出 iframe 播放器地址（下一步交给 WebView）
  Future<String?> findPlayerIframe(String pageUrl, String referer, {String cookie = ''}) async {
    try {
      final html = await gateAwareGet(pageUrl, (headers) async {
        final res = await _c
            .get(Uri.parse(pageUrl), headers: headers)
            .timeout(const Duration(seconds: 12));
        return utf8.decode(res.bodyBytes, allowMalformed: true);
      }, {
        'User-Agent': _uaDesktop,
        if (referer.isNotEmpty) 'Referer': referer,
        // 【v1.8.0】规则里带了站点 Cookie（人机验证通过后）就随播放页请求发送
        if (cookie.isNotEmpty) 'Cookie': cookie,
      });

      // ① 页面里真的写了 <iframe src=...>（部分源是静态的）
      //
      // 【v1.8.0 实测修复】不能无脑取「第一个 iframe」：ezdmw 播放页的第一个
      // iframe 是**评论区**（/comment/?comment_index=…），取到它必然解析超时。
      // 现在改成打分：命中播放器特征（player / danmuku / video / play / m3u8）
      // 加分，命中干扰项（comment / 广告 / ad / 统计）直接跳过，取最高分那个。
      final iframes = RegExp(r'<iframe[^>]*\bsrc\s*=\s*"([^"]+)"', caseSensitive: false)
          .allMatches(html)
          .map((x) => x.group(1)!.trim())
          .where((u) => u.isNotEmpty)
          .toList();
      String? best;
      var bestScore = -1;
      for (final u in iframes) {
        final lower = u.toLowerCase();
        if (lower.contains('comment') ||
            lower.contains('/ad') ||
            lower.contains('advert') ||
            lower.contains('stat') ||
            lower.contains('hm.baidu')) {
          continue;
        }
        var score = 0;
        for (final k in <String>['player', 'danmuku', 'danmu', 'video', 'play', 'm3u8']) {
          if (lower.contains(k)) score += 10;
        }
        if (score > bestScore) {
          bestScore = score;
          best = u;
        }
      }
      if (best != null) return absolutize(best, pageUrl);

      // ② 【实测新增】jx 云播源：HTML 里**没有** iframe 标签，
      //    播放器 iframe 是由 `/static/player/<from>.js` 在运行时 document.write 出来的。
      //    我们已经能直接推导出那个地址（见 buildJxPlayerUrl），所以在这里补上，
      //    让上层拿到「真正的播放器页」用于兜底展示 / 或作为 WebView 备选目标。
      final cfg = extractPlayerConfig(html);
      if (cfg != null) {
        final jx = buildJxPlayerUrl(cfg, pageUrl);
        if (jx != null) return jx;
      }

      // ③ 【v1.8.0 实测新增】播放器地址由 JS 拼装、静态 HTML 里没有 iframe
      //    标签（ezdmw 就是：地址藏在 JS 里的 player.ezdmw.com/danmuku/?nk=…）。
      //    直接从页面文本里找「像播放器」的绝对地址。
      // 注意：Dart 原始字符串里无法转义引号，这里用「先取宽匹配、再剔除
      // 含引号的候选」代替正则字符类里写引号。
      final urls = RegExp(r'https?://[^\s<>\\]{10,300}')
          .allMatches(html)
          .map((x) => x.group(0)!)
          .where((u) => !u.contains('"') && !u.contains("'"))
          .toList();
      String? bestUrl;
      var bestUrlScore = 0;
      for (final u in urls) {
        final low = u.toLowerCase();
        if (low.contains('comment') || low.contains('baidu') || low.contains('google')) {
          continue;
        }
        var sc = 0;
        if (low.contains('.m3u8')) sc += 100;
        if (low.contains('player.')) sc += 40;
        if (low.contains('/danmuku/') || low.contains('danmu')) sc += 30;
        if (low.contains('/play') || low.contains('video')) sc += 10;
        if (sc > bestUrlScore) {
          bestUrlScore = sc;
          bestUrl = u;
        }
      }
      if (bestUrl != null) {
        kLog('[Resolver] 页面文本里找到播放器地址: $bestUrl');
        return bestUrl;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 【对齐 Kazumi legacy 解析器】
  ///
  /// api=1 / useLegacyParser 的源（典型：AGE）：播放页 HTML 里挂一个
  /// `<iframe src="...?url=真实m3u8">`，直链藏在 iframe 地址的 query 参数里。
  /// 这条路**纯 HTTP 就能走通**（不需要跑 JS），Windows 同样适用。
  ///
  /// 返回 null 表示 iframe 地址里没有明文直链（真实地址由 JS 运行时取回，
  /// 得交给 WebView/Edge CDP 的 legacy 模式）。
  Future<ResolvedStream?> tryLegacyResolve(String pageUrl, String referer, {String cookie = ''}) async {
    try {
      final html = await gateAwareGet(pageUrl, (headers) async {
        final res = await _c
            .get(Uri.parse(pageUrl), headers: headers)
            .timeout(const Duration(seconds: 12));
        return utf8.decode(res.bodyBytes, allowMalformed: true);
      }, {
        'User-Agent': _uaDesktop,
        'Accept-Language': 'zh-CN,zh;q=0.9',
        if (referer.isNotEmpty) 'Referer': referer,
      });

      // ① 所有静态 iframe 的 src 都试一遍 decodeVideoSource
      final iframes = RegExp(
        r'<iframe[^>]*\bsrc\s*=\s*"([^"]+)"',
        caseSensitive: false,
      ).allMatches(html);
      for (final m in iframes) {
        final src = absolutize(m.group(1)!.trim(), pageUrl);
        final decoded = decodeVideoSource(src);
        if (decoded != src && looksLikeMedia(decoded) && !_isNoise(decoded)) {
          return ResolvedStream(
            url: decoded,
            type: decoded.contains('.m3u8')
                ? 'application/x-mpegURL'
                : 'video/mp4',
            headers: _headersFor(decoded, referer),
            via: 'legacy iframe 直链',
          );
        }
      }

      // ② 【实测】部分 legacy 源把 iframe 地址写在 JS 变量里
      //    （document.write / 动态插入），HTML 标签里抓不到。
      final jsIfs = RegExp(
        r'''(?:iframe|player|play)[\w$]*\s*[=:]\s*["']([^"']*(?:\?|&)url=[^"']+)["']''',
        caseSensitive: false,
      ).allMatches(html);
      for (final m in jsIfs) {
        final src = absolutize(m.group(1)!.trim(), pageUrl);
        final decoded = decodeVideoSource(src);
        if (decoded != src && looksLikeMedia(decoded) && !_isNoise(decoded)) {
          return ResolvedStream(
            url: decoded,
            type: decoded.contains('.m3u8')
                ? 'application/x-mpegURL'
                : 'video/mp4',
            headers: _headersFor(decoded, referer),
            via: 'legacy JS 变量直链',
          );
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Map<String, String> _headersFor(String url, String referer) {
    final h = <String, String>{'User-Agent': _uaDesktop};
    if (referer.isNotEmpty) h['Referer'] = referer;
    return h;
  }
}

// ───────────────────────── 策略 2：WebView ─────────────────────────

/// WebView 解析结果回调
typedef StreamCallback = void Function(ResolvedStream? result, String log);

/// 由界面层提供的 WebView 控制器工厂。
///
/// 之所以要「工厂」而不是直接给实例：Android 的 WebView 必须挂进 Widget 树
/// 才持有真实平台 view；每次解析都要一个新的控制器，所以传函数。
/// 返回类型用 `dynamic` 是为了让本文件不依赖任何 WebView 插件
/// （Windows 构建时不引入 webview_flutter，避免原生依赖）。
typedef WebViewControllerFactory = dynamic Function();

/// WebView 解析器抽象。
///
/// 之所以抽出来，是因为不同平台实现不同：
///  - Android：webview_flutter（系统 WebView）
///  - Windows：flutter_inappwebview（WebView2）
/// 解析逻辑一致：加载目标页 → 监听网络请求 → 抓到媒体地址就回调。
abstract class WebViewResolver {
  /// 是否可用（平台支持 + 依赖就绪）
  bool get available;

  /// 加载 [url]，等最多 [timeout]；抓到媒体地址即完成。
  /// [legacy] 为真时走 Kazumi legacy 模式：盯 iframe 的 src 并做
  /// [decodeVideoSource] 解包（api=1 的源，如 AGE）；否则盯
  /// XHR/fetch 的 `#EXTM3U` 内容与 `<video>` 标签。
  Future<ResolvedStream> resolve(
    String url, {
    String referer = '',
    bool legacy = false,
    Duration timeout = const Duration(seconds: 25),
  });
}

/// 当平台没有 WebView 时的占位实现，直接抛可读错误
class UnsupportedWebViewResolver implements WebViewResolver {
  final String reason;
  const UnsupportedWebViewResolver(this.reason);
  @override
  bool get available => false;
  @override
  Future<ResolvedStream> resolve(String url,
      {String referer = '',
      bool legacy = false,
      Duration timeout = const Duration(seconds: 25)}) async {
    throw ResolveException('当前平台没有可用的 WebView 解析器', detail: reason);
  }
}

// ───────────────────────── 统一入口 ─────────────────────────

/// 解析任意一集的真实播放地址。
///
/// 流程：纯 HTTP 试一次 → 不行就找播放器 iframe → WebView 解析。
///
/// 关键保证：**绝不返回空**。全部解析失败时，返回一个 `isEmpty == true`
/// 但带 `manualPageUrl` 的结果，UI 据此提示用户「用浏览器打开」，
/// 从而彻底避免「点了完全没反应 / 完全看不了」。
class PlayResolver {
  final DirectHttpResolver _http = DirectHttpResolver();
  final WebViewResolver webview;

  PlayResolver({required this.webview});

  Future<ResolvedStream> resolveEpisode({
    required String episodeUrl,
    required KazumiRule rule,
    Duration webviewTimeout = const Duration(seconds: 25),
  }) async {
    final referer = rule.referer.isNotEmpty ? rule.referer : rule.baseURL;
    final legacy = rule.useLegacyParser || rule.api == '1';
    kLog('[Resolver] 解析 ${rule.name} 的 $episodeUrl (legacy=$legacy)');

    // ── ⓪ legacy 源先试纯 HTTP：iframe 地址 query 里常藏明文直链（AGE 实测）──
    if (legacy) {
      try {
        final hit = await _http.tryLegacyResolve(episodeUrl, referer, cookie: rule.cookie);
        if (hit != null && !hit.isEmpty) {
          kLog('[Resolver] legacy HTTP 命中: ${hit.url}');
          return hit;
        }
      } catch (e) {
        kLog('[Resolver] legacy HTTP 异常: $e');
      }
    }

    // ── ① 纯 HTTP：页面里直接有媒体地址 ──
    ResolvedStream? jxHint; // jx 云播：已知播放器地址，但必须跑 JS
    try {
      final httpHit = await _http.tryResolve(episodeUrl, referer, cookie: rule.cookie);
      // 【v1.8.0 实测】站点会把**广告视频**直接写在播放页里（实测 sbdl.cc /
      // 7sefun 都命中 v1.adkwai.com 的 .mp4）。这类地址能播但播的是广告，
      // 不能当命中 → 判为广告后继续走浏览器解析找真正的正片地址。
      // （判定函数已提升为模块级 `looksLikeAdUrl`，WebView 路径共用。）
      if (httpHit != null && !httpHit.isEmpty) {
        if (looksLikeAdUrl(httpHit.url)) {
          kLog('[Resolver] 纯HTTP命中的是广告地址，弃用: ${httpHit.url}');
        } else {
          kLog('[Resolver] 纯HTTP命中: ${httpHit.url}');
          return httpHit;
        }
      }
      // 【实测新增】jx 云播源：tryResolve 会把「已推导出的播放器地址」
      // 放在 manualPageUrl 里（url 为空）。记下来，直接当 WebView 的首选目标，
      // 省掉一次 findPlayerIframe 抓取，命中率也更高。
      if (httpHit != null && httpHit.isEmpty && httpHit.manualPageUrl != null) {
        jxHint = httpHit;
        kLog('[Resolver] jx 云播地址: ${httpHit.manualPageUrl}');
      }
    } catch (e) {
      kLog('[Resolver] 纯HTTP异常: $e');
    }

    // ── ② 找出播放器 iframe（jx 已推导出就跳过） ──
    String? iframeUrl = jxHint?.manualPageUrl;
    if (iframeUrl == null || iframeUrl.isEmpty) {
      try {
        iframeUrl = await _http.findPlayerIframe(episodeUrl, referer, cookie: rule.cookie);
      } catch (_) {}
      kLog('[Resolver] 播放器 iframe: $iframeUrl');
    }

    // 兜底页面：iframe 优先（那是真正能播的页面），其次原始播放页
    final manual = (iframeUrl != null && iframeUrl.isNotEmpty) ? iframeUrl : episodeUrl;

    // ── ③ WebView 解析 ──
    if (webview.available) {
      // 【实测更正 · 很重要】
      // 早前以为「把 jx 播放器地址作为顶层文档加载成功率最高」，**这是错的**。
      // 实测抓 `player.gugu3.com` 的源码发现它开头就有反盗链检查：
      //     if (window.self === window.top) { window.location.href = 'https://www.gugu3.com'; return; }
      // 也就是说：**直接打开 jx 播放器会被它自己跳走**，永远解析不到地址。
      //
      // 正确顺序是：**先加载原始播放页** —— 播放页用 `MacPlayer.Html` 把 jx
      // 播放器写进 `<iframe>`，这样 `self !== top`，反盗链检查通过，JS 才会真正跑。
      // （Kazumi 的 useWebview 走的也是这个路径：加载播放页，而不是播放器页。）
      //
      // jx 地址作为第二候选，只对**没有反盗链**的播放器有效，留着不吃亏。
      final candidates = <String>[
        episodeUrl, // 首选：原始播放页（iframe 上下文，绕过 self!==top 反盗链）
        if (iframeUrl != null && iframeUrl.isNotEmpty) iframeUrl,
      ];
      final tried = <String>{};
      // WebView 命中的广告地址（记录下来：所有候选都只出广告时，至少要告诉
      // 用户「这个源的正片地址没解析出来」，而不是拿广告充数）
      final adHits = <String>[];
      for (final target in candidates) {
        if (target.isEmpty || !tried.add(target)) continue;
        try {
          final s = await webview.resolve(
            target,
            referer: referer,
            legacy: legacy,
            timeout: webviewTimeout,
          );
          if (!s.isEmpty) {
            // 【v1.9.3】过滤广告：实测「星际牛仔」那次，正片还没嗅探到，
            // 先来的 v1.adkwai.com 广告 mp4 就被当成命中直接起播了。
            if (looksLikeAdUrl(s.url)) {
              kLog('[Resolver] WebView 命中的是广告地址，弃用: ${s.url}');
              adHits.add(s.url);
              continue; // 试下一个候选目标
            }
            kLog('[Resolver] WebView 命中: ${s.url}');
            return ResolvedStream(
              url: s.url,
              type: s.type,
              headers: {
                ...s.headers,
                // 解析器若已给出更精确的 Referer（如 jx 清单域名）就别覆盖
                if (referer.isNotEmpty && !s.headers.containsKey('Referer'))
                  'Referer': referer,
              },
              via: s.via.isEmpty ? 'WebView 解析' : s.via,
              manualPageUrl: manual,
            );
          }
        } catch (e) {
          kLog('[Resolver] WebView 尝试失败 ($target): $e');
        }
      }
      if (adHits.isNotEmpty) {
        kLog('[Resolver] 该源只解析到 ${adHits.length} 个广告地址，未找到正片 → 判为失败');
      }
    }

    // ── ④ 全失败：返回「空地址 + 可手动播放页」而不是直接抛错 ──
    //     这样 UI 永远有东西可展示、可点击，用户不会遇到死路。
    kLog('[Resolver] 全部解析失败，回退到手动播放页: $manual');
    return ResolvedStream(
      url: '',
      type: 'application/x-mpegURL',
      via: '需在播放器页内播放',
      manualPageUrl: manual,
    );
  }

  /// 供「浏览器打开」兜底用：返回最适合手动播放的页面地址
  Future<String> manualPageFor(String episodeUrl, KazumiRule rule) async {
    final referer = rule.referer.isNotEmpty ? rule.referer : rule.baseURL;
    final iframe = await _http.findPlayerIframe(episodeUrl, referer, cookie: rule.cookie);
    return (iframe != null && iframe.isNotEmpty) ? iframe : episodeUrl;
  }
}
