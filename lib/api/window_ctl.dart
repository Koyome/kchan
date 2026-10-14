/// Windows 原生窗口控制（**纯 `dart:ffi`，不依赖任何原生插件**）
///
/// ## 为什么是 FFI 而不是插件
///
/// 本机 MinGW 工具链已损坏，任何需要重编 `windows/runner/*.cpp` 或引入
/// 原生插件的方案都做不了。`dart:ffi` 在编译期不需要新原生代码，
/// 与 exe 是否需要重链无关 —— 所以窗口控制走 FFI。
///
/// ## 全屏实现：**逐行移植 media_kit 的官方实现**
///
/// Kazumi 桌面端的全屏走 `window_manager`，而 `window_manager` 的
/// Windows 全屏用的就是 media_kit 的 `fullscreen_utils.cpp`
/// （`windows/runner/fullscreen_utils.cpp`，MIT，Hitesh Kumar Saini）。
/// 那套代码是久经验证的，所以这里**严格照搬它的每一步**，
/// 而不是自己发明。之前几轮全屏反复出问题，根因就是我自己那套写法和它
/// 在关键细节上都不一样：
///
/// | 步骤 | media_kit（正确） | 我早期的写法（会出问题） |
/// | --- | --- | --- |
/// | 清样式 | `style & ~WS_OVERLAPPEDWINDOW` | 逐位拼 7 个掩码 |
/// | z 序 | `HWND_TOP` + `SWP_NOOWNERZORDER` | `HWND_TOPMOST` → `NOTOPMOST` 来回切 |
/// | 保存矩形 | `GetWindowPlacement().rcNormalPosition` | `GetWindowRect()` |
/// | 标志 | `SWP_FRAMECHANGED`（进）/ `SWP_NOACTIVATE\|SWP_NOZORDER`（出） | `SWP_SHOWWINDOW` 等 |
///
/// 关键差异解释（都是实测出来的）：
/// - **`~WS_OVERLAPPEDWINDOW` 而不是逐位清**：`WS_OVERLAPPEDWINDOW` 就是
///   `WS_CAPTION|WS_THICKFRAME|WS_MINIMIZEBOX|WS_MAXIMIZEBOX|WS_SYSMENU` 的组合，
///   按它取反正好清掉「属于普通窗口的那一组」，而**保留**
///   `WS_CLIPCHILDREN` / `WS_CLIPSIBLINGS` / `WS_VISIBLE` 等。
///   用 `HWND_TOPMOST` 那一套反而会引入「窗口被反复重排」的问题。
/// - **`HWND_TOP` 足够盖住任务栏**：不需要 topmost。任务栏虽是 topmost，
///   但普通全屏窗口在各家播放器里都是这么做的。
/// - **`GetWindowPlacement().rcNormalPosition`**：这是窗口「还原后」的位置，
///   比 `GetWindowRect()` 更准确 —— 窗口处于最大化时 `GetWindowRect` 拿到的是
///   最大化后的矩形，用它当「还原目标」会让退出全屏后窗口变大。
library;

import 'dart:ffi' as ffi;
import 'dart:io' show Platform;

import 'package:ffi/ffi.dart' show calloc;

import 'diag_log.dart' show kLog;

// ═══════════════════════════ Win32 结构体 ═══════════════════════════

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

final class _MonitorInfo extends ffi.Struct {
  @ffi.Uint32()
  external int cbSize;
  external _Rect rcMonitor;
  external _Rect rcWork;
  @ffi.Uint32()
  external int dwFlags;
}

/// `WINDOWPLACEMENT`
///
/// ```c
/// typedef struct tagWINDOWPLACEMENT {
///   UINT  length;
///   UINT  flags;
///   UINT  showCmd;
///   POINT ptMinPosition;
///   POINT ptMaxPosition;
///   RECT  rcNormalPosition;
/// } WINDOWPLACEMENT;
/// ```
final class _WindowPlacement extends ffi.Struct {
  @ffi.Uint32()
  external int length;
  @ffi.Uint32()
  external int flags;
  @ffi.Uint32()
  external int showCmd;
  @ffi.Int32()
  external int ptMinPositionX;
  @ffi.Int32()
  external int ptMinPositionY;
  @ffi.Int32()
  external int ptMaxPositionX;
  @ffi.Int32()
  external int ptMaxPositionY;
  external _Rect rcNormalPosition;
}

