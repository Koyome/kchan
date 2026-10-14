/// 深挖第二轮：搞清 media_bangumi 与 media_ft 的互补关系
///
/// 第一轮发现：两者**互补** —— 一个返回 null（错误）时另一个常有结果。
/// 需要确认：
///   1. `null` 时接口到底回了什么 code（是不支持该 search_type，还是风控）
///   2. `media_ft` 拿到的条目里有没有可用的 `season_id`
///   3. 两者合并后覆盖率能到多少
///
/// 跑法：`dart run tool/diag_bili_deep2.dart`
library;

import 'dart:convert';
import 'dart:io';

const _ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

late HttpClient _client;
String? _cookie;

Future<(int, Map<String, dynamic>?)> getJson(String url) async {
  try {
    final req = await _client.getUrl(Uri.parse(url));
    req.headers.set('User-Agent', _ua);
    req.headers.set('Accept', 'application/json, text/plain, */*');
    req.headers.set('Accept-Language', 'zh-CN,zh;q=0.9');
    req.headers.set('Referer', 'https://www.bilibili.com/');
    req.headers.set('Origin', 'https://www.bilibili.com');
    if (_cookie != null) req.headers.set('Cookie', _cookie!);
    final res = await req.close();
    final body = await res.transform(utf8.decoder).join();
    final sc = res.headers['set-cookie'];
    if (sc != null && sc.isNotEmpty) {
      _cookie = sc.map((s) => s.split(';').first.trim()).join('; ');
    }
    if (res.statusCode != 200) return (res.statusCode, null);
    return (res.statusCode, jsonDecode(body) as Map<String, dynamic>);
  } catch (_) {
    return (-1, null);
  }
}

Future<void> probe(String label, String url) async {
  final (code, j) = await getJson(url);
  if (j == null) {
    stdout.writeln('    $label: HTTP $code（无 JSON）');
    return;
  }
  final data = j['data'];
  final res = (data is Map ? data['result'] : null) as List?;
  stdout.writeln('    $label: HTTP $code  api.code=${j['code']} '
      'msg=${j['message']}  result=${res?.length ?? "无"}');
  if (res != null) {
    for (final r in res.take(4)) {
      if (r is! Map) continue;
      final title = '${r['title'] ?? ''}'.replaceAll(RegExp(r'<[^>]*>'), '');
      stdout.writeln('        season_id=${r['season_id']} '
          'media_id=${r['media_id']} type=${r['season_type_name']} '
          '「$title」');
    }
  }
}

Future<void> main() async {
  _client = HttpClient();
  await getJson('https://www.bilibili.com/');
  stdout.writeln('cookie=$_cookie\n');

  for (final t in ['进击的巨人', '我推的孩子', '命运石之门', '钢之炼金术师 FA',
                   'Code Geass 反叛的鲁路修R2', '葬送的芙莉莲']) {
    final q = Uri.encodeQueryComponent(t);
    stdout.writeln('${'=' * 74}');
    stdout.writeln('  「$t」');
    await probe('media_bangumi', 'https://api.bilibili.com/x/web-interface'
        '/search/type?search_type=media_bangumi&keyword=$q');
    await probe('media_ft     ', 'https://api.bilibili.com/x/web-interface'
        '/search/type?search_type=media_ft&keyword=$q');
    stdout.writeln('');
  }
  _client.close(force: true);
}
