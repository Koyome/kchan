/// WebView 解析器实现（Android）
///
/// ## 与 Kazumi 完全同款的解析逻辑（2026-10-13 重写）
///
/// Kazumi 的 Android 解析核心 = 无头 WebView 加载**原始播放页** + 三段
/// `AT_DOCUMENT_START` 注入脚本，本文件把它们原样移植到 webview_flutter：
///
///  1. **blobParserScript**（非 legacy 源，DM84 / aafun 走这条）：
///     包装 `Response.prototype.text` 与 `XMLHttpRequest` 的 load 事件，
///     **按响应内容是否 `#EXTM3U` 判定** —— 不靠 URL 后缀（jx 的 m3u8
///     地址经常不带 .m3u8），这是 Kazumi 命中率高的关键。
///  2. **videoTagParserScript**：MutationObserver 盯 `<video>/<source>`
///     标签的 src（mp4 直链源走这条）。
///  3. **jsBridgeDebugScript**（legacy 源，api=1 的 AGE 走这条）：
///     MutationObserver 盯 `<iframe>` 的 src —— 真实地址藏在 iframe
///     地址的 query 参数里，Dart 侧用 [decodeVideoSource] 解包。
///
/// 另保留 K酱 原有的 URL 级探测（导航/onUrlChange/周期 probe）作为补充，
/// 双保险。
///
/// ## 为什么 WebView 必须挂进 Widget 树
///
/// webview_flutter 的 `WebViewController` 必须挂进树才持有真实平台 view。
/// 播放页放一个「可见但不拦操作」的小窗 WebView：解析期间用户能看到
/// 「确实在跑」，解析失败时它本身就是可点播的兜底播放器页。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:webview_flutter/webview_flutter.dart';
// Android 专属 WebView 配置（混合内容模式 / 免手势起播）。
// 通用层 webview_flutter 不暴露这两个开关，只能下钻到平台实现。
import 'package:webview_flutter_android/webview_flutter_android.dart';

import 'play_resolver.dart';
import 'diag_log.dart';

/// 是否为媒体流地址
bool isMediaUrl(String u) {
  final l = u.toLowerCase();
  if (l.startsWith('blob:') || l.startsWith('data:')) return false;
  const bad = [
    '.svg', '.css', '.png', '.jpg', '.jpeg', '.gif', '.webp',
    '.woff', '.woff2', '.ttf', '.ico', '.otf', '.json', '.xml',
  ];
  for (final b in bad) {
    if (l.contains(b)) return false; // 命中静态资源后缀 → 不是媒体
  }
  if (l.endsWith('.js') || l.contains('.js?')) return false;
  if (l.endsWith('.html') || l.endsWith('/')) return false;
  return l.contains('.m3u8') || l.contains('.mp4') || l.contains('.flv') ||
      l.contains('.m4s') || l.contains('mime=m3u8') || l.contains('format=m3u8');
}

/// 判断 URL 是否为播放器页面（用于「交给用户手动播」兜底）
bool isPlayerPage(String u) {
  final l = u.toLowerCase();
  return l.contains('/play/') ||
      l.contains('/m3u8/') ||
      l.contains('m3u8?') ||
      l.contains('/player') ||
      l.contains('jx.') ||
      l.contains('/vodplay/') ||
      l.contains('/v_play/');
}

/// 把相对路径补全
String absUrl(String u, String base) {
  if (u.isEmpty) return u;
  if (u.startsWith('//')) return 'https:$u';
  if (u.startsWith('http://') || u.startsWith('https://')) return u;
  try {
    return Uri.parse(base).resolve(u).toString();
  } catch (_) {
    return u;
  }
}

/// Android 端 WebView 解析器。
///
/// 控制器由播放页创建好再传进来 —— 见文件头说明。
class AndroidWebViewResolver implements WebViewResolver {
  final bool preferHls;

  /// 由播放页注入的控制器工厂
  final WebViewControllerFactory controllerFactory;

