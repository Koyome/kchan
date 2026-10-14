/// 子进程生命周期管理（专治「退出应用后 Edge 进程仍在」）
///
/// ## 问题（实测）
///
/// `edge_cdp_resolver.dart` 用 `--headless=new` 拉起 msedge 做 CDP 解析，
/// 但释放时只调了 `proc.kill()` —— 那**只杀掉父进程**。
/// Chromium 是多进程架构：父进程之外还有 renderer / GPU / utility /
/// crashpad 等 5～8 个子进程，父进程一死它们全部变成孤儿继续驻留。
///
/// 实测：跑几轮解析后 `Get-Process msedge` 能看到 8 个残留进程，
/// 合上应用也不消失 —— 用户看到的正是这个。
///
/// ## 修法（三重保险）
///
/// 1. **进程树终止**：Windows 上用 `taskkill /F /T /PID`，
///    一条命令连整棵树一起收掉（`/T` 就是 tree）；
/// 2. **登记在册 + 统一回收**：所有拉起的浏览器进程登记到本管理器，
///    应用退出 / `dispose` 时统一清理，避免漏掉某条代码路径；
/// 3. **孤儿回收**：每个实例都用独立的 `--user-data-dir` 临时目录，
///    启动时用该路径去匹配命令行，把**上次运行遗留**的进程也扫掉。
///    这一步能兜住「上次异常退出」的情况。
///
/// 之所以不整体改用 Windows Job Object：那需要 C++ 或较重的 FFI 结构体编排，
/// 而本开发机的 MinGW 工具链损坏、无法改 C++（见 README）。
/// 上面的三重保险在纯 Dart 范围内已能覆盖实测到的全部泄漏场景。
library;

import 'dart:io';

import 'diag_log.dart';

/// 一个被托管的子进程
class _Tracked {
  _Tracked(this.pid, this.tag, this.userDataDir);
  final int pid;

  /// 便于日志辨认（如 'edge'）
  final String tag;

  /// 该实例独占的临时 user-data-dir（用于孤儿回收匹配）
  final String? userDataDir;

  bool reaped = false;
}

class ChildProcessManager {
  ChildProcessManager._();

  static final ChildProcessManager instance = ChildProcessManager._();

  final List<_Tracked> _tracked = [];

  /// 是否已做过一次「上次遗留进程」清扫
  bool _swept = false;

  /// 登记一个刚拉起的浏览器进程
  void track(Process proc, {required String tag, String? userDataDir}) {
    _tracked.add(_Tracked(proc.pid, tag, userDataDir));
    kLog('[进程] 登记 $tag pid=${proc.pid}（当前托管 ${_tracked.length} 个）');
  }

  /// 终止**整棵进程树**。
  ///
  /// Windows 必须用 `taskkill /T` —— Dart 的 `Process.kill()` 没有树的概念。
  Future<void> killTree(int pid, {String tag = ''}) async {
    if (!Platform.isWindows) {
      // 非 Windows：尽力而为（本项目主要面向 Windows / Android）
      try {
        Process.killPid(pid, ProcessSignal.sigterm);
      } catch (_) {}
      return;
    }
    try {
      final r = await Process.run(
        'taskkill',
        ['/F', '/T', '/PID', '$pid'],
        runInShell: false,
      ).timeout(const Duration(seconds: 8));
      if (r.exitCode == 0) {
        kLog('[进程] 已终止进程树 $tag pid=$pid');
      } else {
        // 【降噪】退出码 128 = 「没有找到进程」—— 说明它已经自己退出了。
        // 清扫孤儿时这是**最常见**的情况（父进程杀掉后子进程很快自己也没了），
        // 实测一轮能刷 14 行无意义日志，把真正有用的信息埋掉。
        final err = r.stderr.toString();
        if (err.contains('没有找到进程') || r.exitCode == 128) {
          return; // 静默：目标已消失，符合预期
        }
        kLog('[进程] 终止 pid=$pid 返回 ${r.exitCode}'
            '${err.trim().isEmpty ? '' : '（${err.trim()}）'}');
      }
    } catch (e) {
      kLog('[进程] 终止 pid=$pid 异常: $e');
      try {
        Process.killPid(pid, ProcessSignal.sigkill);
      } catch (_) {}
    }
  }

