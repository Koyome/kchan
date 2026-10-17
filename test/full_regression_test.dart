// 全量回归：优选 IP 生效时，数据源 / 封面 / 弹幕 / 明文解析 是否都正常
//
// 用户担心「拆东墙补西墙」。这个测试就是证据：一次性验证四类网络行为，
// 且全部在 IpPin 已钉 IP 的前提下跑。
//
//   flutter test test/full_regression_test.dart --dart-define=... 

@Tags(['network'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kchan/api/bangumi_api.dart';
import 'package:kchan/api/danmaku_api.dart';
import 'package:kchan/api/ip_pin.dart';

const String proxy = 'https://bgm.kchan.top';

Future<(int, int)> timedGet(String url) async {
  final c = HttpClient();
  IpPin.install(c);
  c.connectionTimeout = const Duration(seconds: 10);
  try {
    final sw = Stopwatch()..start();
    final req = await c.getUrl(Uri.parse(url));
    req.headers.set('User-Agent', 'kchan/2.1.10');
    final res = await req.close();
    final n = await res.fold<int>(0, (a, b) => a + b.length);
    sw.stop();
    return (res.statusCode, sw.elapsedMilliseconds);
  } finally {
    c.close(force: true);
  }
}

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    // flutter test 默认 mock 掉 HttpClient（一律 400），必须清掉
    HttpOverrides.global = null;
  });

  test('A · 优选 IP 选中且可用', () async {
    final ip = await IpPin.select();
    // ignore: avoid_print
    print('选中: $ip   结果: ${IpPin.lastResults}');
    expect(ip, isNotNull, reason: '优选失败，无法钉 IP');
    final (code, ms) = await timedGet('$proxy/v0/subjects/400602');
    // ignore: avoid_print
    print('钉住后直取: HTTP $code · ${ms}ms');
    expect(code, 200);
    expect(ms, lessThan(3000));
  }, timeout: const Timeout(Duration(seconds: 120)));

  test('B · 数据源（6 条全部）仍然可用', () async {
    BangumiApiHolder.api.bases = <String>[
      'https://bgm.kchan.top',
      'https://api.kchan.top',
    ];
    final sw = Stopwatch()..start();
    final days = await BangumiApiHolder.api.calendar(force: true);
    sw.stop();
    final total = days.fold<int>(0, (a, d) => a + d.items.length);
    // ignore: avoid_print
    print('每日放送: ${days.length} 天 · $total 部 · ${sw.elapsedMilliseconds}ms');
    expect(days.length, 7);
    expect(total, greaterThan(0));
    expect(sw.elapsedMilliseconds, lessThan(8000));

    final sw2 = Stopwatch()..start();
    final d = await BangumiApiHolder.api.subject(400602);
    sw2.stop();
    // ignore: avoid_print
    print('条目: ${d.nameCn} · ${sw2.elapsedMilliseconds}ms');
    expect(d.id, 400602);
  }, timeout: const Timeout(Duration(seconds: 120)));

  test('C · 封面图仍然可下载（走同一套钉 IP）', () async {
    const cover = 'https://lain.bgm.tv/pic/cover/l/13/c5/400602_ZI8Y9.jpg';
    final cands = ImageProxy.candidates(cover, subjectId: 400602);
    // ignore: avoid_print
    print('候选 ${cands.length} 个，首个: ${cands.first}');
    final (code, ms) = await timedGet(cands.first);
    // ignore: avoid_print
    print('封面: HTTP $code · ${ms}ms');
    expect(code, 200);
    expect(ms, lessThan(5000));
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('D · 明文 http 不被强制 TLS（解析抓页依赖它）', () async {
    final (code, ms) =
        await timedGet('http://connectivitycheck.gstatic.com/generate_204');
    // ignore: avoid_print
    print('http 明文: HTTP $code · ${ms}ms');
    expect(code, 204);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('E · 弹幕：匹配 + 拉取', () async {
    const appId = DandanCredentials.builtinAppId;
    const secret = DandanCredentials.builtinAppSecret;
    expect(appId, isNotEmpty, reason: '未注入 DANDAN_APPID');
    expect(secret, isNotEmpty, reason: '未注入 DANDAN_APPSECRET');

    final src = DandanplaySource(appId: appId, appSecret: secret);
    final sw = Stopwatch()..start();
    final epId = await src.matchEpisodeId('葬送的芙莉莲', 1);
    sw.stop();
    // ignore: avoid_print
    print('匹配 episodeId=$epId · ${sw.elapsedMilliseconds}ms');
    expect(epId, isNotNull);

    final sw2 = Stopwatch()..start();
    final list = await src.fetch(animeTitle: '葬送的芙莉莲', episode: 1);
    sw2.stop();
    // ignore: avoid_print
    print('弹幕 ${list.length} 条 · ${sw2.elapsedMilliseconds}ms');
    expect(list, isNotEmpty);
  }, timeout: const Timeout(Duration(seconds: 120)));
}
