/// 规则库在线更新（对齐 Kazumi `plugins_controller` + `init_page` 的机制）
///
/// ## Kazumi 原版做法与本文件的一一对应
///
/// | Kazumi 做法 | 本文件实现 |
/// | --- | --- |
/// | 远程目录 `{repo}index.json`（name / version / lastUpdate） | [_fetchText] + [_parseCatalog] |
/// | GitHub 主仓库 + gitcode 镜像（`_RulesMirrorInterceptor`） | [repos] 多仓库自动故障转移 |
/// | 目录 5 分钟新鲜期 + single-flight（[`isPluginCatalogFresh`]） | [_catalogFresh] + [_catalogFlight] |
/// | 逐段数字版本比对（`utils/version.dart` 的 `needUpdate`） | [BuiltinRules.isNewerVersion] |
/// | 只更新「本地已有且远程更新」的（`_updatablePluginNames`） | [_updatableItems] |
/// | 并发 4 个下载 worker（`_maxConcurrentRuleDownloads`） | [_downloadAll] |
/// | 下载后校验：名字匹配 / api level / **永不降级** | [_validate] |
/// | 同名覆盖或追加（`_replacePlugin`，大小写不敏感） | [BuiltinRules.mergeRules] |
/// | 串行队列落盘，失败整体回滚（`_mutateAndPersistNow`） | [_persistOverride]（tmp→校验→bak→原子替换） |
/// | 启动检查 + toast「检测到 N 条可更新」+「全部更新」动作 | [autoCheck]（检查 → 有更新自动应用 → 回调更新源列表） |
/// | 记录规则搜索有效性（`PluginValidityTracker`） | [RuleUpdater.markSearchValid] / [RuleUpdater.isSearchValid] |
///
/// ## 为什么做成「先检查、后下载」两段式（照抄 Kazumi）
///
/// 一次性把 86 条规则全下下来会在启动时产生 86 个突发请求 —— 既慢、
/// 又容易把站点打爆（用户已反馈过「变卡」）。Kazumi 的做法是：
/// 启动只发 **1 个请求**拉目录，比对出真正有版本更新的那几条，
/// 再提示用户；只有用户确认（或开启自动更新）才下载那几条。
///
/// ## 容错底线（用户明确要求「更新失败不得影响已有功能」）
///
///  - 所有网络 / 解析 / 落盘错误都只进日志并以 `error` 字段返回，**绝不向上抛**；
///  - 覆盖文件写坏时自动恢复 `.bak`；载入时解析失败直接忽略覆盖、继续用内置规则；
///  - 覆盖文件只保存**下载成功且校验通过**的规则；内置资产永远是基线；
///  - 任一条规则下载失败只影响它自己，其余照常应用。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'diag_log.dart';
import 'kazumi_rules.dart';

/// 远程目录里的一条（对齐 KazumiRules `index.json` 的条目）
class RuleCatalogItem {
  final String name;
  final String version;
  final int lastUpdate;
  final String author;

  const RuleCatalogItem({
    required this.name,
    required this.version,
    this.lastUpdate = 0,
    this.author = '',
  });
}

/// 【阶段一：检查】只拉远程目录并做版本比对，**不下载任何规则**
///
/// 对应 Kazumi 的 `refreshPluginCatalog()` + `_updatablePluginNames()`。
class RuleUpdateCheck {
  /// 远程目录条数（0 = 目录没拉到）
  final int catalogCount;

  /// 本地已收录、且远程版本更新的规则（可更新候选，保持目录顺序）
  final List<RuleCatalogItem> updatable;

  /// 实际生效的仓库（空 = 未能连通任何仓库）
  final String repo;

  /// 失败原因（null = 成功）
  final String? error;

  final DateTime at;

  const RuleUpdateCheck({
    this.catalogCount = 0,
    this.updatable = const [],
    this.repo = '',
    this.error,
    required this.at,
  });