  AndroidWebViewResolver({
    required this.controllerFactory,
    this.preferHls = true,
  });

  @override
  bool get available => true;

  @override
  Future<ResolvedStream> resolve(
    String url, {
    String referer = '',
    bool legacy = false,
    Duration timeout = const Duration(seconds: 25),
  }) async {
    final completer = Completer<ResolvedStream>();
    final found = <String>[];
    final log = <String>[];

    late final WebViewController ctrl;

    void note(String s) {
      log.add(s);
      debugPrint('[WebView解析] $s');
    }

    ResolvedStream? pickBest() {
      if (found.isEmpty) return null;
      if (preferHls) {
        for (final u in found) {
          if (u.toLowerCase().contains('.m3u8')) {
            return ResolvedStream(
              url: u,
              type: 'application/x-mpegURL',
              via: 'WebView 截获 HLS',
            );
          }
        }
      }
      final u = found.first;
      return ResolvedStream(
        url: u,
        type: u.toLowerCase().contains('.m3u8')
            ? 'application/x-mpegURL'
            : 'video/mp4',
        via: 'WebView 截获',
      );
    }

    void finish(String why) {
      if (completer.isCompleted) return;
      note(why);
      final best = pickBest();
      if (best != null) {
        completer.complete(best);
      } else {
        completer.completeError(ResolveException(
          'WebView 没能截获播放地址',
          detail: log.join(' / '),
        ));
      }
    }

    /// JS 通道上报的统一入口。
    ///
    /// [fromContentSniff] 为真表示这是「`#EXTM3U` 内容嗅探」命中的地址
    /// （Kazumi blobParser 路径）：此时 URL 可能不带任何媒体后缀，
    /// 必须无条件采信 —— 这正是 Kazumi 对 jx 源高命中的关键。
    void onJsReport(String raw, {required String base, bool fromContentSniff = false}) {
      for (final piece in raw.split('\n')) {
        var full = absUrl(piece.trim(), base);
        if (full.isEmpty) continue;
        if (fromContentSniff) {
          // 内容嗅探命中：URL 形态任意，强制按 HLS 处理
          if (!found.contains(full)) {
            found.insert(0, full); // 内容级命中排最前
            note('内容嗅探命中 $full');
          }
          finish('拿到地址（#EXTM3U 内容判定），结束');
          return;
        }
        // legacy 模式：上报的是 iframe src，先解包 query 参数
        final decoded = decodeVideoSource(full);
        if (decoded != full) {
          full = decoded;
          note('legacy 解包 $full');
        }
        if (isMediaUrl(full) && !found.contains(full)) {
          found.add(full);
          note('JS通道命中 $full');
          finish('拿到地址，结束');
          return;
        }
      }
    }

    try {
      ctrl = controllerFactory();
    } catch (e) {
      throw ResolveException('WebView 控制器不可用', detail: e.toString());
    }

    try {
      await ctrl.setJavaScriptMode(JavaScriptMode.unrestricted);
      // 【桌面 UA · 关键】
      //
      // 原来这里用移动 UA（`Android 13; Pixel 6 ... Mobile Safari`），
      // 手机端反馈「解析很慢、解析不出来」。原因是番剧站按 UA 分页面：
      // 移动 UA 拿到的是另一套**移动播放器**，它往往
      //   · 换用不同的播放内核，不在 document/window 层暴露 m3u8
      //   · 或把 iframe 换成需要点击交互才起来的播放器
      // 于是挂钩的 JS 嗅探一条都收不到，只能干等到超时。
      //
      // Windows 版走 EdgeCdpResolver（无头 Edge），UA 天然是桌面浏览器，
      // 同一批源能解析出来 —— 这就是两端表现不一致的根源。
      // 所以改用与桌面一致的 Chrome UA，让站点返回**与电脑上相同的**播放页。
      // （Kazumi 的解析规则同样是按桌面页面结构写的。）
      await ctrl.setUserAgent(
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
      );

      // 【混合内容 · 关键】
      //
      // Android WebView 默认在 https 页面里**拦截** http 子资源。
      // 实测大量源是「播放页 https、m3u8 http」的组合，被拦后嗅探同样
      // 一条都收不到 → 表现就是「解析不出来」。
      // webview_flutter 通用层没暴露这个开关，只能取 Android 专属实例。
      try {
        final plat = ctrl.platform;
        if (plat is AndroidWebViewController) {
          await plat.setMixedContentMode(MixedContentMode.alwaysAllow);
          // 部分播放器要用户手势才起播；解析阶段没有真实手势，放开限制
          await plat.setMediaPlaybackRequiresUserGesture(false);
        }
      } catch (e) {
        kLog('[AndroidWebView] 混合内容设置失败（继续）: $e');
      }

      // 【Kazumi 同款】内容嗅探走独立通道（不带后缀也必须采信）
      await ctrl.addJavaScriptChannel(
        'KChanM3U8',
        onMessageReceived: (msg) =>
            onJsReport(msg.message.trim(), base: url, fromContentSniff: true),
      );
      // URL 级通道（video 标签 / iframe legacy / 周期扫描）
      await ctrl.addJavaScriptChannel(
        'KChanMedia',
        onMessageReceived: (msg) {
          final raw = msg.message.trim();
          if (raw.isEmpty) return;
          onJsReport(raw, base: url);
        },
      );

      // 每次导航都重新挂钩子（多页/换线路场景）
      await ctrl.setNavigationDelegate(NavigationDelegate(
        onNavigationRequest: (req) {
          final u = req.url;
          if (isMediaUrl(u)) {
            if (!found.contains(u)) {
              found.add(u);
              note('导航命中 $u');
            }
            Future.microtask(() => finish('导航命中'));
            return NavigationDecision.navigate;
          }
          return NavigationDecision.navigate;
        },
        onPageStarted: (u) => note('开始加载 $u'),
        onPageFinished: (u) async {
          note('加载完成 $u');
          // 页面换了就重新挂钩子（脚本里用 __kchanHooked 幂等）
          try {
            await ctrl.runJavaScript(legacy ? legacyIframeScript : kazumiSniffScript);
          } catch (_) {}
          try {
            await ctrl.runJavaScript(iframeHookScript);
          } catch (_) {}
          await _probe(ctrl, url, found, note);
          if (found.isNotEmpty) finish('页面完成后探测命中');
        },
        onWebResourceError: (e) => note('资源错误 ${e.errorCode} ${e.description}'),
        onUrlChange: (c) {
          final u = c.url;
          if (u != null && isMediaUrl(u) && !found.contains(u)) {
            found.add(u);
            note('URL 变化命中 $u');
            finish('URL 变化命中');
          }
        },
      ));

      await ctrl.loadRequest(Uri.parse(url));
      note('已发起加载 (legacy=$legacy)');

      // 立即注入一次（尽早 hook fetch/XHR/标签）
      try {
        await ctrl.runJavaScript(legacy ? legacyIframeScript : kazumiSniffScript);
      } catch (_) {}

      // 定时轮询：jx 播放器要先加载 artplayer/hls.js 再发解析请求，给足时间
      for (final ms in [1200, 2500, 4000, 6500, 9000, 13000, 18000, 24000]) {
        Future<void>.delayed(Duration(milliseconds: ms), () async {
          if (completer.isCompleted) return;
          try {
            await ctrl.runJavaScript(iframeHookScript);
          } catch (_) {}
          try {
            await _probe(ctrl, url, found, note);
            if (found.isNotEmpty) finish('轮询命中');
          } catch (e) {
            note('轮询失败 $e');
          }
        });
      }

      return await completer.future.timeout(
        timeout,
        onTimeout: () {
          final best = pickBest();
          if (best != null) return best;
          throw ResolveException('解析超时', detail: log.join(' / '));
        },
      );
    } on ResolveException {
      rethrow;
    } catch (e) {
      throw ResolveException('WebView 解析异常', detail: e.toString());
    }
  }

