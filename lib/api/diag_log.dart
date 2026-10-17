/// 极小的日志出口（**不依赖 Flutter**，可在纯 Dart VM 上跑）
///
/// 为什么单独抽一个文件：
///  解析链（kazumi_rules / play_resolver / android_webview_resolver）需要在
///  真机上验证 —— 而验证程序必须跑在**纯 Dart VM** 上（无法启动 Flutter engine）。
///  可 `package:flutter/foundation.dart` 会传递引入 `dart:ui`，
///  导致 `dart:ui is not available on this platform`，验证程序根本编译不出来。
///
/// 所以：把 `debugPrint` 换成一个可注入的函数指针。
///   - 在 App 里：main() 启动时把它接到 `debugPrint`（看到原有日志）
///   - 在验证程序里：默认打 stdout，什么都不用配
library;

import 'dart:async';
import 'dart:io' show Directory, File, IOSink, FileMode, Platform, RandomAccessFile;

// ═══════════════════════ 日志出口 ═══════════════════════

/// 日志回调。默认走 stdout，App 启动后可以替换成 debugPrint。
void Function(String message)? kLogSink = _stdoutSink;

void _stdoutSink(String message) {
  // ignore: avoid_print
  print(message);
}

/// 统一日志入口。
void kLog(String message) {
  final sink = kLogSink;
  if (sink == null) return;
  sink(message);
}

// ═══════════════════════ 文件诊断日志 ═══════════════════════
//
// 目的：把解析链的每一步（源搜索关键词/命中数/耗时/异常）落到磁盘，
// 排查「所有源显示未收录」这类只在用户环境复现的问题时，不再靠猜。
//
// 设计约束：
//  - 不依赖 Flutter（本文件保持纯 Dart，验证程序也能用）；
//  - 写文件失败静默忽略（日志永远不能拖垮业务）；
//  - **绝不能同步刷盘阻塞 UI**（见下方 v1.9.1 说明）。

IOSink? _diagFileSink;
RandomAccessFile? _diagFileSync;
String? _diagFilePath;

/// 【v1.9.1 · 启动提速的关键一处】
///
/// 旧实现每条日志都做 `writeStringSync` + **`flushSync`**。`flushSync` 是一次
/// 真正的磁盘刷写（fsync 走内核缓存也要进 syscall），而解析链一条搜索会打
/// 十几行日志、启动阶段又是最密集的时候 —— 实测这就是「进入软件有点卡」
/// 的稳定贡献项之一（每次 0.1～2ms × 上百条，且全在 UI 线程上）。
///
/// 现在改为**内存缓冲 + 定期批量落盘**：
///  - 平时只 `buffer.add(line)`（纳秒级，无 syscall）；
///  - 每 800ms 或缓冲超过 64 行时，一次性 `writeStringSync` 整块写出；
///  - [flushDiagLog] 供「即将可能崩溃/退出」的关键点主动强刷（如起播前）。
///
/// 崩溃时会丢最后 ≤800ms 的日志 —— 这是可接受的取舍：真要看崩溃现场，
/// [kchan_crash.log]（`main.dart` 的 `_syncDiag`）仍是纯同步写，不受影响。
final List<String> _diagBuffer = <String>[];
Timer? _diagFlushTimer;
const int _kDiagBufferMax = 64;

/// 由 [initDiagFileLog] 调用，启动批量落盘定时器
void _ensureFlushTimer() {
  _diagFlushTimer ??= Timer.periodic(
    const Duration(milliseconds: 800),
    (_) => flushDiagLog(),
  );
}

/// 把缓冲的日志一次写出（幂等、可手动调用）
void flushDiagLog() {
  if (_diagBuffer.isEmpty) return;
  final chunk = _diagBuffer.join();
  _diagBuffer.clear();
  try {
    _diagFileSync?.writeStringSync(chunk);
  } catch (_) {
    // 落盘失败静默忽略：日志永远不能拖垮业务
  }
}

/// 诊断日志文件路径（初始化失败时为 null）
String? get diagLogPath => _diagFilePath;

/// App 启动时调用一次。 directory 为空或不可写时自动跳过。
void initDiagFileLog(String directory) {
  if (_diagFileSink != null) return;
  try {
    final dir = Directory(directory);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    // 【v1.9.8】允许用环境变量指定日志文件名，便于自动化测试用**唯一文件**，
    // 避免多实例抢同一路径 / 删除与重建竞争导致的读取失败。
    final name = Platform.environment['KCHAN_LOG_NAME'] ?? 'kchan_diag.log';
    final path = '$directory${Platform.pathSeparator}$name';
    _diagFilePath = path;
    _diagFileSink = File(path).openWrite(mode: FileMode.append);
    _diagFileSink!.writeln(
        '==== K酱 诊断日志 ${DateTime.now().toIso8601String()} ====');
    // 同步句柄：进程若 native 崩溃，异步 IOSink 的缓冲会整体丢失；
    // 靠 flushDiagLog() 的批量写 + 关键点手动 flush 兼顾性能与留存。
    try {
      _diagFileSync = File(path).openSync(mode: FileMode.append);
    } catch (_) {}
    _ensureFlushTimer();
  } catch (_) {
    _diagFileSink = null;
    _diagFilePath = null;
  }
}

/// 接到 [kLogSink] 上：每条 kLog 带时间戳进内存缓冲，批量落盘。
void diagFileSink(String message) {
  if (_diagFileSync == null) return;
  try {
    final ts = DateTime.now().toIso8601String().substring(11, 23);
    _diagBuffer.add('[$ts] $message\n');
    // 缓冲满了立刻写一次（避免长时间运行内存无限增长）
    if (_diagBuffer.length >= _kDiagBufferMax) flushDiagLog();
  } catch (_) {}
}

/// 构建一个复合 sink：同时发送到 [a] 和 [b]。
void Function(String message) combineSinks(
    void Function(String message) a,
    void Function(String message)? b) {
  return (String message) {
    a(message);
    if (b != null) b(message);
  };
}
