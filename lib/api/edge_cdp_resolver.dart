/// Windows 端本地解析器：无头 Edge + CDP（Chrome DevTools Protocol）
///
/// ## 为什么是它（而不是 webview_windows 原生插件）
///
/// Kazumi 在 Windows 上用 `webview_windows`（WebView2 原生插件）做无头解析。
/// 但本项目的 Windows 构建链是「MinGW 手搓、无 CMake」，编译 WebView2 宿主
/// （WIL/COM/WebView2Loader）风险极高，会动摇 exe 可启动性。
///
/// 纯 Dart 的等价方案：**系统必装的 Edge 就是 WebView2**。
/// 用 `msedge --headless --remote-debugging-port` 拉起一个无头浏览器，
/// 通过 CDP 的 Network 域嗅探媒体请求 —— 判定标准与 Kazumi 完全一致：
///
///  1. **URL 形态**：`.m3u8 / .mp4 / .flv / .m4s`
///  2. **内容形态**：响应体以 `#EXTM3U` 开头（jx 地址常不带后缀，Kazumi
///     高命中的关键）
///  3. **legacy 形态**（api=1，如 AGE）：iframe/请求地址的 query 参数里
///     藏着编码过的直链，用 [decodeVideoSource] 解包
///
/// 零原生依赖、零新 DLL、构建链完全不动；拿到直链即杀掉浏览器进程，
/// 交回内置播放器 —— 这就是「和 Kazumi 一样的本地解析完整观看」。
///
/// 另提供 [renderedHtml] / [readCookies]：给 JS 反爬闸门（_guard 类）
/// 做「渲染取页面 + 收割 cookie」，见 js_gate.dart。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'diag_log.dart';
import 'child_process_manager.dart';
import 'play_resolver.dart';

class EdgeCdpResolver implements WebViewResolver {
  EdgeCdpResolver();

  /// 仅启动浏览器（诊断 / 特殊用途）：不导航、不注入脚本
  static Future<_EdgeBrowser?> launchBare({List<String> extraArgs = const []}) =>
      _EdgeBrowser.launch(extraArgs: extraArgs);

  /// 用无头 Edge 把 [url] 渲染一遍，返回 `document.documentElement.outerHTML`。
  /// JS 反爬闸门（如 aafun 的 _guard delay_jump）解锁用：
  /// 真实浏览器跑完挑战脚本后，渲染出的就是正页。
  static Future<String?> renderedHtml(
    String url, {
    Duration wait = const Duration(seconds: 8),
    String referer = '',
  }) async {
    final browser = await _EdgeBrowser.launch(referer: referer);
    if (browser == null) return null;
    try {
      await browser.navigate(url);
      await Future<void>.delayed(wait);
      String? html = await _readDoc(browser);
      // 【实测修复】aafun 的 `delay_jump_html` 挑战要跑完 JS 再自行跳转，
      // 首次读到的常常还是只有几十字节的闸门外壳（`<script src="/_guard/...">`）。
      // 旧逻辑只读一次就返回，解析必然 0 命中。这里轮询到正页为止。
      var reloaded = false;
      for (var i = 0; i < 6; i++) {
        if (_isRealPage(html)) return html;
        await Future<void>.delayed(const Duration(seconds: 2));
        html = await _readDoc(browser);
        // 轮询两轮仍拿不到正页：重载一次（挑战脚本往往靠 reload 带上 cookie）
        if (!reloaded && i == 1) {
          reloaded = true;
          try {
            await browser.navigate(url);
          } catch (_) {}
          await Future<void>.delayed(const Duration(seconds: 3));
          html = await _readDoc(browser);
        }
      }
      return _isRealPage(html) ? html : (html != null && html.length > 32 ? html : null);
    } finally {
      await browser.close();
    }
  }

  static Future<String?> _readDoc(_EdgeBrowser browser) => browser.evaluate(
      'document.documentElement ? document.documentElement.outerHTML : ""');

  /// 是否已经是「正页」而不是闸门外壳
  static bool _isRealPage(String? html) {
    if (html == null) return false;
    if (html.length < 500) return false;
    final h = html.toLowerCase();
    if (h.contains('/_guard/')) return false;
    if (h.contains('delay_jump')) return false;
    if (h.contains('security check') && html.length < 4000) return false;
    return true;
  }

