/// 规则库在线更新（RuleUpdater）验证：**联网**跑一遍真实链路。
///
/// 运行：dart run tool/verify_rule_update.dart
///
/// 覆盖点（与 Kazumi 机制逐条对齐）：
///   1. 版本比对 isNewerVersion（含 Kazumi 的补零语义）；
///   2. 覆盖合并 mergeRules（同名覆盖、永不降级、追加新规则）；
///   3. 多仓库故障转移拉 index.json（阶段一：只 1 个请求）；
///   4. 阶段二：并发下载 + 校验（名字匹配 / api level / 不降级）；
///   5. 原子落盘（写坏不替换 + 载入忽略坏文件）；
///   6. 幂等：第二次检查应无可更新项；
///   7. 断网容错：失败只进报告，不抛异常，内置规则完好。
library;

import 'dart:convert';
import 'dart:io';

import 'package:kchan/api/kazumi_rules.dart';
import 'package:kchan/api/rule_update.dart';

int _pass = 0, _fail = 0;

void check(String name, bool ok, [String detail = '']) {
  if (ok) {
    _pass++;
    stdout.writeln('  PASS  $name${detail.isEmpty ? '' : '  ($detail)'}');
  } else {
    _fail++;
    stdout.writeln('  FAIL  $name${detail.isEmpty ? '' : '  ($detail)'}');
  }
}