  Future<void> _probe(
    WebViewController ctrl,
    String base,
    List<String> found,
    void Function(String) note,
  ) async {
    try {
      final r = await ctrl.runJavaScriptReturningResult(probeScript);
      final s = r.toString();
      for (final u in scanMedia(s)) {
        final full = absUrl(u, base);
        if (isMediaUrl(full) && !found.contains(full)) {
          found.add(full);
          note('探测命中 $full');
        }
      }
      // 也直接扫一遍原始返回（scanMedia 的正则可能有边角漏网）
      for (final piece in s.split(RegExp(r'[\s\\",]+'))) {
        final t = piece.trim();
        if (t.startsWith('http') && isMediaUrl(t) && !found.contains(t)) {
          found.add(t);
          note('探测(raw)命中 $t');
        }
      }
    } catch (_) {
      // 页面还没准备好时 runJavaScript 会失败，正常忽略
    }
  }
}

/// 【Kazumi blobParserScript + videoTagParserScript 原样移植】
///
/// 与 Kazumi 的唯一区别：上报通道从 `flutter_inappwebview.callHandler`
/// 换成 webview_flutter 的 `KChanM3U8.postMessage` / `KChanMedia.postMessage`。
///
/// 关键判定：**按响应内容是否 `#EXTM3U` 判定**，而不是 URL 后缀 ——
/// jx 云播的 m3u8 经常长这样：`https://vip.xxx.com/play?id=123&tm=456`，
/// 没有 .m3u8 后缀，纯 URL 匹配必漏。
const String kazumiSniffScript = r'''
(function(){
  if (window.__kchanSniffed) return;
  window.__kchanSniffed = true;

  function reportM3U8(u){
    try{ if (u && typeof u === 'string' && u.length > 4) KChanM3U8.postMessage(u); }catch(e){}
  }
  function reportUrl(u){
    try{ if (u && typeof u === 'string' && u.length > 8) KChanMedia.postMessage(u); }catch(e){}
  }

  // ── 1) blobParser：按「响应内容」嗅探 m3u8（Kazumi 命中率的核心）──
  try{
    var _r_text = window.Response && window.Response.prototype && window.Response.prototype.text;
    if (_r_text){
      window.Response.prototype.text = function(){
        var self = this;
        return new Promise(function(resolve, reject){
          _r_text.call(self).then(function(text){
            resolve(text);
            try{
              if (text && text.trim().indexOf('#EXTM3U') === 0){
                reportM3U8(self.url);
              }
            }catch(e){}
          }).catch(reject);
        });
      };
    }
  }catch(e){}

  try{
    var _open = window.XMLHttpRequest.prototype.open;
    window.XMLHttpRequest.prototype.open = function(){
      var args = arguments;
      this.addEventListener('load', function(){
        try{
          var content = this.responseText;
          if (content && content.trim().indexOf('#EXTM3U') === 0){
            reportM3U8(args[1]);
          }
        }catch(e){}
      });
      return _open.apply(this, args);
    };
  }catch(e){}

  // ── 2) videoTagParser：盯 <video>/<source> 的 src ──
  function processVideoElement(video){
    try{
      var src = video.getAttribute('src');
      if (src && src.trim() !== '' && src.indexOf('blob:') !== 0 && src.indexOf('googleads') < 0){
        reportUrl(src);
        return true;
      }
      var sources = video.getElementsByTagName('source');
      for (var i = 0; i < sources.length; i++){
        src = sources[i].getAttribute('src');
        if (src && src.trim() !== '' && src.indexOf('blob:') !== 0 && src.indexOf('googleads') < 0){
          reportUrl(src);
          return true;
        }
      }
    }catch(e){}
    return false;
  }
  function setupVideoProcessing(){
    try{
      var vs = document.querySelectorAll('video');
      for (var i = 0; i < vs.length; i++){ if (processVideoElement(vs[i])) return; }
      _observer.observe(document.body || document.documentElement, {
        childList: true, subtree: true, attributes: true, attributeFilter: ['src']
      });
    }catch(e){}
  }
  var _observer = new MutationObserver(function(mutations){
    for (var i = 0; i < mutations.length; i++){
      var mutation = mutations[i];
      if (mutation.type === 'attributes' && mutation.target.nodeName === 'VIDEO'){
        if (processVideoElement(mutation.target)) return;
        continue;
      }
      var nodes = mutation.addedNodes;
      for (var j = 0; j < nodes.length; j++){
        var node = nodes[j];
        if (node.nodeName === 'VIDEO'){ if (processVideoElement(node)) return; }
        if (node.querySelectorAll){
          var vids = node.querySelectorAll('video');
          for (var k = 0; k < vids.length; k++){ if (processVideoElement(vids[k])) return; }
        }
      }
    }
  });
  if (document.readyState === 'loading'){
    document.addEventListener('DOMContentLoaded', setupVideoProcessing);
  } else {
    setupVideoProcessing();
  }

  // ── 3) K酱 原有兜底：fetch/XHR 的 URL 级上报 + 周期扫全局变量 ──
  function report(u){ reportUrl(u); }
  window.__kchanReport = report;
  try{
    var _f = window.fetch;
    if (_f){
      window.fetch = function(){
        try{
          var a = arguments[0];
          report(typeof a === 'string' ? a : (a && a.url));
        }catch(e){}
        return _f.apply(this, arguments);
      };
    }
  }catch(e){}
  try{
    var d = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'src');
    if (d && d.set){
      Object.defineProperty(HTMLMediaElement.prototype, 'src', {
        configurable: true,
        get: d.get,
        set: function(v){ try{ report(v); }catch(e){} return d.set.call(this, v); }
      });
    }
  }catch(e){}
  setInterval(function(){
    try{ if (window.Vurl) report(window.Vurl); }catch(e){}
    try{ if (window.art && window.art.url) report(window.art.url); }catch(e){}
    try{ if (window.option && window.option.url) report(window.option.url); }catch(e){}
  }, 700);
})();
''';

