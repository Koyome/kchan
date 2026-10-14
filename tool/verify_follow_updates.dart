/// 【追番更新检测验证】用真实线路跑一遍完整逻辑：
///   首次扫描记基线（不误报）→ 模拟落后 → 再扫应报更新 → markSeen 清除
///   → 节流生效 → 各种失败场景不崩
///
/// 运行：
///   dart run tool/verify_follow_updates.dart
library;

import 'dart:async';
import 'dart:io';

import 'package:kchan/api/follow_updates.dart';
import 'package:kchan/api/kazumi_rules.dart';
import 'package:kchan/api/video_sources.dart';
import 'package:kchan/models.dart';

var _pass = 0;
var _fail = 0;

void check(String name, bool ok, {String detail = ''}) {
  if (ok) {
    _pass++;
    stdout.writeln('  PASS  $name${detail.isEmpty ? '' : '  ($detail)'}');
  } else {
    _fail++;
    stdout.writeln('  FAIL  $name${detail.isEmpty ? '' : '  ($detail)'}');
  }
}

/// 一个「内存版」的追番更新快照表，语义与 FollowUpdatesStore.put 保持一致
class _MemStore {
  final map = <int, FollowUpdateEntry>{};

  FollowUpdateEntry? read(int id) => map[id];

  void write(FollowUpdateEntry e) => map[e.subjectId] = e;
}

