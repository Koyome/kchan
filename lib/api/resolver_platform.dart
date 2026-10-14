/// WebView 解析器的平台工厂
///
/// 各个平台的 WebView 能力差很多：
///
/// | 平台    | 依赖                     | 是否可用 |
/// |---------|--------------------------|----------|
/// | Android | webview_flutter（系统 WebView） | ✅ |
/// | Windows | WebView2（flutter_inappwebview） | 需验证 |
/// | 其它    | —                        | ❌ 走兜底 |
///
/// 关键设计：**解析器的成功不依赖于「平台一定有 WebView」**。
/// 即使 WebView 不可用，[PlayResolver] 仍会返回一条 `manualPageUrl`，
/// 用户可以在系统浏览器里打开播放器页面 —— 这是永远不会「完全看不了」的保证。
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

import 'android_webview_resolver.dart';
import 'edge_cdp_resolver.dart';
import 'play_resolver.dart';
export 'play_resolver.dart' show WebViewControllerFactory;

/// 平台类型
enum WebViewPlatform { android, windows, none }

WebViewPlatform detectWebViewPlatform() {
  if (kIsWeb) return WebViewPlatform.none;
  if (Platform.isAndroid) return WebViewPlatform.android;
  if (Platform.isWindows) return WebViewPlatform.windows;
  return WebViewPlatform.none;
}

/// 建解析器：按平台返回最合适的实现。
///
/// [androidControllerFactory] 由播放页提供 —— Android 的 WebView
/// 必须挂进 Widget 树才能用，所以控制器在界面层创建。
///
/// Windows：EdgeCdpResolver（无头 Edge + CDP，纯 Dart 零原生依赖），
/// 与 Kazumi 的 WebView2 无头解析等效；系统没有 Edge/Chrome 时
/// 自动降级为「HTTP + 浏览器兜底」。
WebViewResolver createWebViewResolver({
  WebViewControllerFactory? androidControllerFactory,
}) {
  switch (detectWebViewPlatform()) {
    case WebViewPlatform.android:
      if (androidControllerFactory == null) {
        return UnsupportedWebViewResolver('Android WebView 控制器尚未初始化');
      }
      return AndroidWebViewResolver(controllerFactory: androidControllerFactory);
    case WebViewPlatform.windows:
      return EdgeCdpResolver();
    case WebViewPlatform.none:
      return UnsupportedWebViewResolver('该平台没有内置 WebView 解析能力');
  }
}