  /// 读取某页当前的 `document.cookie`（JS 闸门解锁后的 cookie 收割）
  static Future<String?> readCookies(
    String url, {
    Duration wait = const Duration(seconds: 3),
  }) async {
    final browser = await _EdgeBrowser.launch();
    if (browser == null) return null;
    try {
      await browser.navigate(url);
      await Future<void>.delayed(wait);
      return await browser.evaluate('document.cookie || ""');
    } finally {
      await browser.close();
    }
  }

  bool _available = true;

  @override
  bool get available => _available;

  @override
  Future<ResolvedStream> resolve(
    String url, {
    String referer = '',
    bool legacy = false,
    Duration timeout = const Duration(seconds: 25),
  }) async {
    if (!Platform.isWindows) {
      throw const ResolveException('EdgeCdpResolver 仅支持 Windows');
    }
    final browser = await _EdgeBrowser.launch(referer: referer);
    if (browser == null) {
      _available = false;
      throw const ResolveException('未找到可用的 Edge/Chrome 浏览器',
          detail: 'Windows 本地解析依赖系统浏览器内核');
    }

    final found = <String>[];
    final done = Completer<ResolvedStream>();
    final log = <String>[];

    void note(String s) {
      log.add(s);
      kLog('[EdgeCDP] $s');
    }

    void hit(String u, String via) {
      if (u.isEmpty || found.contains(u)) return;
      found.add(u);
      note('$via: $u');
      if (!done.isCompleted) {
        done.complete(ResolvedStream(
          url: u,
          type: u.toLowerCase().contains('.m3u8')
              ? 'application/x-mpegURL'
              : 'video/mp4',
          headers: {
            'User-Agent': _uaWin,
            // 【实测】jx 的播放清单（如 hhjx /playlist/*.m3u8）会校验来源，
            // 用**清单自己的域名**做 Referer 比源站域名靠谱。
            'Referer': Uri.tryParse(u)?.origin ?? referer,
          },
          via: via,
        ));
      }
    }

    /// 统一判定一个 URL 是否可采信
    void checkUrl(String u, {bool fromContentSniff = false}) {
      if (u.startsWith('blob:') || u.startsWith('data:')) return;
      if (fromContentSniff) {
        hit(u, 'Edge 内容嗅探(#EXTM3U)');
        return;
      }
      // legacy：query 参数里藏直链
      final decoded = decodeVideoSource(u);
      if (decoded != u && _looksLikeMedia(decoded)) {
        hit(decoded, 'Edge legacy 解包');
        return;
      }
      if (_looksLikeMedia(u) && !_isNoiseUrl(u)) {
        hit(u, 'Edge URL 命中');
      }
    }

    // 待查响应体的请求（内容嗅探用）
    final pendingBodies = <String, String>{}; // requestId -> url

    try {
      // 【Kazumi 同款】注入钩子脚本：
      //  - Response.prototype.text / XHR load 的**内容**是否 #EXTM3U
      //  - <video>/<source> 标签的 src
      // 命中即 console.log('KCHAN_M3U8:<url>')，由 Runtime.consoleAPICalled 收。
      await browser.enableRuntime(edpHookScript);

      browser.onConsoleMessage = (text) {
        for (final line in text.split('\n')) {
          final t = line.trim();
          if (t.startsWith(kM3u8Prefix)) {
            final u = t.substring(kM3u8Prefix.length).trim();
            checkUrl(u, fromContentSniff: true);
          }
        }
      };

      browser.onNetworkEvent = (method, params) async {
        switch (method) {
          case 'Network.requestWillBeSent':
            final req = params['request'];
            final u = req is Map ? '${req['url'] ?? ''}' : '';
            if (u.isNotEmpty) checkUrl(u);
            break;
          case 'Network.responseReceived':
            final resp = params['response'];
            if (resp is! Map) return;
            final u = '${resp['url'] ?? ''}';
            final mime = '${resp['mimeType'] ?? ''}'.toLowerCase();
            checkUrl(u);
            // 内容嗅探候选：
            //  - m3u8 常见 mime / 不透明二进制 / 文本 / JSON
            //  - 【实测关键】jx 播放器（hhjx）走 POST /api/parse 拿真实地址，
            //    地址在 **JSON 响应体**里，直接 HTTP 访问会被 403 校验拦下，
            //    只能从响应体里扫出来。
            if (mime.contains('mpegurl') ||
                mime.contains('vnd.apple') ||
                mime.contains('octet-stream') ||
                mime.contains('json') ||
                mime.startsWith('text/')) {
              final reqId = '${params['requestId'] ?? ''}';
              if (reqId.isNotEmpty && u.isNotEmpty) pendingBodies[reqId] = u;
            }
            break;
          case 'Network.loadingFinished':
            final reqId = '${params['requestId'] ?? ''}';
            final u = pendingBodies.remove(reqId);
            if (u != null && !done.isCompleted) {
              final text = await browser.responseBody(reqId);
              if (text == null || text.isEmpty) return;
              // 【Kazumi 同款判定】内容是否 #EXTM3U → 该 URL 就是播放清单
              if (text.trimLeft().startsWith('#EXTM3U')) {
                checkUrl(u, fromContentSniff: true);
                return;
              }
              // 【实测新增】响应体里**藏着的**媒体地址（jx 的 /api/parse 走这条）
              for (final m in RegExp(r'''https?:[^\s"'\\]+?\.(?:m3u8|mp4|flv)[^\s"'\\]*''')
                  .allMatches(text)) {
                checkUrl(m.group(0)!, fromContentSniff: true);
              }
            }
            break;
        }
      };

      await browser.enableNetwork();
      // 【实测】部分站点（dmbus）的播放器 iframe 是**懒加载**的：
      // 视口外的 iframe 永远不触发请求 → 页面里等不到任何 m3u8。
      // 给一个足够大的视口，避免这类假死。
      await browser.setViewport(1280, 900);
      await browser.navigate(url);
      note('开始加载 $url (legacy=$legacy)');

      // 【实测关键兜底】页面里若迟迟没有结果，就把它内部的 iframe
      // 依次**导航为顶层文档**再试（jx 播放器地址实测可直接顶层加载，
      // 如 hhjx：1.2s 即拿到 m3u8）。这样单一浏览器会话内完成多级尝试。
      final navigated = <String>{url};
      for (final atSecond in [9, 16]) {
        Future<void>.delayed(Duration(seconds: atSecond), () async {
          if (done.isCompleted) return;
          final list = await browser.evaluate(
              'JSON.stringify([].map.call(document.querySelectorAll("iframe"), f => f.src))');
          if (list == null || list.isEmpty) return;
          List<dynamic> srcs;
          try {
            srcs = jsonDecode(list) as List<dynamic>;
          } catch (_) {
            return;
          }
          // 【v1.8.0 实测修复】按「像不像播放器」排序后再跳：
          // ezdmw 播放页的第一个 iframe 是评论区，先跳它必超时。
          final scored = <MapEntry<String, int>>[];
          for (final s in srcs) {
            final src = '$s';
            if (src.isEmpty || !src.startsWith('http')) continue;
            if (_isNoiseUrl(src)) continue;
            final low = src.toLowerCase();
            if (low.contains('comment') || low.contains('/ad') || low.contains('advert')) {
              continue;
            }
            var sc = 0;
            for (final k in <String>['player', 'danmuku', 'danmu', 'video', 'play', 'm3u8']) {
              if (low.contains(k)) sc += 10;
            }
            scored.add(MapEntry(src, sc));
          }
          scored.sort((a, b) => b.value.compareTo(a.value));
          for (final e in scored) {
            final src = e.key;
            if (!navigated.add(src)) continue;
            if (done.isCompleted) return;
            note('跳转到页面内 iframe: $src');
            await browser.navigate(src);
            return; // 一次跳一个，留出后续时间
          }
        });
      }

      // 等待命中或超时
      return await done.future.timeout(
        timeout,
        onTimeout: () {
          if (found.isNotEmpty) {
            final u = found.first;
            return ResolvedStream(
              url: u,
              type: u.toLowerCase().contains('.m3u8')
                  ? 'application/x-mpegURL'
                  : 'video/mp4',
              headers: {
                'User-Agent': _uaWin,
                if (referer.isNotEmpty) 'Referer': referer,
              },
              via: 'Edge 解析',
            );
          }
          throw ResolveException('Edge 解析超时',
              detail: log.take(6).join(' / '));
        },
      );
    } on ResolveException {
      rethrow;
    } catch (e) {
      throw ResolveException('Edge 解析异常', detail: e.toString());
    } finally {
      await browser.close();
    }
  }