  bool get success => error == null;
  bool get hasUpdate => updatable.isNotEmpty;
  int get count => updatable.length;

  String get summary {
    if (!success) return '检查失败：$error';
    if (hasUpdate) return '检测到 $count 条规则可以更新';
    return '已是最新（远程目录 $catalogCount 条）';
  }
}

/// 【阶段二：下载】把候选规则下载 → 校验 → 合并 → 落盘
///
/// 对应 Kazumi 的 `_preparePluginUpdates()` + `updatePlugins()`。
class RuleUpdateReport {
  /// 实际被更新替换的条数
  final int updated;

  /// 已是最新 / 远程不更新的条数
  final int latest;

  /// 下载或校验失败的条数
  final int failed;

  /// api level 超出本客户端支持而跳过的条数
  final int requiresNewerClient;

  final String repo;
  final String? error;
  final DateTime at;

  const RuleUpdateReport({
    this.updated = 0,
    this.latest = 0,
    this.failed = 0,
    this.requiresNewerClient = 0,
    this.repo = '',
    this.error,
    required this.at,
  });

  bool get success => error == null;
  bool get hasUpdate => updated > 0;

  String get summary {
    if (!success) return '更新失败：$error';
    if (updated > 0) return '已更新 $updated 条规则';
    return '无需更新';
  }
}

class RuleUpdater {
  RuleUpdater._();

  static final RuleUpdater instance = RuleUpdater._();

  /// 规则仓库（顺序 = 尝试优先级）。
  ///
  /// Kazumi 是「GitHub 主仓库 + gitcode 镜像（设置开关控制）」。
  /// 交接文档 §8 记着本机 GitHub 时常不可达、raw 通常通，
  /// 所以这里做成**多仓库自动故障转移**而不是让用户手切开关。
  static const List<String> repos = [
    'https://raw.githubusercontent.com/Predidit/KazumiRules/main/',
    'https://cdn.jsdelivr.net/gh/Predidit/KazumiRules@main/',
    'https://raw.gitcode.com/gh_mirrors/ka/KazumiRules/raw/main/',
  ];

  /// 启动自动检查的最小间隔。
  ///
  /// Kazumi 的目录新鲜期是 5 分钟（为「规则商店页」服务）；
  /// 启动检查不需要那么勤 —— 12 小时一次足以覆盖新番周更节奏，
  /// 同时避免每次启动都打远程仓库。手动「检查更新」不受此限制。
  static const Duration autoInterval = Duration(hours: 12);

  /// 单次请求超时（规则仓库在境外，给足；连不上会自动换下一个仓库）
  static const Duration _timeout = Duration(seconds: 12);

  /// 批量下载并发上限（对齐 Kazumi `_maxConcurrentRuleDownloads = 4`）
  static const int _maxConcurrentDownloads = 4;

  final http.Client _c = http.Client();

  /// 覆盖文件（应用文档目录下 rules_override.json），由 App 侧注入
  File? _overrideFile;

  /// 覆盖文件当前内容（内存态）
  List<KazumiRule> _installed = [];

  List<KazumiRule> get installed => _installed;

  /// 本次进程内已验证可用的仓库（下次请求优先用它）
  String? _workingRepo;

  List<RuleCatalogItem>? _catalog;
  DateTime? _lastCheck;

  /// 目录刷新 single-flight：并发的刷新共享一次真实请求
  Future<List<RuleCatalogItem>>? _catalogFlight;

  /// 写入串行化：避免「检查」与「手动更新」同时写覆盖文件
  final _writeLock = _SerialLock();

  DateTime? get lastCheck => _lastCheck;
  List<RuleCatalogItem>? get catalog => _catalog;

  /// 注入覆盖文件路径（main() 在规则加载前调用）
  void installOverrideFile(String path) {
    _overrideFile = File(path);
  }

  // ─────────────────────── 规则有效性追踪 ───────────────────────