// ═══════════════════════════ Win32 函数签名 ═══════════════════════════

typedef _GetForegroundWindowC = ffi.Pointer Function();
typedef _GetForegroundWindowD = ffi.Pointer Function();

typedef _GetWindowLongPtrC = ffi.IntPtr Function(ffi.Pointer, ffi.Int32);
typedef _GetWindowLongPtrD = int Function(ffi.Pointer, int);

typedef _SetWindowLongPtrC = ffi.IntPtr Function(ffi.Pointer, ffi.Int32, ffi.IntPtr);
typedef _SetWindowLongPtrD = int Function(ffi.Pointer, int, int);

typedef _ShowWindowC = ffi.Int32 Function(ffi.Pointer, ffi.Int32);
typedef _ShowWindowD = int Function(ffi.Pointer, int);

typedef _IsZoomedC = ffi.Int32 Function(ffi.Pointer);
typedef _IsZoomedD = int Function(ffi.Pointer);

typedef _GetWindowRectC = ffi.Int32 Function(ffi.Pointer, ffi.Pointer);
typedef _GetWindowRectD = int Function(ffi.Pointer, ffi.Pointer);

typedef _GetWindowPlacementC = ffi.Int32 Function(ffi.Pointer, ffi.Pointer);
typedef _GetWindowPlacementD = int Function(ffi.Pointer, ffi.Pointer);

typedef _MonitorFromWindowC = ffi.Pointer Function(ffi.Pointer, ffi.Uint32);
typedef _MonitorFromWindowD = ffi.Pointer Function(ffi.Pointer, int);

typedef _GetMonitorInfoC = ffi.Int32 Function(ffi.Pointer, ffi.Pointer);
typedef _GetMonitorInfoD = int Function(ffi.Pointer, ffi.Pointer);

typedef _SetForegroundWindowC = ffi.Int32 Function(ffi.Pointer);
typedef _SetForegroundWindowD = int Function(ffi.Pointer);

typedef _BringWindowToTopC = ffi.Int32 Function(ffi.Pointer);
typedef _BringWindowToTopD = int Function(ffi.Pointer);

typedef _GetCurrentProcessIdC = ffi.Uint32 Function();
typedef _GetCurrentProcessIdD = int Function();

typedef _EnumWindowsC = ffi.Int32 Function(ffi.Pointer, ffi.IntPtr);
typedef _EnumWindowsD = int Function(ffi.Pointer, int);

typedef _GetWindowThreadProcessIdC = ffi.Uint32 Function(ffi.Pointer, ffi.Pointer);
typedef _GetWindowThreadProcessIdD = int Function(ffi.Pointer, ffi.Pointer);

typedef _IsWindowVisibleC = ffi.Int32 Function(ffi.Pointer);
typedef _IsWindowVisibleD = int Function(ffi.Pointer);

typedef _GetWindowC = ffi.Pointer Function(ffi.Pointer, ffi.Uint32);
typedef _GetWindowD = ffi.Pointer Function(ffi.Pointer, int);

/// `SetWindowPos` 的 hWndInsertAfter 允许 `(HWND)-1` / `(HWND)-2` / `(HWND)0`，
/// 所以用 `IntPtr` 签名。
typedef _SetWindowPosC = ffi.Int32 Function(
    ffi.Pointer, ffi.IntPtr, ffi.Int32, ffi.Int32, ffi.Int32, ffi.Int32, ffi.Uint32);
typedef _SetWindowPosD = int Function(
    ffi.Pointer, int, int, int, int, int, int);

typedef _SetThreadDpiAwarenessContextC = ffi.Pointer Function(ffi.Pointer);
typedef _SetThreadDpiAwarenessContextD = ffi.Pointer Function(ffi.Pointer);

typedef _DwmGetWindowAttributeC = ffi.Int32 Function(
    ffi.Pointer, ffi.Uint32, ffi.Pointer, ffi.Uint32);
typedef _DwmGetWindowAttributeD = int Function(ffi.Pointer, int, ffi.Pointer, int);

// ═══════════════════════════ Win32 绑定 ═══════════════════════════