  static const _uaWin =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

  static bool _looksLikeMedia(String u) {
    return RegExp(r'\.(m3u8|mp4|flv|m4s|ts)(?:[?#]|$)', caseSensitive: false)
        .hasMatch(u);
  }

  static bool _isNoiseUrl(String u) {
    final l = u.toLowerCase();
    const bad = [
      'baidu.com', 'hm.js', 'google-analytics', 'googletagmanager',
      'doubleclick', 'googleads', 'googlesyndication', '.gif', '.png',
      '.jpg', '.jpeg', '.webp', '.svg', '.css', '.woff',
    ];
    for (final b in bad) {
      if (l.contains(b)) return true;
    }
    return false;
  }
}

/// JS 钩子回传前缀（避免与页面自身的 console 混淆）
const String kM3u8Prefix = 'KCHAN_M3U8:';

/// 【Kazumi blobParserScript + videoTagParserScript 的 CDP 版本】
/// 判定标准与 Kazumi 完全一致：按**响应内容是否 #EXTM3U**，而不是 URL 后缀。
const String edpHookScript = r'''
(function(){
  if (window.__kchanHooked) return;
  window.__kchanHooked = true;
  function report(u){
    try{
      if (u && typeof u === 'string' && u.length > 4){
        console.log('KCHAN_M3U8:' + u);
      }
    }catch(e){}
  }
  try{
    var _r_text = window.Response && window.Response.prototype && window.Response.prototype.text;
    if (_r_text){
      window.Response.prototype.text = function(){
        var self = this;
        return new Promise(function(resolve, reject){
          _r_text.call(self).then(function(text){
            resolve(text);
            try{
              if (text && text.trim().indexOf('#EXTM3U') === 0) report(self.url);
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
          var c = this.responseText;
          if (c && c.trim().indexOf('#EXTM3U') === 0) report(args[1]);
        }catch(e){}
      });
      return _open.apply(this, args);
    };
  }catch(e){}
  function processVideo(video){
    try{
      var src = video.getAttribute('src');
      if (src && src.trim() !== '' && src.indexOf('blob:') !== 0 && src.indexOf('googleads') < 0){ report(src); return true; }
      var ss = video.getElementsByTagName('source');
      for (var i=0;i<ss.length;i++){
        src = ss[i].getAttribute('src');
        if (src && src.trim() !== '' && src.indexOf('blob:') !== 0){ report(src); return true; }
      }
    }catch(e){}
    return false;
  }
  function setup(){
    try{
      var vs = document.querySelectorAll('video');
      for (var i=0;i<vs.length;i++){ if (processVideo(vs[i])) return; }
      _obs.observe(document.body || document.documentElement, {
        childList:true, subtree:true, attributes:true, attributeFilter:['src']
      });
    }catch(e){}
  }
  var _obs = new MutationObserver(function(ms){
    for (var i=0;i<ms.length;i++){
      var m = ms[i];
      if (m.type === 'attributes' && m.target.nodeName === 'VIDEO'){ if (processVideo(m.target)) return; continue; }
      var ns = m.addedNodes;
      for (var j=0;j<ns.length;j++){
        if (ns[j].nodeName === 'VIDEO'){ if (processVideo(ns[j])) return; }
        if (ns[j].querySelectorAll){
          var vv = ns[j].querySelectorAll('video');
          for (var k=0;k<vv.length;k++){ if (processVideo(vv[k])) return; }
        }
      }
    }
  });
  if (document.readyState === 'loading'){
    document.addEventListener('DOMContentLoaded', setup);
  } else { setup(); }
})();
''';

