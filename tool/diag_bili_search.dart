/// 诊断 B站搜索返回结构：`season_id` 到底在哪一层
///
/// 背景：`BilibiliDanmakuSource._findCid` 从搜索结果项**顶层**取 `season_id`，
/// 但实测「葬送的芙莉莲」能取到、另外几个番名取不到。
/// 怀疑不同条目的结构不一致（有的嵌在 `media.season_id`）。
/// 此脚本把两层都打印出来，一次看清。
///
/// 跑法：`dart run tool/diag_bili_search.dart`
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
    req.headers.set('Origin', 'https://www.bilibili.com');
    if (cookie != null) req.headers.set('Cookie', cookie!);
    final res = await req.close();
    final body = await res.transform(utf8.decoder).join();
    // 收集 cookie
    final sc = res.headers['set-cookie'];
    if (sc != null && sc.isNotEmpty) {
      cookie = sc.map((s) => s.split(';').first.trim()).join('; ');
    }
    return body;
  }

  stdout.writeln('[预热] 访问首页取 cookie');
  await get('https://www.bilibili.com/');
  stdout.writeln('  cookie: $cookie');

  final kws = args.isNotEmpty
      ? args
      : ['葬送的芙莉莲', '进击的巨人', 'Code Geass 反叛的鲁路修R2', 'Code Geass',
         '进击的巨人 最终季', '孤独摇滚'];

  for (final kw in kws) {
    stdout.writeln('\n${'=' * 72}');
    stdout.writeln('  关键词: $kw');
    final body = await get(
        'https://api.bilibili.com/x/web-interface/search/type'
        '?search_type=media_bangumi&keyword=${Uri.encodeQueryComponent(kw)}');
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
    for (final r in res.take(5)) {
      if (r is! Map) continue;
      final media = r['media'];
      stdout.writeln('    title=${r['title']}');
      stdout.writeln('      顶层 season_id=${r['season_id']}  '
          'media_id=${r['media_id']}  type=${r['season_type_name']}');
      if (media is Map) {
        stdout.writeln('      media.season_id=${media['season_id']}  '
            'media.title=${media['title']}');
      } else {
        stdout.writeln('      (无 media 子对象)');
      }
    }
  }
  c.close(force: true);
}
