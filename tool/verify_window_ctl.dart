/// Windows 窗口控制 FFI 自检（**独立进程验证**，不依赖按键注入）
///
/// 为什么单独写这个：
/// 全屏是通过播放页的快捷键（F）触发的，而在自动化环境里**按键注入本身很不可靠**
/// （中文输入法会截走按键、`keybd_event` 对某些键不生效）。
/// 于是「全屏到底有没有实现」就被按键注入的不确定性掩盖了。
///
/// 这个程序直接调用 `windowCtl` 的 API，操作**调用方自己的控制台窗口**，
/// 从而把「FFI 代码是否正确」和「按键有没有送到」两件事彻底分开。
///
/// 运行：
///   dart run tool/verify_window_ctl.dart          # 只读检查
///   dart run tool/verify_window_ctl.dart --do     # 真的进入/退出全屏
library;

import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart' show calloc;

import 'package:kchan/api/window_ctl.dart' as wc;

typedef _GetForegroundWindowC = ffi.Pointer Function();
typedef _GetForegroundWindowD = ffi.Pointer Function();
typedef _GetWindowRectC = ffi.Int32 Function(ffi.Pointer, ffi.Pointer);
typedef _GetWindowRectD = int Function(ffi.Pointer, ffi.Pointer);
typedef _GetWindowLongPtrC = ffi.IntPtr Function(ffi.Pointer, ffi.Int32);
typedef _GetWindowLongPtrD = int Function(ffi.Pointer, int);

final class _Rect extends ffi.Struct {
  @ffi.Int32()
  external int left;
  @ffi.Int32()
  external int top;
  @ffi.Int32()
  external int right;
  @ffi.Int32()
  external int bottom;
}

void main(List<String> args) {
  if (!Platform.isWindows) {
    stdout.writeln('仅 Windows 适用');
    exit(0);
  }
  final doIt = args.contains('--do');

  final user32 = ffi.DynamicLibrary.open('user32.dll');
  final getFg = user32.lookupFunction<_GetForegroundWindowC, _GetForegroundWindowD>(
      'GetForegroundWindow');
  final getRect =
      user32.lookupFunction<_GetWindowRectC, _GetWindowRectD>('GetWindowRect');
  final getStyle = user32.lookupFunction<_GetWindowLongPtrC, _GetWindowLongPtrD>(
      ffi.sizeOf<ffi.IntPtr>() == 8 ? 'GetWindowLongPtrW' : 'GetWindowLongW');

  String rectOf(ffi.Pointer h) {
    final r = calloc<_Rect>();
    try {
      if (getRect(h, r.cast()) == 0) return '(取不到)';
      return '${r.ref.right - r.ref.left}x${r.ref.bottom - r.ref.top} '
          'at (${r.ref.left},${r.ref.top})';
    } finally {
      calloc.free(r);
    }
  }

  // 注意：控制台窗口不一定在前台。这里唤醒并前置它，避免误判。
  wc.bringToFront();
  sleep(const Duration(milliseconds: 300));

  final hwndBefore = getFg();
  stdout.writeln('前台窗口        : $hwndBefore');
  stdout.writeln('窗口尺寸        : ${rectOf(hwndBefore)}');
  stdout.writeln('窗口样式 GWL_STYLE: 0x${getStyle(hwndBefore, -16).toRadixString(16)}');
  stdout.writeln('当前是否全屏    : ${wc.isFullscreen}');

  if (!doIt) {
    stdout.writeln('\n（只读检查完成；加 --do 会真的进入/退出全屏）');
    exit(0);
  }

  stdout.writeln('\n>>> enterFullscreen()');
  final ok = wc.enterFullscreen();
  stdout.writeln('返回            : $ok');
  sleep(const Duration(milliseconds: 500));
  final hwndAfter = getFg();
  stdout.writeln('窗口尺寸        : ${rectOf(hwndAfter)}');
  stdout.writeln('窗口样式 GWL_STYLE: 0x${getStyle(hwndAfter, -16).toRadixString(16)}');
  stdout.writeln('isFullscreen    : ${wc.isFullscreen}');

  stdout.writeln('\n>>> exitFullscreen()');
  final ok2 = wc.exitFullscreen();
  stdout.writeln('返回            : $ok2');
  sleep(const Duration(milliseconds: 500));
  stdout.writeln('窗口尺寸        : ${rectOf(getFg())}');
  stdout.writeln('窗口样式 GWL_STYLE: 0x${getStyle(getFg(), -16).toRadixString(16)}');
  stdout.writeln('isFullscreen    : ${wc.isFullscreen}');
}
