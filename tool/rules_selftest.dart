/// 规则引擎自检（纯 Dart VM，无需 Flutter）
///
/// 覆盖三件本次改造的事，任何一项回归都必须在这里失败：
///   1. `xpath_lite` —— 新 XPath 引擎能覆盖 KazumiRules 用到的全部语法；
///   2. `jsonpath_lite` —— api level 8 规则用的 JSONPath；
///   3. 规则库 —— `assets/rules/kazumi_rules.json` 能被严格解析且字段完整。
///
/// 运行：
///   dart run tool/rules_selftest.dart
library;

import 'dart:convert';
import 'dart:io';

import 'package:html/parser.dart' as html_parser;
import 'package:kchan/api/jsonpath_lite.dart';
import 'package:kchan/api/kazumi_rules.dart';
import 'package:kchan/api/xpath_lite.dart';

int _pass = 0;
int _fail = 0;

void check(String name, Object? actual, Object? expected) {
  final a = '$actual';
  final e = '$expected';
  if (a == e) {
    _pass++;
  } else {
    _fail++;
    stdout.writeln('  ✗ $name\n      期望: $e\n      实际: $a');
  }
}

void checkTrue(String name, bool cond, [String? detail]) {
  if (cond) {
    _pass++;
  } else {
    _fail++;
    stdout.writeln('  ✗ $name${detail == null ? '' : '\n      $detail'}');
  }
}

// ───────────────────────── XPath ─────────────────────────

void testXPath() {
  stdout.writeln('── xpath_lite ──');
  const html = '''
<html><body>
  <div class="cata_video_item">
    <a href="/detail/1.html"><h5>番剧A</h5></a>
    <div class="info"><a href="http://x.com/detail/2.html">番剧B</a></div>
  </div>
  <div class="cata_video_item">
    <a href="/detail/3.html"><h5>番剧C</h5></a>
  </div>
  <section id="list">
    <ul class="anthology-list-play size">
      <li><a href="/play/1-1.html">第1话</a></li>
      <li><a href="/play/1-2.html">第2话</a></li>
      <li><a href="javascript:void(0)">第3话</a></li>
    </ul>
    <ul class="anthology-list-play size">
      <li><a href="/play/2-1.html">第1话</a></li>
    </ul>
  </section>
  <div id="mdym"><div class="video-img-box"><h6><a href="/v/9">深层</a></h6></div></div>
  <div class="box a b">多class</div>
  <input name="verify" value="v1">
</body></html>
''';
  final doc = html_parser.parse(html);

  // ① 属性存在谓词 + 位置谓词 + text() 终结
  check('//div[@class="box a b"]/text()',
      xpathSelect(doc, '//div[@class="box a b"]/text()').length, 1);

  // ② contains(@class)
  final items = xpathSelect(doc, "//div[contains(@class,'cata_video_item')]");
  check('contains(@class) 命中数', items.length, 2);

  // ③ 在结果项内部取相对路径（模拟 searchName/searchResult）
  final inner = innerXPath(items[0], "//a[contains(@href,'/detail/')]");
  check('innerXPath 命中数', inner.length, 2);
  check('innerXPath 首个 href', resolveHref(inner[0]), '/detail/1.html');

  // ④ 位置谓词 [2]
  final second = xpathSelect(doc, "//div[contains(@class,'cata_video_item')][2]");
  check('[2] 命中数', second.length, 1);
  check('[2] 的文本', nodeText(second[0]), '番剧C');

  // ⑤ 后代轴 // 在节点内部
  final deep = innerXPath(items[0], "//div[contains(@class,'info')]//a");
  check('节点内 // 后代', deep.length, 1);
  check('节点内 // 后代 href', resolveHref(deep[0]), 'http://x.com/detail/2.html');

  // ⑥ chapterRoads + chapterResult 两段式
  final roads = xpathSelect(doc, "//ul[contains(@class, 'anthology-list-play')]");
  check('chapterRoads 命中数', roads.length, 2);
  final ep1 = innerXPath(roads[0], '//li/a');
  check('第一条线路剧集数', ep1.length, 3);
  final ep2 = innerXPath(roads[1], '//li/a');
  check('第二条线路剧集数', ep2.length, 1);

  // ⑦ .// 相对写法
  check('.// 相对写法',
      innerXPath(items[0], ".//a[contains(@href,'/detail/')]").length, 2);

  // ⑧ starts-with
  check('starts-with(@id)',
      xpathSelect(doc, "//div[starts-with(@id, 'md')]").length, 1);

  // ⑨ 通配 *
  checkTrue('//* 通配非空', xpathSelect(doc, '//*').isNotEmpty);

  // ⑩ /@attr 终结
  final hrefs = xpathSelect(doc, '//a[@href="/v/9"]/@href');
  check('/@href 终结', hrefs.length == 1 ? hrefs[0].text : 'none', '/v/9');

  // ⑪ 属性存在但无值
  check('[@name] 存在性', xpathSelect(doc, '//input[@name]').length, 1);

  // ⑫ text()='...'
  check("text()='多class'",
      xpathSelect(doc, "//div[text()='多class']").length, 1);

  // ⑬ 不支持的语法 → 空（不抛错）
  check('last() 不支持 → 空', xpathSelect(doc, '//div[last()]').length, 0);
  check('空表达式 → 空', xpathSelect(doc, '').length, 0);
  check('垃圾表达式 → 空', xpathSelect(doc, '///[[[').length, 0);

  // ⑭ absolutize：http → https 升级（AGE 站点 80 端口已死）
  check('absolutize http→https', absolutize('http://a.com/x', 'https://a.com/'),
      'https://a.com/x');
  check('absolutize 相对路径', absolutize('/d/1', 'https://a.com/base/'),
      'https://a.com/d/1');
  check('absolutize 协议相对', absolutize('//a.com/x', 'https://a.com/'),
      'https://a.com/x');
}

