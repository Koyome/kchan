/// 弹幕覆盖率抽测（20 部样本）
///
/// 用途：给出**可信的覆盖率数字**，而不是拿一两个能用的例子就说「接好了」。
/// 明确列出未命中的番名，便于判断是「B站确实没有」还是「匹配逻辑有漏」。
///
/// 跑法：`dart run tool/probe_danmaku_coverage.dart`
library;

import 'dart:io';

import 'package:kchan/api/danmaku_source.dart';

/// (番名, 集数) —— 覆盖近年热门与经典老番
const _samples = <(String, int)>[
  ('葬送的芙莉莲', 1),
  ('孤独摇滚', 1),
  ('间谍过家家', 1),
  ('莉可丽丝', 1),
  ('地。-关于地球的运动-', 1),
  ('我推的孩子', 1),
  ('咒术回战', 1),
  ('鬼灭之刃', 1),
  ('辉夜大小姐想让我告白', 1),
  ('进击的巨人', 1),
  ('凉宫春日的忧郁', 1),
  ('CLANNAD', 1),
  ('命运石之门', 1),
  ('钢之炼金术师 FA', 1),
  ('Code Geass 反叛的鲁路修R2', 1),
  ('星际牛仔', 1),
  ('攻壳机动队', 1),
  ('虫师', 1),
  ('夏目友人帐', 1),
  ('Fate/Zero', 1),
];

/// 中文按 2 个显示宽度对齐
String _pad(String s, int width) {
  var w = 0;
  for (final r in s.runes) {
    w += r > 0x2000 ? 2 : 1;
  }
  return s + ' ' * (width - w > 0 ? width - w : 0);
}

Future<void> main() async {
  final src = BilibiliDanmakuSource();
  var hit = 0;
  final misses = <String>[];

  stdout.writeln('=' * 78);
  stdout.writeln('  B站弹幕覆盖率抽测（${_samples.length} 部，第 1 集）');
  stdout.writeln('=' * 78);

  for (final (title, ep) in _samples) {
    final sw = Stopwatch()..start();
    final items = await src.fetch(animeTitle: title, episode: ep.toDouble());
    sw.stop();
    if (items.isEmpty) {
      misses.add(title);
      stdout.writeln(
          '  [MISS] ${_pad(title, 24)} （${sw.elapsedMilliseconds}ms）');
    } else {
      hit++;
      final span = (items.last.timeMs / 1000).round();
      stdout.writeln('  [HIT ] ${_pad(title, 24)} '
          '${items.length.toString().padLeft(5)} 条  '
          '覆盖至 ${span}s  （${sw.elapsedMilliseconds}ms）');
    }
  }

  src.dispose();
  final rate = (100 * hit / _samples.length).round();
  stdout.writeln('');
  stdout.writeln('=' * 78);
  stdout.writeln('  命中 $hit / ${_samples.length}（$rate%）');
  if (misses.isNotEmpty) {
    stdout.writeln('  未命中 ${misses.length} 部:');
    for (final m in misses) {
      stdout.writeln('    - $m');
    }
  }
  stdout.writeln('=' * 78);
  exit(0);
}
