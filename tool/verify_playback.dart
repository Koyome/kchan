/// K酱 · 解析链真机验证（跑在 Dart VM 上，用**真实的** KazumiParser + DirectHttpResolver）
///
/// 为什么必须这一步：Python/Node 的原型验证只能证明「思路对」，
/// 真正的交付物是 Dart 代码。这个程序直接用 lib/ 里的**同一份**代码跑真实网络，
/// 把「搜索 → 详情 → 解析出 m3u8」全链路走一遍，最后真的去下载一个 ts 分片。
///
/// 用法（由 build_kernel 之外的独立脚本编译运行）：
///   dart run tool/verify_playback.dart
library;

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'package:kchan/api/kazumi_rules.dart';
import 'package:kchan/api/play_resolver.dart';

const _ua =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

const _keyword = '葬送的芙莉莲';

Future<String> _get(String url, {String referer = '', int timeoutS = 20}) async {
  final c = http.Client();
  try {
    final r = await c.get(Uri.parse(url), headers: {
      'User-Agent': _ua,
      'Accept': 'text/html,application/xhtml+xml,*/*;q=0.8',
      'Accept-Language': 'zh-CN,zh;q=0.9',
      if (referer.isNotEmpty) 'Referer': referer,
    }).timeout(Duration(seconds: timeoutS));
    return utf8.decode(r.bodyBytes, allowMalformed: true);
  } finally {
    c.close();
  }
}

/// 下载并返回 (状态码, 字节数, contentType)
Future<List<Object>> _head(String url, {String referer = ''}) async {
  final c = http.Client();
  try {
    final req = http.Request('GET', Uri.parse(url));
    req.headers.addAll({
      'User-Agent': _ua,
      'Range': 'bytes=0-65535',
      if (referer.isNotEmpty) 'Referer': referer,
    });
    final res = await c.send(req).timeout(const Duration(seconds: 25));
    final body = await res.stream.toBytes();
    return [
      res.statusCode,
      body.length,
      res.headers['content-type'] ?? '',
      body.isEmpty ? -1 : body[0],
    ];
  } catch (e) {
    return [0, 0, 'ERR:${e.toString().split('\n').first}', -1];
  } finally {
    c.close();
  }
}

/// 从 m3u8 里挑一个能下载的分片（支持 master → media playlist 两层）
Future<String?> _findPlayableSegment(String m3u8Url, String referer) async {
  String text;
  try {
    text = await _get(m3u8Url, referer: referer);
  } catch (_) {
    return null;
  }
  var base = m3u8Url;
  // master playlist → 进子清单
  final lines = text.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty);
  final sub = lines.firstWhere(
    (l) => !l.startsWith('#') && l.contains('.m3u8'),
    orElse: () => '',
  );
  if (sub.isNotEmpty) {
    base = _abs(sub, m3u8Url);
    try {
      text = await _get(base, referer: referer);
    } catch (_) {
      return null;
    }
  }
  final seg = text
      .split('\n')
      .map((l) => l.trim())
      .firstWhere((l) => l.isNotEmpty && !l.startsWith('#'), orElse: () => '');
  if (seg.isEmpty) return null;
  return _abs(seg, base);
}

String _abs(String u, String base) {
  if (u.startsWith('//')) return 'https:$u';
  if (u.startsWith('http')) return u;
  return Uri.parse(base).resolve(u).toString();
}

Future<void> main() async {
  stdout.writeln('=' * 78);
  stdout.writeln(' K酱 · 解析链真机验证（Dart VM，真实网络，用 lib/ 里的正式代码）');
  stdout.writeln('=' * 78);

  final resolver = PlayResolver(webview: UnsupportedWebViewResolver('纯HTTP验证模式'));
  var pass = 0;
  var total = 0;

  for (final rule in BuiltinRules.all) {
    if (!rule.verified) continue;
    total++;
    stdout.writeln('\n${'━' * 78}');
    stdout.writeln('【${rule.name}】${rule.baseURL}');
    stdout.writeln('━' * 78);

    final referer = rule.referer.isNotEmpty ? rule.referer : rule.baseURL;
    final parser = KazumiParser(rule);

    // ① 搜索
    List<RuleSearchItem> hits;
    try {
      final html = await _get(rule.buildSearchUrl(_keyword), referer: referer);
      hits = parser.parseSearch(html);
    } catch (e) {
      stdout.writeln('  ✗ 搜索请求失败: $e');
      continue;
    }
    stdout.writeln('  ① 搜索 → ${hits.length} 条');
    for (final h in hits.take(2)) {
      stdout.writeln('     · ${h.title}');
    }
    if (hits.isEmpty) {
      stdout.writeln('  ✗ 搜索无命中');
      continue;
    }

    // ② 详情
    RuleBangumiDetail detail;
    try {
      final html = await _get(hits.first.url, referer: referer);
      detail = parser.parseDetail(html);
      // 若详情无分集，退化：把搜索命中当分集
    } catch (e) {
      stdout.writeln('  ✗ 详情请求失败: $e');
      continue;
    }
    final eps = detail.allEpisodes;
    stdout.writeln('  ② 详情 → ${detail.roads.length} 线路 / ${eps.length} 集');
    if (eps.isEmpty) {
      stdout.writeln('  ✗ 详情无分集');
      continue;
    }
    final first = eps.first;
    stdout.writeln('     第1集: ${first.title}  ${first.url}');

    // ③ 解析真实地址
    final epUrl = first.url;
    if (!epUrl.startsWith('http')) {
      stdout.writeln('  △ 分集链接非 http（$epUrl），跳过');
      continue;
    }
    ResolvedStream stream;
    try {
      stream = await resolver.resolveEpisode(episodeUrl: epUrl, rule: rule);
    } catch (e) {
      stdout.writeln('  ✗ 解析异常: $e');
      continue;
    }
    if (stream.isEmpty) {
      stdout.writeln('  △ 未解析出直链（需 WebView）: ${stream.via}');
      continue;
    }
    stdout.writeln('  ③ 解析 → [${stream.via}] ${stream.url}');

    // ④ 真的下载一个分片
    final seg = await _findPlayableSegment(stream.url, referer);
    if (seg == null) {
      stdout.writeln('  ✗ 找不到可下载分片');
      continue;
    }
    final r = await _head(seg, referer: referer);
    final code = r[0] as int;
    final size = r[1] as int;
    final ct = r[2] as String;
    final b0 = r[3] as int;
    final isTs = b0 == 0x47; // MPEG-TS sync byte
    stdout.writeln('  ④ 分片 HTTP $code  $size 字节  $ct  首字节=0x${b0.toRadixString(16)}'
        '${isTs ? '  ★ TS 同步字节，视频真实可播' : ''}');
    if (code == 200 && size > 1000) {
      pass++;
      stdout.writeln('     ✅ 通过');
    } else {
      stdout.writeln('     ✗ 分片不可用');
    }
  }

  stdout.writeln('\n${'=' * 78}');
  stdout.writeln(' 结论：$pass / $total 个源完成「搜索→详情→解析→分片下载」全链路验证');
  stdout.writeln('=' * 78);
  exitCode = pass > 0 ? 0 : 1;
}
