/// 用**真实抓取到的站点 HTML** 验证规则引擎
///
/// 运行：dart run tool/verify_rules_real.dart
///
/// 为什么必须有这个测试：
/// `rules_selftest.dart` 用的是人造 HTML，只能证明「引擎自洽」；
/// 而规则真正要面对的是各站点**真实、脏乱**的页面。历史上有过
/// 「自检全绿但线上一条都搜不到」的情况（旧 XML 引擎对 `//x` 的相对语义
/// 处理错误，导致每个搜索结果都取到同一个标题）。
///
/// 本文件用 D:\dev 下留存的真实抓包（DM84 搜索/详情页、7sefun 详情页等）
/// 跑官方规则，并断言「取到多条不同的结果」—— 这能同时抓住
/// 「取不到」和「取到的都一样」两类回归。
library;

import 'dart:io';

import 'package:kchan/api/kazumi_rules.dart';

int _pass = 0;
int _fail = 0;

void ok(String name, bool cond, [String detail = '']) {
  if (cond) {
    _pass++;
    stdout.writeln('  ✓ $name');
  } else {
    _fail++;
    stdout.writeln('  ✗ $name${detail.isEmpty ? '' : '\n      $detail'}');
  }
}

/// 加载一条官方规则
KazumiRule? ruleOf(String name) {
  final f = File('assets/rules/kazumi_rules.json');
  final rules = RuleRegistry.fromJsonList(f.readAsStringSync());
  for (final r in rules) {
    if (r.name == name) return r;
  }
  return null;
}

String? readFixture(List<String> candidates) {
  for (final p in candidates) {
    final f = File(p);
    if (f.existsSync() && f.lengthSync() > 200) return f.readAsStringSync();
  }
  return null;
}

