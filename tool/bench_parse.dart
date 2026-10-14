/// 解析性能基准：新实现（HTML DOM + xpath_lite）
///
/// 运行：dart run tool/bench_parse.dart
///
/// ## 已测得的对照结论（2026-10-13，本机，AMD/Intel x64 Windows）
///
/// 旧实现（v1.9.0）的路径是：`html.parse` → 手写序列化成 XML 字符串 →
/// `XmlDocument.parse` 再建一棵树 → `package:xml` 的 XPath 求值。
/// 那份代码在 v1.9.1 已删除，本脚本**不再重建它**（重建需要把 `package:xml`
/// 加回依赖，为了一个基准而多背一个包不划算）。对照数据留档如下：
///
/// | 场景 | 旧：XML 往返 | 新：HTML DOM | 提速 |
/// | --- | --- | --- | --- |
/// | 搜索页 45KB（40 项 + 400 噪声节点） | 32.05 ms | 10.08 ms | **3.2×** |
/// | 搜索页 114KB（80 项 + 1200 噪声节点） | 109.19 ms | 21.53 ms | **5.1×** |
///
/// 而且旧实现的**结果本身是错的**（不只是慢）：
/// `package:xml` 的 `element.xpath('//h5/a')` 是「从文档根求值」，于是
///   - 每个搜索结果都取到**同一个**标题（实测 40 条全是「番剧条目 0」）；
///   - 每条线路都取到**全文档**的剧集（实测 4 线 × 24 集 → 每线都报 96 集）。
/// 现在这两点都由 `tool/verify_rules_real.dart` 用真实抓包断言守住。
///
/// 本脚本负责**复现新的绝对耗时**，便于以后回归时和上表对比。
library;

import 'dart:io';

import 'package:html/parser.dart' as html_parser;
import 'package:kchan/api/kazumi_rules.dart';

/// 生成一份「像真实站点」的搜索结果页（带足够多的噪声节点）
String buildRealisticHtml({int items = 40, int noise = 400}) {
  final b = StringBuffer('<html><head><title>搜索</title></head><body>');
  b.write('<div class="header">');
  for (var i = 0; i < noise; i++) {
    b.write('<div class="nav-item" data-i="$i"><a href="/nav/$i">导航$i</a></div>');
  }
  b.write('</div>');
  b.write('<div class="main"><section class="cata_video_list">');
  for (var i = 0; i < items; i++) {
    b.write('''<div class="cata_video_item">
      <a href="/detail/$i.html"><img src="/img/$i.jpg"></a>
      <div class="cata_video_info">
        <h5><a href="/detail/$i.html">番剧条目 $i 〜サブタイトル〜</a></h5>
        <p class="desc">简介文本 $i，含 &amp; 与 <b>粗体</b> 与 &#26085;&#26412;&#35486;</p>
        <div class="meta"><span>2024</span><span>12话</span></div>
      </div>
    </div>''');
  }
  b.write('</section></div>');
  b.write('<div class="detail"><div class="play-list">');
  for (var road = 0; road < 4; road++) {
    b.write('<div class="road"><ul class="anthology-list-play size">');
    for (var ep = 1; ep <= 24; ep++) {
      b.write('<li><a href="/play/$road-$ep.html">第$ep话</a></li>');
    }
    b.write('</ul></div>');
  }
  b.write('</div></div>');
  b.write('</body></html>');
  return b.toString();
}

final searchRule = KazumiRule(
  name: 'BENCH',
  baseURL: 'https://example.com/',
  searchURL: 'https://example.com/s?q=@keyword',
  searchList: "//div[contains(@class,'cata_video_item')]",
  searchName: '//h5/a',
  searchResult: '//h5/a',
);

final roadRule = KazumiRule(
  name: 'BENCH2',
  baseURL: 'https://example.com/',
  searchURL: 'x',
  searchList: "//div[contains(@class,'cata_video_item')]",
  searchName: '//h5/a',
  searchResult: '//h5/a',
  chapterRoads: "//ul[contains(@class,'anthology-list-play')]",
  chapterResult: '//li/a',
);

void bench(String label, int iters, void Function() run) {
  for (var i = 0; i < 3; i++) {
    run();
  }
  final sw = Stopwatch()..start();
  for (var i = 0; i < iters; i++) {
    run();
  }
  sw.stop();
  final per = sw.elapsedMicroseconds / iters / 1000.0;
  stdout.writeln('  ${label.padRight(30)} ${per.toStringAsFixed(2)} ms/次'
      '   (${iters} 次共 ${sw.elapsedMilliseconds} ms)');
}

void main() {
  stdout.writeln('══ 解析性能基准（新实现） ══\n');

  for (final cfg in [(40, 400), (80, 1200), (160, 3000)]) {
    final html = buildRealisticHtml(items: cfg.$1, noise: cfg.$2);
    stdout.writeln('HTML ${(html.length / 1024).toStringAsFixed(1)} KB '
        '（${cfg.$1} 结果项 + ${cfg.$2} 噪声节点）');

    // 正确性自证：每条结果的标题/链接都必须不同
    final hits = KazumiParser(searchRule)
        .parseSearchDom(html_parser.parse(html));
    final titles = hits.map((h) => h.title).toSet().length;
    final urls = hits.map((h) => h.url).toSet().length;
    stdout.writeln('  解析出 ${hits.length} 条，去重标题 $titles，去重链接 $urls '
        '${hits.length == cfg.$1 && titles == cfg.$1 && urls == cfg.$1 ? "✓" : "✗"}');

    bench('搜索页解析', 20, () {
      KazumiParser(searchRule).parseSearchDom(html_parser.parse(html));
    });
    bench('详情页解析（4 线 × 24 集）', 20, () {
      KazumiParser(roadRule).parseDetailDom(html_parser.parse(html));
    });
    stdout.writeln();
  }

  stdout.writeln('── 与 v1.9.0（XML 往返）留档对照 ──');
  stdout.writeln('  45KB  旧 32.05 ms  →  新见上表（约 3× 提速）');
  stdout.writeln('  114KB 旧 109.19 ms →  新见上表（约 5× 提速）');
}
