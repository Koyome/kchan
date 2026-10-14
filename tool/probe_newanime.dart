/// 【新番解析失败排查】用「本季新番」真实标题跑一遍默认启用的源，
/// 逐条记录：搜了哪些变体、命中数、分集数、失败在哪一步。
///
/// 运行：
///   dart run tool/probe_newanime.dart
///   dart run tool/probe_newanime.dart 药屋少女的呢喃 第三季
library;

import 'dart:async';
import 'dart:io';

import 'package:kchan/api/kazumi_rules.dart';
import 'package:kchan/api/video_sources.dart';

/// 本季（2026 年 10 月）新番：日文原名 + 中文译名
const _pairs = <(String jp, String cn)>[
  ('薬屋のひとりごと 第3期', '药屋少女的呢喃 第三季'),
  ('アオのハコ Season 2', '青之箱 第二季'),
  ('転生したら剣でしたII', '转生就是剑 第二季'),
  ('佐々木とピーちゃん 第2期', '佐佐木与文鸟小哔 第二季'),
  ('らんま1/2 第3期', '乱马1/2 第三季'),
  ('ロメリア戦記', '罗梅莉亚战记'),
  ('生徒会にも穴はある！', '学生会也有洞！'),
  ('ホタルの嫁入り', '萤火虫的出嫁'),
];

Future<void> main(List<String> argv) async {
  final pairs = <(String, String)>[];
  if (argv.length >= 2) {
    pairs.add((argv[0], argv[1]));
  } else {
    pairs.addAll(_pairs);
  }

  await BuiltinRules.load(loader: (k) async {
    final f = File('assets/rules/kazumi_rules.json');
    return f.existsSync() ? f.readAsStringSync() : '';
  });
  final rules = BuiltinRules.all
      .where((r) => RuleRegistry.defaultEnabledNames.contains(r.name))
      .toList();
  stdout.writeln('规则 ${BuiltinRules.all.length} 条，待测启用源 ${rules.length} 条');

  final sources = [for (final r in rules) RuleVideoSource(r, enabled: true)];
  var ok = 0, noHit = 0, noEp = 0, err = 0;

  for (final src in sources) {
    stdout.writeln('\n════ ${src.name} (api=${src.rule.api}) ════');
    for (final p in pairs) {
      final sw = Stopwatch()..start();
      try {
        final hits = await src.search(p.$2).timeout(const Duration(seconds: 15));
        if (hits.isEmpty) {
          noHit++;
          stdout.writeln('  ✗ [${p.$2}] 搜索无结果 ${sw.elapsedMilliseconds}ms');
          // 换日文名再试一次，看看是不是「译名不匹配」
          final hitsJp =
              await src.search(p.$1).timeout(const Duration(seconds: 15));
          if (hitsJp.isNotEmpty) {
            stdout.writeln('    ↳ 但用日文名「${p.$1}」命中 ${hitsJp.length} 条 '
                '→ 译名不匹配');
          }
          continue;
        }
        final b = await src
            .bangumiDetail(fallbackTitle: hits.first.title, seeds: hits)
            .timeout(const Duration(seconds: 15));
        final eps = b.episodes.length;
        if (eps == 0) {
          noEp++;
          stdout.writeln('  ✗ [${p.$2}] 命中 ${hits.length} 条但分集为 0 '
              '（首条=${hits.first.title} → ${hits.first.url}）');
        } else {
          ok++;
          stdout.writeln('  ✓ [${p.$2}] 命中 ${hits.length} 分集 $eps '
              '${sw.elapsedMilliseconds}ms  首条=${hits.first.title}');
        }
      } catch (e) {
        err++;
        stdout.writeln('  ! [${p.$2}] 异常: ${e.toString().split('\n').first}');
      }
    }
  }

  stdout.writeln('\n════ 汇总：成功 $ok / 搜索无命中 $noHit / 有命中无分集 $noEp / 异常 $err ════');
}
