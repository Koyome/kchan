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
        // 进程可能已经自己退出了 —— 不算错误
        final err = r.stderr.toString().trim();
        kLog('[进程] 终止 pid=$pid 返回 ${r.exitCode}${err.isEmpty ? '' : '（$err）'}');
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
    try {
      // 匹配规则：命令行里同时含 "msedge" 与我们的临时目录标记
      final marker = 'kchan-edge-';
      final ps = '''
Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" |
  Where-Object { \$_.CommandLine -like '*$marker*' } |
  ForEach-Object { \$_.ProcessId }
''';
      final r = await Process.run(
        'powershell',
        ['-NoProfile', '-NonInteractive', '-Command', ps],
        runInShell: false,
      ).timeout(const Duration(seconds: 20));
      final pids = r.stdout
          .toString()
          .split(RegExp(r'\r?\n'))
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .map(int.tryParse)
          .whereType<int>()
          .toList();
      if (pids.isEmpty) {
        kLog('[进程] 未发现上次遗留的浏览器进程');
        return;
      }
      kLog('[进程] 发现 ${pids.length} 个上次遗留的浏览器进程，正在清理');
      for (final pid in pids) {
        await killTree(pid, tag: 'orphan');
      }
    } catch (e) {
      kLog('[进程] 孤儿回收失败（忽略）: $e');
    }
  }
}

/// 便捷入口
Future<void> reapAllChildren() => ChildProcessManager.instance.reapAll();
