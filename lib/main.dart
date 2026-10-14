import 'dart:async';
import 'dart:ui' show PlatformDispatcher;
import 'dart:io' show Directory, File, FileMode, Platform;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:fvp/fvp.dart' as fvp;
import 'package:webview_flutter/webview_flutter.dart' as wv;

import 'store/local_store.dart';
import 'pages/detail_page.dart';
import 'theme.dart';
import 'api/diag_log.dart';
import 'api/js_gate.dart';
import 'api/kazumi_rules.dart';
import 'api/player_backend.dart' show initPlayerBackend;
import 'api/play_resolver.dart' as resolver;
import 'api/system_proxy.dart';
import 'api/window_ctl.dart' as windowCtl;
import 'api/video_sources.dart';
import 'pages/home_page.dart';
import 'pages/popular_page.dart';
import 'pages/search_page.dart';
import 'pages/library_page.dart';
import 'pages/history_page.dart';
import 'pages/settings_page.dart';


/// 【诊断】同步落盘的**启动阶段追踪**（异步 IOSink 在原生崩溃时会丢数据，
/// 所以这里用同步写）。
///
/// 【v1.9.8 改名】原来叫 `kchan_crash.log`，但里面写的其实是
/// `step: diag` / `before runApp` / `first frame rendered` 这类**正常进度**，
/// 不是崩溃信息 —— 名字有误导性（回归脚本一度把它当成"应用崩溃了"）。
/// 现在改为 `kchan_startup.log`，语义与内容一致。
void _syncDiag(String msg) {
  try {
    File('${Directory.systemTemp.path}/kchan_startup.log')
        .writeAsStringSync('${DateTime.now().toIso8601String()} $msg\n',
            mode: FileMode.append);
  } catch (_) {}
}