/// 【Kazumi jsBridgeDebugScript 原样移植】legacy（api=1）源专用。
///
/// 盯 `<iframe>` 的 src（静态 + 动态插入 + 属性变更全部覆盖），
/// 上报给 Dart 后用 [decodeVideoSource] 从 query 参数里解出真实地址。
const String legacyIframeScript = r'''
(function(){
  if (window.__kchanSniffed) return;
  window.__kchanSniffed = true;

  function report(u){
    try{ if (u && typeof u === 'string' && u.length > 8) KChanMedia.postMessage(u); }catch(e){}
  }
  window.__kchanReport = report;

  function processIframeElement(iframe){
    try{
      var src = iframe.getAttribute('src');
      if (src) report(src);
    }catch(e){}
  }

  // 已有的 iframe 先扫一遍
  try{
    var fs = document.querySelectorAll('iframe');
    for (var i = 0; i < fs.length; i++) processIframeElement(fs[i]);
  }catch(e){}

  var _observer = new MutationObserver(function(mutations){
    mutations.forEach(function(mutation){
      if (mutation.type === 'attributes' && mutation.target.nodeName === 'IFRAME'){
        processIframeElement(mutation.target);
      } else {
        mutation.addedNodes.forEach(function(node){
          if (node.nodeName === 'IFRAME') processIframeElement(node);
          if (node.querySelectorAll){
            node.querySelectorAll('iframe').forEach(processIframeElement);
          }
        });
      }
    });
  });
  _observer.observe(document.documentElement, {
    childList: true,
    subtree: true,
    attributes: true,
    attributeFilter: ['src']
  });
})();
''';

