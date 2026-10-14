#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // ---------------------------------------------------------------------------
  // 【2026-10-12 修复高分屏模糊】双保险声明 Per-Monitor V2 DPI 感知：
  //   1. runner.exe.manifest 已随资源嵌入（见 build_windows.sh）。
  //   2. 这里再运行时调用一次：防止 manifest 丢失/被剥离时 Windows 把进程
  //      当「DPI 不感知」做位图拉伸（= 字体图片整体发虚的根因）。
  // 必须在创建任何窗口 / 初始化 Flutter 引擎之前调用。
  // ---------------------------------------------------------------------------
  if (auto set_ctx = reinterpret_cast<BOOL(WINAPI*)(DPI_AWARENESS_CONTEXT)>(
          GetProcAddress(GetModuleHandleW(L"user32.dll"),
                         "SetProcessDpiAwarenessContext"))) {
    set_ctx(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
  } else {
    // 老系统回退：至少声明 system DPI 感知
    SetProcessDPIAware();
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"K酱 · 追番", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
