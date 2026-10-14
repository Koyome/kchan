/// 诊断 B站「视频搜索」回退路径能否覆盖番剧库搜不到的番
///
/// 背景：实测「进击的巨人」「Code Geass」在 `search_type=media_bangumi`
/// 下命中 **0 条**（未上架番剧库 / 版权原因）。
/// 但 B站有大量用户搬运的**普通投稿**，走 `search_type=video` 可能找得到，
/// 且视频搜索结果里直接带 `cid`，能省掉一次 season 请求。
///
/// 跑法：`dart run tool/diag_bili_video.dart`
library;

import 'dart:convert';
import 'dart:io';

const _ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

Future<void> main(List<String> args) async {
  final c = HttpClient();
  String? cookie;

  Future<String> get(String url) async {
    final req = await c.getUrl(Uri.parse(url));
    req.headers.set('User-Agent', _ua);
    req.headers.set('Accept', 'application/json, text/plain, */*');
    req.headers.set('Accept-Language', 'zh-CN,zh;q=0.9');
    req.headers.set('Referer', 'https://www.bilibili.com/');
    if (cookie != null) req.headers.set('Cookie', cookie!);
    final res = await req.close();
    final body = await res.transform(utf8.decoder).join();
    final sc = res.headers['set-cookie'];
    if (sc != null && sc.isNotEmpty) {
      cookie = sc.map((s) => s.split(';').first.trim()).join('; ');
    }
    return body;
  }

  await get('https://www.bilibili.com/');

  final kws = args.isNotEmpty
      ? args
      : ['进击的巨人 第1集', 'Code Geass 反叛的鲁路修 R2 第1集', '孤独摇滚 第1集'];

  for (final kw in kws) {
    stdout.writeln('\n${'=' * 72}');
    stdout.writeln('  视频搜索: $kw');
    final body = await get(
        'https://api.bilibili.com/x/web-interface/search/type'
        '?search_type=video&keyword=${Uri.encodeQueryComponent(kw)}');
    Map<String, dynamic> j;
    try {
      j = jsonDecode(body) as Map<String, dynamic>;
    } catch (e) {
      stdout.writeln('  解析失败: $e');
      continue;
    }
    final data = (j['data'] as Map?) ?? const {};
    final res = (data['result'] as List?) ?? const [];
    stdout.writeln('  命中 ${res.length} 条  (code=${j['code']} msg=${j['message']})');
    for (final r in res.take(6)) {
      if (r is! Map) continue;
      final title = '${r['title'] ?? ''}'.replaceAll(RegExp(r'<[^>]*>'), '');
      stdout.writeln('    cid=${r['cid']}  bvid=${r['bvid']}  '
          'aid=${r['aid']}  dur=${r['duration']}');
      stdout.writeln('      「$title」');
    }
  }
  c.close(force: true);
}