final bool _unsupported = !Platform.isWindows;

class _Win32 {
  static final bool ok = !_unsupported;

  static final ffi.DynamicLibrary _user32 = _unsupported
      ? ffi.DynamicLibrary.process()
      : ffi.DynamicLibrary.open('user32.dll');

  static final ffi.DynamicLibrary _kernel32 = _unsupported
      ? ffi.DynamicLibrary.process()
      : ffi.DynamicLibrary.open('kernel32.dll');

  static final _GetForegroundWindowD getForegroundWindow =
      _user32.lookupFunction<_GetForegroundWindowC, _GetForegroundWindowD>(
          'GetForegroundWindow');

  static final _GetWindowLongPtrD getWindowLongPtr =
      _user32.lookupFunction<_GetWindowLongPtrC, _GetWindowLongPtrD>(
          ffi.sizeOf<ffi.IntPtr>() == 8 ? 'GetWindowLongPtrW' : 'GetWindowLongW');

  static final _SetWindowLongPtrD setWindowLongPtr =
      _user32.lookupFunction<_SetWindowLongPtrC, _SetWindowLongPtrD>(
          ffi.sizeOf<ffi.IntPtr>() == 8 ? 'SetWindowLongPtrW' : 'SetWindowLongW');

  static final _ShowWindowD showWindow =
      _user32.lookupFunction<_ShowWindowC, _ShowWindowD>('ShowWindow');

  static final _IsZoomedD isZoomed =
      _user32.lookupFunction<_IsZoomedC, _IsZoomedD>('IsZoomed');

  static final _GetWindowRectD getWindowRect =
      _user32.lookupFunction<_GetWindowRectC, _GetWindowRectD>('GetWindowRect');

  static final _GetWindowPlacementD getWindowPlacement =
      _user32.lookupFunction<_GetWindowPlacementC, _GetWindowPlacementD>(
          'GetWindowPlacement');

  static final _MonitorFromWindowD monitorFromWindow =
      _user32.lookupFunction<_MonitorFromWindowC, _MonitorFromWindowD>(
          'MonitorFromWindow');

  static final _GetMonitorInfoD getMonitorInfo =
      _user32.lookupFunction<_GetMonitorInfoC, _GetMonitorInfoD>(
          'GetMonitorInfoW');

  static final _SetForegroundWindowD setForegroundWindow =
      _user32.lookupFunction<_SetForegroundWindowC, _SetForegroundWindowD>(
          'SetForegroundWindow');

  static final _BringWindowToTopD bringWindowToTop =
      _user32.lookupFunction<_BringWindowToTopC, _BringWindowToTopD>(
          'BringWindowToTop');

  static final _GetCurrentProcessIdD currentProcessId =
      _kernel32.lookupFunction<_GetCurrentProcessIdC, _GetCurrentProcessIdD>(
          'GetCurrentProcessId');

  static final _EnumWindowsD enumWindows =
      _user32.lookupFunction<_EnumWindowsC, _EnumWindowsD>('EnumWindows');

  static final _GetWindowThreadProcessIdD getWindowThreadProcessId =
      _user32.lookupFunction<_GetWindowThreadProcessIdC,
          _GetWindowThreadProcessIdD>('GetWindowThreadProcessId');

  static final _IsWindowVisibleD isWindowVisible =
      _user32.lookupFunction<_IsWindowVisibleC, _IsWindowVisibleD>(
          'IsWindowVisible');

  static final _GetWindowD getWindow =
      _user32.lookupFunction<_GetWindowC, _GetWindowD>('GetWindow');

  /// `SetWindowPos`。
  ///
  /// hWndInsertAfter 用 `IntPtr` 签名，所以 Dart 侧传 int：
  /// `HWND_TOP`=0、`HWND_TOPMOST`=-1、`HWND_NOTOPMOST`=-2。
  static final _SetWindowPosD setWindowPos =
      _user32.lookupFunction<_SetWindowPosC, _SetWindowPosD>('SetWindowPos');

  static final _SetThreadDpiAwarenessContextD? setThreadDpiAwarenessContext =
      _unsupported
          ? null
          : () {
              try {
                return _user32.lookupFunction<_SetThreadDpiAwarenessContextC,
                    _SetThreadDpiAwarenessContextD>(
                    'SetThreadDpiAwarenessContext');
              } catch (_) {
                return null;
              }
            }();

