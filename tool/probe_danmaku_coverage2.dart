/// 弹幕覆盖率对照测试：B站单源 vs 聚合实例
///
/// 用法：
///   dart run tool/probe_danmaku_coverage2.dart                    # 仅 B站
///   dart run tool/probe_danmaku_coverage2.dart http://127.0.0.1:9321
///
/// 给出两个数字便于对比，并列出仍未覆盖的番名。
library;

import 'dart:io';

import 'package:kchan/api/danmaku_api.dart';
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

Future<void> main(List<String> args) async {
  final aggUrl = args.isNotEmpty ? args.first : '';
  final api = DanmakuApi(danmuApiBaseUrl: aggUrl);

  stdout.writeln('=' * 82);
  stdout.writeln('  弹幕覆盖率测试');
  stdout.writeln('  可用源: ${api.enabledSourceNames.join(" + ")}');
  stdout.writeln('=' * 82);

  var hit = 0;
  final misses = <String>[];
  final srcTally = <String, int>{};

  for (final (title, ep) in _samples) {
    final sw = Stopwatch()..start();
    final items = await api.fetchAll(title, ep.toDouble());
    sw.stop();
    if (items.isEmpty) {
      misses.add(title);
      stdout.writeln(
          '  [MISS] ${_pad(title, 24)} （${sw.elapsedMilliseconds}ms）');
    } else {
      hit++;
      for (final i in items) {
        srcTally[i.source] = (srcTally[i.source] ?? 0) + 1;
      }
      final span = (items.last.timeMs / 1000).round();
      stdout.writeln('  [HIT ] ${_pad(title, 24)} '
          '${items.length.toString().padLeft(5)} 条  覆盖至 ${span}s  '
          '（${sw.elapsedMilliseconds}ms）');
    }
  }

  api.dispose();
  final rate = (100 * hit / _samples.length).round();
  stdout.writeln('');
  stdout.writeln('=' * 82);
  stdout.writeln('  命中 $hit / ${_samples.length}（$rate%）');
  if (srcTally.isNotEmpty) {
    final top = srcTally.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    stdout.writeln('  弹幕来源分布（弹幕条数）: '
        '${top.take(10).map((e) => '${e.key}=${e.value}').join('  ')}');
  }
  if (misses.isNotEmpty) {
    stdout.writeln('  未命中 ${misses.length} 部: ${misses.join('、')}');
  }
  stdout.writeln('=' * 82);
  exit(0);
}