/// 一次性的无头浏览器会话：启动 → CDP 连接 → 导航/评估/网络事件 → 清理
class _EdgeBrowser {
  final Process _proc;
  final WebSocketChannel _ws;
  final _CdpSession _cdp;
  final String _sessionId; // 主页面会话（导航 / evaluate 用这个）
  final Directory _tmp;

  /// 已挂载的全部会话（含跨域 iframe / OOPIF）。
  ///
  /// 【实测关键】jx 播放器常挂在**跨站点 iframe** 里（如 hhjx.hhplayer.com），
  /// Chrome 会把它放进独立进程（OOPIF），只有主页面的会话**看不到它的网络请求**。
  /// 必须 `Target.setAutoAttach` 把所有子目标也挂上，才能嗅到真正的 m3u8。
  final Set<String> _sessions = {};

  _EdgeBrowser._(this._proc, this._ws, this._cdp, this._sessionId, this._tmp);

  static String? _browserPathCache;
  static bool _probeDone = false;

  /// 浏览器候选路径（Edge 是 Windows 必装；Chrome 作为补充）
  static const _candidates = [
    r'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
    r'C:\Program Files\Microsoft\Edge\Application\msedge.exe',
    r'C:\Program Files\Google\Chrome\Application\chrome.exe',
    r'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe',
  ];

