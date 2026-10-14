/// 深挖：为何部分番在 B站 `search_type=media_bangumi` 下 0 命中
///
/// 三种可能：
///   A. 这些番确实不在 B站番剧库（版权/未上架）→ 只能换源
///   B. `media_bangumi` 这个 search_type 覆盖不全 → 换 `media_bangumi` 之外的入口
///   C. 反爬/风控在部分关键词上返回空 → 补 Referer/Cookie/WBI 签名
///
/// 本脚本同时验证多个**不同入口**，定位到底是哪一种。
/// 关键对照：「进击的巨人」在 B站网页端**是有的**（有番剧页），
/// 所以如果所有 API 入口都搜不到，那多半是 C 或接口覆盖问题，不是 A。
///
/// 跑法：`dart run tool/diag_bili_deep.dart`
library;

import 'dart:convert';
import 'dart:io';

const _ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

late HttpClient _client;
String? _cookie;

Future<Map<String, dynamic>?> getJson(String url,
    {bool wantJson = true, String? referer}) async {
  try {
    final req = await _client.getUrl(Uri.parse(url));
    req.headers.set('User-Agent', _ua);
    req.headers.set('Accept', 'application/json, text/plain, */*');
    req.headers.set('Accept-Language', 'zh-CN,zh;q=0.9');
    req.headers.set('Referer', referer ?? 'https://www.bilibili.com/');
    req.headers.set('Origin', 'https://www.bilibili.com');
    if (_cookie != null) req.headers.set('Cookie', _cookie!);
    final res = await req.close();
    final body = await res.transform(utf8.decoder).join();
    final sc = res.headers['set-cookie'];
    if (sc != null && sc.isNotEmpty) {
      _cookie = sc.map((s) => s.split(';').first.trim()).join('; ');
    }
    if (!wantJson) return {'__raw': body, '__code': res.statusCode};
    if (res.statusCode != 200) return {'__code': res.statusCode};
    return jsonDecode(body) as Map<String, dynamic>;
  } catch (e) {
    return {'__err': '$e'};
  }
}

Future<void> main() async {
  _client = HttpClient();
  stdout.writeln('[预热] 首页取 cookie');
  await getJson('https://www.bilibili.com/', wantJson: false);
  stdout.writeln('  cookie=$_cookie');

  const titles = ['进击的巨人', '我推的孩子', '命运石之门', '葬送的芙莉莲'];

  for (final t in titles) {
    stdout.writeln('\n${'=' * 74}');
    stdout.writeln('  「$t」');
    stdout.writeln('=' * 74);
    final q = Uri.encodeQueryComponent(t);

    // 入口 1：media_bangumi（当前实现）
    final r1 = await getJson(
        'https://api.bilibili.com/x/web-interface/search/type'
        '?search_type=media_bangumi&keyword=$q');
    final n1 = ((r1?['data'] as Map?)?['result'] as List?)?.length ?? -1;
    stdout.writeln('  [1] search/type media_bangumi : ${n1 >= 0 ? "$n1 条" : r1?['__code'] ?? r1?['__err']}');

    // 入口 2：media_ft（影视）—— 有些番被归类到影视
    final r2 = await getJson(
        'https://api.bilibili.com/x/web-interface/search/type'
        '?search_type=media_ft&keyword=$q');
    final n2 = ((r2?['data'] as Map?)?['result'] as List?)?.length ?? -1;
    stdout.writeln('  [2] search/type media_ft      : ${n2 >= 0 ? "$n2 条" : r2?['__code'] ?? r2?['__err']}');

    // 入口 3：PGC 专用搜索（番剧页面用的那个）
    final r3 = await getJson(
        'https://api.bilibili.com/pgc/season/search/web/v2/search'
        '?season_type=1&keyword=$q&page=1&page_size=20');
    final d3 = r3?['data'];
    final n3 = d3 is Map ? (d3['list'] as List?)?.length ?? 0 : (d3 is List ? d3.length : -1);
    stdout.writeln('  [3] pgc/season/search v2    : ${n3 >= 0 ? "$n3 条" : r3?['__code'] ?? r3?['__err']}');
    if (n3 > 0 && d3 is Map) {
      for (final it in (d3['list'] as List).take(3)) {
        if (it is Map) {
          stdout.writeln('        season_id=${it['season_id']} '
              'title=${it['title']}');
        }
      }
    }

    // 入口 4：综合搜索（web_search）—— 会带出番剧卡片
    final r4 = await getJson(
        'https://api.bilibili.com/x/web-interface/wbi/search/all/v2?keyword=$q');
    final res4 = ((r4?['data'] as Map?)?['result'] as List?) ?? const [];
    stdout.writeln('  [4] wbi/search/all/v2       : '
        '${res4.isEmpty ? "${r4?['code']} ${r4?['message']}" : "${res4.length} 个分组"}');
    for (final g in res4.take(12)) {
      if (g is Map) {
        final tn = g['result_type'];
        final arr = g['data'] as List?;
        if (arr != null && arr.isNotEmpty) {
          stdout.writeln('        $tn: ${arr.length} 条');
        }
      }
    }

    // 入口 5：番剧时间表（确认番剧库连通性）
    if (t == titles.first) {
      final r5 = await getJson('https://api.bilibili.com/pgc/web/timeline?types=1');
      stdout.writeln('  [5] pgc/web/timeline（对照，确认番剧库可达）: '
          '${r5?['code']} ${r5?['message']}');
    }
  }
  _client.close(force: true);
}
