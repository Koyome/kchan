// 被动源健康：纯逻辑单测（不发任何网络请求）
//
//   flutter test test/source_health_passive_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:kchan/api/source_health.dart';

void main() {
  setUp(SourceHealth.reset);

  test('未记录时：中性分数，不影响原有排序', () {
    // 有静态值时用静态值
    expect(SourceHealth.sortScore('A', staticFallback: 900), 900);
    // 没静态值时给中性值
    expect(SourceHealth.sortScore('A'), 5000);
    expect(SourceHealth.isDegraded('A'), isFalse);
  });

  test('成功一次：按实测耗时排（更快）', () {
    SourceHealth.reportSuccess('A', 320);
    expect(SourceHealth.latencyOf('A'), 320);
    expect(SourceHealth.sortScore('A', staticFallback: 900), 320);
    expect(SourceHealth.isDegraded('A'), isFalse);
  });

  test('失败一次：不降权，只轻微后移', () {
    SourceHealth.reportFailure('A');
    expect(SourceHealth.isDegraded('A'), isFalse,
        reason: '单次失败不该判死，网络抖一下就误伤');
    final s = SourceHealth.sortScore('A', staticFallback: 500);
    expect(s, greaterThan(500), reason: '应该比纯静态值靠后');
    expect(s, lessThan(1 << 30), reason: '但没到「排最后」的程度');
  });

  test('连续失败两次：降权到最后', () {
    SourceHealth.reportFailure('A');
    SourceHealth.reportFailure('A');
    expect(SourceHealth.isDegraded('A'), isTrue);
    expect(SourceHealth.sortScore('A'), 1 << 30);
  });

  test('失败后又成功：连续失败清零，恢复正常', () {
    SourceHealth.reportFailure('A');
    SourceHealth.reportFailure('A');
    expect(SourceHealth.isDegraded('A'), isTrue);

    SourceHealth.reportSuccess('A', 410);
    expect(SourceHealth.isDegraded('A'), isFalse,
        reason: '成功一次就该恢复，不能因为历史失败一直压着');
    expect(SourceHealth.latencyOf('A'), 410);
  });

  test('排序效果：快源在前、坏源在后', () {
    SourceHealth.reportSuccess('fast', 300);
    SourceHealth.reportSuccess('mid', 1500);
    SourceHealth.reportFailure('bad');
    SourceHealth.reportFailure('bad');

    final names = ['bad', 'unknown', 'mid', 'fast'];
    names.sort((a, b) => SourceHealth.sortScore(a).compareTo(
        SourceHealth.sortScore(b)));

    // ignore: avoid_print
    print('排序结果: $names '
        '(${names.map((n) => SourceHealth.sortScore(n)).toList()})');

    expect(names.first, 'fast');
    expect(names.last, 'bad');
  });

  test('describe 不抛异常', () {
    SourceHealth.reportSuccess('x', 100);
    SourceHealth.reportFailure('y');
    // ignore: avoid_print
    print(SourceHealth.describe());
    expect(SourceHealth.describe(), contains('成功'));
  });
}
