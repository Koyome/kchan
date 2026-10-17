// 安卓交付前的网络与解析链路验证（跑在 flutter test 环境里）
//
// 运行：
//   flutter test test/android_parity_test.dart `
//     --dart-define=DANDAN_APPID=xxx --dart-define=DANDAN_APPSECRET=yyy
//
// 说明：
//   · 这里跑的是与 APK **完全相同**的 Dart 代码（ImageProxy / BangumiApi /
//     DandanplaySource）。
//   · 本轮无法在真机/模拟器上跑起 App：x86_64 模拟器需要 WHPX/AEHD
//     硬件加速驱动，装驱动要管理员权限。所以用这个测试把「网络与解析」
//     这一段先钉死，原生渲染/解码那段由 APK 内的 libmpv.so / libmdk.so
//     负责（已核对两个 ABI 都在）。
//   · 测试需要真实联网，因此标了 tags: network，可按需跳过。

@Tags(['network'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kchan/api/bangumi_api.dart';
import 'package:kchan/api/danmaku_api.dart';

const String proxy = 'https://bgm.kchan.top';

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    // Flutter 的测试环境默认把 HttpClient 替换成 mock —— 任何真实网络请求
    // 都会直接返回 400（"Any test expecting a real network connection ...
    // will fail"）。把这些 overrides 清掉才能真的联网。
    HttpOverrides.global = null;
  });

  test('① 封面候选链非空且首个可下载', () async {
    const sample = 'https://lain.bgm.tv/pic/cover/l/13/c5/400602_ZI8Y9.jpg';
    final cands = ImageProxy.candidates(sample, subjectId: 400602);
    // ignore: avoid_print
    print('候选 ${cands.length} 个:');
    for (final c in cands.take(5)) {
      // ignore: avoid_print
      print('  $c');
    }
    expect(cands, isNotEmpty);

    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(cands.first));
      req.headers.set('User-Agent', 'kchan-parity/1.0');
      final res = await req.close();
      final bytes = await res.fold<int>(0, (a, b) => a + b.length);
      // ignore: avoid_print
      print('封面: HTTP ${res.statusCode} · ${(bytes / 1024).toStringAsFixed(1)}KB');
      expect(res.statusCode, 200);
      expect(bytes, greaterThan(1024));
    } finally {
      client.close(force: true);
    }
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('② 每日放送走自建反代', () async {
    BangumiApiHolder.api.bases = <String>[proxy];
    final sw = Stopwatch()..start();
    final days = await BangumiApiHolder.api.calendar(force: true);
    sw.stop();
    final total = days.fold<int>(0, (a, d) => a + d.items.length);
    // ignore: avoid_print
    print('每日放送: ${days.length} 天 · $total 部 · ${sw.elapsedMilliseconds}ms');
    expect(days.length, 7);
    expect(total, greaterThan(0));
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('②b 条目详情走自建反代', () async {
    BangumiApiHolder.api.bases = <String>[proxy];
    final sw = Stopwatch()..start();
    final d = await BangumiApiHolder.api.subject(400602);
    sw.stop();
    // ignore: avoid_print
    print('条目: ${d.nameCn.isNotEmpty ? d.nameCn : d.name} · ${sw.elapsedMilliseconds}ms');
    expect(d.id, 400602);
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('③ 弹幕凭据已注入且能取到弹幕', () async {
    const appId = DandanCredentials.builtinAppId;
    const appSecret = DandanCredentials.builtinAppSecret;
    // ignore: avoid_print
    print('AppId=${appId.isEmpty ? "(空)" : appId} '
        'hasBuiltin=${DandanCredentials.hasBuiltin}');
    expect(appId, isNotEmpty,
        reason: '未注入 DANDAN_APPID，运行测试时要带 --dart-define');
    expect(appSecret, isNotEmpty,
        reason: '未注入 DANDAN_APPSECRET，运行测试时要带 --dart-define');

    final src = DandanplaySource(appId: appId, appSecret: appSecret);
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
    if (list.isNotEmpty) {
      // ignore: avoid_print
      print('样例: ${list.take(3).map((e) => e.text).join(" / ")}');
    }
    expect(list, isNotEmpty);
  }, timeout: const Timeout(Duration(seconds: 120)));
}