Future<void> main() async {
  final tmpDir = Directory.systemTemp.createTempSync('kchan_rule_update_');
  final overridePath =
      '${tmpDir.path}${Platform.pathSeparator}rules_override.json';
  stdout.writeln('临时目录: ${tmpDir.path}\n');

  // ── 1. 版本比对（不联网）──
  stdout.writeln('【1】版本比对 isNewerVersion');
  check('1.4 → 1.5 应更新', BuiltinRules.isNewerVersion('1.4', '1.5'));
  check('1.5 → 1.4 不更新', !BuiltinRules.isNewerVersion('1.5', '1.4'));
  check('1.0 → 1.0.1 应更新', BuiltinRules.isNewerVersion('1.0', '1.0.1'));
  check('1.10 → 1.9 不更新', !BuiltinRules.isNewerVersion('1.10', '1.9'));
  check('非法版本退化为不等比较', BuiltinRules.isNewerVersion('abc', 'abd'));

  // ── 2. 合并语义（不联网）──
  stdout.writeln('\n【2】覆盖合并 mergeRules（绝不降级）');
  const base = [
    KazumiRule(name: 'A', version: '1.0', baseURL: 'https://a/'),
    KazumiRule(name: 'B', version: '2.0', baseURL: 'https://b/'),
  ];
  const newer = [
    KazumiRule(name: 'A', version: '1.1', baseURL: 'https://a2/'),
    KazumiRule(name: 'B', version: '1.9', baseURL: 'https://b-old/'),
    KazumiRule(name: 'C', version: '1.0', baseURL: 'https://c/'),
  ];
  final merged = BuiltinRules.mergeRules(base, newer);
  check('合并后条数 = 3', merged.length == 3, '${merged.length}');
  check('A 被更新', merged.firstWhere((r) => r.name == 'A').baseURL == 'https://a2/');
  check('B 不被降级（保留 2.0）',
      merged.firstWhere((r) => r.name == 'B').version == '2.0');
  check('C 追加到末尾', merged.last.name == 'C');

  // ── 3. 载入坏覆盖文件（不联网）──
  //
  // 【注意】必须先 await load()：BuiltinRules.load 是 async，不 await 就读
  // `all` 会拿到「未加载」的空列表 —— 测试自己的 bug（交接文档 §10.1）。
  stdout.writeln('\n【3】坏覆盖文件必须被忽略（不影响内置规则）');
  await BuiltinRules.load(loader: (k) async {
    final f = File(k);
    return f.existsSync() ? f.readAsStringSync() : '';
  });
  final baseCount = BuiltinRules.all.length;
  check('内置规则已加载（应 86 条）', baseCount == 86, '$baseCount');
  File(overridePath).writeAsStringSync('{ this is not json');
  RuleUpdater.instance.installOverrideFile(overridePath);
  await RuleUpdater.instance.loadInstalledOverride();
  check('坏文件载入后规则数不变', BuiltinRules.all.length == baseCount,
      '${BuiltinRules.all.length} vs $baseCount');
  check('坏文件未产出在线更新', BuiltinRules.externalRules.isEmpty);

  // ── 4. 阶段一：检查（只拉目录，1 个请求）──
  stdout.writeln('\n【4】阶段一 checkForUpdates：拉远程目录 + 版本比对');
  final checkResult = await RuleUpdater.instance.checkForUpdates(force: true);
  stdout.writeln('  结果: catalog=${checkResult.catalogCount} '
      'updatable=${checkResult.count} repo=${checkResult.repo} error=${checkResult.error}');
  if (checkResult.success) {
    check('拉到远程目录', checkResult.catalogCount > 0, '${checkResult.catalogCount} 条');
    check('记录生效仓库', checkResult.repo.isNotEmpty, checkResult.repo);
    if (checkResult.hasUpdate) {
      stdout.writeln('  可更新: ${checkResult.updatable.map((c) => '${c.name} ${c.version}').join(', ')}');
      check('候选都是「本地已有且远程更新」', checkResult.updatable.every((c) {
        final local = BuiltinRules.byName(c.name);
        return local != null &&
            BuiltinRules.isNewerVersion(local.version, c.version);
      }));
    } else {
      stdout.writeln('  （全部已是最新，跳过阶段二断言）');
    }
  } else {
    stdout.writeln('  ⚠ 网络不可达 → 验证「失败不影响现有功能」：');
    check('失败后内置规则完好', BuiltinRules.all.length == baseCount);
  }

  // ── 5. 阶段二：下载 + 校验 + 合并 + 落盘 ──
  stdout.writeln('\n【5】阶段二 applyUpdates：下载 → 校验 → 合并 → 原子落盘');
  if (checkResult.success && checkResult.hasUpdate) {
    final report = await RuleUpdater.instance.applyUpdates(checkResult.updatable);
    stdout.writeln('  报告: updated=${report.updated} latest=${report.latest} '
        'failed=${report.failed} newerClient=${report.requiresNewerClient} '
        'error=${report.error}');
    check('覆盖文件已写出', File(overridePath).existsSync());
    final listed = jsonDecode(File(overridePath).readAsStringSync());
    check('覆盖文件是合法 JSON 数组', listed is List, '${(listed as List).length} 条');
    check('内存里已应用', BuiltinRules.externalRules.isNotEmpty,
        '${BuiltinRules.externalRules.length} 条');
    check('规则总数不减少（覆盖而非丢失）',
        BuiltinRules.all.length >= baseCount, '${BuiltinRules.all.length}');
    check('生效规则都在支持范围内',
        BuiltinRules.all.every((r) => !r.requiresNewerClient));
    final names = BuiltinRules.all.map((r) => r.name.toLowerCase()).toSet();
    check('无重名规则', names.length == BuiltinRules.all.length);

    // ── 6. 幂等：第二次检查应无可更新项（不会重复下载）──
    stdout.writeln('\n【6】幂等：第二次检查应无更新');
    final again = await RuleUpdater.instance.checkForUpdates(force: true);
    check('第二次无更新', !again.hasUpdate, 'updatable=${again.count}');
    check('第二次仍不抛错', again.error == null, '${again.error}');

    // ── 7. 重启路径：重新载入覆盖文件，规则数不减少 ──
    stdout.writeln('\n【7】重启路径：重新载入覆盖文件');
    BuiltinRules.setExternalRules(RuleRegistry.fromJsonList(
        File(overridePath).readAsStringSync()));
    check('重载后规则数不减少', BuiltinRules.all.length >= baseCount,
        '${BuiltinRules.all.length} ≥ $baseCount');
  }

  try {
    tmpDir.deleteSync(recursive: true);
  } catch (_) {}

  stdout.writeln('\n══════ 结果：$_pass PASS / $_fail FAIL ══════');
  exit(_fail == 0 ? 0 : 1);
}