  /// 【对齐 Kazumi `PluginValidityTracker`】记录「本次启动后某条规则
  /// 是否成功返回过搜索结果」。UI 上把未验证过的源降权/标灰，
  /// 避免用户一上来就挑了一条其实已经失效的线路。
  ///
  /// 与 Kazumi 一致：**只活在内存里**，进程退出即清空（下次启动重新校验）。
  final Set<String> _searchValid = {};

  void markSearchValid(String name) => _searchValid.add(name.toLowerCase());
  bool isSearchValid(String name) => _searchValid.contains(name.toLowerCase());
  void resetValidity() => _searchValid.clear();

  // ─────────────────────── 覆盖文件：载入 ───────────────────────

  /// 启动时装入「上次下载的规则更新」（不联网）。
  ///
  /// 文件不存在 / 损坏 / 解析为空 → 只记日志并忽略，
  /// 内置资产规则完全不受影响。
  Future<void> loadInstalledOverride() async {
    final f = _overrideFile;
    if (f == null) return;
    try {
      if (!await f.exists()) return;
      final rules = RuleRegistry.fromJsonList(await f.readAsString());
      if (rules.isEmpty) {
        kLog('[规则更新] 覆盖文件为空或无法解析，忽略（${f.path}）');
        return;
      }
      _installed = rules;
      BuiltinRules.setExternalRules(rules);
      kLog('[规则更新] 已载入在线规则 ${rules.length} 条');
    } catch (e) {
      kLog('[规则更新] 覆盖文件读取失败，忽略: ${e.toString().split('\n').first}');
    }
  }

  // ─────────────────────── 远程拉取（多仓库容错） ───────────────────────

  /// 拉一个远程文本；多仓库**竞速**取最快，成功即记住该仓库。
  /// 全部失败抛错（调用方统一吞掉并写入报告）。
  ///
  /// ## 【v2.1.10 · 修「启动卡几十秒」】
  ///
  /// 旧实现是**顺序**尝试：GitHub → jsDelivr → gitcode，每个失败要等满
  /// [_timeout]（12 秒）。实测本网络下：
  ///
  ///     raw.githubusercontent.com   3/3 但中位 **24606ms**  ← 慢
  ///     cdn.jsdelivr.net            0/3 完全不可达          ← 白等 12 秒
  ///     raw.gitcode.com             3/3 中位 **344ms**      ← 最快
  ///
  /// 最快的排在最后 → 每次取规则都要白烧 24 秒以上。
  ///
  /// 现在改成**竞速**：所有源同时发，谁先回 200 用谁。
  /// gitcode 344ms 就回，所以正常情况下 0.3 秒完成，
  /// 而不是「等两个死的源超时」。
  Future<String> _fetchText(String path) async {
    final order = <String>[
      if (_workingRepo != null) _workingRepo!,
      ...repos.where((r) => r != _workingRepo),
    ];

    final completer = Completer<String>();
    Object? lastErr;
    var remaining = order.length;

    for (var i = 0; i < order.length; i++) {
      final repo = order[i];
      // 上次成功的源立即发（它最可能又快又对）；其余错峰 250ms 起步
      final delayMs = i == 0 ? 0 : 250 * i;
      unawaited(Future<void>(() async {
        if (delayMs > 0) {
          await Future<void>.delayed(Duration(milliseconds: delayMs));
        }
        if (completer.isCompleted) {
          remaining--;
          return;
        }
        try {
          final res = await _c.get(
            Uri.parse('$repo$path'),
            headers: {
              'User-Agent': 'kchan-rule-updater',
              'Accept': 'application/json, text/plain, */*',
            },
          ).timeout(_timeout);
          if (res.statusCode == 200) {
            final body = utf8.decode(res.bodyBytes);
            if (body.trim().isNotEmpty) {
              // 【v2.1.10】**只认第一个成功的源，之后不再改**。
              //
              // 竞速时几个源几乎同时返回（都在 300~600ms），谁先到就切谁 ——
              // 实测日志里三个仓库反复横跳：
              //     生效仓库: raw.githubusercontent.com
              //     生效仓库: cdn.jsdelivr.net
              //     生效仓库: raw.gitcode.com
              // 这会让**同一批文件来自不同源**，规则集可能不一致。
              //
              // 现在只在 `_workingRepo == null`（首次或上次全失败后）才认源，
              // 之后一直用它，直到它真的失败。
              if (_workingRepo == null) {
                _workingRepo = repo;
                kLog('[规则更新] 竞速定源: $repo');
              }
              if (!completer.isCompleted) completer.complete(body);
              return;
            }
            lastErr = '空响应';
          } else {
            lastErr = 'HTTP ${res.statusCode}';
          }
        } catch (e) {
          lastErr = e;
        }
        remaining--;
        // 全部出局且没人成功 → 明确失败（绝不让调用方静默挂死）
        if (remaining <= 0 && !completer.isCompleted) {
          completer.completeError(
            StateError('全部规则源均不可用：${lastErr ?? "未知错误"}'),
          );
        }
      }));
    }

    // 保险丝：即使上面的计数逻辑出意外，也保证有结论
    return completer.future.timeout(
      Duration(milliseconds: _timeout.inMilliseconds + 4000),
      onTimeout: () => throw StateError('规则源全部超时（$path）'),
    );
  }

