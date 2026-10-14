/// 验证弹幕获取的真实链路（跑在 Dart VM 上，用真实网络）
///
/// 【要点】这里走的是**应用实际调用的那个入口** —— `DanmakuApi.fetchAll()`，
/// 而不是单独测某个 source。因为多源调度、兜底顺序、错误吞掉这些逻辑
/// 都在 `fetchAll` 里，只测 source 会漏掉它们。
///
/// 同时验证手写的 protobuf 解析器（`_ProtoReader`）能否正确解出
/// progress / mode / color / content 四个字段。
///
/// 跑法：`dart run tool/verify_danmaku.dart [番名...]`
library;

import 'dart:io';

import 'package:kchan/api/danmaku_api.dart';
import 'package:kchan/api/danmaku_source.dart';

Future<void> main(List<String> args) async {
  final titles = args.isNotEmpty
      ? args
      : ['葬送的芙莉莲', '孤独摇滚', '凉宫春日的忧郁'];

  // 走应用真实入口：不配弹弹play 凭证（模拟「审核通过前」的状态）
  final api = DanmakuApi();
  stdout.writeln('可用弹幕源: ${api.enabledSourceNames.join("、")}');

  var pass = 0;
  var fail = 0;

  for (final t in titles) {
    stdout.writeln('\n${'=' * 70}');
    stdout.writeln('  「$t」第 1 集');
    stdout.writeln('=' * 70);
    final sw = Stopwatch()..start();
    String? notice;
    final items = await api.fetchAll(
      t,
      1,
      onNotice: (m) => notice = m,
    );
    sw.stop();

    if (items.isEmpty) {
      stdout.writeln('  [FAIL] 未取到弹幕（${sw.elapsedMilliseconds}ms）');
      if (notice != null) stdout.writeln('         应用会提示: $notice');
      fail++;
      continue;
    }
    pass++;
    stdout.writeln('  [PASS] ${items.length} 条，耗时 ${sw.elapsedMilliseconds}ms');

    // 字段合理性
    final modes = <DanmakuMode, int>{};
    var badColor = 0;
    var badTime = 0;
    for (final i in items) {
      modes[i.mode] = (modes[i.mode] ?? 0) + 1;
      if (i.color < 0 || i.color > 0xFFFFFF) badColor++;
      if (i.timeMs < 0 || i.timeMs > 4 * 3600 * 1000) badTime++;
    }
    stdout.writeln('  模式分布: '
        '${modes.entries.map((e) => '${e.key.name}=${e.value}').join('  ')}');
    stdout.writeln('  异常字段: color=$badColor  time=$badTime');
    stdout.writeln('  时间范围: ${(items.first.timeMs / 1000).toStringAsFixed(1)}s'
        ' ~ ${(items.last.timeMs / 1000).toStringAsFixed(1)}s');
    stdout.writeln('  来源标记: ${items.first.source}');

    stdout.writeln('  样本（前 6 条）:');
    for (final i in items.take(6)) {
      stdout.writeln('    ${(i.timeMs / 1000).toStringAsFixed(1).padLeft(7)}s  '
          '${i.mode.name.padRight(6)}  '
          '#${i.color.toRadixString(16).padLeft(6, '0')}  ${i.text}');
    }
    final empty = items.where((i) => i.text.trim().isEmpty).length;
    final weird = items.where((i) => i.text.contains('\uFFFD')).length;
    stdout.writeln('  文本质量: 空串=$empty  含替换符=$weird');
    if (empty > 0 || weird > 0) stdout.writeln('  [WARN] 文本质量异常');
  }

  api.dispose();
  stdout.writeln('\n${'=' * 70}');
  stdout.writeln('  通过 $pass / 失败 $fail');
  stdout.writeln('=' * 70);
  exit(fail > 0 ? 1 : 0);
}