  /// dwmapi 只用于**排查**（读扩展边框判断还有没有系统边框），不影响功能。
  static final ffi.DynamicLibrary? _dwm = _unsupported
      ? null
      : () {
          try {
            return ffi.DynamicLibrary.open('dwmapi.dll');
          } catch (_) {
            return null;
          }
        }();

  static final _DwmGetWindowAttributeD? dwmGetWindowAttribute = _dwm == null
      ? null
      : _dwm!.lookupFunction<_DwmGetWindowAttributeC, _DwmGetWindowAttributeD>(
          'DwmGetWindowAttribute');
}

// ═══════════════════════════ 常量 ═══════════════════════════

const int _gwlStyle = -16;

/// **`WS_OVERLAPPEDWINDOW`** = `WS_CAPTION | WS_THICKFRAME |
/// WS_MINIMIZEBOX | WS_MAXIMIZEBOX | WS_SYSMENU`（0x00CF0000）。
///
/// ⚠️ **不要用它来做全屏**（v1.9.7 的教训）：
/// media_kit 的 C++ 把 `style & ~WS_OVERLAPPEDWINDOW` 与窗口过程里的
/// `WM_NCCALCSIZE` / `WM_NCHITTEST` 处理**成对使用**；K酱 的 runner 里
/// 没有那段处理，清掉这个样式会让 Flutter 客户区/视频 surface 几何错位
/// —— 表现就是「播放器脱离窗口、画面区透明」。
/// 这里只把该常量用于**诊断日志**（判断当前是不是普通窗口样式）。
const int _wsOverlappedWindow = 0x00CF0000;

const int _wsPopup = 0x80000000;

/// `WS_MAXIMIZE`（0x01000000）。
///
/// 进全屏前必须清掉它，否则 Windows 认为窗口「仍是最大化」，
/// 每次重算窗口矩形都按最大化规则摆放，和我们设的坐标打架
/// （实测位置会连续漂移 `(0,0)→(-30,60)→(-479,585)→(-722,20)`）。
const int _wsMaximize = 0x01000000;

/// WS_CAPTION（标题栏）
const int _wsCaption = 0x00C00000;

/// WS_BORDER（细边框）
const int _wsBorder = 0x00800000;

/// WS_THICKFRAME（可缩放边框）
const int _wsThickFrame = 0x00040000;

// ShowWindow 命令
const int _swShowNormal = 1;
const int _swMaximize = 3;
const int _swRestore = 9;

// SetWindowPos 标志
const int _swpNoActivate = 0x0010;
const int _swpNoZOrder = 0x0004;
const int _swpNoMove = 0x0002;
const int _swpNoSize = 0x0001;
const int _swpNoOwnerZOrder = 0x0200;
const int _swpFrameChanged = 0x0020;
const int _swpShowWindow = 0x0040;

/// `HWND_TOP`
const int _hwndTop = 0;

/// `HWND_TOPMOST` = `(HWND)-1`
const int _hwndTopmost = -1;

/// `HWND_NOTOPMOST` = `(HWND)-2`
const int _hwndNotTopmost = -2;

const int _monitorDefaultToNearest = 0x00000002;

const int _dwmaExtendedFrameBounds = 9;
const int _gwOwner = 4;
const int _dpiPerMonitorAwareV2 = -4;

// ═══════════════════════════ DPI ═══════════════════════════

/// 临时把当前线程切成 `PER_MONITOR_AWARE_V2`，返回原值供还原。
///
/// Flutter 主线程是 DPI-unaware，`GetMonitorInfo` / `SetWindowPos` 会拿到
/// 被缩放虚拟化的逻辑坐标（本机 2560/1.5 = 1707），
/// 于是「按 rcMonitor 铺满」实际只铺 1/1.5 屏幕。用完立刻切回。
int _beginDpiAware() {
  if (!_Win32.ok) return 0;
  final fn = _Win32.setThreadDpiAwarenessContext;
  if (fn == null) return 0;
  try {
    return fn(ffi.Pointer.fromAddress(_dpiPerMonitorAwareV2)).address;
  } catch (_) {
    return 0;
  }
}

