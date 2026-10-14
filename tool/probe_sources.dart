/// 全量规则「真实网络」体检：逐条跑「搜索 → 详情/分集」
///
/// 运行：
///   dart run tool/probe_sources.dart                 # 全部 86 条，默认关键词
///   dart run tool/probe_sources.dart 进击的巨人 鬼灭之刃
///   dart run tool/probe_sources.dart --enabled       # 只测当前默认启用的
///   dart run tool/probe_sources.dart --json out.json # 额外写 JSON 结果
///
/// 为什么要它：
///   官方 KazumiRules 有 86 条，但**站点可用性随时间/网络变化**，
///   凭规则 JSON 里的 `deprecated` 标记判断不准。这个工具用真实请求逐条跑，
///   把「能搜到 + 能拿到分集 + 分集里有真实播放页链接」的源挑出来，
///   用于决定 K酱 的默认启用列表与「线路大类」分组。
///
/// 注意：会真实访问各站点。默认串行 + 并发 6，避免把站点打爆。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:kchan/api/kazumi_rules.dart';
import 'package:kchan/api/video_sources.dart';

/// 体检结果
class ProbeResult {
  final String name;
  final String api;
  final bool ok;
  final int hits;        // 搜索命中数
  final int episodes;    // 分集数
  final int roads;       // 线路数
  final int ms;
  final String detail;   // 失败原因 / 命中标题
  final String? sampleUrl; // 第一集播放页 URL（人工核对用）
  const ProbeResult({
    required this.name,
    required this.api,
    required this.ok,
    this.hits = 0,
    this.episodes = 0,
    this.roads = 0,
    this.ms = 0,
    this.detail = '',
    this.sampleUrl,
  });
}

Future<ProbeResult> probeOne(RuleVideoSource src, String keyword) async {
  final sw = Stopwatch()..start();
  try {
    final hits = await src.search(keyword).timeout(const Duration(seconds: 25));
    if (hits.isEmpty) {
      return ProbeResult(
        name: src.name, api: src.rule.api, ok: false, ms: sw.elapsedMilliseconds,
        detail: '搜索无结果',
      );
    }
    final b = await src
        .bangumiDetail(fallbackTitle: hits.first.title, seeds: hits)
        .timeout(const Duration(seconds: 30));
    final roads = b.roads.where((r) => r.episodes.isNotEmpty).toList();
    final eps = roads.isNotEmpty
        ? roads.fold<int>(0, (a, r) => a + r.episodes.length)
        : b.episodes.length;
    String? sample;
    if (roads.isNotEmpty) {
      sample = roads.first.episodes.first.pageUrl;
    } else if (b.episodes.isNotEmpty) {
      sample = b.episodes.first.pageUrl;
    }
    return ProbeResult(
      name: src.name, api: src.rule.api, ok: eps > 0,
      hits: hits.length, episodes: eps, roads: roads.length,
      ms: sw.elapsedMilliseconds,
      detail: eps > 0
          ? '${hits.first.title}${roads.length > 1 ? " · ${roads.length}线路" : ""}'
          : '有搜索命中但分集为空',
      sampleUrl: sample,
    );
  } catch (e) {
    return ProbeResult(
      name: src.name, api: src.rule.api, ok: false, ms: sw.elapsedMilliseconds,
      detail: e.toString().split('\n').first,
    );
  }
}