/// 把钩子也挂进子 iframe（jx 播放器常在子 iframe 里，顶层钩子管不到）。
const String iframeHookScript = r'''
(function(){
  if (!window.__kchanReport){
    window.__kchanReport = function(u){
      try{ if (u && typeof u === 'string' && u.length > 8) KChanMedia.postMessage(u); }catch(e){}
    };
  }
  try{
    var fs = document.querySelectorAll('iframe');
    for (var i = 0; i < fs.length; i++){
      var f = fs[i];
      try{ if (f.src) window.__kchanReport(f.src); }catch(e){}
      try{
        var w = f.contentWindow;
        if (!w || w.__kchanHooked) continue;
        var d = w.document;
        if (!d) continue;
        w.__kchanHooked = true;
        (function(w, d){
          function report(u){
            try{ if (u && typeof u === 'string' && u.length > 8) KChanMedia.postMessage(u); }catch(e){}
          }
          try{
            var _f = w.fetch;
            if (_f){ w.fetch = function(){ try{ var a=arguments[0]; report(typeof a==='string'?a:(a&&a.url)); }catch(e){} return _f.apply(this,arguments); }; }
          }catch(e){}
          try{
            var _o = w.XMLHttpRequest.prototype.open;
            w.XMLHttpRequest.prototype.open = function(m,u){ try{ report(u); }catch(e){} return _o.apply(this,arguments); };
          }catch(e){}
          try{
            var dd = Object.getOwnPropertyDescriptor(w.HTMLMediaElement.prototype,'src');
            if (dd && dd.set){
              Object.defineProperty(w.HTMLMediaElement.prototype,'src',{
                configurable:true, get:dd.get,
                set:function(v){ try{ report(v); }catch(e){} return dd.set.call(this,v); }
              });
            }
          }catch(e){}
          try{
            var t = d.querySelectorAll('video,source');
            for (var k=0;k<t.length;k++){ if (t[k].src) report(t[k].src); }
          }catch(e){}
          try{
            setInterval(function(){
              try{ if (w.Vurl) report(w.Vurl); }catch(e){}
              try{ if (w.art && w.art.url) report(w.art.url); }catch(e){}
              try{
                var vs = d.querySelectorAll('video');
                for (var n=0;n<vs.length;n++){ if (vs[n].src) report(vs[n].src); }
              }catch(e){}
            }, 700);
          }catch(e){}
        })(w, d);
      }catch(e){}
    }
  }catch(e){}
  return 'ok';
})();
''';