void _endDpiAware(int prev) {
  if (prev == 0 || !_Win32.ok) return;
  try {
    _Win32.setThreadDpiAwarenessContext?.call(ffi.Pointer.fromAddress(prev));
  } catch (_) {}
}

// ═══════════════════════════ 状态 ═══════════════════════════

/// 是否处于我们设置的全屏状态
bool _isFullscreen = false;

bool get isFullscreen => _isFullscreen;

/// 进入全屏前的样式（退出时 `| WS_OVERLAPPEDWINDOW` 还原）
int? _savedStyle;

/// 进入全屏前的**正常位置**矩形（`GetWindowPlacement().rcNormalPosition`）
///
/// 用 `rcNormalPosition` 而不是 `GetWindowRect()`：
/// 窗口处于最大化时 `GetWindowRect` 返回的是最大化后的矩形，
/// 拿它当「还原目标」会导致退出全屏后窗口尺寸不对。
(int, int, int, int)? _rectBeforeFullscreen;

/// 进入全屏前是否处于最大化（退出时还原该状态）
bool _wasZoomed = false;

// ═══════════════════════════ 窗口句柄 ═══════════════════════════

ffi.Pointer _cachedHwnd = ffi.nullptr;

/// 取本进程的顶层可见窗口（按 pid 枚举，避免 `GetForegroundWindow` 不可靠）
ffi.Pointer _currentWindow() {
  if (_cachedHwnd != ffi.nullptr) return _cachedHwnd;
  if (!_Win32.ok) return ffi.nullptr;

  final myPid = _Win32.currentProcessId();

  try {
    final fg = _Win32.getForegroundWindow();
    if (fg != ffi.nullptr && _pidOf(fg) == myPid) {
      _cachedHwnd = fg;
      return fg;
    }
  } catch (_) {}

  try {
    final found = calloc<ffi.Pointer>();
    int onWindow(ffi.Pointer hwnd, int lparam) {
      if (_pidOf(hwnd) != myPid) return 1;
      if (_Win32.isWindowVisible(hwnd) == 0) return 1;
      if (_Win32.getWindow(hwnd, _gwOwner) != ffi.nullptr) return 1;
      found.value = hwnd;
      return 0;
    }

    final cb = ffi.NativeCallable<ffi.Int32 Function(ffi.Pointer, ffi.IntPtr)>
        .isolateLocal(onWindow, exceptionalReturn: 1);
    try {
      _Win32.enumWindows(cb.nativeFunction.cast(), 0);
      _cachedHwnd = found.value;
    } finally {
      cb.close();
      calloc.free(found);
    }
    if (_cachedHwnd == ffi.nullptr) {
      kLog('[窗口] 未找到本进程的顶层窗口（pid=$myPid）');
    }
    return _cachedHwnd;
  } catch (e) {
    kLog('[窗口] 枚举窗口失败: $e');
    return ffi.nullptr;
  }
}

int _pidOf(ffi.Pointer hwnd) {
  final pid = calloc<ffi.Uint32>();
  try {
    _Win32.getWindowThreadProcessId(hwnd, pid);
    return pid.value;
  } catch (_) {
    return 0;
  } finally {
    calloc.free(pid);
  }
}

/// 取窗口所在显示器的**完整**范围（`rcMonitor`，不是避开任务栏的 `rcWork`）
(int, int, int, int)? _monitorRect(ffi.Pointer hwnd) {
  final mon = _Win32.monitorFromWindow(hwnd, _monitorDefaultToNearest);
  final mi = calloc<_MonitorInfo>();
  try {
    mi.ref.cbSize = ffi.sizeOf<_MonitorInfo>();
    if (_Win32.getMonitorInfo(mon, mi.cast<ffi.Void>()) == 0) return null;
    final x = mi.ref.rcMonitor.left;
    final y = mi.ref.rcMonitor.top;
    final w = mi.ref.rcMonitor.right - x;
    final h = mi.ref.rcMonitor.bottom - y;
    if (w <= 0 || h <= 0) return null;
    return (x, y, w, h);
  } catch (_) {
    return null;
  } finally {
    calloc.free(mi);
  }
}

// ═══════════════════════════ 全屏（移植 media_kit） ═══════════════════════════