  static Future<String?> _findBrowser() async {
    if (_probeDone) return _browserPathCache;
    for (final p in _candidates) {
      try {
        if (await File(p).exists()) {
          _browserPathCache = p;
          _probeDone = true;
          return p;
        }
      } catch (_) {}
    }
    // 兜底：PATH 里找
    for (final name in ['msedge.exe', 'chrome.exe']) {
      try {
        final r = await Process.run('where', [name]);
        if (r.exitCode == 0) {
          final line = '${r.stdout}'.split(RegExp(r'\r?\n')).first.trim();
          if (line.isNotEmpty && await File(line).exists()) {
            _browserPathCache = line;
            _probeDone = true;
            return line;
          }
        }
      } catch (_) {}
    }
    _probeDone = true;
    return null;
  }

  /// 启动无头浏览器并建立一个 CDP 页面会话。失败返回 null。
  ///
  /// 用「固定端口 + HTTP 轮询 `/json/version`」握手，而不是解析 stderr
  /// 的 `DevTools listening on`：更稳（GUI 子系统进程不保证 stderr 有输出，
  /// 且部分环境下进程管道不可用）。
  static Future<_EdgeBrowser?> launch(
      {String referer = '', List<String> extraArgs = const []}) async {
    final exe = await _findBrowser();
    if (exe == null) return null;
    final tmp = await Directory.systemTemp
        // 前缀 `kchan-edge-` 供 ChildProcessManager.sweepOrphans() 匹配；
        // 启动时按该标记清扫上次运行遗留的孤儿浏览器进程。
        .createTemp('kchan-edge-${DateTime.now().millisecondsSinceEpoch}_');
    Process? proc;
    WebSocketChannel? ws;
    // 端口：20000+随机，避开常用段
    final port = 20000 + (DateTime.now().millisecondsSinceEpoch % 30000);
    try {
      proc = await Process.start(exe, [
        '--headless=new',
        '--disable-gpu',
        '--mute-audio',
        '--no-first-run',
        '--no-default-browser-check',
        '--disable-extensions',
        '--disable-background-networking',
        '--remote-debugging-port=$port',
        '--remote-allow-origins=*',
        '--user-data-dir=${tmp.path}',
        ...extraArgs,
        'about:blank',
      ], mode: ProcessStartMode.inheritStdio);

      // 登记托管：释放时用 taskkill /T 终止**整棵进程树**。
      // 只 kill 父进程会留下 5~8 个孤儿（renderer/GPU/utility/crashpad）。
      ChildProcessManager.instance.track(proc, tag: 'edge', userDataDir: tmp.path);

      // 轮询 DevTools HTTP 端点直到就绪（最长 10s）
      //
      // 【关键 · 实测】本机若配置了系统代理，dart:io 默认会走代理：
      //  - HTTP 探测被代理拦成 200，WS 握手也被代理当成普通 HTTP 返回 200
      //    （报 "was not upgraded to websocket, HTTP status code: 200"）。
      //  DevTools 是 127.0.0.1 的本地服务，必须强制直连。
      String? browserWs;
      final http = HttpClient()..findProxy = (_) => 'DIRECT';
      try {
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (DateTime.now().isBefore(deadline)) {
          try {
            final req = await http
                .getUrl(Uri.parse('http://127.0.0.1:$port/json/version'))
                .timeout(const Duration(seconds: 2));
            final res = await req.close().timeout(const Duration(seconds: 2));
            if (res.statusCode == 200) {
              final body = await res.transform(utf8.decoder).join();
              final j = jsonDecode(body);
              if (j is Map && j['webSocketDebuggerUrl'] is String) {
                browserWs = j['webSocketDebuggerUrl'] as String;
                break;
              }
            }
          } catch (_) {
            // 还没起来，稍后再试
          }
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }
      } finally {
        http.close(force: true);
      }
      if (browserWs == null) {
        await ChildProcessManager.instance.release(proc.pid, tag: 'edge');
        return null;
      }

      // WS 同样必须直连（见上方代理说明）
      final directClient = HttpClient()..findProxy = (_) => 'DIRECT';
      ws = IOWebSocketChannel.connect(Uri.parse(browserWs),
          customClient: directClient);
      final cdp = _CdpSession(ws);
      final targetId = await cdp
          .send('Target.createTarget', {'url': 'about:blank'})
          .then((r) => r['targetId'] as String?);
      if (targetId == null) throw StateError('createTarget failed');
      final sessionId = await cdp
          .send('Target.attachToTarget',
              {'targetId': targetId, 'flatten': true})
          .then((r) => r['sessionId'] as String?);
      if (sessionId == null) throw StateError('attach failed');

      final browser = _EdgeBrowser._(proc, ws, cdp, sessionId, tmp);
      browser._sessions.add(sessionId);
      // 事件分发
      cdp.onEvent = (session, method, params) {
        // ① 子目标（跨域 iframe / OOPIF）自动挂载并配置
        if (method == 'Target.attachedToTarget') {
          final sid = params['sessionId'] as String?;
          if (sid != null && browser._sessions.add(sid)) {
            unawaited(browser._setupSession(sid));
          }
          return;
        }
        if (session.isEmpty || !browser._sessions.contains(session)) return;
        browser.onLog?.call('[$method] ${jsonEncode(params).length > 200 ? jsonEncode(params).substring(0, 200) : jsonEncode(params)}');
        if (method.startsWith('Network.')) {
          browser.onNetworkEvent?.call(method, params);
        } else if (method == 'Runtime.consoleAPICalled') {
          // console.log('...') 的 args[0].value
          final args = params['args'];
          if (args is List && args.isNotEmpty && args.first is Map) {
            final v = args.first['value'];
            if (v is String) browser.onConsoleMessage?.call(v);
          }
        }
      };
      return browser;
    } catch (e) {
      kLog('[EdgeCDP] 启动失败: $e');
      try {
        await ws?.sink.close();
      } catch (_) {}
      // 启动失败也要收掉整棵树（否则这半条命会一直挂着）
      final failPid = proc?.pid;
      if (failPid != null) {
        try {
          await ChildProcessManager.instance.release(failPid, tag: 'edge');
        } catch (_) {}
      }
      try {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      } catch (_) {}
      return null;
    }
  }

