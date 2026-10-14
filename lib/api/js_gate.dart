/// JS 反爬闸门（Kazumi 反爬能力的等价实现）
///
/// ## 背景
///
/// 部分源站（实测：aafun.cc）全站挂 JS 挑战：第一次请求只返回
/// `<script src="/_guard/html.js?js=delay_jump_html">`，页面由 JS 算好
/// cookie 再刷新，纯 HTTP 永远拿不到内容。挑战脚本是加密的，无法离线复算。
/// Kazumi 的做法是让 WebView 跑一遍（它叫 antiCrawler / cookie 管理）。
///
/// ## 本文件的做法
///
///  1. **检测**：响应体形如 `_guard` / `Security Check` / 极短且只有一个
///     script 标签 → 判定为 JS 闸门。
///  2. **解锁**：用平台 JS 引擎真的加载一次该页面：
///     - Android：挂在 RootShell 的常驻离屏 WebView（[AndroidGateWebView]）
///     - Windows：无头 Edge + CDP（复用 [EdgeCdpResolver] 的通道）
///  3. **取物**：渲染后的 `outerHTML` 直接可用；同时读出 `document.cookie`
///     缓存到内存，后续同域 HTTP 请求带上 Cookie 头 —— 一次解锁，
///     后续搜索/详情/分集全部走快速 HTTP（直到进程结束或 cookie 失效）。
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

import 'diag_log.dart';
import 'edge_cdp_resolver.dart';

/// 判断一段 HTML 是否是「JS 反爬闸门页」
bool looksLikeJsGate(String html) {
  final h = html.trim();
  if (h.contains('/_guard/')) return true;
  if (h.contains('Security Check') && h.length < 4000) return true;
  // 极短且只有一个 script（典型：<script src="/_guard/html.js?...">）
  if (h.length < 600 && h.contains('<script') && !h.contains('<div')) {
    return true;
  }
  return false;
}

/// 平台 JS 抓取器
abstract class JsGateFetcher {
  bool get available;

  /// 用 JS 引擎加载 [url]，返回渲染后的 HTML（失败返回 null）
  Future<String?> fetchRendered(String url,
      {Duration wait = const Duration(seconds: 6)});

  /// 读取某域当前 cookie（解锁后调用）
  Future<String> readCookies(String url);
}

/// 内存 cookie 罐：host → cookie 字符串（进程级，无需持久化）
class GateCookies {
  static final Map<String, String> _jar = {};

  static String? forUrl(String url) {
    final host = Uri.tryParse(url)?.host ?? '';
    if (host.isEmpty) return null;
    return _jar[host];
  }

  static void store(String url, String cookie) {
    final host = Uri.tryParse(url)?.host ?? '';
    if (host.isEmpty || cookie.trim().isEmpty) return;
    _jar[host] = cookie.trim();
    kLog('[JsGate] $host cookie 已缓存 (${cookie.length} 字符)');
  }

  static void clear(String url) {
    final host = Uri.tryParse(url)?.host ?? '';
    _jar.remove(host);
  }
}

// ───────────────────── Android：常驻离屏 WebView ─────────────────────

/// Android 端实现：由一个挂在 Widget 树里的常驻 WebView 驱动。
/// RootShell 启动时调用 [AndroidGateWebView.attach] 注入控制器。
class AndroidGateWebView extends JsGateFetcher {
  static AndroidGateWebView instance = AndroidGateWebView._();
  AndroidGateWebView._();

  /// 由界面层注入：loadUrl / evaluateJs 两个能力
  Future<void> Function(String url)? _loadUrl;
  Future<String> Function(String js)? _evalJs;
  void Function(void Function())? _onPageFinished;
  bool _ready = false;

  void attach({
    required Future<void> Function(String url) loadUrl,
    required Future<String> Function(String js) evalJs,
    required void Function(void Function()) onPageFinished,
  }) {
    _loadUrl = loadUrl;
    _evalJs = evalJs;
    _onPageFinished = onPageFinished;
    _ready = true;
  }

  @override
  bool get available => _ready;

  /// 常驻 WebView 只有一个，并发渲染会互相覆盖页面 → 串行化
  Future<void> _queue = Future<void>.value();

  @override
  Future<String?> fetchRendered(String url,
      {Duration wait = const Duration(seconds: 6)}) {
    final task = _queue.then((_) => _doFetch(url, wait: wait));
    _queue = task.then((_) {}, onError: (_) {});
    return task;
  }

  Future<String?> _doFetch(String url,
      {Duration wait = const Duration(seconds: 6)}) async {
    if (!_ready) return null;
    try {
      final finished = Completer<void>();
      _onPageFinished?.call(() {
        if (!finished.isCompleted) finished.complete();
      });
      await _loadUrl!(url);
      await finished.future.timeout(const Duration(seconds: 12),
          onTimeout: () {});
      // 给挑战页留跑 JS / 二次跳转的时间
      await Future<void>.delayed(wait);
      final html = await _evalJs!(
          'document.documentElement ? document.documentElement.outerHTML : ""');
      return _unquote(html);
    } catch (e) {
      kLog('[JsGate] Android 渲染失败: $e');
      return null;
    }
  }

  @override
  Future<String> readCookies(String url) async {
    if (!_ready) return '';
    try {
      final c = await _evalJs!('document.cookie || ""');
      return _unquote(c) ?? '';
    } catch (_) {
      return '';
    }
  }

  /// webview_flutter 的 runJavaScriptReturningResult 会带 JSON 引号与转义
  static String? _unquote(String raw) {
    var s = raw;
    if (s.length >= 2 && s.startsWith('"') && s.endsWith('"')) {
      s = s.substring(1, s.length - 1);
    }
    s = s
        .replaceAll(r'\"', '"')
        .replaceAll(r'\n', '\n')
        .replaceAll(r'\t', '\t')
        .replaceAll(r'\\', r'\');
    return s.length > 32 ? s : null;
  }
}

// ───────────────────── Windows：Edge CDP ─────────────────────

class WindowsGateWebView extends JsGateFetcher {
  @override
  bool get available => Platform.isWindows;

  @override
  Future<String?> fetchRendered(String url,
      {Duration wait = const Duration(seconds: 6)}) async {
    try {
      return await EdgeCdpResolver.renderedHtml(url, wait: wait);
    } catch (e) {
      kLog('[JsGate] Windows 渲染失败: $e');
      return null;
    }
  }

  @override
  Future<String> readCookies(String url) async {
    try {
      return await EdgeCdpResolver.readCookies(url) ?? '';
    } catch (_) {
      return '';
    }
  }
}

/// 平台工厂
JsGateFetcher createGateFetcher() {
  if (kIsWeb) return AndroidGateWebView.instance; // 不会用到
  if (Platform.isWindows) return WindowsGateWebView();
  return AndroidGateWebView.instance;
}

// ───────────────────── 给 HTTP 抓取层的一站式帮手 ─────────────────────

/// 用平台 JS 引擎解锁 [url] 的反爬闸门：
/// 成功返回渲染后的 HTML，并顺手收割 cookie 进 [GateCookies]。
Future<String?> bypassJsGate(String url, {String referer = ''}) async {
  final fetcher = createGateFetcher();
  if (!fetcher.available) return null;
  final html = await fetcher.fetchRendered(url);
  if (html != null && !looksLikeJsGate(html)) {
    try {
      final ck = await fetcher.readCookies(url);
      if (ck.isNotEmpty) GateCookies.store(url, ck);
    } catch (_) {}
    return html;
  }
  return null;
}