/// 进入全屏：把窗口铺满所在显示器。
///
/// ## ⚠️ 为什么不改窗口样式（v1.9.7 的重要修正）
///
/// 早期版本照搬 media_kit 的 `~WS_OVERLAPPEDWINDOW`，结果**视频播放器脱离了窗口**
/// —— 画面区变成透明（能透出桌面），只有控制条/进度条还在正常绘制，
/// 时间也在走，就是没画面。用户的原话：「那个播放器都脱离窗口了，肯定不能完整运行啊」。
///
/// 原因：media_kit 的 C++ 里，`~WS_OVERLAPPEDWINDOW` 是**和窗口过程里的
/// `WM_NCCALCSIZE` / `WM_NCHITTEST` 处理成对出现**的 ——
/// 它靠「没有 WS_OVERLAPPEDWINDOW」来判断自己处于全屏，并据此把客户区
/// 扩展到整块显示器。**K酱 的 windows/runner 里没有这段处理**
/// （本机 MinGW 损坏，改不了 C++），于是清掉样式后客户区/子窗口（视频 surface）
/// 的几何计算就错位，播放器就不在窗口里了。
///
/// 所以这里**完全不碰窗口样式**，只做「移动 + 缩放 + 置前」：
/// 窗口本身仍是正常的 `WS_OVERLAPPEDWINDOW`，Flutter 引擎与视频 surface
/// 的耦合保持原样 —— 播放器始终在窗口内，稳定可靠。
///
/// 代价：顶部会保留一条标题栏（这是 Windows 对普通窗口的绘制）。
/// 这是**在「改不了 C++」这个硬约束下最稳的做法** —— 优先保证能正常播放。
bool enterFullscreen() {
  if (!_Win32.ok) return false;
  final hwnd = _currentWindow();
  if (hwnd == ffi.nullptr) {
    kLog('[窗口] 进入全屏失败：拿不到窗口句柄');
    return false;
  }
  final prevDpi = _beginDpiAware();
  try {
    // 保存「还原目标」——用 rcNormalPosition（最大化时 GetWindowRect 不准）
    final pl = calloc<_WindowPlacement>();
    try {
      pl.ref.length = ffi.sizeOf<_WindowPlacement>();
      if (_Win32.getWindowPlacement(hwnd, pl.cast<ffi.Void>()) != 0) {
        _rectBeforeFullscreen = (
          pl.ref.rcNormalPosition.left,
          pl.ref.rcNormalPosition.top,
          pl.ref.rcNormalPosition.right - pl.ref.rcNormalPosition.left,
          pl.ref.rcNormalPosition.bottom - pl.ref.rcNormalPosition.top,
        );
      }
    } finally {
      calloc.free(pl);
    }
    // 记住进入前是否最大化
    _wasZoomed = _Win32.isZoomed(hwnd) != 0;

    final target = _monitorRect(hwnd);
    if (target == null) {
      kLog('[窗口] 进入全屏失败：取不到显示器范围');
      return false;
    }
    final x = target.$1, y = target.$2, w = target.$3, h = target.$4;

    // 【关键】清掉最大化状态位，否则 Windows 会按「最大化规则」重算矩形，
    // 和我们设的坐标打架（实测位置会连续漂移）。
    if (_wasZoomed) {
      var st = _Win32.getWindowLongPtr(hwnd, _gwlStyle);
      st = st & ~_wsMaximize;
      _Win32.setWindowLongPtr(hwnd, _gwlStyle, st);
      _Win32.showWindow(hwnd, _swRestore);
    }

    // 只移动 + 缩放 + 置前；**不动 WS_OVERLAPPEDWINDOW**
    _Win32.setWindowPos(hwnd, _hwndTop, x, y, w, h,
        _swpNoOwnerZOrder | _swpShowWindow);

    // ── 去掉标题栏（可选，`KCHAN_FS_STRIP=1`；默认开）────────────────────
    //
    // 目标：既去掉顶部标题栏，又**不弄坏视频渲染**。
    //
    // 关键区别（与 v1.9.6 那次失败的做法不同）：
    //   ✗ 失败做法：`style & ~WS_OVERLAPPEDWINDOW` —— 一次清掉整组
    //     （CAPTION+THICKFRAME+MINBOX+MAXBOX+SYSMENU）并同时改尺寸，
    //     K酱 的 runner 没有 media_kit 那套 WM_NCCALCSIZE 处理，客户区错位。
    //   ✓ 本次做法：**分两步**先「改尺寸」，再「只清 CAPTION/BORDER 两位」，
    //     并保留 THICKFRAME 的尺寸计算语义 —— 让 Flutter 有一次完整的
    //     resize 过程来更新子窗口几何，再动非客户区。
    //
    // 如果这一步在真机上又让视频脱离窗口，把 `KCHAN_FS_STRIP=0`
    // 设进环境变量即可回到「保留标题栏但视频一定正常」的模式。
    final strip = Platform.environment['KCHAN_FS_STRIP'] != '0';
    if (strip) {
      final st = _Win32.getWindowLongPtr(hwnd, _gwlStyle);
      // 清 CAPTION（标题栏）、BORDER、THICKFRAME（缩放边框）。
      //
      // 顺序是这里唯一要紧的事（也是与 v1.9.6 那次失败做法的区别）：
      //   ① 先把窗口尺寸改好（上面的 SetWindowPos 已完成）
      //   ② 再清样式位
      //   ③ 最后用 SWP_FRAMECHANGED 让系统重算非客户区
      // 失败那版把「清整组样式 + 改尺寸 + FRAMECHANGED」塞进**同一个**
      // SetWindowPos，Flutter 没有中间机会去更新子窗口（视频 surface）几何。
      const removeMask = _wsCaption | _wsBorder | _wsThickFrame;
      final cleared = st & ~removeMask;
      _Win32.setWindowLongPtr(hwnd, _gwlStyle, cleared);
      // SWP_FRAMECHANGED 让系统按新样式重算非客户区；几何不变
      _Win32.setWindowPos(hwnd, _hwndTop, x, y, w, h,
          _swpNoOwnerZOrder | _swpFrameChanged);
      kLog('[窗口] 去边框：样式 0x${st.toRadixString(16)} → '
          '0x${cleared.toRadixString(16)}（清 0x'
          '${(st & removeMask).toRadixString(16)}）');
      // 再钉一次，确保去边框后仍精确铺满
      _Win32.setWindowPos(hwnd, _hwndTop, x, y, w, h,
          _swpNoOwnerZOrder | _swpShowWindow);
    }

    _isFullscreen = true;
    kLog('[窗口] 进入全屏（不改 OVERLAPPED 位）：目标 ${w}x$h@($x,$y)'
        '${strip ? " 已去边框" : " 保留边框"}');
    _logGeometry(hwnd, tag: '全屏后');
    return true;
  } catch (e) {
    kLog('[窗口] 进入全屏失败: $e');
    return false;
  } finally {
    _endDpiAware(prevDpi);
  }
}