  /// Network.* 事件回调（由 [enableNetwork] 后生效）
  Future<void> Function(String method, Map<String, dynamic> params)?
      onNetworkEvent;

  /// console.log 回调（JS 钩子回传用）
  void Function(String text)? onConsoleMessage;

  /// 原始 CDP 事件日志（诊断用）
  void Function(String text)? onLog;

  /// 给一个会话装上「网络嗅探 + JS 钩子」（主页面与每个子 iframe 都要装）
  Future<void> _setupSession(String sid) async {
    // 子目标可能是 worker / 非页面类型，某些域不存在 → 逐条容错
    Future<void> safe(String method, Map<String, dynamic> params) async {
      try {
        await _cdp.send(method, params, sessionId: sid);
      } catch (_) {}
    }

    await safe('Network.enable', {});
    await safe('Page.enable', {});
    await safe('Runtime.enable', {});
    if (_hookSource != null) {
      await safe('Page.addScriptToEvaluateOnNewDocument', {'source': _hookSource!});
    }
  }

  /// 已注入的钩子脚本（新挂上的子目标也会补注）
  String? _hookSource;

  Future<void> enableNetwork() async {
    await _setupSession(_sessionId);
    // 之后出现的跨域 iframe 自动挂载（jx 播放器常在此处）
    await _cdp.send('Target.setAutoAttach', {
      'autoAttach': true,
      'waitForDebuggerOnStart': false,
      'flatten': true,
    });
  }