  static List<RuleCatalogItem> _parseCatalog(String raw) {
    final j = jsonDecode(raw);
    if (j is! List) throw const FormatException('index.json 不是数组');
    final out = <RuleCatalogItem>[];
    for (final it in j) {
      if (it is! Map) continue;
      final name = '${it['name'] ?? ''}'.trim();
      final version = '${it['version'] ?? ''}'.trim();
      if (name.isEmpty || version.isEmpty) continue;
      out.add(RuleCatalogItem(
        name: name,
        version: version,
        lastUpdate: (it['lastUpdate'] as num?)?.toInt() ?? 0,
        author: '${it['author'] ?? ''}',
      ));
    }
    if (out.isEmpty) throw const FormatException('index.json 无有效条目');
    return out;
  }

  /// 【可选持久化钩子】由 App 侧注入。
  ///
  /// 本文件刻意**不 import package:flutter**（与 kazumi_rules.dart 一致，
  /// 便于纯 Dart 环境跑校验脚本），所以跨重启的「上次检查时间」由外部提供：
  ///   - [lastCheckReader]：读取上次检查时间戳（毫秒；0 = 从未检查）
  ///   - [lastCheckWriter]：写入本次检查时间戳
  int Function()? lastCheckReader;
  void Function(int ms)? lastCheckWriter;