/// 退出全屏：还原到进入前的窗口位置与大小
bool exitFullscreen() {
  if (!_Win32.ok) return false;
  final hwnd = _currentWindow();
  if (hwnd == ffi.nullptr) return false;
  final prevDpi = _beginDpiAware();
  try {
    _isFullscreen = false;
    // 先把标题栏样式位还原（与 enterFullscreen 的清除动作对称）
    final st = _Win32.getWindowLongPtr(hwnd, _gwlStyle);
    if (st & _wsCaption == 0) {
      _Win32.setWindowLongPtr(hwnd, _gwlStyle, st | _wsCaption | _wsBorder | _wsThickFrame);
      kLog('[窗口] 还原标题栏样式 0x${st.toRadixString(16)} → '
          '0x${(st | _wsCaption | _wsBorder | _wsThickFrame).toRadixString(16)}');
    }
    final r = _rectBeforeFullscreen;
    if (r != null) {
      _Win32.setWindowPos(hwnd, 0, r.$1, r.$2, r.$3, r.$4,
          _swpNoActivate | _swpNoZOrder | _swpFrameChanged);
    }
    // 进全屏前是最大化的，还原回最大化
    if (_wasZoomed) {
      _Win32.showWindow(hwnd, _swMaximize);
      _wasZoomed = false;
    }
    _rectBeforeFullscreen = null;
    _logGeometry(hwnd, tag: '退出全屏后');
    kLog('[窗口] 退出全屏（已还原窗口大小与位置）');
    return true;
  } catch (e) {
    kLog('[窗口] 退出全屏失败: $e');
    return false;
  } finally {
    _endDpiAware(prevDpi);
  }
}