// ───────────────────────── JSONPath ─────────────────────────

void testJsonPath() {
  stdout.writeln('── jsonpath_lite ──');
  final doc = jsonDecode('''
{
  "data": {
    "records": [
      {"id": "a1", "title": "番剧A", "meta": {"ep": 12}},
      {"id": "a2", "title": "番剧B", "meta": {"ep": 24}}
    ],
    "slug": "slug-9"
  },
  "sources": [
    {"name": "线路1", "episodes": [{"title": "第1话", "ep": 1}, {"title": "第2话", "ep": 2}]},
    {"name": "线路2", "episodes": [{"title": "第1话", "ep": 1}]}
  ]
}
''');

  check(r'$.data.records[*] 长度', jsonPathRead(doc, r'$.data.records[*]').length, 2);
  check(r'$.data.records[0].title',
      jsonPathFirst(doc, r'$.data.records[0].title'), '番剧A');
  check(r'$.data.slug', jsonPathFirst(doc, r'$.data.slug'), 'slug-9');
  check(r'$.sources[*] 长度', jsonPathRead(doc, r'$.sources[*]').length, 2);

  final src0 = jsonPathFirst(doc, r'$.sources[0]');
  check(r'嵌套 $.episodes[*]',
      jsonPathRead(src0, r'$.episodes[*]').length, 2);
  check(r'嵌套 $.name', jsonPathFirst(src0, r'$.name'), '线路1');

  // 顶层数组（xfdmnext 的 searchApiConfig.listPath 就是 $[*]）
  final arr = jsonDecode('[{"id":1,"title":"x"},{"id":2,"title":"y"}]');
  check(r'$[*] 顶层数组', jsonPathRead(arr, r'$[*]').length, 2);
  check(r'$[1].title', jsonPathFirst(arr, r'$[1].title'), 'y');

  // 引号键
  final q = jsonDecode('{"a b": {"c": 7}}');
  check(r"$['a b'].c", jsonPathFirst(q, r"$['a b'].c"), 7);

  // 非法 → 空（不抛错）
  check(r'非 $ 开头 → 空', jsonPathRead(doc, 'data.records').length, 0);
  check('递归下降不支持 → 空', jsonPathRead(doc, r'$..title').length, 0);
  check('过滤器不支持 → 空', jsonPathRead(doc, r'$.data[?(@.x)]').length, 0);

  // 路径不存在 → null
  check('不存在路径 → null', jsonPathFirst(doc, r'$.nope.deep'), null);
}