  /// 目录是否还新鲜（对齐 Kazumi `isPluginCatalogFresh`）
  ///
  /// 优先用持久化的时间戳（跨重启生效）；没有注入钩子时退化为
  /// 进程内时间戳（仅本次启动有效）。
  bool _catalogFresh() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final at = (lastCheckReader?.call() ?? 0) > 0
        ? lastCheckReader!.call()
        : (_lastCheck?.millisecondsSinceEpoch ?? 0);
    if (at <= 0) return false;
    return now - at < autoInterval.inMilliseconds;
  }

  /// 刷新目录：single-flight，并发调用共享一次请求（对齐 `refreshPluginCatalog`）
  Future<List<RuleCatalogItem>> _refreshCatalog() {
    final active = _catalogFlight;
    if (active != null) return active;
    final f = () async {
      final items = _parseCatalog(await _fetchText('index.json'));
      _catalog = items;
      _lastCheck = DateTime.now();
      // 持久化「本次检查时间」，让启动节流跨重启生效
      lastCheckWriter?.call(_lastCheck!.millisecondsSinceEpoch);
      return items;
    }();
    _catalogFlight = f;
    f.whenComplete(() => _catalogFlight = null);
    return f;
  }

  // ─────────────────────── 阶段一：检查可更新 ───────────────────────

  /// 【两段式的第一段】拉远程目录 + 版本比对，返回可更新候选。
  ///
  /// 只发 1 个请求（[autoInterval] 内会直接复用内存里的目录）。
  /// 任何失败都收敛进 [RuleUpdateCheck.error]，**绝不抛异常**。
  Future<RuleUpdateCheck> checkForUpdates({bool force = false}) async {
    try {
      if (force || !_catalogFresh() || _catalog == null) {
        await _refreshCatalog();
      }
      final items = _updatableItems();
      kLog('[规则更新] 目录 ${_catalog?.length ?? 0} 条 / '
          '本地 ${BuiltinRules.all.length} 条 / 可更新 ${items.length} 条');
      return RuleUpdateCheck(
        catalogCount: _catalog?.length ?? 0,
        updatable: items,
        repo: _workingRepo ?? '',
        at: DateTime.now(),
      );
    } catch (e) {
      final msg = e.toString().split('\n').first;
      kLog('[规则更新] 检查失败: $msg');
      return RuleUpdateCheck(error: msg, at: DateTime.now());
    }
  }

  /// 比对：本地已有、且远程版本号更新的规则
  ///
  /// 与 Kazumi 一致的三条语义：
  ///   - 不在远程目录里的（本地独家修补的规则）→ **不动**；
  ///   - 远程版本不高于本地 → 跳过（镜像可能滞后于主仓库）；
  ///   - 本客户端不支持的 api level → 由 [_validate] 单独统计。
  List<RuleCatalogItem> _updatableItems() {
    final catalog = _catalog ?? const [];
    final byName = <String, KazumiRule>{};
    for (final r in BuiltinRules.all) {
      byName[r.name.toLowerCase()] = r;
    }
    final out = <RuleCatalogItem>[];
    for (final c in catalog) {
      final local = byName[c.name.toLowerCase()];
      if (local == null) continue; // 本地没有 → 不自动安装新源
      if (BuiltinRules.isNewerVersion(local.version, c.version)) {
        out.add(c);
      }
    }
    return out;
  }

  // ─────────────────────── 阶段二：下载 + 校验 + 合并 ───────────────────────

  /// 下载一条规则并做 Kazumi 同款校验。
  ///
  /// 返回 `null` 表示失败（错误已记日志），原因由 [where] 归类：
  ///   - `'failed'`：网络 / 解析 / 名字不符
  ///   - `'requiresNewerClient'`：api level 超纲
  ///   - `'notNewer'`：远程版本不高于本地（镜像滞后）
  Future<({KazumiRule? rule, String kind})> _downloadOne(
      RuleCatalogItem c) async {
    KazumiRule rule;
    try {
      final raw = await _fetchText('${c.name}.json');
      final rules = RuleRegistry.fromJsonList(raw);
      if (rules.isEmpty) {
        kLog('[规则更新] ${c.name} 下载内容无法解析为规则');
        return (rule: null, kind: 'failed');
      }
      rule = rules.first;
    } catch (e) {
      kLog('[规则更新] ${c.name} 下载失败: ${e.toString().split('\n').first}');
      return (rule: null, kind: 'failed');
    }
    final kind = _validate(rule, c);
    if (kind != 'ok') return (rule: null, kind: kind);
    return (rule: rule, kind: 'ok');
  }

  /// Kazumi `_preparePluginUpdate` 的校验段（返回 'ok' 或失败原因）
  String _validate(KazumiRule rule, RuleCatalogItem c) {
    // ① 名字必须匹配：防「张冠李戴」的坏包污染本地规则
    if (rule.name.toLowerCase() != c.name.toLowerCase()) {
      kLog('[规则更新] 拒收名字不符的规则：${rule.name} ≠ ${c.name}');
      return 'failed';
    }
    // ② api level 超出本客户端 → 记一笔，不覆盖本地（装了也用不了）
    if (rule.requiresNewerClient) return 'requiresNewerClient';
    // ③ 永不降级
    final local = BuiltinRules.byName(rule.name);
    if (local != null &&
        !BuiltinRules.isNewerVersion(local.version, rule.version)) {
      return 'notNewer';
    }
    return 'ok';
  }

  /// 并发下载（worker 池，最多 [_maxConcurrentDownloads] 个）
  Future<List<({KazumiRule? rule, String kind})>> _downloadAll(
      List<RuleCatalogItem> items) async {
    final results = List<({KazumiRule? rule, String kind})?>.filled(
        items.length, null);
    var next = 0;
    Future<void> worker() async {
      while (next < items.length) {
        final i = next++;
        results[i] = await _downloadOne(items[i]);
      }
    }

    final workers = items.length < _maxConcurrentDownloads
        ? items.length
        : _maxConcurrentDownloads;
    await Future.wait([for (var i = 0; i < workers; i++) worker()]);
    return [
      for (final r in results) r ?? (rule: null, kind: 'failed'),
    ];
  }

  /// 检查并应用规则更新（= 两段式合起来的便捷入口，启动自动检查用）。
  ///
  /// [force] 为 true 时忽略 [autoInterval] 限制（手动刷新用）。
  /// 任何失败都只写日志 + 返回报告，不抛出。
  Future<RuleUpdateReport> updateAll({bool force = false}) async {
    // ① 只拉目录做版本比对（1 个请求）
    final check = await checkForUpdates(force: force);
    if (!check.success) {
      return RuleUpdateReport(
        repo: check.repo,
        error: check.error,
        at: check.at,
      );
    }
    if (!check.hasUpdate) {
      return RuleUpdateReport(
        latest: check.catalogCount,
        repo: check.repo,
        at: check.at,
      );
    }
    // ② 只下载真正有更新的那几条
    return applyUpdates(check.updatable);
  }

  /// 【两段式的第二段】下载 → 校验 → 合并 → 落盘。
  ///
  /// [items] 通常是 [checkForUpdates] 返回的候选；为空时返回「无需更新」。
  /// 逐条独立：某条下载失败只影响它自己，其余照常应用。
  Future<RuleUpdateReport> applyUpdates(List<RuleCatalogItem> items) async {
    if (items.isEmpty) {
      return RuleUpdateReport(
        repo: _workingRepo ?? '',
        at: DateTime.now(),
      );
    }

    final results = await _downloadAll(items);
    final downloaded = <KazumiRule>[];
    var failed = 0, needNewer = 0, notNewer = 0;
    for (final r in results) {
      switch (r.kind) {
        case 'ok':
          downloaded.add(r.rule!);
        case 'requiresNewerClient':
          needNewer++;
        case 'notNewer':
          notNewer++;
        default:
          failed++;
      }
    }

    // ③ 合并进已装覆盖集合 → 原子落盘（串行化）→ 应用到内存
    if (downloaded.isNotEmpty) {
      final merged = BuiltinRules.mergeRules(_installed, downloaded);
      var writeError = '';
      try {
        // 串行化：启动自动检查与手动刷新并发时不会互相覆盖文件
        await _writeLock.run(() => _persistOverride(merged));
      } catch (e) {
        writeError = e.toString().split('\n').first;
      }
      // 【降级策略】哪怕落盘失败，内存里的新规则也照常生效
      // （本次启动仍然受益），只是重启后会回到旧版 —— 有意为之，
      // 优于「因为写盘失败就整批不生效」。
      _installed = merged;
      BuiltinRules.setExternalRules(merged);
      kLog('[规则更新] 已应用 ${downloaded.length} 条更新：'
          '${downloaded.map((r) => '${r.name}→${r.version}').join(', ')}');
      return RuleUpdateReport(
        updated: downloaded.length,
        latest: notNewer,
        failed: failed,
        requiresNewerClient: needNewer,
        repo: _workingRepo ?? '',
        error: writeError.isEmpty ? null : '覆盖文件写入失败（内存已生效，重启后回退）',
        at: DateTime.now(),
      );
    }
    return RuleUpdateReport(
      latest: notNewer,
      failed: failed,
      requiresNewerClient: needNewer,
      repo: _workingRepo ?? '',
      at: DateTime.now(),
    );
  }

  // ─────────────────────── 落盘（备份 + 回退） ───────────────────────

  /// 原子写覆盖文件：写 `.tmp` → 重新解析校验 → 原文件改名 `.bak` → `.tmp` 顶上。
  ///
  /// 任一步失败都恢复 `.bak` 并抛出（调用方据此写报告 / 日志）。
  /// 这样**绝不会**留下一个写坏的覆盖文件导致下次启动规则全丢。
  Future<void> _persistOverride(List<KazumiRule> rules) async {
    final f = _overrideFile;
    if (f == null) return; // 未注入路径（纯 Dart 测试环境）：只留内存态
    final jsonText = const JsonEncoder.withIndent('  ')
        .convert([for (final r in rules) r.toJson()]);
    final bak = File('${f.path}.bak');
    final tmp = File('${f.path}.tmp');
    try {
      await f.parent.create(recursive: true);
      await tmp.writeAsString(jsonText, flush: true);
      // 防御：写出去的东西必须能解析回来，否则绝不替换正式文件
      if (RuleRegistry.fromJsonList(await tmp.readAsString()).isEmpty) {
        throw const FormatException('写出的覆盖文件无法解析');
      }
      if (await f.exists()) {
        if (await bak.exists()) await bak.delete();
        await f.rename(bak.path);
      }
      await tmp.rename(f.path);
    } catch (e) {
      // 回退：有 .bak 就恢复，没有就删掉半成品
      try {
        if (await bak.exists()) {
          if (await f.exists()) await f.delete();
          await bak.rename(f.path);
        }
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
      kLog('[规则更新] 覆盖文件写入失败，已回退: ${e.toString().split('\n').first}');
      rethrow;
    }
  }

  // ─────────────────────── 启动自动检查 ───────────────────────

  /// 启动时的自动检查（对齐 Kazumi `init_page._pluginUpdate`）。
  ///
  /// 流程：拉目录 → 版本比对 → **只下载有更新的几条** → 覆盖合并 →
  /// 成功应用后回调 [onApplied]（App 侧据此重建源列表）。
  ///
  /// 新番出新一集时，这条链路保证解析规则是最新的；
  /// 用户进入详情页 / 点刷新时重新聚合即可拿到最新一集的可用资源。
  ///
  /// **失败只进日志，不影响任何现有规则与功能。**
  Future<void> autoCheck(
      {void Function(RuleUpdateReport report)? onApplied}) async {
    final report = await updateAll();
    kLog('[规则更新] 启动自动检查：${report.summary}');
    if (report.hasUpdate) onApplied?.call(report);
  }
}

/// 串行锁：让多个写覆盖文件的操作一个一个来（对齐 Kazumi 的
/// `AsyncSerialQueue`，这里按本项目规模简化为链式 Future）。
///
/// 用途：启动时的自动检查与设置页的手动刷新可能并发触发，
/// 串行化后不会出现「后写的半成品」覆盖「先写完的完整文件」。
class _SerialLock {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() action) {
    final previous = _tail;
    final completer = Completer<T>();
    _tail = () async {
      // 前一个任务无论成败都不影响后一个（与 Kazumi 的 try/catch 一致）
      await previous.catchError((Object _) {});
      try {
        completer.complete(await action());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    }();
    return completer.future;
  }
}