/// 切换全屏
bool toggleFullscreen() {
  final hwnd = _currentWindow();
  if (hwnd == ffi.nullptr) return false;
  final ok = _isFullscreen ? exitFullscreen() : enterFullscreen();
  kLog('[窗口] toggleFullscreen → $ok（现在 isFullscreen=$_isFullscreen）');
  return ok;
}

// ═══════════════════════════ 常规窗口操作 ═══════════════════════════

bool maximize() {
  if (!_Win32.ok) return false;
  final hwnd = _currentWindow();
  if (hwnd == ffi.nullptr) return false;
  try {
    _Win32.showWindow(hwnd, _swMaximize);
    return true;
  } catch (_) {
    return false;
  }
}

bool restore() {
  if (!_Win32.ok) return false;
  final hwnd = _currentWindow();
  if (hwnd == ffi.nullptr) return false;
  try {
    _Win32.showWindow(hwnd, _swRestore);
    return true;
  } catch (_) {
    return false;
  }
}

bool bringToFront() {
  if (!_Win32.ok) return false;
  final hwnd = _currentWindow();
  if (hwnd == ffi.nullptr) return false;
  try {
    _Win32.bringWindowToTop(hwnd);
    _Win32.setForegroundWindow(hwnd);
    return true;
  } catch (_) {
    return false;
  }
}

// ═══════════════════════════ 诊断 ═══════════════════════════

void logGeometry({required String tag}) {
  final hwnd = _currentWindow();
  if (hwnd == ffi.nullptr) {
    kLog('[窗口] $tag: 拿不到窗口句柄');
    return;
  }
  _logGeometry(hwnd, tag: tag);
}

void _logGeometry(ffi.Pointer hwnd, {required String tag}) {
  final prevDpi = _beginDpiAware();
  try {
    var winDesc = '?';
    var frame = '';
    final r = calloc<_Rect>();
    try {
      if (_Win32.getWindowRect(hwnd, r.cast<ffi.Void>()) != 0) {
        final w = r.ref.right - r.ref.left;
        final h = r.ref.bottom - r.ref.top;
        winDesc = '${w}x$h@(${r.ref.left},${r.ref.top})';
        final dwm = calloc<_Rect>();
        try {
          final fn = _Win32.dwmGetWindowAttribute;
          if (fn != null &&
              fn(hwnd, _dwmaExtendedFrameBounds, dwm.cast<ffi.Void>(),
                      ffi.sizeOf<_Rect>()) ==
                  0) {
            frame = ' DWM边框(L${r.ref.left - dwm.ref.left} '
                'T${r.ref.top - dwm.ref.top} '
                'R${r.ref.right - dwm.ref.right} '
                'B${r.ref.bottom - dwm.ref.bottom})';
          }
        } finally {
          calloc.free(dwm);
        }
      }
    } finally {
      calloc.free(r);
    }

    var monDesc = '?';
    final mon = _Win32.monitorFromWindow(hwnd, _monitorDefaultToNearest);
    final mi = calloc<_MonitorInfo>();
    try {
      mi.ref.cbSize = ffi.sizeOf<_MonitorInfo>();
      if (_Win32.getMonitorInfo(mon, mi.cast<ffi.Void>()) != 0) {
        monDesc = '${mi.ref.rcMonitor.right - mi.ref.rcMonitor.left}x'
            '${mi.ref.rcMonitor.bottom - mi.ref.rcMonitor.top}';
      }
    } finally {
      calloc.free(mi);
    }

    final st = _Win32.ok ? _Win32.getWindowLongPtr(hwnd, _gwlStyle) : 0;
    kLog('[窗口] $tag: 窗口 $winDesc | 显示器 $monDesc | '
        '样式 0x${st.toRadixString(16)} '
        '(OVERLAPPED=${st & _wsOverlappedWindow != 0})$frame');
  } catch (_) {
  } finally {
    _endDpiAware(prevDpi);
  }
}