/// 主动探测脚本：把页面里当前能看到的媒体地址/播放器地址整体吐出来。
const String probeScript = r'''
(function(){
  var out = [];
  function push(v){ try{ if (v && typeof v === 'string') out.push(v); }catch(e){} }
  try{ push(window.Vurl); }catch(e){}
  try{ push(window.art && window.art.url); }catch(e){}
  try{ push(window.option && window.option.url); }catch(e){}
  try{
    var vs = document.querySelectorAll('video');
    for (var i = 0; i < vs.length; i++){
      push(vs[i].src);
      if (vs[i].currentSrc) push(vs[i].currentSrc);
      try{
        for (var c = 0; c < vs[i].childNodes.length; c++){
          var ch = vs[i].childNodes[c];
          if (ch.src) push(ch.src);
        }
      }catch(e){}
    }
  }catch(e){}
  try{
    var ss = document.querySelectorAll('source');
    for (var j = 0; j < ss.length; j++){ push(ss[j].src); }
  }catch(e){}
  try{
    var fs = document.querySelectorAll('iframe');
    for (var k = 0; k < fs.length; k++){
      push(fs[k].src);
      try{
        var w = fs[k].contentWindow, d = w && w.document;
        if (d){
          try{ push(w.Vurl); }catch(e){}
          try{ push(w.art && w.art.url); }catch(e){}
          var ivs = d.querySelectorAll('video,source');
          for (var m = 0; m < ivs.length; m++){ push(ivs[m].src); if (ivs[m].currentSrc) push(ivs[m].currentSrc); }
        }
      }catch(e){}
    }
  }catch(e){}
  try{ out.push(document.documentElement.outerHTML.slice(0, 300000)); }catch(e){}
  return out.join('\n');
})();
''';