/// 清理旧版本留下的诊断文件（改名后不再使用）
void _cleanupLegacyDiag() {
  try {
    final old = File('${Directory.systemTemp.path}/kchan_crash.log');
    if (old.existsSync()) old.deleteSync();
  } catch (_) {}
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _cleanupLegacyDiag();

  // ---------------------------------------------------------------------------
  // 【v1.9.1 · 启动耗时改造】把启动路径拆成「必须阻塞首帧」与「首帧后补做」。
  //
  // 旧顺序（全部 await，全程阻塞 runApp）：
  //   fvp.registerWith → 资产自检(读 2 个资产) → BuiltinRules.load(读+解析 65KB JSON)
  //   → Store.init → installProxyOverrides → initDiagFileLog → initPlayerBackend
  //   → runApp
  //
  // 问题在于这些事**都不需要**在第一帧之前完成：
  //   - initPlayerBackend：只有真的点播放才用得到；
  //   - 资产自检：纯诊断，输出只进日志；
  //   - Store.init / installProxyOverrides：首帧渲染不需要，但**规则搜索需要**，
  //     所以它们仍在 runApp 前，只是排到最省时的位置。
  //
  // 现在只有三件事阻塞首帧：错误兜底注册 → Store.init（读设置，4ms）→
  // 装代理 overrides（纯内存，1ms）。规则解析挪到首帧后（见下方 postFrame）。
  // ---------------------------------------------------------------------------

  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    debugPrint('[K酱][FlutterError] ${details.exceptionAsString()}');
  };
  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    debugPrint('[K酱][PlatformError] $error\n$stack');
    return true; // 已处理，不让它终止进程
  };

  // 诊断文件日志尽量早（后续所有日志都要落盘）
  try {
    _syncDiag('step: diag');
    initDiagFileLog(Directory.systemTemp.path);
    kLogSink = combineSinks(debugPrint, diagFileSink);
    PlatformDispatcher.instance.onError = (e, st) {
      _syncDiag('未捕获异常: $e\n$st');
      return true;
    };
  } catch (e) {
    debugPrint('initDiagFileLog failed: $e');
  }

  // 本地存储：规则/设置/历史都依赖它。失败也放行（不闪退）。
  _syncDiag('step: store');
  try {
    await Store.init();
    _syncDiag('step: store done');
  } catch (e) {
    debugPrint('Store.init failed: $e');
  }

  // ---------------------------------------------------------------------------
  // 网络出口：跟随系统代理 / 手动代理（**对齐 Kazumi**）。
  //
  // 【为什么要做】实测 api.bgm.tv、next.bgm.tv、agedm.io 在大陆直连不可达，
  // 而 Kazumi 之所以「用得好好的」，是因为它会跟随 Windows 系统代理，
  // 把代理规则装到所有 HTTP 客户端上。这里用同样的做法：
  //  HttpOverrides.global 让 package:http、规则搜索、解析链、图片加载
  //  全部统一走代理。回环地址（本机 CDP）永远直连。
  // ---------------------------------------------------------------------------
  _syncDiag('step: proxy');
  try {
    installProxyOverrides();
    _syncDiag('step: proxy done');
  } catch (e) {
    debugPrint('installProxyOverrides failed: $e');
  }

  final e2eSubject = int.tryParse(Platform.environment['KCHAN_E2E_SUBJECT'] ?? '');

  /// 【自检】`KCHAN_E2E_PAGE` 让自动化测试直接打开指定页面。
  ///
  /// 用途：发布前的回归测试要逐页确认「页面能渲染、网络请求发出、日志无异常」，
  /// 但自动化环境里**没法可靠地点 UI**（鼠标坐标脆弱、输入法会截走按键）。
  /// 这个钩子把「打不开页面」这类问题变成可自动验证的：
  ///   home / popular / search / settings / detail
  final e2ePage = Platform.environment['KCHAN_E2E_PAGE'] ?? '';

  // ─────────────────────────────────────────────────────────────────────────
  // 【首帧即可见】立即 runApp。规则加载放在首帧回调里做，并保证：
  //   - 设置页/详情页读 SourceRegistry 前规则已就绪（它们都在首帧之后）；
  //   - 规则未就绪时 `SourceRegistry.active` 返回空 → UI 显示「等待加载」，
  //     不会显示错误的空列表。
  // ─────────────────────────────────────────────────────────────────────────
  kLog('[启动] 首帧前初始化完成，立即 runApp'
      '（e2eSubject=$e2eSubject e2ePage=${e2ePage.isEmpty ? '-' : e2ePage}）');
  _syncDiag('before runApp');
  FlutterError.onError = (details) {
    _syncDiag('FlutterError: ${details.exception}');
  };
  runApp(KChanApp(e2eSubject: e2eSubject, e2ePage: e2ePage));
  _syncDiag('after runApp');

  // ─────────────────────────────────────────────────────────────────────────
  // 首帧后再做「不阻塞可见性」的重活，并让它们**串行排队**避免互相抢 CPU。
  // 顺序按「用到的时间早晚」排：规则（设置页/详情页立刻要用）→ 播放器后端
  // （点播放才用）→ fvp 注册（只在 media-kit 失败时兜底）。
  // ─────────────────────────────────────────────────────────────────────────
  unawaited(_warmUpAfterFirstFrame());

  // 【自检】KCHAN_SELFTEST=window：启动后自动做一次「进入全屏 → 退出全屏」，
  // 把结果写进诊断日志。用途是把「窗口 FFI 代码是否正确」与
  // 「按键有没有送到」分开验证 —— 自动化环境里按键注入很不可靠（见交接文档）。
  if (Platform.environment['KCHAN_SELFTEST'] == 'window') {
    unawaited(_windowSelfTest());
  }
}