// ───────────────────────── 规则库 ─────────────────────────

void testRules() {
  stdout.writeln('── assets/rules/kazumi_rules.json ──');
  final f = File('assets/rules/kazumi_rules.json');
  checkTrue('规则资产存在', f.existsSync());
  if (!f.existsSync()) return;

  final text = f.readAsStringSync();
  // ① 必须是严格合法 JSON（历史上这里就是坏的）
  dynamic data;
  try {
    data = jsonDecode(text);
    checkTrue('JSON 合法', true);
  } catch (e) {
    checkTrue('JSON 合法', false, '$e');
    return;
  }
  checkTrue('顶层是数组', data is List);
  final list = (data as List).cast<Map>();
  checkTrue('规则数 >= 80', list.length >= 80, '实际 ${list.length}');

  // ② 不得再出现被删除的私有字段
  checkTrue('无 adSkipMs 字段', !text.contains('adSkipMs'));
  checkTrue('无 playType 字段', !text.contains('playType'));

  // ③ 每条规则都能被引擎解析
  final rules = RuleRegistry.fromJsonList(text);
  check('可解析规则数 == 总数', rules.length, list.length);

  // ④ api level 全部在支持范围内
  final tooNew = rules.where((r) => r.requiresNewerClient).map((r) => r.name).toList();
  check('无超出 api level 的规则', tooNew.length, 0);

  // ⑤ api 模式规则必须带齐 JSONPath 配置
  final apiRules = rules.where((r) => r.usesApiSearch).toList();
  checkTrue('存在 api 模式规则', apiRules.isNotEmpty);
  for (final r in apiRules) {
    checkTrue('${r.name}: searchApiConfig.request.url 非空',
        r.searchApiConfig.request.url.trim().isNotEmpty);
    checkTrue('${r.name}: listPath 以 \$ 开头',
        r.searchApiConfig.listPath.trim().startsWith(r'$'));
    if (r.usesApiChapter) {
      checkTrue('${r.name}: chapterApiConfig.request.url 非空',
          r.chapterApiConfig.request.url.trim().isNotEmpty);
    }
  }
  stdout.writeln('     api 模式规则: ${apiRules.map((r) => r.name).join(', ')}');

  // ⑥ 每条规则的 XPath 都能编译（不存在语法不支持的字段）
  final bad = <String>[];
  for (final r in rules) {
    if (r.usesApiSearch) continue;
    for (final e in [r.searchList, r.searchName, r.searchResult,
                     r.chapterRoads, r.chapterResult]) {
      if (e.trim().isEmpty) continue;
      if (CompiledXPath.of(e) == null) bad.add('${r.name}: $e');
    }
  }
  checkTrue('全部 XPath 可编译', bad.isEmpty, bad.take(8).join('\n      '));
  if (bad.isNotEmpty) {
    for (final b in bad) {
      stdout.writeln('      - $b');
    }
  }

  // ⑦ 用真实 DOM 跑一遍「全部规则的 searchList」——确认选择器不会抛异常
  const html = '<html><body><div class="a"><ul><li><a href="/x">t</a></li></ul></div></body></html>';
  final doc = html_parser.parse(html);
  var ran = 0;
  for (final r in rules) {
    if (r.usesApiSearch) continue;
    xpathSelect(doc, r.searchList);
    xpathSelect(doc, r.chapterRoads);
    ran++;
  }
  check('XPath 规则全量求值无异常', ran, rules.where((r) => !r.usesApiSearch).length);
}

// ───────────────────────── main ─────────────────────────

void main() {
  stdout.writeln('══ 规则引擎自检 ══\n');
  testXPath();
  stdout.writeln();
  testJsonPath();
  stdout.writeln();
  testRules();
  stdout.writeln('\n══════════════════');
  stdout.writeln('通过 $_pass / 失败 $_fail');
  exit(_fail == 0 ? 0 : 1);
}