  /// 开启 Runtime 并在每个文档注入 [hookScript]（Page.addScriptToEvaluateOnNewDocument）
  Future<void> enableRuntime(String hookScript) async {
    _hookSource = hookScript;
    await _cdp.send('Runtime.enable', {}, sessionId: _sessionId);
    await _cdp.send(
      'Page.addScriptToEvaluateOnNewDocument',
      {'source': hookScript},
      sessionId: _sessionId,
    );
  }

  Future<void> navigate(String url) async {
    await _cdp.send('Page.navigate', {'url': url}, sessionId: _sessionId);
  }

  /// 设置视口（避免懒加载 iframe 永远不加载）
  Future<void> setViewport(int width, int height) async {
    try {
      await _cdp.send('Emulation.setDeviceMetricsOverride', {
        'width': width,
        'height': height,
        'deviceScaleFactor': 1,
        'mobile': false,
      }, sessionId: _sessionId);
    } catch (_) {}
  }

  /// 在当前页面执行 JS 表达式，返回字符串值（returnByValue）
  Future<String?> evaluate(String expression) async {
    try {
      final r = await _cdp.send(
        'Runtime.evaluate',
        {
          'expression': expression,
          'returnByValue': true,
          'awaitPromise': false,
        },
        sessionId: _sessionId,
      );
      final result = r['result'];
      if (result is Map) {
        final v = result['value'];
        if (v is String) return v;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 取响应体文本（处理 base64）
  Future<String?> responseBody(String requestId) async {
    try {
      final body = await _cdp.send(
        'Network.getResponseBody',
        {'requestId': requestId},
        sessionId: _sessionId,
      );
      var text = '${body['body'] ?? ''}';
      if (body['base64Encoded'] == true) {
        try {
          text = utf8.decode(base64.decode(text), allowMalformed: true);
        } catch (_) {}
      }
      return text;
    } catch (_) {
      return null;
    }
  }

  Future<void> close() async {
    try {
      await _ws.sink.close();
    } catch (_) {}
    // 【v2.0.0】进程**树**终止：只 kill 父进程会留下 5~8 个孤儿浏览器进程
    try {
      await ChildProcessManager.instance.release(_proc.pid, tag: 'edge');
    } catch (_) {}
    unawaited(Future<void>(() async {
      try {
        if (await _tmp.exists()) await _tmp.delete(recursive: true);
      } catch (_) {}
    }));
  }
}

/// 极简 CDP 会话封装：id 路由 + sessionId 事件分发
class _CdpSession {
  final WebSocketChannel _ws;
  int _nextId = 1;
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  void Function(String sessionId, String method, Map<String, dynamic> params)?
      onEvent;

  _CdpSession(this._ws) {
    _ws.stream.listen(
      (data) {
        Map<String, dynamic> msg;
        try {
          msg = jsonDecode('$data') as Map<String, dynamic>;
        } catch (_) {
          return;
        }
        final id = msg['id'];
        if (id is int) {
          final c = _pending.remove(id);
          if (c != null && !c.isCompleted) {
            if (msg.containsKey('error')) {
              c.completeError(StateError('CDP error: ${msg['error']}'));
            } else {
              c.complete((msg['result'] as Map?)?.cast<String, dynamic>() ?? {});
            }
          }
          return;
        }
        final method = msg['method'];
        if (method is String) {
          onEvent?.call(
            '${msg['sessionId'] ?? ''}',
            method,
            (msg['params'] as Map?)?.cast<String, dynamic>() ?? {},
          );
        }
      },
      onError: (_) {},
      cancelOnError: false,
    );
  }

  Future<Map<String, dynamic>> send(
    String method,
    Map<String, dynamic> params, {
    String? sessionId,
  }) {
    final id = _nextId++;
    final c = Completer<Map<String, dynamic>>();
    _pending[id] = c;
    _ws.sink.add(jsonEncode({
      'id': id,
      'method': method,
      'params': params,
      if (sessionId != null) 'sessionId': sessionId,
    }));
    return c.future.timeout(const Duration(seconds: 10), onTimeout: () {
      _pending.remove(id);
      return {};
    });
  }
}