/// 窗口控制自检（仅 `KCHAN_SELFTEST=window` 时执行）
Future<void> _windowSelfTest() async {
  await Future<void>.delayed(const Duration(seconds: 6));
  try {
    kLog('[自检] window: 当前全屏=${windowCtl.isFullscreen}');
    final a = windowCtl.enterFullscreen();
    kLog('[自检] window: enterFullscreen -> $a，现在=${windowCtl.isFullscreen}');
    await Future<void>.delayed(const Duration(seconds: 2));
    final b = windowCtl.exitFullscreen();
    kLog('[自检] window: exitFullscreen -> $b，现在=${windowCtl.isFullscreen}');
    final c = windowCtl.maximize();
    kLog('[自检] window: maximize -> $c');
    windowCtl.logGeometry(tag: '最大化后');
    await Future<void>.delayed(const Duration(seconds: 1));
    final d = windowCtl.restore();
    kLog('[自检] window: restore -> $d');
    kLog('[自检] window: 完成');
  } catch (e, st) {
    kLog('[自检] window 失败: $e\n$st');
  }
  flushDiagLog();
}

/// 首帧后的后台预热链
Future<void> _warmUpAfterFirstFrame() async {
  // 等第一帧真的画出来（而不是等一个固定延时）
  await WidgetsBinding.instance.endOfFrame;
  _syncDiag('first frame rendered');

  // ① 规则库：65KB JSON 读取 + 解析。设置页/详情页/首页都要用。
  try {
    installRuleAssetLoader(rootBundle.loadString);
    final sw = Stopwatch()..start();
    await BuiltinRules.load();
    kLog('[启动] 规则库就绪：${BuiltinRules.all.length} 条（${sw.elapsedMilliseconds}ms）');
    SourceRegistry.invalidate(); // 规则换新后重建源列表
  } catch (e, st) {
    debugPrint('BuiltinRules.load failed: $e\n$st');
  }
  flushDiagLog(); // 关键节点：把启动日志真正落盘

  // ② 反爬闸门钩子：纯赋值，无 IO
  resolver.jsGateHook = bypassJsGate;
  resolver.gateCookieFor = GateCookies.forUrl;

  // ③ 播放器后端：MediaKit.ensureInitialized 只是装 FFI 绑定（不加载 DLL），
  //    但仍放到这里，让首帧完全不受影响。
  try {
    initPlayerBackend();
  } catch (e, st) {
    kLog('[播放器] media-kit init 异常: $e');
    debugPrint('media-kit init failed: $e\n$st');
  }

  // ④ fvp（libmdk 兜底内核）注册。
  //
  // 【重要】必须包 try/catch：
  //   fvp 在 Android 上会通过 JNI 加载 libfvp.so / libmdk.so。若设备 ABI 不匹配、
  //   库被 ROM 拦截、或 JNI 初始化异常，这里会抛错；若不在 try/catch 内，
  //   会让整个预热链断掉。播放器不可用只是功能降级，不该影响应用。
  //
  // 【v1.7.0 实测教训】不要传 video.decoders / lowLatency 自定义项：
  //  - fvp 默认解码链（Win: MFT:d3d=11→D3D11→DXVA→CUDA→FFmpeg；Android:
  //    AMediaCodec→FFmpeg）本身就是「硬解优先、软解兜底」的 auto-safe；
  //  - 实测 lowLatency=1 会把 ffmpeg analyzeduration 压到 0.1s，
  //    对 AES-128 加密的 HLS 流 initialize() 直接挂死（永远不出首帧）。
  try {
    fvp.registerWith(options: {
      'platforms': ['windows', 'android', 'linux', 'macos'],
    });
  } catch (e, st) {
    debugPrint('fvp.registerWith failed: $e\n$st');
  }

  kLog('[启动] 后台预热完成');
  flushDiagLog();
}

class KChanApp extends StatelessWidget {
  final int? e2eSubject;

  /// 【自检】自动化测试要直接打开的页面名（空 = 正常启动 RootShell）
  final String e2ePage;
  const KChanApp({super.key, this.e2eSubject, this.e2ePage = ''});