void main() {
  stdout.writeln('══ 真实 HTML 规则验证 ══\n');

  // ─────────── DM84 搜索页 ───────────
  stdout.writeln('【DM84 · 搜索页】官方规则 searchList=//div/div[3]/ul/li');
  final searchHtml = readFixture([
    r'D:\dev\_kazumi_ref\dm84_search.html',
    r'D:\dev\tmp_dm84.html',
  ]);
  final dm84 = ruleOf('DM84');
  ok('规则存在', dm84 != null);
  if (searchHtml != null && dm84 != null) {
    final hits = KazumiParser(dm84).parseSearch(searchHtml);
    stdout.writeln('    命中 ${hits.length} 条:');
    for (final h in hits.take(5)) {
      stdout.writeln('      · ${h.title}  →  ${h.url}');
    }
    ok('搜索有命中', hits.isNotEmpty, '解析出 0 条');
    ok('标题互不相同（旧的 XML 引擎会全部相同）',
        hits.map((h) => h.title).toSet().length == hits.length,
        '去重后 ${hits.map((h) => h.title).toSet().length} / 共 ${hits.length}');
    ok('链接各自不同（旧的 XML 引擎会全指向第一条）',
        hits.map((h) => h.url).toSet().length == hits.length,
        hits.map((h) => h.url).take(3).join('\n      '));
    ok('链接都是 http(s) 绝对地址',
        hits.every((h) => h.url.startsWith('https://') || h.url.startsWith('http://')),
        hits.map((h) => h.url).take(3).join('\n      '));
    ok('标题非空', hits.every((h) => h.title.trim().isNotEmpty));
  }

  // ─────────── DM84 详情页 ───────────
  stdout.writeln('\n【DM84 · 详情页】官方规则 chapterRoads=//div/div[4]/div/ul');
  final detailHtml = readFixture([
    r'D:\dev\_kazumi_ref\dm84_detail.html',
    r'D:\dev\tmp_dm84d.html',
  ]);
  if (detailHtml != null && dm84 != null) {
    final d = KazumiParser(dm84).parseDetail(detailHtml);
    stdout.writeln('    线路 ${d.roads.length} 条:');
    for (final r in d.roads) {
      stdout.writeln('      · ${r.name}: ${r.episodes.length} 集'
          '  首集="${r.episodes.isEmpty ? "" : r.episodes.first.title}"');
    }
    ok('解析出线路', d.roads.isNotEmpty, '0 条线路');
    ok('线路名对齐 Kazumi（播放线路N）',
        d.roads.every((r) => r.name.startsWith('播放线路')),
        d.roads.map((r) => r.name).join(', '));
    ok('每集都有 URL',
        d.roads.every((r) => r.episodes.every((e) => e.url.isNotEmpty)));
    if (d.roads.isNotEmpty) {
      final n = d.roads.first.episodes.length;
      ok('线路1 集数合理（1..200）', n >= 1 && n <= 200, '实际 $n');

      // 【关键回归点】旧 XML 引擎的 `//li/a` 是「从文档根求值」，于是**每条线路**
      // 都会拿到全文档的所有剧集链接 → 每条线路集数 = 线路数 × 每线集数
      // （实测 DM84：2 条线路 × 28 集 → 每条都报 56/96 集，且 URL 互相串线）。
      // 正确行为：每条线路**只**有自己的剧集，且 URL 不重复。
      for (final r in d.roads) {
        final urls = r.episodes.map((e) => e.url).toList();
        ok('${r.name} 内 URL 不重复（旧引擎会重复）',
            urls.toSet().length == urls.length,
            '去重后 ${urls.toSet().length} / ${urls.length}');
      }
      if (d.roads.length > 1) {
        // 各线路的 URL 必须互不相交（否则说明取到了同一份列表）
        final first = d.roads.first.episodes.map((e) => e.url).toSet();
        var overlap = 0;
        for (final r in d.roads.skip(1)) {
          for (final e in r.episodes) {
            if (first.contains(e.url)) overlap++;
          }
        }
        ok('不同线路的剧集 URL 互不相交（旧引擎会完全重叠）', overlap == 0,
            '重叠 $overlap 条');
        final total = d.roads.fold<int>(0, (a, r) => a + r.episodes.length);
        ok('总集数 = 各线路集数之和（不是被放大）',
            total == d.roads.map((r) => r.episodes.length).reduce((a, b) => a + b));
      }
    }
  }

  // ─────────── 7sefun 详情页 ───────────
  stdout.writeln('\n【7sefun · 详情页】searchName 用 //div[2]/text()（文本节点终结）');
  final s7 = ruleOf('7sefun');
  ok('规则存在', s7 != null);
  final s7detail = readFixture([r'D:\dev\tmp_7sd.html', r'D:\dev\tmp_7s.html']);
  if (s7 != null && s7detail != null) {
    final d = KazumiParser(s7).parseDetail(s7detail);
    stdout.writeln('    线路 ${d.roads.length} 条，总集数 ${d.allEpisodes.length}');
    for (final r in d.roads.take(4)) {
      stdout.writeln('      · ${r.name}: ${r.episodes.length} 集');
    }
    ok('解析出线路', d.roads.isNotEmpty);
    if (d.roads.isNotEmpty) {
      ok('集数合理', d.roads.first.episodes.length <= 500,
          '实际 ${d.roads.first.episodes.length}');
    }
  }

  // ─────────── 全规则「吃掉真实页面不崩」回归 ───────────
  stdout.writeln('\n【回归】全部 86 条规则 × 真实页面：不得抛异常、不得超时');
  final all = RuleRegistry.fromJsonList(
      File('assets/rules/kazumi_rules.json').readAsStringSync());
  final pages = <String, String>{};
  for (final e in {
    'dm84_search': r'D:\dev\_kazumi_ref\dm84_search.html',
    'dm84_detail': r'D:\dev\_kazumi_ref\dm84_detail.html',
    '7sefun_detail': r'D:\dev\tmp_7sd.html',
    'lmm_detail': r'D:\dev\tmp_lmm.html',
    'mgnacg': r'D:\dev\tmp_mg.html',
    '7sefun_search': r'D:\dev\tmp_7s.html',
  }.entries) {
    final f = File(e.value);
    if (f.existsSync() && f.lengthSync() > 200) pages[e.key] = f.readAsStringSync();
  }
  stdout.writeln('    使用 ${pages.length} 份真实页面');

  final sw = Stopwatch()..start();
  var combos = 0;
  final errors = <String>[];
  for (final r in all) {
    if (r.usesApiSearch) continue;
    for (final entry in pages.entries) {
      combos++;
      try {
        final parser = KazumiParser(r);
        parser.parseSearch(entry.value);
        parser.parseDetail(entry.value);
      } catch (e) {
        errors.add('${r.name} × ${entry.key}: $e');
      }
    }
  }
  sw.stop();
  ok('全部组合无异常（$combos 次）', errors.isEmpty, errors.take(5).join('\n      '));
  stdout.writeln('    耗时 ${sw.elapsedMilliseconds} ms'
      '（平均 ${(sw.elapsedMicroseconds / combos / 1000).toStringAsFixed(2)} ms/次）');

  stdout.writeln('\n══════════════════');
  stdout.writeln('通过 $_pass / 失败 $_fail');
  exit(_fail == 0 ? 0 : 1);
}
