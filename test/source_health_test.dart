// 验证 SourceHealth：真的探测、真的排序
//
//   flutter test test/source_health_test.dart

@Tags(['network'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kchan/api/kazumi_rules.dart';
import 'package:kchan/api/source_groups.dart';
import 'package:kchan/api/source_health.dart';

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    HttpOverrides.global = null; // flutter test 默认 mock 网络
  });

  test('探测全部源站并给出排序依据', () async {
    // flutter test 里 rootBundle 读不到资产（会退化成 2 条兜底规则）。
    // 直接从磁盘读真实的规则文件，才能验证 86 条源的真实分布。
    await BuiltinRules.load(loader: (key) async {
      final f = File('assets/rules/kazumi_rules.json');
      if (!f.existsSync()) return '';
      return f.readAsString();
    });
    // ignore: avoid_print
    print('规则总数: ${RuleRegistry.all.length}');

    final sw = Stopwatch()..start();
    await SourceHealth.prime(force: true);
    sw.stop();
    // ignore: avoid_print
    print('探测用时: ${sw.elapsedMilliseconds}ms');
    // ignore: avoid_print
    print('结果: ${SourceHealth.describe()}');

    expect(SourceHealth.hasData, isTrue, reason: '一个都没探到');

    final rules = RuleRegistry.all;
    final scored = [
      for (final r in rules)
        (r.name, SourceHealth.sortScore(r.name), SourceHealth.isDead(r.name))
    ]..sort((a, b) => a.$2.compareTo(b.$2));

    // ignore: avoid_print
    print('');
    // ignore: avoid_print
    print('── 排序后最快 12 条（会进快车道）──');
    for (final s in scored.take(12)) {
      // ignore: avoid_print
      print('  ${s.$1.padRight(16)} ${s.$2}ms');
    }

    final dead = scored.where((s) => s.$3).toList();
    // ignore: avoid_print
    print('');
    // ignore: avoid_print
    print('── 判定连不上 ${dead.length} 条（排在最后，但不删除）──');
    for (final s in dead.take(10)) {
      // ignore: avoid_print
      print('  ${s.$1}');
    }

    // 死源必须排在最后
    final aliveMax = scored
        .where((s) => !s.$3)
        .map((s) => s.$2)
        .fold<int>(0, (a, b) => a > b ? a : b);
    final deadMin = dead.isEmpty
        ? (1 << 31)
        : dead.map((s) => s.$2).reduce((a, b) => a < b ? a : b);
    // ignore: avoid_print
    print('');
    // ignore: avoid_print
    print('活着的最差 ${aliveMax}ms · 死源的最好 ${deadMin}ms');
    expect(deadMin, greaterThan(aliveMax), reason: '死源必须全部排在活源之后');
  }, timeout: const Timeout(Duration(seconds: 240)));
}