  /// 按 `KCHAN_E2E_PAGE` 的值构造对应页面；未知值返回 null（走正常流程）
  Widget? _e2ePage() {
    switch (e2ePage) {
      case 'settings':
        return const SettingsPage();
      case 'search':
        return const SearchPage();
      case 'popular':
        return const PopularPage();
      case 'home':
      case 'calendar':
        return const HomePage();
      default:
        return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Store.settings,
      builder: (context, _) {
        final mode = Store.settings.themeMode;
        final target = _e2ePage();
        return MaterialApp(
          title: 'K酱',
          debugShowCheckedModeBanner: false,
          theme: K.light(),
          darkTheme: K.dark(),
          themeMode: mode == 1 ? ThemeMode.light : (mode == 2 ? ThemeMode.dark : ThemeMode.system),
          locale: const Locale('zh', 'CN'),
          supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: e2eSubject != null
              ? DetailPage(subjectId: e2eSubject!, autoPlay: true)
              : (target != null
                  ? Scaffold(appBar: AppBar(title: const Text('K酱 · 自检')), body: target)
                  : const RootShell()),
        );
      },
    );
  }
}

class RootShell extends StatefulWidget {
  const RootShell({super.key});
  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  int _index = 0;

  /// Android 常驻离屏 WebView：给 JS 反爬闸门（如 aafun 的 _guard）
  /// 做「渲染取页 + cookie 收割」。Windows 不需要（走无头 Edge CDP）。
  wv.WebViewController? _gateCtrl;
  void Function()? _gateOnFinished;

  @override
  void initState() {
    super.initState();
    if (!kIsWeb && Platform.isAndroid) {
      _gateCtrl = wv.WebViewController()
        ..setJavaScriptMode(wv.JavaScriptMode.unrestricted)
        ..setUserAgent(
          'Mozilla/5.0 (Linux; Android 13; Pixel 6) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36',
        )
        ..setNavigationDelegate(wv.NavigationDelegate(
          onPageFinished: (_) => _gateOnFinished?.call(),
        ));
      AndroidGateWebView.instance.attach(
        loadUrl: (url) => _gateCtrl!.loadRequest(Uri.parse(url)),
        evalJs: (js) async {
          final r = await _gateCtrl!.runJavaScriptReturningResult(js);
          return r.toString();
        },
        onPageFinished: (cb) => _gateOnFinished = cb,
      );
    }
  }

  static const _destinations = [
    (Icons.star_outline_rounded, Icons.star_rounded, '推荐'),
    (Icons.calendar_month_outlined, Icons.calendar_month, '放送'),
    (Icons.search_outlined, Icons.search, '搜索'),
    (Icons.bookmark_border, Icons.bookmark, '追番'),
    (Icons.history_outlined, Icons.history, '历史'),
    (Icons.settings_outlined, Icons.settings, '设置'),
  ];

  @override
  Widget build(BuildContext context) {
    final pages = [
      const PopularPage(),
      const HomePage(),
      const SearchPage(),
      const LibraryPage(),
      const HistoryPage(),
      const SettingsPage(),
    ];
    return Scaffold(
      body: Stack(
        children: [
          IndexedStack(index: _index, children: pages),
          // 0 尺寸但必须真实挂载：平台 view 只有进树才活着
          if (_gateCtrl != null)
            Positioned(
              left: 0,
              top: 0,
              child: SizedBox(
                width: 1,
                height: 1,
                child: Opacity(
                  opacity: 0.001,
                  child: wv.WebViewWidget(controller: _gateCtrl!),
                ),
              ),
            ),
        ],
      ),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: Theme.of(context).colorScheme.outlineVariant, width: .8)),
        ),
        child: NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: (i) => setState(() => _index = i),
          destinations: [
            for (final d in _destinations)
              NavigationDestination(
                icon: Icon(d.$1, size: 21),
                selectedIcon: Icon(d.$2, size: 21, color: K.accent),
                label: d.$3,
              ),
          ],
        ),
      ),
    );
  }
}
