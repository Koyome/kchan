/// 枚举窗口调试：打印所有顶层窗口的 pid / 可见性 / owner / 标题
///
/// 用来定位 `window_ctl.dart` 里「找不到本进程顶层窗口」的原因。
library;

import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart' show calloc;
import 'package:ffi/ffi.dart' as pkgffi;

typedef _EnumWindowsC = ffi.Int32 Function(ffi.Pointer, ffi.IntPtr);
typedef _EnumWindowsD = int Function(ffi.Pointer, int);
typedef _GetWindowThreadProcessIdC = ffi.Uint32 Function(ffi.Pointer, ffi.Pointer);
typedef _GetWindowThreadProcessIdD = int Function(ffi.Pointer, ffi.Pointer);
typedef _IsWindowVisibleC = ffi.Int32 Function(ffi.Pointer);
typedef _IsWindowVisibleD = int Function(ffi.Pointer);
typedef _GetWindowC = ffi.Pointer Function(ffi.Pointer, ffi.Uint32);
typedef _GetWindowD = ffi.Pointer Function(ffi.Pointer, int);
typedef _GetWindowTextWC = ffi.Int32 Function(ffi.Pointer, ffi.Pointer, ffi.Int32);
typedef _GetWindowTextWD = int Function(ffi.Pointer, ffi.Pointer, int);
typedef _GetCurrentProcessIdC = ffi.Uint32 Function();
typedef _GetCurrentProcessIdD = int Function();

void main() {
  final user32 = ffi.DynamicLibrary.open('user32.dll');
  final kernel32 = ffi.DynamicLibrary.open('kernel32.dll');

  final enumWindows =
      user32.lookupFunction<_EnumWindowsC, _EnumWindowsD>('EnumWindows');
  final getPid = user32.lookupFunction<_GetWindowThreadProcessIdC,
      _GetWindowThreadProcessIdD>('GetWindowThreadProcessId');
  final isVisible =
      user32.lookupFunction<_IsWindowVisibleC, _IsWindowVisibleD>('IsWindowVisible');
  final getWindow = user32.lookupFunction<_GetWindowC, _GetWindowD>('GetWindow');
  final getText =
      user32.lookupFunction<_GetWindowTextWC, _GetWindowTextWD>('GetWindowTextW');
  final myPid = kernel32.lookupFunction<_GetCurrentProcessIdC,
      _GetCurrentProcessIdD>('GetCurrentProcessId')();

  stdout.writeln('my pid = $myPid\n');
  var total = 0;
  var mine = 0;

  int cb(ffi.Pointer hwnd, int lparam) {
    total++;
    final pidp = calloc<ffi.Uint32>();
    try {
      getPid(hwnd, pidp.cast());
      final pw = pidp.value;
      final vis = isVisible(hwnd);
      final owner = getWindow(hwnd, 4);
      final buf = calloc<ffi.Uint16>(256);
      try {
        getText(hwnd, buf.cast(), 256);
        final title = buf.cast<pkgffi.Utf16>().toDartString();
        if (pw == myPid) {
          mine++;
          stdout.writeln('  MINE hwnd=$hwnd vis=$vis owner=$owner title="$title"');
        } else if (title.contains('K酱') || title.contains('kchan')) {
          stdout.writeln('  kchan? hwnd=$hwnd pid=$pw vis=$vis owner=$owner title="$title"');
        }
      } finally {
        calloc.free(buf);
      }
    } finally {
      calloc.free(pidp);
    }
    return 1;
  }

  final callable =
      ffi.NativeCallable<ffi.Int32 Function(ffi.Pointer, ffi.IntPtr)>.isolateLocal(
          cb,
          exceptionalReturn: 1);
  final ok = enumWindows(callable.nativeFunction.cast(), 0);
  callable.close();
  stdout.writeln('\nEnumWindows 返回 $ok；共枚举 $total 个顶层窗口，其中本进程 $mine 个');
}