Future<void> main() async {
  stdout.writeln('════════ 追番更新检测验证 ════════\n');

  // ── 准备：加载真实规则 ──
  await BuiltinRules.load(loader: (k) async {
    final f = File('assets/rules/kazumi_rules.json');
    return f.existsSync() ? f.readAsStringSync() : '';
  });
  SourceRegistry.invalidate();
  check('规则加载', BuiltinRules.all.isNotEmpty, detail: '${BuiltinRules.all.length} 条');

  final sources = SourceRegistry.active.toList();
  check('有启用的线路', sources.isNotEmpty, detail: '${sources.length} 条');

  final mem = _MemStore();
  final svc = FollowUpdateService()
    ..configure(
      reader: mem.read,
      writer: mem.write,
      subjects: () => _subjects,
    );

  // ── 1. 首次扫描：只记基线，不能误报更新 ──
  stdout.writeln('\n── 1. 首次扫描（应只记基线，不报更新）──');
  final r1 = await svc.scan();
  check('扫描了番剧', r1.scanned > 0, detail: 'scanned=${r1.scanned}');
  check('首次不误报更新', r1.updated == 0, detail: 'updated=${r1.updated}');
  check('快照已写入', mem.map.isNotEmpty, detail: '${mem.map.length} 部');
  check(
    '基线集数 > 0',
    mem.map.values.every((e) => e.latestSort > 0),
    detail: mem.map.values.map((e) => '${e.subjectId}:${e.latestSort.toInt()}').join(' '),
  );
  check('首次无红点', mem.map.values.every((e) => !e.hasUpdate));

  // ── 2. 节流：紧接着再扫一次，应被跳过 ──
  stdout.writeln('\n── 2. 节流（短时间内重复扫描应跳过）──');
  final r2 = await svc.scan();
  check('全部跳过', r2.scanned == 0 && r2.skipped > 0, detail: 'scanned=${r2.scanned} skipped=${r2.skipped}');

  // ── 3. 模拟落后：把基线调小，再强制扫描，应报更新 ──
  stdout.writeln('\n── 3. 模拟「出了新一集」（基线调小后强制扫描）──');
  final before = <int, double>{
    for (final e in mem.map.values) e.subjectId: e.latestSort
  };
  for (final e in mem.map.values.toList()) {
    final lowered = (e.latestSort > 1 ? e.latestSort - 1 : 1).toDouble();
    mem.map[e.subjectId] = e.copyWith(latestSort: lowered);
  }
  final r3 = await svc.scan(force: true);
  check('force 跳过节流', r3.scanned > 0, detail: 'scanned=${r3.scanned}');
  check('检测到更新', r3.updated > 0, detail: 'updated=${r3.updated}');
  check(
    '基线已回补到最新',
    mem.map.values.every((e) => (before[e.subjectId] ?? 0) <= e.latestSort),
  );

  final withUpdate = mem.map.values.where((e) => e.hasUpdate).toList();
  check('有红点的番 > 0', withUpdate.isNotEmpty, detail: '${withUpdate.length} 部');
  if (withUpdate.isNotEmpty) {
    check('红点带发现时间', withUpdate.every((e) => e.newSince > 0));
    check('红点记住了来源', withUpdate.every((e) => e.sourceName.isNotEmpty),
        detail: withUpdate.first.sourceName);
  }

  // ── 4. markSeen：看过之后红点消失 ──
  stdout.writeln('\n── 4. markSeen（看过最新集后清红点）──');
  final id = withUpdate.isNotEmpty ? withUpdate.first.subjectId : 0;
  if (id != 0) {
    check('清除前有红点', svc.hasUpdate(id));
    svc.markSeen(id);
    check('清除后无红点', !svc.hasUpdate(id));
    check('清除后仍保留集数', (mem.map[id]?.latestSort ?? 0) > 0, detail: '第 ${mem.map[id]?.latestSort.toInt()} 集');
  }

  // ── 4.5 recordLatest：详情页刷新同步基线，且不能重新点亮红点 ──
  //
  // 这个用例来自一个真实的误报链：用户点进详情看过了（红点清掉），
  // 详情页聚合完又把 newSince 写回 now → 出来又亮红点，等于白清。
  stdout.writeln('\n── 4.5 recordLatest（同步基线但不重复点亮）──');
  if (id != 0) {
    final cur = mem.map[id]?.latestSort ?? 0;
    // 源站偶尔只返回更少集数 → 基线不能被拉低
    svc.recordLatest(id, cur > 1 ? cur - 1 : 1);
    check('基线不被拉低', (mem.map[id]?.latestSort ?? 0) == cur,
        detail: '仍第 ${mem.map[id]?.latestSort.toInt()} 集');
    // 拿到更新的集数 → 基线推进，但红点保持已清除
    svc.recordLatest(id, cur + 1);
    check('基线已推进', (mem.map[id]?.latestSort ?? 0) == cur + 1,
        detail: '第 ${mem.map[id]?.latestSort.toInt()} 集');
    check('不重复点亮红点', !svc.hasUpdate(id));
  }

  // ── 5. 容错：各种失败都不能崩 ──
  stdout.writeln('\n── 5. 容错（失败只进日志，不外抛）──');

  final svcNoProvider = FollowUpdateService();
  final r5a = await svcNoProvider.scan();
  check('未注入 provider 不崩', r5a.scanned == 0);

  final svcThrow = FollowUpdateService()
    ..configure(
      reader: (_) => null,
      writer: (e) {},
      subjects: () => throw StateError('boom'),
    );
  final r5b = await svcThrow.scan();
  check('provider 抛异常不崩', r5b.scanned == 0);

  final svcBadStore = FollowUpdateService()
    ..configure(
      reader: (_) => throw StateError('disk gone'),
      writer: (e) => throw StateError('disk full'),
      subjects: () => _subjects,
    );
  final r5c = await svcBadStore.scan(force: true);
  check('存储读写异常不崩', r5c.scanned == _subjects.length, detail: 'scanned=${r5c.scanned}');

  // ── 汇总 ──
  stdout.writeln('\n════════ 汇总：$_pass 通过 / $_fail 失败 ════════');
  stdout.writeln('首次扫描 $r1');
  stdout.writeln('节流扫描 ${r2.elapsed.inMilliseconds}ms');
  stdout.writeln('更新扫描 $r3');
  // 显式退出：诊断日志内部有周期性 flush 的 Timer，不显式退出的话
  // VM 会一直挂着等它（CI 里表现为脚本跑完不返回）。
  exit(_fail > 0 ? 1 : 0);
}

/// 本季（2026 年 10 月）新番，日文原名 + 中文译名，用于真实检索
final _subjects = <Subject>[
  Subject(id: 100001, name: '薬屋のひとりごと 第3期', nameCn: '药屋少女的呢喃 第三季'),
  Subject(id: 100002, name: 'アオのハコ Season 2', nameCn: '青之箱 第二季'),
  Subject(id: 100003, name: '転生したら剣でしたII', nameCn: '转生就是剑 第二季'),
];