Future<void> main(List<String> argv) async {
  // 手写参数解析：`--json <path>` 的值不能被当成关键词。
  // （上一版用 `where((a) => !a.startsWith('--'))` 过滤，结果把 `--json` 后面的
  //   路径也当成了搜索关键词，86 条规则全在搜那个路径 —— 实测踩过。）
  final keywords = <String>[];
  var onlyEnabled = false;
  String? jsonOut;
  for (var i = 0; i < argv.length; i++) {
    final a = argv[i];
    if (a == '--enabled') {
      onlyEnabled = true;
    } else if (a == '--json') {
      if (i + 1 < argv.length) jsonOut = argv[++i];
    } else if (a.startsWith('--')) {
      stdout.writeln('未知参数已忽略: $a');
    } else {
      keywords.add(a);
    }
  }
  if (keywords.isEmpty) {
    // 默认关键词集：覆盖「热门新番 / 经典长番 / 剧场版」三类，
    // 单一关键词会把「搜得到 A 但搜不到 B」的源误判为不可用。
    keywords.addAll([
      '进击的巨人',
      '葬送的芙莉莲',
      '间谍过家家',
      '咒术回战',
      '鬼灭之刃',
      'CLANNAD',
      '孤独摇滚',
      '赛马娘',
    ]);
  }
  stdout.writeln('关键词(${keywords.length}): ${keywords.join(" / ")}');

  await BuiltinRules.load(loader: (k) async {
    final f = File('assets/rules/kazumi_rules.json');
    return f.existsSync() ? f.readAsStringSync() : '';
  });
  var rules = BuiltinRules.all.toList();
  if (onlyEnabled) {
    rules = rules
        .where((r) => RuleRegistry.defaultEnabledNames.contains(r.name))
        .toList();
  }
  stdout.writeln('待测规则: ${rules.length} 条\n');

  final sources = [for (final r in rules) RuleVideoSource(r)];
  final results = <ProbeResult>[];
  const concurrency = 6;
  var idx = 0;

  Future<void> worker() async {
    while (true) {
      final i = idx++;
      if (i >= sources.length) return;
      final src = sources[i];
      // 依次试每个关键词，命中即停
      ProbeResult? best;
      for (final kw in keywords) {
        final r = await probeOne(src, kw);
        if (r.ok) {
          best = r;
          break;
        }
        best ??= r;
      }
      final r = best!;
      results.add(r);
      stdout.writeln('${r.ok ? "OK  " : "--  "}'
          '${r.name.padRight(14)} api=${r.api.padLeft(2)} '
          '${r.ms.toString().padLeft(6)}ms '
          '命中=${r.hits.toString().padLeft(3)} 集=${r.episodes.toString().padLeft(4)} '
          '线路=${r.roads}  ${r.detail}');
    }
  }

  final swAll = Stopwatch()..start();
  await Future.wait([for (var i = 0; i < concurrency; i++) worker()]);
  swAll.stop();

  results.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  final ok = results.where((r) => r.ok).toList();
  stdout.writeln('\n══════════ 汇总 ══════════');
  stdout.writeln('可用 ${ok.length} / ${results.length}（总耗时 ${swAll.elapsed.inSeconds}s）');
  stdout.writeln('\n【可用】');
  for (final r in ok) {
    stdout.writeln('  ${r.name.padRight(14)} api=${r.api.padLeft(2)} '
        '${r.ms.toString().padLeft(6)}ms 集=${r.episodes.toString().padLeft(4)} '
        '线路=${r.roads}  ${r.detail}');
  }
  stdout.writeln('\n【不可用】');
  for (final r in results.where((r) => !r.ok)) {
    stdout.writeln('  ${r.name.padRight(14)} ${r.detail}');
  }
  stdout.writeln('\n【可直接作为默认启用的候选（按耗时排序，含 2+ 线路的优先）】');
  final cand = ok.toList()
    ..sort((a, b) {
      final ar = a.roads >= 2 ? 0 : 1;
      final br = b.roads >= 2 ? 0 : 1;
      if (ar != br) return ar.compareTo(br);
      return a.ms.compareTo(b.ms);
    });
  for (final r in cand.take(20)) {
    stdout.writeln("  '${r.name}',   // ${r.ms}ms ${r.roads}线路 ${r.episodes}集");
  }

  if (jsonOut != null) {
    File(jsonOut).writeAsStringSync(const JsonEncoder.withIndent('  ').convert([
      for (final r in results)
        {
          'name': r.name,
          'api': r.api,
          'ok': r.ok,
          'hits': r.hits,
          'episodes': r.episodes,
          'roads': r.roads,
          'ms': r.ms,
          'detail': r.detail,
          'sampleUrl': r.sampleUrl,
        }
    ]));
    stdout.writeln('\nJSON 已写入 $jsonOut');
  }
}