  /// 释放一个已登记的进程（按 pid）
  Future<void> release(int pid, {String tag = ''}) async {
    final i = _tracked.indexWhere((t) => t.pid == pid);
    if (i >= 0) {
      if (_tracked[i].reaped) return;
      _tracked[i].reaped = true;
    }
    await killTree(pid, tag: tag);
  }

  /// 回收**所有**已登记且尚未释放的进程（应用退出时调用）
  Future<void> reapAll() async {
    final pending = _tracked.where((t) => !t.reaped).toList();
    if (pending.isEmpty) return;
    kLog('[进程] 开始回收 ${pending.length} 个子进程树');
    for (final t in pending) {
      t.reaped = true;
      await killTree(t.pid, tag: t.tag);
    }
    _tracked.clear();
  }

  /// 清扫**上一次运行遗留**的浏览器进程。
  ///
  /// 依据：每个实例都用自己独占的 `--user-data-dir`（位于本应用的临时目录下），
  /// 所以按命令行里的这个路径就能精确匹配到「我们拉起的」进程，
  /// 不会误伤用户自己开的浏览器。
  ///
  /// 由 `main()` 在启动后调用一次（延迟执行，不挡首帧）。
  Future<void> sweepOrphans() async {
    if (_swept) return;
    _swept = true;
    if (!Platform.isWindows) return;
    await _killByMarker(tag: 'orphan');
    _lastSweep = DateTime.now();
  }

  /// 上一次清扫时间（节流用）
  DateTime? _lastSweep;

  /// 运行期**周期性**回收遗留浏览器进程（安全网）。
  ///
  /// ## 为什么需要它
  ///
  /// 正常退出走 `AppLifecycleListener.onExitRequested` → [reapAll]。
  /// 但**崩溃 / 被任务管理器强杀 / 被 Stop-Process 杀掉**时，
  /// 那个钩子不会执行 —— 实测一次运行能留下 14~15 个孤儿浏览器进程，
  /// 下次启动才被 [sweepOrphans] 清掉。
  ///
  /// 对用户的实际影响：连着看几集、期间应用被强杀过一次，
  /// 后台就会攒着几十个 msedge 进程占内存 —— 正是「播放体验变卡」的来源之一。
  ///
  /// ## 安全性
  ///
  /// 用 [minAge] 保证只杀「存在超过 N 秒」的进程。
  /// 当前正在用于解析的浏览器刚启动不久，绝不会被误杀。
  Future<void> reapStale({Duration minAge = const Duration(seconds: 120)}) async {
    if (!Platform.isWindows) return;
    // 节流：最多每 45 秒扫一次，避免频繁起 powershell 反而拖慢
    final now = DateTime.now();
    if (_lastSweep != null && now.difference(_lastSweep!).inSeconds < 45) {
      return;
    }
    _lastSweep = now;
    await _killByMarker(
      tag: 'stale',
      extraFilter: "\$_.CreationDate -lt (Get-Date).AddSeconds(-${minAge.inSeconds})",
    );
  }

  /// 按 `kchan-edge-` 标记查找并终止浏览器进程
  ///
  /// [extraFilter] 追加到 Where-Object 里（如按创建时间过滤）。
  Future<void> _killByMarker({required String tag, String? extraFilter}) async {
    try {
      final marker = 'kchan-edge-';
      final cond = StringBuffer("\$_.CommandLine -like '*$marker*'");
      if (extraFilter != null) cond.write(' -and $extraFilter');
      final ps = '''
Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" |
  Where-Object { $cond } |
  ForEach-Object { \$_.ProcessId }
''';
      final r = await Process.run(
        'powershell',
        ['-NoProfile', '-NonInteractive', '-Command', ps],
        runInShell: false,
      ).timeout(const Duration(seconds: 25));
      final pids = r.stdout
          .toString()
          .split(RegExp(r'\r?\n'))
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .map(int.tryParse)
          .whereType<int>()
          .toList();
      if (pids.isEmpty) {
        if (tag == 'orphan') kLog('[进程] 未发现上次遗留的浏览器进程');
        return;
      }
      kLog('[进程] 发现 ${pids.length} 个$tag浏览器进程，正在清理');
      for (final pid in pids) {
        await killTree(pid, tag: tag);
      }
    } catch (e) {
      kLog('[进程] 清扫浏览器进程失败（忽略）: $e');
    }
  }
}

/// 便捷入口
Future<void> reapAllChildren() => ChildProcessManager.instance.reapAll();
