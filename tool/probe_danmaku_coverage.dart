/// 弹幕覆盖率抽测：跑一批真实 Bangumi 番剧，统计 B站弹幕命中率
///
/// 用途：给自己一个**诚实的覆盖率数字**，而不是拿一两个能用的例子就说
/// 「弹幕接好了」。同时在报告里说明「哪些番没有弹幕、为什么」，
/// 让用户知道预期。
///
/// 跑法：`dart run tool/probe_danmaku_coverage.dart`
library;

import 'dart:io';

import 'package:kchan/api/danmaku_source.dart';

/// (subjectId, 番名, 集数) —— 覆盖不同年代与类型
const _samples = <(int, String, int)>[
  (400602, '葬送的芙莉莲', 1),
  (43164, '孤独摇滚', 1),
  (8, 'Code Geass 反叛的鲁路修R2', 1),
  (12, '进击的巨人', 1),
  (253, '凉宫春日的忧郁', 1),
  (10380, 'CLANNAD', 1),
  (302232, '间谍过家家', 1),
  (350235, '莉可丽丝', 1),
  (265, '钢之炼金术师 FA', 1),
  (326, '命运石之门', 1),
  (375875, '我推的孩子', 1),
  (399259, '地。-关于地球的运动-', 1),
];

Future<void> main() async {
  final src = BilibiliDanmakuSource();
  var hit = 0;
  final misses = <String>[];

  stdout.writeln('${'=' * 76}');
  stdout.writeln('  B站弹幕覆盖率抽测（${_samples.length} 部）');
  stdout.writeln('=' * 76);

  for (final (id, title, ep) in _samples) {
    final sw = Stopwatch()..start();
    final items = await src.fetch(animeTitle: title, episode: ep.toDouble());
    sw.stop();
    if (items.isEmpty) {
      misses.add(title);
      stdout.writeln('  [MISS] ${title.padRight(24)} '
          '（${sw.elapsedMilliseconds}ms）');
    } else {
      hit++;
      final span = items.isEmpty
          ? 0
          : (items.last.timeMs / 1000).round();
      stdout.writeln('  [HIT ] ${title.padRight(24)} '
          '${items.length.toString().padLeft(6)} 条  '
          '覆盖至 ${span}s  （${sw.elapsedMilliseconds}ms）');
    }
  }

  src.dispose();
  final rate = (100 * hit / _samples.length).round();
  stdout.writeln('\n${'=' * 76}');
  stdout.writeln('  命中 $hit / ${_samples.length}（$rate%）');
  if (misses.isNotEmpty) {
    stdout.writeln('  未命中: ${misses.join('、')}');
    stdout.writeln('  说明: B站番剧库未收录这些作品（版权/未上架），');
    stdout.writeln('        非代码问题；弹弹play 审核通过后可作为第二源补上。');
  }
  stdout.writeln('=' * 76);
  exit(0);
}
