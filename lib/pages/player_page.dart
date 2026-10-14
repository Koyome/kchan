/// 播放页：规则解析（HTTP → WebView）→ video_player(fvp 后端) 播放
///
/// ## 三层播放保证（关键设计）
///
/// 用户反馈过「完全看不了」，所以这一版把「可播」做成**必然事件**：
///
///  第 1 层 · 纯 HTTP 直链     —— 少数源直接把 m3u8/mp4 写在页面里
///  第 2 层 · WebView 解析     —— 跑真实 JS 截获 jx 播放器的地址（主路径）
///  第 3 层 · WebView 内播放    —— 解析失败时，直接把播放器页显示出来让用户点播
///
/// 第 3 层是兜底的关键：即使解析引擎失效，用户手里仍然有一个
/// **真实、可点、能播**的播放器页面，绝不会出现死路。
library;

import 'dart:async';
import 'dart:io' show HttpClient, HttpHeaders, Platform, Process;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart' as wv;

import '../api/danmaku_api.dart';
import '../api/danmaku_source.dart';
import '../api/child_process_manager.dart';
import '../api/diag_log.dart' show kLog;
import '../api/kazumi_rules.dart';
import '../api/player_backend.dart';
import '../api/play_resolver.dart';
import '../api/resolver_platform.dart';
import '../api/video_sources.dart' show PlayInfo;
import '../api/window_ctl.dart' as windowCtl;
import '../models.dart';
import '../store/local_store.dart';
import '../theme.dart';
import '../widgets/danmaku_layer.dart';

class PlayerPage extends StatefulWidget {
  final Subject subject;
  final KazumiRule? rule; // 播放源规则（需要解析时提供）
  final String? pageUrl; // 源站播放页
  final String? playUrl; // 已有直链（历史续播）
  final String episodeTitle;
  final double episodeSort;
  final int episodeId;
  final String episodeDesc;
  final int startPositionMs;

  /// 同一番剧的可切换线路（(规则, 分集) 列表），供播放页内换源
  final List<PlayerAlternative> alternatives;

  /// 【v1.9.2】当前源的全部播放线路（Kazumi 的「播放线路1/2…」）。
  ///
  /// 旧版只有 `episodes`（各线路合并去重后的总列表），于是播放页里
  /// **看不到也没有办法切换**站点提供的多条线路。现在把每条线路各自的
  /// 剧集原样带进来，选集面板顶部就是 Kazumi 同款的线路切换按钮。
  final List<PlayerLine> lines;

  /// 进入播放页时选中的线路序号（对应 [lines] 的下标）
  final int startLineIndex;

  const PlayerPage({
    super.key,
    required this.subject,
    this.rule,
    this.pageUrl,
    this.playUrl,
    required this.episodeTitle,
    required this.episodeSort,
    this.episodeId = 0,
    this.episodeDesc = '',
    this.startPositionMs = 0,
    this.alternatives = const [],
    this.lines = const [],
    this.startLineIndex = 0,
  });

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

/// 备用线路
class PlayerAlternative {
  final String sourceName;
  final KazumiRule rule;
  final String pageUrl;
  final String episodeTitle;
  final double episodeSort;

  /// 【v1.9.2】该候选落在源内的第几条播放线路（0 = 线路1）
  final int lineIndex;
  const PlayerAlternative({
    required this.sourceName,
    required this.rule,
    required this.pageUrl,
    required this.episodeTitle,
    required this.episodeSort,
    this.lineIndex = 0,
  });
}

/// 选集项（当前源的分集）
class PlayerEpisodeOption {
  final int sort;
  final String title;
  final String pageUrl;
  const PlayerEpisodeOption({required this.sort, required this.title, required this.pageUrl});
}

/// 【v1.9.2】一条播放线路（对齐 Kazumi 的 `Road`）
class PlayerLine {
  final String name;
  final List<PlayerEpisodeOption> episodes;
  const PlayerLine({required this.name, this.episodes = const []});
}

/// 播放阶段
enum _Stage { resolving, playing, manualFallback, failed }

class _PlayerPageState extends State<PlayerPage> {
  VideoHandle? _controller;
  PlayResolver? _resolver;

  _Stage _stage = _Stage.resolving;
  String? _error;
  String _statusText = '解析播放地址…';

  /// WebView 控制器（Android 上必须挂在树里；用于解析 & 兜底播放）
  wv.WebViewController? _wvCtrl;
  bool _wvReady = false;

  /// 兜底：需要在 WebView 里播放的页面
  String? _manualUrl;
  /// 用户是否把 WebView 放大到全屏（兜底播放时）
  bool _webviewFullscreen = false;
  /// 解析过程中「前台跑 WebView」的目标
  String? _resolveTarget;

  /// 当前生效的规则（换线路后会变）
  late KazumiRule? _rule;
  late String? _pageUrl;
  late String _epTitle;
  late double _epSort;

  /// 【v1.9.2】当前所处的播放线路序号（对应 [PlayerPage.lines] 下标）。
  ///
  /// 站点常常提供多条线路（同一集在不同 CDN 上），Kazumi 让用户在
  /// 「选集」面板顶部直接切。这里同样支持：切线路只换剧集来源，
  /// 当前集号尽量保持不变。
  int _lineIndex = 0;

  /// 当前线路的剧集（= `widget.lines[_lineIndex].episodes`；无线路时为混合列表）
  List<PlayerEpisodeOption> get _currentEpisodes {
    if (_lineIndex >= 0 &&
        _lineIndex < widget.lines.length &&
        widget.lines[_lineIndex].episodes.isNotEmpty) {
      return widget.lines[_lineIndex].episodes;
    }
    // 兜底：把所有线路的剧集合并（按集号去重）
    if (widget.lines.isEmpty) return const [];
    final seen = <int>{};
    final out = <PlayerEpisodeOption>[];
    for (final l in widget.lines) {
      for (final e in l.episodes) {
        if (seen.add(e.sort)) out.add(e);
      }
    }
    out.sort((a, b) => a.sort.compareTo(b.sort));
    return out;
  }

  /// 当前线路名（Kazumi 的「播放线路1/2…」）
  String get _lineName {
    if (_lineIndex >= 0 && _lineIndex < widget.lines.length) {
      final n = widget.lines[_lineIndex].name.trim();
      return n.isEmpty ? '播放线路${_lineIndex + 1}' : n;
    }
    return '播放线路1';
  }

  // ── 键盘快捷键（对齐 Kazumi `defaultShortcuts`）──
  //
  // Kazumi 的默认键位：
  //   空格 播放/暂停 · ←/→ 快退/快进（长按加速）· ↑/↓ 音量 · M 静音
  //   N 下一集 · P 上一集 · F 全屏 · Esc 退出全屏 · D 弹幕开关
  //   1/2/3 设为 1x/2x/3x · X 倍速+ · Z 倍速-
  // 这里全部实现（跳片头/截图这两项 K酱 没有对应能力，故省略）。
  //
  // 【关键】用 `FocusManager.addEarlyKeyEventHandler` 而不是包一层 `Focus`。
  //
  // 实测踩坑（2026-10-13，Windows 简中输入法）：包 `Focus` + `onKeyEvent`
  // 时按键会**先被输入法/焦点树消费** —— 实测按下 X 弹出的是微软拼音的
  // 候选框（"1下 2先 3想…"），播放器一个键都收不到。
  // Kazumi 官方用的就是 `addEarlyKeyEventHandler`：它在焦点树**之前**接管，
  // 因此不受 IME 与控件焦点影响 —— 这正是「快捷键必须看齐 Kazumi」的要点。
  final FocusNode _keyFocus = FocusNode(debugLabel: 'player-shortcuts');
  Timer? _keySeekTimer;
  bool _keySeekFast = false;
  double _lastVolumeBeforeMute = 1.0;
  bool _muted = false;
  /// 快捷键提示（屏幕中央短暂显示）
  String? _hint;
  Timer? _hintTimer;

  bool _landscape = false;
  bool _showUi = true;
  Timer? _uiTimer;
  Timer? _saveTimer;

  // ── 手势（v1.5.0 · 对齐 Kazumi/主流追番交互）──
  /// 长按倍速：按住时的倍速（松开恢复原速）
  static const double _longPressSpeed = 2.0;
  double _speedBeforeLongPress = 1.0;
  bool _longPressBoost = false;

  /// 滑屏 seek：拖动中标记 + 预览目标位置（松手才真正 seek）
  bool _seekDragging = false;
  int _seekBaseMs = 0;
  int _seekPreviewMs = 0;

  // ── v1.8.0 · 对齐 Kazumi 的播放交互 ──
  /// 竖向拖动手势（右侧半屏）调音量：0.0~1.0
  double _volume = 1.0;
  bool _volumeDragging = false;
  Timer? _volumeHintTimer;
  /// 画面比例：0 原始 / 1 16:9 / 2 4:3 / 3 拉伸铺满
  int _fitMode = 0;
  /// 锁定控件（防误触，Kazumi 同款锁屏）
  bool _locked = false;
  /// 【v1.9.1 移除】此前这里有一个「规则声明的前贴广告时长」字段（_adSkipMs），
  /// 由 DM84 规则的 adSkipMs:16000 驱动、起播时无条件 seek 到 16s。
  /// 已按用户要求彻底移除：它会吞掉正片开头 16 秒，且不同集/不同线路的前贴
  /// 时长并不一致。真正的广告由「解析到广告域名判无效」+ HLS 注入广告区间
  /// 识别（adBlocker）处理，不靠写死秒数。
  ///
  /// 预检被拒后是否已重新解析过一次（防死循环）
  bool _preflightRetried = false;
  /// 常用倍速档位（Kazumi 同款列表）
  static const List<double> _speedPresets = <double>[
    0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0
  ];

  // ── 弹幕（弹弹play）──
  /// 弹幕调度器（多源）。凭证在构造时从 Store 读取 —— 见 _makeDanmakuApi。
  late DanmakuApi _danmakuApi;
  /// 弹幕条目（统一类型，来自 B站 或 弹弹play）
  List<DanmakuItem> _danmakus = const [];

  /// 弹幕时间轴锚点：由 controller 监听器推进，驱动 DanmakuLayer 投放弹幕
  int _danmakuPosMs = 0;

  /// 当前是否已置「禁止息屏」（避免重复调用 Win32 API）
  bool _keepScreenOn = false;

  /// 本集的弹幕是否已开始加载（保证只加载一次，且与播放后端无关）
  bool _danmakuLoadStarted = false;

  /// 弹幕显示设置（开关 / 透明度 / 字号）
  DanmakuStyle _danmakuStyle = const DanmakuStyle();

  /// 弹幕层 key：换集/换源时用它强制重建，彻底重置时间轴与在场弹幕
  Key _danmakuKey = UniqueKey();

  DanmakuApi _makeDanmakuApi() => DanmakuApi(
        appId: Store.settings.danmakuAppId,
        appSecret: Store.settings.danmakuAppSecret,
        danmuApiBaseUrl: Store.settings.danmakuApiBaseUrl,
      );

  bool get _isAndroid => !kIsWeb && Platform.isAndroid;

  @override
  void initState() {
    super.initState();
    _rule = widget.rule;
    _pageUrl = widget.pageUrl;
    _epTitle = widget.episodeTitle;
    _epSort = widget.episodeSort;
    _lineIndex = widget.startLineIndex.clamp(
        0, widget.lines.isEmpty ? 0 : widget.lines.length - 1);
    WidgetsBinding.instance.addObserver(_lifecycle);
    _lifecycle.onPause = _saveProgress;
    // 【v2.0.0】弹幕调度器与显示设置必须在 boot 之前就绪：
    // `_loadDanmaku()` 在起播成功后立即调用，那时如果 `_danmakuApi` 还是
    // `late` 未初始化的状态，会抛 LateInitializationError。
    // （实测踩过：弹幕整体加载失败，但播放不受影响 —— 因为调用处有兜底。）
    _danmakuApi = _makeDanmakuApi();
    _danmakuStyle = DanmakuStyle(
      enabled: Store.settings.danmakuEnabled,
      opacity: Store.settings.danmakuOpacity,
      fontSize: Store.settings.danmakuFontSize,
    );
    // 【快捷键】全局提前接管键盘事件（见 `_keyFocus` 处的说明）
    FocusManager.instance.addEarlyKeyEventHandler(_onGlobalKey);
    _boot();
  }

  // ───────────────────── 键盘快捷键 ─────────────────────

  /// 切换弹幕显示（右上角按钮 / `D` 键共用）
  ///
  /// 【v2.0.0 修「弹幕能开不能关」】
  /// 原先存在**两个互不相干的状态**：
  ///   · `_danmakuVisible` —— 按钮与 `D` 键改的是它，但它只用于图标显隐；
  ///   · `_danmakuStyle.enabled` —— `DanmakuLayer` 真正读取的就是它。
  /// 两者从不同步，而 `DanmakuLayer.didUpdateWidget` 只在「样式变化」时
  /// 调 `controller.updateOption()`，样式没变 → 弹幕照旧 → 关不掉。
  ///
  /// 现在合并为单一事实来源，切换后就地更新 `_danmakuStyle`，
  /// 由 `didUpdateWidget` → `_applyStyle()` → `hideScroll/hideTop/hideBottom`
  /// 真正隐藏/恢复。
  void _toggleDanmaku() {
    final on = !_danmakuStyle.enabled;
    setState(() {
      _danmakuStyle = _danmakuStyle.copyWith(enabled: on);
    });
    _showHint(on ? '弹幕：开' : '弹幕：关');
  }

  bool _e2eToggleDone = false;

  /// 【自检】`KCHAN_E2E_DANMAKU_TOGGLE=1` 时，起播 12 秒后自动关一次、
  /// 18 秒后再开，用于验证「关得掉、开得回来」。
  ///
  /// 是否真的生效看两行日志：
  ///   `[自检] 弹幕开关 → 关`（页面状态）
  ///   `[弹幕] 显示开关 → 关`（DanmakuLayer 真正下发给渲染库）
  /// 后者缺失就说明状态没传到渲染层 —— 正是原 bug 的形态。
  void _e2eDanmakuToggle() {
    if (_e2eToggleDone) return;
    if (Platform.environment['KCHAN_E2E_DANMAKU_TOGGLE'] != '1') return;
    _e2eToggleDone = true;
    Timer(const Duration(seconds: 12), () {
      if (!mounted) return;
      kLog('[自检] 弹幕开关 → 关（切换前 enabled=${_danmakuStyle.enabled}）');
      _toggleDanmaku();
      kLog('[自检] 切换后 enabled=${_danmakuStyle.enabled}');
    });
    Timer(const Duration(seconds: 18), () {
      if (!mounted) return;
      kLog('[自检] 弹幕开关 → 开（切换前 enabled=${_danmakuStyle.enabled}）');
      _toggleDanmaku();
      kLog('[自检] 切换后 enabled=${_danmakuStyle.enabled}');
    });
  }

  /// 屏幕中央短暂提示（快捷键反馈）
  void _showHint(String text) {
    _hintTimer?.cancel();
    setState(() => _hint = text);
    _hintTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _hint = null);
    });
  }

  /// 桌面端全局键盘事件入口（对齐 Kazumi `PlayerKeyboardShortcuts`）。
  ///
  /// 由 `FocusManager.addEarlyKeyEventHandler` 调用 —— 在焦点树之前执行，
  /// 因此输入法与聚焦控件都抢不走按键。
  ///
  /// 必须做的「该不该处理」判断（照抄 Kazumi 的 `_shouldHandleShortcut`）：
  ///   - 底层路由不是当前页（比如弹了对话框）→ 不处理；
  ///   - 焦点在文本框里（用户正在输入）→ 不处理，否则打字会触发播放操作。
  KeyEventResult _onGlobalKey(KeyEvent event) {
    if (!mounted) return KeyEventResult.ignored;
    // 弹了对话框/底部面板时让它们自己处理（Esc 关面板等）
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return KeyEventResult.ignored;
    // 正在文本框里打字 → 不抢按键
    final focus = FocusManager.instance.primaryFocus;
    final fctx = focus?.context;
    if (fctx != null &&
        (fctx.widget is EditableText ||
            fctx.findAncestorWidgetOfExactType<EditableText>() != null)) {
      return KeyEventResult.ignored;
    }
    return _onKey(event);
  }

  /// 桌面端键盘事件处理（键位映射本体）
  KeyEventResult _onKey(KeyEvent event) {
    // 只响应按下；重复事件里只有 ←/→ 需要（长按加速），单独处理
    final key = event.logicalKey;
    if (event is KeyUpEvent) {
      if (key == LogicalKeyboardKey.arrowRight && _keySeekFast) {
        _keySeekFast = false;
        _keySeekTimer?.cancel();
      }
      return KeyEventResult.ignored;
    }
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final repeat = event is KeyRepeatEvent;

    switch (key) {
      case LogicalKeyboardKey.space:
      case LogicalKeyboardKey.mediaPlayPause:
        if (repeat) return KeyEventResult.handled;
        _togglePlayPause();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowRight:
        _seekRelative(const Duration(seconds: 5));
        // 长按 → 连续快进（Kazumi 的 forward 长按加速）
        if (!repeat) {
          _keySeekFast = true;
          _keySeekTimer?.cancel();
          _keySeekTimer = Timer.periodic(const Duration(milliseconds: 220), (_) {
            if (mounted && _keySeekFast) {
              _seekRelative(const Duration(seconds: 5));
            }
          });
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowLeft:
        _seekRelative(const Duration(seconds: -5));
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
        _changeVolume(0.05);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowDown:
        _changeVolume(-0.05);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyM:
        if (repeat) return KeyEventResult.handled;
        _toggleMute();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyN:
        if (repeat) return KeyEventResult.handled;
        _jumpEpisode(1);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyP:
        if (repeat) return KeyEventResult.handled;
        _jumpEpisode(-1);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyF:
        if (repeat) return KeyEventResult.handled;
        _toggleFullscreen();
        return KeyEventResult.handled;
      // F11：Windows 上「全屏」的通用键位（浏览器/播放器都是它）。
      // 与 F、控制条上的全屏按钮等价。
      case LogicalKeyboardKey.f11:
        if (repeat) return KeyEventResult.handled;
        _toggleFullscreen();
        return KeyEventResult.handled;      case LogicalKeyboardKey.escape:
        if (repeat) return KeyEventResult.handled;
        if (_windowFullscreen) {
          _toggleFullscreen();
        } else if (_locked) {
          setState(() => _locked = false);
          _showHint('已解锁');
        } else if (_webviewFullscreen) {
          setState(() => _webviewFullscreen = false);
        } else {
          _closePlayer();
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.backspace:
        // Windows 用户习惯：Backspace = 返回上一页
        if (repeat) return KeyEventResult.handled;
        if (_windowFullscreen) {
          _toggleFullscreen();
        } else {
          _closePlayer();
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyD:
        if (repeat) return KeyEventResult.handled;
        // 与右上角按钮共用同一实现，避免两处状态再次分叉
        _toggleDanmaku();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyX:
        _stepSpeed(1);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyZ:
        _stepSpeed(-1);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.digit1:
        _setSpeed(1.0);
        _showHint('倍速 1.0x');
        return KeyEventResult.handled;
      case LogicalKeyboardKey.digit2:
        _setSpeed(2.0);
        _showHint('倍速 2.0x');
        return KeyEventResult.handled;
      case LogicalKeyboardKey.digit3:
        _setSpeed(3.0);
        _showHint('倍速 3.0x');
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyL:
        if (repeat) return KeyEventResult.handled;
        setState(() => _locked = !_locked);
        _showHint(_locked ? '已锁定' : '已解锁');
        return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _togglePlayPause() {
    final c = _controller;
    if (c == null) return;
    if (c.isPlaying) {
      c.pause();
      _showHint('已暂停');
    } else {
      c.play();
      _showHint('播放中');
    }
  }

  void _seekRelative(Duration delta) {
    final c = _controller;
    if (c == null || !c.initialized) return;
    var target = c.position + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (c.duration > Duration.zero && target > c.duration) target = c.duration;
    c.seekTo(target);
    _showHint('${delta.isNegative ? "◀" : "▶"} ${_fmt(target)} / ${_fmt(c.duration)}');
  }

  void _changeVolume(double delta) {
    _setVolumeLevel((_volume + delta).clamp(0.0, 1.0));
  }

  void _setVolumeLevel(double v) {
    _volume = v;
    _muted = v <= 0.001;
    try {
      _controller?.setVolume(v);
    } catch (_) {}
    if (mounted) setState(() {});
    _showHint('音量 ${(v * 100).round()}%');
  }

  void _toggleMute() {
    if (_muted) {
      _setVolumeLevel(_lastVolumeBeforeMute <= 0.001 ? 1.0 : _lastVolumeBeforeMute);
    } else {
      _lastVolumeBeforeMute = _volume;
      _setVolumeLevel(0);
    }
  }

  /// 倍速步进（X 加 / Z 减），按 `_speedPresets` 档位走
  Future<void> _stepSpeed(int dir) async {
    final cur = _controller?.speed ?? 1.0;
    var idx = _speedPresets.indexWhere((s) => (s - cur).abs() < 0.001);
    if (idx < 0) {
      // 当前不在档位上：找最接近的档
      idx = 0;
      for (var i = 0; i < _speedPresets.length; i++) {
        if (_speedPresets[i] <= cur) idx = i;
      }
    }
    final next = (idx + dir).clamp(0, _speedPresets.length - 1);
    final v = _speedPresets[next];
    await _setSpeed(v);
    _showHint('倍速 ${v}x');
  }

  /// 全屏切换。
  ///
  /// 【v1.9.3 · Windows 真全屏】旧实现在桌面端只弹一句
  /// 「请用窗口最大化（F11/双击标题栏）」—— 等于没实现，用户明确说过
  /// 「不能全屏幕模式播放……这些基本的都不能少」。
  ///
  /// 现在桌面端走 `window_ctl.dart`（**纯 Dart FFI 调 user32**，
  /// 不需要改 C++、也就不受本机 MinGW 工具链损坏的影响）：
  /// 去掉标题栏 + 覆盖所在显示器；全屏时同时隐藏我们的控制层，
  /// 按 Esc / F 退出并还原窗口样式。
  void _toggleFullscreen() {
    // 【v1.9.5 诊断】把每次调用与结果都记下来。
    // 之前用户反馈「还是不能全屏」，但日志里一条都没有 —— 无法判断到底是
    // 「按钮/按键没触发」还是「FFI 调了但没生效」。现在每一步都有记录。
    kLog('[全屏] 触发：android=${Platform.isAndroid} windows=${Platform.isWindows} '
        'isAndroid=$_isAndroid landscape=$_landscape '
        'windowFullscreen=$_windowFullscreen');
    if (_isAndroid || (!kIsWeb && Platform.isIOS)) {
      _toggleOrientation();
      _showHint(_landscape ? '竖屏' : '全屏');
      kLog('[全屏] 移动端 → 切横屏，landscape 现在=$_landscape');
      return;
    }
    // 桌面端
    final ok = windowCtl.toggleFullscreen();
    kLog('[全屏] windowCtl.toggleFullscreen() → $ok，'
        'isFullscreen=${windowCtl.isFullscreen}');
    if (!ok) {
      // FFI 不可用（非 Windows / 取窗口句柄失败）：退化为最大化
      final m = windowCtl.maximize();
      kLog('[全屏] 全屏失败 → 回退最大化=$m');
      _showHint(m ? '已最大化（全屏不可用）' : '当前平台不支持全屏');
      return;
    }
    setState(() {
      _windowFullscreen = windowCtl.isFullscreen;
      _showUi = true;
    });
    _showHint(_windowFullscreen ? '全屏（按 F 或 Esc 退出）' : '已退出全屏');
    _autoHideUi();
  }

  /// 【自检】`KCHAN_E2E_FULLSCREEN=1` 时，页面打开后自动进一次全屏。
  ///
  /// 为什么需要：自动化环境里**按键注入不可靠** ——
  /// `PostMessage` 到不了 Flutter 的键盘事件层、中文输入法会截走真实按键，
  /// 所以「全屏到底有没有生效」一直没法自动验证（这也是前几轮反复出问题的原因）。
  /// 这个钩子让脚本能触发全屏，从而用**截图 + 几何数据**确认结果。
  ///
  /// 【必须只跑一次】`_startPlayback()` 会被调用多次（重试、换线路、跨源切换），
  /// 早期版本没做幂等 → 钩子反复触发 → 全屏被开了又关，
  /// 验证时看起来就像「全屏坏掉了」。用 [_e2eFullscreenDone] 锁住。
  bool _e2eFullscreenDone = false;

  void _e2eAutoFullscreen() {
    if (_e2eFullscreenDone) return;
    final mode = Platform.environment['KCHAN_E2E_FULLSCREEN'];
    if (mode == null || mode.isEmpty) return;
    _e2eFullscreenDone = true;
    unawaited(Future<void>.delayed(const Duration(milliseconds: 2000), () async {
      if (!mounted) return;
      kLog('[自检] 进入前窗口状态');
      windowCtl.logGeometry(tag: '进入前');
      kLog('[自检] 自动触发全屏');
      _toggleFullscreen();
      if (mode != 'roundtrip') return;
      await Future<void>.delayed(const Duration(seconds: 4));
      if (!mounted) return;
      kLog('[自检] 自动退出全屏（验证还原）');
      windowCtl.logGeometry(tag: '退出前');
      _toggleFullscreen();
      await Future<void>.delayed(const Duration(seconds: 2));
      if (!mounted) return;
      windowCtl.logGeometry(tag: '还原后');
      kLog('[自检] 往返测试完成');
    }));
  }

  /// 桌面端是否处于窗口全屏
  bool _windowFullscreen = false;

  final _lifecycle = _LifecycleListener();

  // ───────────────────── 引导流程 ─────────────────────

  /// 本次播放会话已尝试过的源（防重复；解析失败、播放失败都会累积，
  /// 供「自动跨源切换」按顺序找到下一个没试过的源）。
  final Set<String> _triedSources = {};

  Future<void> _boot({String? overridePageUrl, KazumiRule? overrideRule, bool freshAttempt = false}) async {
    final pageUrl = overridePageUrl ?? _pageUrl;
    final rule = overrideRule ?? _rule;

    if (freshAttempt) _triedSources.clear();
    if (rule != null) _triedSources.add(rule.name);

    // 【自检】`KCHAN_E2E_PLAY_URL=<直链>` —— 直接播该地址，完全绕过线路解析。
    //
    // 用途：验证弹幕开关、看门狗、防息屏等功能时，不该被「解析源恰好挂了」
    // 干扰（实测某些时段资源站集体不可达，导致所有依赖起播的验证都跑不起来）。
    final e2eUrl = Platform.environment['KCHAN_E2E_PLAY_URL'];
    if (e2eUrl != null && e2eUrl.isNotEmpty) {
      kLog('[自检] 使用 KCHAN_E2E_PLAY_URL 直接起播，跳过解析');
      await _startPlayback(PlayInfo(url: e2eUrl));
      return;
    }

    // 已经有直链（历史续播）：直接播
    if (widget.playUrl != null &&
        widget.playUrl!.isNotEmpty &&
        overridePageUrl == null) {
      await _startPlayback(PlayInfo(url: widget.playUrl!));
      return;
    }

    if (pageUrl == null || pageUrl.isEmpty || rule == null) {
      await _failover(reason: '缺少播放页地址或播放源');
      return;
    }

    setState(() {
      _stage = _Stage.resolving;
      _error = null;
      _statusText = '解析播放地址…';
    });

    var ok = await _resolveAndPlay(rule, pageUrl);
    // 【v1.5.0 · 自动重试】首个源解析失败时，隔 1.5s 自动重试一次再考虑换源
    // （站点抽风/CDP 冷启动导致的失败，重试一次大概率恢复——Kazumi 靠手动
    //   刷新解决的场景，这里自动做掉）。
    if (!ok && mounted && !_autoRetried) {
      _autoRetried = true;
      setState(() => _statusText = '解析失败，自动重试中…');
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      if (!mounted) return;
      ok = await _resolveAndPlay(rule, pageUrl);
    }
    if (ok) return;
    await _failover();
  }

  /// 本次会话是否已做过一次「同源自動重试」（换源/换集时重置）
  bool _autoRetried = false;

  /// 解析 + 播放一步完成。返回 true 表示「已经在播或已交给 WebView 播」，
  /// false 表示这条路走不通，应该换下一个源。
  Future<bool> _resolveAndPlay(KazumiRule rule, String pageUrl) async {
    // Android：先把 WebView 建好并挂进树（下一帧即可用）
    if (_isAndroid && !_wvReady) {
      _ensureWebView();
      // 给 WebView 一帧时间完成平台 view 创建
      await Future<void>.delayed(const Duration(milliseconds: 350));
    }

    final resolver = PlayResolver(
      webview: createWebViewResolver(
        androidControllerFactory:
            _isAndroid ? () => _wvCtrl! : null,
      ),
    );
    _resolver = resolver;

    ResolvedStream stream;
    try {
      // 解析前先告诉 UI 要加载哪个页面（WebView 会真的去跑它）
      if (mounted && _isAndroid) {
        setState(() => _resolveTarget = pageUrl);
      }
      stream = await resolver.resolveEpisode(
        episodeUrl: pageUrl,
        rule: rule,
        webviewTimeout: const Duration(seconds: 22),
      );
    } catch (e) {
      debugPrint('[Player] 解析异常: $e');
      return false;
    }
    if (!mounted) return true;

    if (!stream.isEmpty) {
      // 【v1.9.4】还原「多编码一层」的地址（见 _normalizeMediaUrl 注释）：
      // 双重编码的地址两个播放引擎都打不开，且预检会因为服务端 404 而误判。
      // 这里统一还原一次，后面预检与起播都用还原后的地址。
      final playUrl = _normalizeMediaUrl(stream.url);
      kLog('[播放] ${rule.name} 解析成功 $playUrl '
          '(headers: ${stream.headers.keys.join(',')})');
      // 【v1.7.0 压测结论】部分源解析出的 m3u8 会被 CDN 直接拒绝（实测 DM84 的
      // hhplayer 域名对一切外部请求回 403）——地址"看起来有效"但必然播不了。
      // 与其等播放器报错再换源（白等十几秒），不如起播前先探 3 秒。
      // 【v1.9.9】扫描 HLS 里的注入广告/前贴（二维码）分片块。
      // 之前 `withAdRanges` 写好了却**从没被调用**，所以检测等于没做。
      // 扫描失败不影响播放，只是没有可跳过的区间。
      var adRanges = stream.adRanges;
      if (stream.isHls && adRanges.isEmpty) {
        try {
          // withAdRanges 是 play_resolver 的**顶层函数**（不是 PlayResolver 方法）
          final scanned = await withAdRanges(
              stream, stream.headers['Referer'] ?? '');
          adRanges = scanned.adRanges;
        } catch (e) {
          kLog('[播放] 广告扫描失败（忽略）: $e');
        }
      }
      if (adRanges.isNotEmpty) {
        kLog('[播放] 检测到 ${adRanges.length} 段注入广告/前贴，将在播放时自动跳过');
      }

      final pre = await _preflightPlayable(stream);
      kLog('[播放] 预检 ${pre ? '通过' : '失败(流被拒)'}');
      if (pre) {
        // ─────────────────────────────────────────────────────────────
        // 【v2.0.0】在这里就加载弹幕，**不等播放器就绪**。
        //
        // 原因：`VideoHandle.network()` 在 media-kit 起播失败时会自动回落 fvp，
        // 那条路径不会走到「控制器已就绪」分支 —— 导致弹幕静默失效
        // （实测日志里一条 [弹幕] 都没有）。
        // 弹幕与视频内核是两件独立的事，放这里与后端选择完全解耦。
        // ─────────────────────────────────────────────────────────────
        unawaited(_loadDanmaku());

        // 解析成功 → 用本地播放器播（比 WebView 更流畅，支持倍速/拖动）
        setState(() => _statusText = '加载播放器…');
        return _startPlayback(PlayInfo(
          url: playUrl,
          type: stream.type,
          headers: stream.headers,
          adRanges: adRanges,
        ));
      }
      // 【v1.8.0 实测】DM84 这类源解析出的地址带**短时效 token**，
      // 偶发返回已过期地址 → 预检 403。这时重新解析一次拿新地址即可，
      // 比直接换源更快也更稳。
      if (!_preflightRetried) {
        _preflightRetried = true;
        kLog('[播放] 预检被拒，重新解析一次拿新地址');
        await Future<void>.delayed(const Duration(milliseconds: 800));
        if (!mounted) return true;
        final again = await _resolveAndPlay(rule, pageUrl);
        if (again) return true;
      }
      return false;
    }

    // 解析失败：Android 直接进 WebView 播放页点播（仍算「能看」）；
    // 其他平台（Windows）返回 false 让上层自动换源。
    final manual = stream.manualPageUrl;
    if (_isAndroid && _wvReady && manual != null && manual.isNotEmpty) {
      setState(() {
        _stage = _Stage.manualFallback;
        _manualUrl = manual;
        _resolveTarget = null;
        _statusText = '已切换到网页播放';
      });
      try {
        await _wvCtrl!.loadRequest(Uri.parse(manual));
        return true;
      } catch (_) {}
    }
    return false;
  }

  /// 还原「被多编码了一层」的媒体地址。
  ///
  /// ## 为什么需要（实测）
  ///
  /// Code Geass R2 走 moonci 线路时解析出的地址是：
  /// ```
  /// https://play.xfvod.pro:8088/F/F-%25E5%258F%258D%25E5%258F%259B.../%255BSHANA%255D...mp4?sign=...
  /// ```
  /// 即中文文件名被**编码了两次**（`%E5` → `%25E5`）。
  /// 播放器把 `%25` 解成 `%` 之后拿到的是字面量 `%E5...` 而不是原字节，
  /// 服务端找不到文件 → 两个引擎都报 `Failed to open`，
  /// 用户看到的就是「随机某部番点了播不出来」。
  ///
  /// 判定条件（同时满足才还原，避免误伤正常地址）：
  ///   1. 路径里出现 `%25` 且后面紧跟两位十六进制（说明是 `%XX` 被再编码）；
  ///   2. 还原后不含裸空格等非法字符（`Uri.parse` 能解析）。
  ///
  /// 只还原**路径部分**，查询串（`?sign=...&t=...`）保持原样 ——
  /// 签名是对原始串算的，动了会失效。
  /// 注意查询串里合法的 `%25`（表示真的百分号）因此不受影响。
  static String _normalizeMediaUrl(String url) {
    if (!url.startsWith('http')) return url;
    final q = url.indexOf('?');
    final path = q < 0 ? url : url.substring(0, q);
    final query = q < 0 ? '' : url.substring(q);

    // %25 后面跟两位 hex（大小写都认）
    final doubleEnc = RegExp(r'%25[0-9A-Fa-f]{2}');
    if (!doubleEnc.hasMatch(path)) return url;

    final fixedPath = path.replaceAllMapped(doubleEnc, (m) => '%${m.group(0)!.substring(3)}');
    final fixed = fixedPath + query;
    // 校验：还原后必须是合法 URI，且路径里不能再有裸空格
    if (fixedPath.contains(' ')) return url;
    try {
      Uri.parse(fixed);
    } catch (_) {
      return url;
    }
    kLog('[播放] 地址存在双重编码，已还原：'
        '${fixed.length > 90 ? '${fixed.substring(0, 90)}…' : fixed}');
    return fixed;
  }

  /// 起播前预检：流地址是否真的可用。
  ///
  /// 【v1.9.3 · 新增 Content-Type 校验】
  /// 旧实现只看状态码，于是**「HTTP 200 + JSON 错误体」被当成可播**。
  /// 实测（moonci 线路的 CDN `apn.moedot.net`）：地址过期时返回
  ///   `200  application/json  {"code":401,"mes...}`
  /// 预检通过 → 交给播放器 → libmpv 报 `Failed to recognize file format`
  /// → 回落 fvp 也失败 → 用户看到的就是「随机加载失败」。
  /// 现在把这类响应判为不可播，直接触发换源/重新解析，失败率显著下降。
  ///
  /// 判定规则：
  /// - `200/206` + 内容是媒体（video/audio/mpegurl/octet-stream）→ 可播
  /// - `200/206` + 内容是 json/html → **不可播**（错误体）
  /// - `200/206` + 内容是 `text/plain` → 放行（部分 m3u8 用这个类型）
  /// - `403/404/410` → 明确被拒
  /// - `5xx` → 重试一次（源站抖动），仍 5xx 放行交给播放器兜底
  /// - 超时/网络异常 → 放行（探测环境与播放环境可能不一致，不误杀）
  Future<bool> _preflightPlayable(ResolvedStream stream) async {
    final url = _normalizeMediaUrl(stream.url);
    if (!url.startsWith('http')) return true;
    for (var attempt = 0; attempt < 2; attempt++) {
      final client = HttpClient();
      try {
        final req = await client
            .getUrl(Uri.parse(url))
            .timeout(const Duration(seconds: 4));
        // 只要响应头，不下载 body（大文件会白耗流量）
        req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1');
        for (final e in stream.headers.entries) {
          try {
            req.headers.set(e.key, e.value);
          } catch (_) {}
        }
        final res = await req.close().timeout(const Duration(seconds: 4));
        final code = res.statusCode;
        final ct = (res.headers.contentType?.mimeType ?? '').toLowerCase();
        // 立刻放掉连接
        unawaited(res.drain<void>().catchError((_) {}));

        if (code == 200 || code == 206) {
          if (ct.isEmpty) return true; // 没给类型：不误杀
          if (ct.contains('json') || ct.contains('html') || ct.contains('xml')) {
            kLog('[播放] 预检发现错误体（$code $ct），判为不可播');
            return false;
          }
          return true;
        }
        if (code == 403 || code == 404 || code == 410) return false;
        if (code >= 500) continue; // 源站抖动 → 重试一次
        return true;
      } catch (_) {
        return true;
      } finally {
        client.close(force: true);
      }
    }
    return true; // 两次都 5xx：放行，交给播放器与重试逻辑
  }

  /// 跨源自动切换：当前源失败后，依次尝试备选线路里**没试过**的源。
  /// 备选列表在详情页生成时已按「直链源优先」排序。
  /// 全部失败后：Android 用 WebView 兜底点播；Windows 显示错误与「浏览器打开」。
  Future<void> _failover({String reason = ''}) async {
    while (mounted) {
      PlayerAlternative? next;
      for (final a in widget.alternatives) {
        if (!_triedSources.contains(a.sourceName)) {
          next = a;
          break;
        }
      }
      if (next == null) break;
      _triedSources.add(next.sourceName);

      setState(() {
        _stage = _Stage.resolving;
        _statusText = reason.isEmpty
            ? '「${_rule?.name ?? '当前源'}」不可用，自动切换到 ${next!.sourceName}…'
            : reason;
      });
      reason = '';
      await _resetForSwitch(next.rule, next.pageUrl, next.episodeTitle, next.episodeSort);
      if (await _resolveAndPlay(next.rule, next.pageUrl)) return;
    }

    if (!mounted) return;
    // 所有源都试过仍失败 → 平台兜底
    final manual = (_pageUrl != null && _rule != null)
        ? await _safeManualPage(_pageUrl!, _rule!)
        : '';
    if (_isAndroid && _wvReady && manual.isNotEmpty) {
      setState(() {
        _stage = _Stage.manualFallback;
        _manualUrl = manual;
        _resolveTarget = null;
        _statusText = '已切换到网页播放';
      });
      try {
        await _wvCtrl!.loadRequest(Uri.parse(manual));
      } catch (_) {}
    } else {
      // 保留可手动打开的页面地址，错误视图里的「在浏览器打开」要用
      _manualUrl = manual.isNotEmpty ? manual : _pageUrl;
      setState(() {
        _stage = _Stage.failed;
        _error = '已自动尝试 ${_triedSources.length} 个播放源，均无法解析出可播地址。\n'
            '可稍后在网络较好时重试，或在设置中启用更多播放源。';
      });
    }
  }

  /// 换线路 / 换集前的统一清理（不触发解析）
  Future<void> _resetForSwitch(KazumiRule rule, String pageUrl, String epTitle, double epSort) async {
    _saveProgress();
    await _controller?.dispose();
    _controller = null;
    _completedHandled = false;
    _errorReported = false;
    setState(() {
      _rule = rule;
      _pageUrl = pageUrl;
      _epTitle = epTitle;
      _epSort = epSort;
      _webviewFullscreen = false;
      _manualUrl = null;
      _autoRetried = false; // 换源/换集后允许新的一轮自动重试
      _sameSourceRetried = false;
      _danmakus = const []; // 换源/换集后重新拉弹幕
      _danmakuPosMs = 0;
      _danmakuLoadStarted = false; // 允许新的一集重新加载
    });
  }

  Future<String> _safeManualPage(String pageUrl, KazumiRule rule) async {
    try {
      if (_resolver != null) return await _resolver!.manualPageFor(pageUrl, rule);
    } catch (_) {}
    return pageUrl;
  }

  /// 创建并挂载 Android WebView
  void _ensureWebView() {
    if (_wvCtrl != null) return;
    _wvCtrl = wv.WebViewController()
      ..setJavaScriptMode(wv.JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      ..setUserAgent(
        'Mozilla/5.0 (Linux; Android 13; Pixel 6) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36',
      )
      ..setNavigationDelegate(wv.NavigationDelegate(
        onPageFinished: (_) {
          if (mounted) setState(() => _wvReady = true);
        },
        onWebResourceError: (e) {
          debugPrint('[PlayerWebView] 错误 ${e.errorCode} ${e.description}');
        },
      ));
    // 让 WebView 至少渲染一次，确保平台 view 生效
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _wvReady = true);
    });
  }

  // ───────────────────── 播放 ─────────────────────

  Future<bool> _startPlayback(PlayInfo info) async {
    // 【v1.9.4 兜底】这里是**所有起播路径的唯一入口**（正常解析、重新解析、
    // 换线路、跨源切换都汇总到这里），所以在这里再还原一次双重编码，
    // 保证无论从哪条路进来，交给播放器的地址都是干净的。
    info = PlayInfo(
      url: _normalizeMediaUrl(info.url),
      type: info.type,
      headers: info.headers,
    );
    kLog('[播放] 开始起播流程 ${Uri.parse(info.url).host}');
    final uri = Uri.parse(info.url);

    try {
      Store.history.push(HistoryEntry(
        subject: widget.subject,
        epId: widget.episodeId,
        epSort: widget.episodeSort,
        epName: widget.episodeTitle,
        playUrl: info.url,
        sourceName: _rule?.name ?? '本地播放',
        pageUrl: _pageUrl ?? '',
        positionMs: widget.startPositionMs,
        watchedAt: DateTime.now().millisecondsSinceEpoch,
      ));
    } catch (e, st) {
      // 历史记录失败绝不能挡播放
      kLog('[播放] 历史记录写入失败（已忽略）: $e');
      debugPrint('$e\n$st');
    }

    // ═══════════════════════════════════════════════════════════════════
    // 【v1.9.9 · 防「两条线路同时播」】创建新控制器前，兜底释放可能残留的旧实例。
    //
    // 正常情况下 `_resetForSwitch()` 已经释放过了，但 `_startPlayback` 还有
    // 其它调用路径（自动重试、跨源切换、E2E 自检），任一路径漏掉就会出现
    // **旧线路还在出声、新线路也开始播**。这里做一次原子替换，成本极低。
    // ═══════════════════════════════════════════════════════════════════
    if (_controller != null) {
      kLog('[播放] 创建新控制器前，先释放上一个实例');
      final old = _controller;
      _controller = null;
      try {
        await old!.dispose();
      } catch (e) {
        kLog('[播放] 释放旧控制器异常（已忽略）: $e');
      }
    }

    final controller = await VideoHandle.network(
      info.url,
      headers: info.headers,
    );
    _controller = controller;

    // 记录本次起播的地址 / 类型 / 头 / 广告区间：
    // 看门狗重建播放器、以及自动跳过前贴时都要用
    _currentPlayUrl = info.url;
    _currentPlayType = info.type;
    _currentPlayHeaders = info.headers;
    _currentAdRanges = info.adRanges;
    _skippedAdIdx.clear();
    _maybeSkipAd(); // 起点为 0 的前贴：不等位置更新，立刻跳过

    kLog('[播放] 控制器已就绪（初始化完成）');
    // 【v2.0.0 · 黑屏修复之一】播放期间禁止系统息屏/休眠。
    // 全屏看番时长时间无键鼠输入，Windows 到点会关显示器，
    // 表现就是「画面黑了但声音还在」—— 与用户反馈完全一致。
    windowCtl.setKeepScreenOn(true);
    _startOutputWatchdog();
    _e2eAutoFullscreen();

    // 播放期间定期回收遗留的浏览器进程（安全网）。
    //
    // 【为什么需要】正常退出会走 AppLifecycleListener 回收子进程，
    // 但**被强杀 / 崩溃**时那个钩子不执行 —— 实测一次运行能留下
    // 14~15 个孤儿 msedge 进程，连看几集就攒到几十个，占内存拖慢系统。
    // reapStale 只杀「存在超过 120 秒」的同类进程，正在解析的那个绝不会被误杀。
    unawaited(ChildProcessManager.instance.reapStale());

    // ═══════════════════════════════════════════════════════════════════
    // 【v2.0.0 · 弹幕与播放后端解耦】
    //
    // 原来 `_loadDanmaku()` 只在起播成功后调用一次（即 media-kit 成功时）。
    // 但 `VideoHandle.network()` 内部会在 media-kit 起播失败时**自动回落 fvp**，
    // 那条路径不会走到这里 —— 实测「media-kit 打开超时 → 回落 fvp」时
    // **弹幕完全不加载**（日志里一条 [弹幕] 都没有）。
    //
    // 弹幕是独立能力，不该依赖视频内核是否成功。所以改为在 `_boot()` 里
    // 与后端选择无关的位置调用；这里只在尚未开始时兜底一次。
    // ═══════════════════════════════════════════════════════════════════
    if (!_danmakuLoadStarted) _loadDanmaku();
    _e2eDanmakuToggle(); // 自检：验证弹幕开关能关能开

    controller.addListener(() {
      if (!mounted) return;
      // 【v1.9.9】位置更新时检查是否落进注入广告/前贴区间 → 自动跳过。
      // 放在最前面且在任何 setState 之前：跳过是即时的，不该等一帧。
      _maybeSkipAd();
      // 【v2.0.0】播放/暂停切换时同步防息屏状态：
      // 暂停时恢复系统默认（省电），继续播放时重新阻止息屏。
      final playing = controller.isPlaying;
      if (playing != _keepScreenOn) {
        _keepScreenOn = playing;
        windowCtl.setKeepScreenOn(playing);
      }

      // 【v2.0.0】推进弹幕时间轴。
      // canvas_danmaku 没有时间轴概念，必须由我们从播放器位置驱动；
      // 用 setState 是为了把新 position 传进 DanmakuLayer.didUpdateWidget。
      // 弹幕层很轻（CustomPainter 直绘），每帧一次 setState 可接受；
      // 无弹幕时不触发，避免无谓重建。
      if (_danmakus.isNotEmpty) {
        final ms = controller.position.inMilliseconds;
        if (ms != _danmakuPosMs) {
          setState(() => _danmakuPosMs = ms);
        }
      }
      if (controller.hasError && !controller.isCompleted) {
        final msg = controller.errorText ?? '未知错误';
        if (!_errorReported) {
          _errorReported = true;
          kLog('[播放] 播放器错误: $msg');
          setState(() => _error = '播放错误：$msg');
          // 解析到了地址但流不可播（403/超时/断流）：也走跨源自动切换。
          // 延迟 1.2s 再确认，排除瞬时缓冲抖动。
          Timer(const Duration(milliseconds: 1200), () {
            if (!mounted || !controller.hasError) return;
            _onPlaybackError(msg);
          });
        }
      }
      if (controller.isCompleted) _onCompleted();
    });

    if (!mounted) return true;
    setState(() => _stage = _Stage.playing);

    // 续播：只有「有真实历史进度」时才 seek。
    //
    // 【v1.9.1】原先这里还会叠加规则里写死的前贴广告时长（DM84 的 16s），
    // 无条件把起播位置推到 16 秒，导致每集正片开头被吞。现已移除，
    // 仅保留用户自己的续播位置。
    final resumeMs = widget.startPositionMs;
    if (resumeMs > 1000) {
      try {
        await controller.seekTo(Duration(milliseconds: resumeMs));
        kLog('[播放] 续播 → ${(resumeMs / 1000).toStringAsFixed(1)}s');
      } catch (_) {}
    }

    // 起播沿用上次选择的倍速（v1.8.0）
    final saved = Store.settings.playbackSpeed;
    if (saved != 1.0) {
      try {
        await controller.setSpeed(saved);
      } catch (_) {}
    }
    try {
      controller.setVolume(1.0);
    } catch (_) {}

    await controller.play();

    _saveTimer?.cancel();
    _saveTimer = Timer.periodic(const Duration(seconds: 5), (_) => _saveProgress());
    _autoHideUi();
    _maybeShowShortcutTip(); // 桌面端首次起播时提示一次快捷键
    _loadDanmaku(); // 后台加载弹幕，不阻塞播放
    return true;
  }

  /// 拉取弹幕（多源：B站 / 弹弹play）。
  ///
  /// 【原则】弹幕是附加功能：任何失败都只记日志 + 给个轻提示，
  /// **绝不影响视频播放**（不抛异常、不阻塞起播、不改播放状态）。
  Future<void> _loadDanmaku() async {
    if (_danmakuLoadStarted) return;
    _danmakuLoadStarted = true;
    if (!Store.settings.danmakuEnabled) return;
    final title = widget.subject.displayName.isNotEmpty
        ? widget.subject.displayName
        : widget.subject.name;
    try {
      _danmakuApi.dispose();
    _danmakus = const [];
      _danmakuApi = _makeDanmakuApi();
      final list = await _danmakuApi.fetchAll(
        title,
        _epSort,
        onNotice: (msg) {
          // 友好提示：不打断播放，只在底部轻轻提示一下
          if (mounted) _showHint(msg);
        },
      );
      if (!mounted) return;
      // 换集/换源要重置弹幕层时间轴：换 key 强制重建 State
      setState(() {
        _danmakus = list;
        _danmakuPosMs = 0;
        _danmakuKey = UniqueKey();
      });
      kLog('[弹幕] 已加载 ${list.length} 条（$title 第${_epSort.toStringAsFixed(0)}集）'
          '，源=${_danmakuApi.enabledSourceNames.join("/")}');
    } catch (e) {
      // 兜底：无论如何都不能影响播放
      kLog('[弹幕] 加载失败（已忽略，不影响播放）: $e');
    }
  }

  /// 播放中出错：**同一源先快速重试一次**（压测证实部分 CDN 间歇性 502/断流，
  /// 重试即可恢复；Kazumi 的处理也是刷新重试优先于换源），仍失败才换源。
  Future<void> _onPlaybackError(String msg) async {
    await _controller?.dispose();
    _controller = null;
    if (!mounted) return;
    if (!_sameSourceRetried && _rule != null && _pageUrl != null) {
      _sameSourceRetried = true;
      kLog('[播放] 同源重试（CDN 抖动场景）: ${_rule!.name}');
      setState(() {
        _stage = _Stage.resolving;
        _statusText = '播放中断，正在重试当前线路…';
      });
      final ok = await _resolveAndPlay(_rule!, _pageUrl!);
      if (ok) return;
    }
    if (!mounted) return;
    await _failover(reason: '播放出错（$msg），正在自动切换线路…');
  }

  /// 本次会话是否已对同一源做过播放重试（换源/换集时重置）
  bool _sameSourceRetried = false;

  bool _errorReported = false;

  // ═══════════════════ 注入广告 / 前贴（二维码）自动跳过 ═══════════════════
  //
  // 数据来自 `play_resolver.scanInjectedAds()`：HLS 播放列表里被两个
  // `#EXT-X-DISCONTINUITY` 夹住、且分片时长整齐划一的独立块。
  // 实测这类块就是站点插的**广告或二维码前贴**（用户反馈「开头有二维码，
  // 点重新解析才正常」）。整块跨过不会吃掉正片，所以可以直接 seek 过去。
  //
  // 【v1.9.9】之前这条链路是断的：扫描函数没人调用、区间字段没人读。
  // 现在扫描在起播前做，跳过在这里做。

  List<({int startMs, int endMs})> _currentAdRanges = const [];

  /// 已跳过的区间下标（避免用户手动拖回广告段时又把它弹走）
  final Set<int> _skippedAdIdx = {};

  /// 当前位置若落在未跳过的广告区间内 → 跳到区间末尾
  void _maybeSkipAd() {
    final c = _controller;
    if (c == null || _currentAdRanges.isEmpty) return;
    final ms = c.position.inMilliseconds;
    for (var i = 0; i < _currentAdRanges.length; i++) {
      if (_skippedAdIdx.contains(i)) continue;
      final r = _currentAdRanges[i];
      // 位置落在区间内（留 300ms 余量，避免刚好卡在边界）
      if (ms >= r.startMs - 300 && ms < r.endMs) {
        _skippedAdIdx.add(i);
        final target = Duration(milliseconds: r.endMs + 200);
        kLog('[播放] 命中注入广告/前贴 '
            '${(r.startMs / 1000).toStringAsFixed(1)}s~'
            '${(r.endMs / 1000).toStringAsFixed(1)}s，跳到 ${target.inSeconds}s');
        unawaited(c.seekTo(target));
        _showHint('已跳过前贴广告');
        return;
      }
    }
  }

  // ═══════════════════════ 视频输出看门狗（v1.9.9）═══════════════════════
  //
  // 治「看久了突然黑屏、有声音没画面、退出全屏恢复」。
  //
  // 判定依据是 mpv 的 `estimated-vf-fps`：输出健康时是实际帧率，
  // **输出掉链时是 0**；后端不支持探测时是 null（跳过判断）。
  // 连续两次为 0 才动手，避免偶发抖动误触。

  Timer? _outWatchdog;
  int _deadStrikes = 0;
  /// 探针调用计数（用于心跳日志）
  int _probeCount = 0;
  bool _recovering = false;
  int _recoverCount = 0;

  /// 同时刻最多重建几次播放器（防止在坏源上无限重建）
  static const int _kMaxRebuilds = 2;

  void _startOutputWatchdog() {
    _outWatchdog?.cancel();
    _deadStrikes = 0;
    _probeCount = 0;
    // 起播后先等一小段，避免把首帧前的正常状态当黑屏
    _outWatchdog = Timer.periodic(const Duration(seconds: 3), (_) async {
      if (!mounted) return;
      final c = _controller;
      if (c == null) return;
      // 只在「正在播且未暂停」时判定；暂停时 fps 本来就可能是 0
      if (!c.isPlaying || c.hasError || c.isCompleted) {
        _deadStrikes = 0;
        return;
      }
      if (_recovering) return;

      // 顺带做周期性的遗留进程回收（内部有 45 秒节流，几乎零开销）。
      // 放在看门狗里是因为它本来就在稳定跳动，不需要再开一个定时器。
      unawaited(ChildProcessManager.instance.reapStale());

      final fps = await c.videoOutputFps();
      // 心跳：每 10 次探测（约 30s）记一行，用于确认探针真的在工作。
      // 没有这行就无法区分「一切正常」与「探针失效导致看门狗空转」。
      _probeCount++;
      if (_probeCount % 10 == 0) {
        kLog('[看门狗] 心跳 #$_probeCount: position=${c.position.inSeconds}s '
            'fps=${fps == null ? "不支持探测" : fps.toStringAsFixed(2)}');
      }
      if (fps == null) return; // 不支持探测
      if (fps > 0.001) {
        if (_deadStrikes > 0) {
          kLog('[看门狗] 视频输出恢复正常（fps=$fps）');
        }
        _deadStrikes = 0;
        return;
      }

      // fps == 0 且在播 → 可疑
      _deadStrikes++;
      kLog('[看门狗] 视频输出未出帧（第 $_deadStrikes 次，position=${c.position.inSeconds}s）');
      if (_deadStrikes < 2) return;

      _deadStrikes = 0;
      await _recoverVideoOutput(c);
    });
  }

  /// 两级恢复：先轻刷输出，无效则重建播放器（等价用户手动「重新解析」）
  Future<void> _recoverVideoOutput(VideoHandle c) async {
    if (_recovering || !mounted) return;
    _recovering = true;
    try {
      kLog('[看门狗] 判定为黑屏（有声音无画面），开始恢复');
      // ① 轻刷：重下发 vo + 回退重绘
      final ok = await c.refreshVideoOutput();
      if (ok) {
        // 给它 4 秒观察期：若恢复正常，看门狗下一轮会把 strikes 清零
        await Future<void>.delayed(const Duration(seconds: 4));
        final fps = await c.videoOutputFps();
        if (fps != null && fps > 0.001) {
          kLog('[看门狗] 轻刷输出后已恢复（fps=$fps）');
          return;
        }
        kLog('[看门狗] 轻刷无效，升级为重建播放器');
      }
      // ② 重建播放器：复用当前地址与进度
      if (_recoverCount >= _kMaxRebuilds) {
        kLog('[看门狗] 已达重建上限（$_kMaxRebuilds 次），不再重试，提示用户换线路');
        _showHint('画面异常，建议换一条线路');
        return;
      }
      final url = _currentPlayUrl;
      if (url == null || url.isEmpty) {
        kLog('[看门狗] 拿不到当前地址，无法重建');
        return;
      }
      _recoverCount++;
      final resume = c.position;
      final wasPlaying = c.isPlaying;
      kLog('[看门狗] 重建播放器（第 $_recoverCount 次），从 ${resume.inSeconds}s 继续');
      setState(() => _statusText = '画面异常，正在恢复…');
      await _startPlayback(PlayInfo(
        url: url,
        type: _currentPlayType,
        headers: _currentPlayHeaders,
      ));
      // 恢复到原进度
      final nc = _controller;
      if (nc != null && resume > const Duration(seconds: 2)) {
        try {
          await nc.seekTo(resume);
        } catch (_) {}
      }
      if (nc != null && wasPlaying) {
        try {
          await nc.play();
        } catch (_) {}
      }
      kLog('[看门狗] 重建完成');
    } catch (e) {
      kLog('[看门狗] 恢复过程异常: $e');
    } finally {
      _recovering = false;
    }
  }

  /// 当前起播用的地址 / 类型 / 头（供看门狗重建时复用）
  String? _currentPlayUrl;
  String _currentPlayType = 'application/x-mpegURL';
  Map<String, String> _currentPlayHeaders = const {};

  void _saveProgress() {
    final c = _controller;
    if (c == null || !c.initialized) return;
    final pos = c.position.inMilliseconds;
    final dur = c.duration.inMilliseconds;
    Store.progress.updatePosition(widget.subject, widget.episodeSort, widget.episodeId, pos);
    Store.history.touchPosition(widget.subject.id, widget.episodeSort, pos, dur);
    if (dur > 0 && pos / dur > .8) {
      Store.progress.markWatched(widget.subject, widget.episodeSort, epId: widget.episodeId);
    }
  }

  bool _completedHandled = false;

  void _onCompleted() {
    if (_completedHandled) return;
    _completedHandled = true;
    _saveProgress();
    Store.progress.markWatched(widget.subject, widget.episodeSort, epId: widget.episodeId);
    if (!mounted) return;
    if (Store.settings.autoNext) {
      setState(() => _statusText = '已看完，标记为已看');
    }
  }

  void _autoHideUi() {
    _uiTimer?.cancel();
    _uiTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _showUi = false);
    });
  }

  void _toggleUi() {
    setState(() => _showUi = !_showUi);
    if (_showUi) _autoHideUi();
  }

  // ── 手势处理（v1.5.0）──

  /// 长按开始：提速到 2×（Kazumi 同款，松手恢复原速）
  void _onLongPressStart() {
    final c = _controller;
    if (c == null || !c.initialized) return;
    _speedBeforeLongPress = c.speed;
    if (_speedBeforeLongPress == _longPressSpeed) return; // 已是 2× 就不折腾
    setState(() => _longPressBoost = true);
    c.setSpeed(_longPressSpeed);
  }

  void _onLongPressEnd() {
    if (!_longPressBoost) return;
    setState(() => _longPressBoost = false);
    _controller?.setSpeed(_speedBeforeLongPress);
  }

  /// 滑屏 seek：开始拖动时记录基准位置
  void _onSeekDragStart() {
    final c = _controller;
    if (c == null || !c.initialized) return;
    _seekBaseMs = c.position.inMilliseconds;
    _seekPreviewMs = _seekBaseMs;
    setState(() => _seekDragging = true);
    // 拖动期间保持 UI 可见，避免进度条消失看不到预览
    _uiTimer?.cancel();
  }

  /// 拖动中：屏幕全宽 ≈ 180 秒（与 Kazumi 一致的换算），只更新预览不 seek
  void _onSeekDragUpdate(double dx, double screenWidth) {
    if (!_seekDragging) return;
    final c = _controller;
    if (c == null || !c.initialized) return;
    final scale = 180000 / screenWidth; // ms per px
    final durMs = c.duration.inMilliseconds;
    var target = _seekPreviewMs + (dx * scale).round();
    if (durMs > 0) target = target.clamp(0, durMs);
    setState(() => _seekPreviewMs = target);
  }

  /// 松手：一次性 seek 到预览位置（比拖动中连续 seek 省流、不卡）
  void _onSeekDragEnd() {
    if (!_seekDragging) return;
    setState(() => _seekDragging = false);
    final c = _controller;
    if (c == null || !c.initialized) return;
    if (_seekPreviewMs != _seekBaseMs) {
      c.seekTo(Duration(milliseconds: _seekPreviewMs));
    }
    _autoHideUi();
  }

  // ── v1.8.0 · 竖向拖动调音量（右侧半屏，Kazumi 同款）──

  void _onVolumeDragStart(double dx, double width) {
    if (dx < width * 0.55) return; // 左半屏留给后续亮度能力
    setState(() => _volumeDragging = true);
    _uiTimer?.cancel();
  }

  void _onVolumeDragUpdate(double dy, double height) {
    if (!_volumeDragging) return;
    final c = _controller;
    if (c == null || !c.initialized) return;
    // 竖向全高拖动 ≈ 整段音量
    final next = (_volume - dy / height).clamp(0.0, 1.0).toDouble();
    if ((next - _volume).abs() < 0.001) return;
    _volume = next;
    c.setVolume(_volume);
    setState(() {});
  }

  void _onVolumeDragEnd() {
    if (!_volumeDragging) return;
    setState(() => _volumeDragging = false);
    _volumeHintTimer?.cancel();
    _volumeHintTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) setState(() {});
    });
    _autoHideUi();
  }

  /// 切换画面比例（原始 / 16:9 / 4:3 / 铺满）
  void _cycleFitMode() => setState(() => _fitMode = (_fitMode + 1) % 4);

  /// 按倍速档位设置（并记到设置里，下次起播沿用）
  Future<void> _setSpeed(double v) async {
    _controller?.setSpeed(v);
    await Store.settings.setPlaybackSpeed(v);
    if (mounted) setState(() {});
  }

  /// 上一集 / 下一集（依赖**当前线路**的分集列表）
  void _jumpEpisode(int delta) {
    final eps = List<PlayerEpisodeOption>.of(_currentEpisodes)
      ..sort((a, b) => a.sort.compareTo(b.sort));
    if (eps.isEmpty) {
      _showHint('当前线路没有其他剧集');
      return;
    }
    final idx = eps.indexWhere((e) => e.sort == _epSort);
    if (idx < 0) {
      // 当前集不在本线路里（切线路后常见）：退化为「跳第一条」
      _switchEpisode(eps.first);
      return;
    }
    final next = idx + delta;
    if (next < 0) {
      _showHint('已经是第一集');
      return;
    }
    if (next >= eps.length) {
      _showHint('已经是最后一集');
      return;
    }
    _switchEpisode(eps[next]);
  }

  /// 切换播放线路（同一源内的「播放线路N」）。
  ///
  /// 行为对齐 Kazumi：切线路后**尽量停在同一个集号**上；如果该线路没有这一集，
  /// 就退到它的第一集（并给出提示，避免用户以为播放器坏了）。
  Future<void> _switchLine(int index) async {
    if (index < 0 || index >= widget.lines.length) return;
    if (index == _lineIndex) return;
    final lines = widget.lines;
    final target = lines[index];
    if (target.episodes.isEmpty) {
      _showHint('该线路暂无剧集');
      return;
    }
    setState(() => _lineIndex = index);
    // 优先同集号
    PlayerEpisodeOption? pick;
    for (final e in target.episodes) {
      if (e.sort == _epSort) {
        pick = e;
        break;
      }
    }
    pick ??= target.episodes.first;
    _showHint('切换到 ${target.name.isEmpty ? "播放线路${index + 1}" : target.name}');
    await _switchEpisode(pick);
  }

  void _toggleOrientation() {
    _landscape = !_landscape;
    SystemChrome.setPreferredOrientations(_landscape
        ? [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]
        : [DeviceOrientation.portraitUp, DeviceOrientation.portraitDown]);
    SystemChrome.setEnabledSystemUIMode(
        _landscape ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge);
    setState(() {});
  }

  /// 换线路 / 换源重试（手动）
  ///
  /// 用户**明确点了某条线路**时，即使它之前自动切换试过、失败了，
  /// 也要尊重用户选择再试一次（从已试列表里移除）。
  Future<void> _switchTo(KazumiRule rule, String pageUrl, String epTitle, double epSort) async {
    _triedSources.remove(rule.name);
    _triedSources.add(rule.name);
    await _resetForSwitch(rule, pageUrl, epTitle, epSort);
    await _boot(overridePageUrl: pageUrl, overrideRule: rule);
  }

  /// 选集（同一源内的其他分集）：重置尝试记录后按全新会话解析
  Future<void> _switchEpisode(PlayerEpisodeOption ep) async {
    _triedSources.clear();
    await _resetForSwitch(_rule!, ep.pageUrl, ep.title, ep.sort.toDouble());
    await _boot(overridePageUrl: ep.pageUrl, overrideRule: _rule, freshAttempt: true);
  }

  /// 在系统浏览器里打开（全部源都失败后的最后手段，Android/Windows 均可用）
  Future<void> _openExternal(String url) async {
    if (url.isEmpty) return;
    var opened = false;
    if (!kIsWeb && Platform.isWindows) {
      try {
        // rundll32 url.dll,FileProtocolHandler 是 Windows 上免 url_launcher
        // 的最稳打开方式（不依赖 cmd / 默认浏览器协议注册）。
        await Process.start('rundll32', ['url.dll,FileProtocolHandler', url]);
        opened = true;
      } catch (_) {}
    }
    if (!opened) {
      // 桌面 Linux/macOS 或启动失败：复制链接 + 提示
      await Clipboard.setData(ClipboardData(text: url));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('播放页链接已复制，可粘贴到浏览器打开'),
          action: SnackBarAction(
            label: '知道了',
            onPressed: () {},
          ),
        ),
      );
    }
  }

  @override
  void dispose() {
    _saveProgress();
    _outWatchdog?.cancel();
    _outWatchdog = null;
    // 离开播放页必须恢复系统息屏策略，否则会一直阻止息屏
    if (_keepScreenOn) {
      _keepScreenOn = false;
      windowCtl.setKeepScreenOn(false);
    }
    FocusManager.instance.removeEarlyKeyEventHandler(_onGlobalKey);
    // 必须主动退出全屏：否则用户返回列表页后，窗口仍是无边框全屏状态
    if (_windowFullscreen) {
      windowCtl.exitFullscreen();
      _windowFullscreen = false;
    }
    _uiTimer?.cancel();
    _saveTimer?.cancel();
    _keySeekTimer?.cancel();
    _hintTimer?.cancel();
    _tipTimer?.cancel();
    _keyFocus.dispose();
    WidgetsBinding.instance.removeObserver(_lifecycle);
    SystemChrome.setPreferredOrientations(
        [DeviceOrientation.portraitUp, DeviceOrientation.portraitDown]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _controller?.dispose();
    _danmakuApi.dispose();
    super.dispose();
  }

  // ───────────────────── UI ─────────────────────

  @override
  Widget build(BuildContext context) {
    // 【v1.9.2】快捷键通过 `FocusManager.addEarlyKeyEventHandler` 全局接管
    // （见 `_keyFocus` 处的说明），所以这里不需要再包一层 Focus。
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        top: false,
        child: Stack(
          children: [
            Positioned.fill(child: _body()),
            // 解析期间：WebView 在后台真实加载（可见但半透明小窗）
            if (_stage == _Stage.resolving && _isAndroid && _resolveTarget != null)
              Positioned(
                right: 10,
                bottom: 10,
                child: _miniWebView(),
              ),
            if (_showUi && !_locked && _stage == _Stage.playing) _topBar(),
            if (_showUi && !_locked && _stage == _Stage.playing) _bottomBar(),
            if (_locked) _lockBadge(),
            // seek 预览浮层已在视频 Stack 内自带；这里只补音量提示
            if (_volumeDragging) _volumeHint(),
            if (_stage == _Stage.manualFallback) _manualBar(),
            // 快捷键反馈（Kazumi 的 toast 同款作用）
            if (_hint != null) _hintOverlay(_hint!),
            // 桌面端首次进入时提示一次快捷键（移动端不显示）
            if (_showShortcutTip) _shortcutTip(),
          ],
        ),
      ),
    );
  }

  /// 桌面端快捷键提示条：进播放页后显示几秒，让用户知道有哪些键可用
  bool _showShortcutTip = false;
  Timer? _tipTimer;

  void _maybeShowShortcutTip() {
    if (_isAndroid || kIsWeb) return;
    if (Store.settings.shortcutTipShown) return;
    setState(() => _showShortcutTip = true);
    _tipTimer = Timer(const Duration(seconds: 7), () {
      if (mounted) setState(() => _showShortcutTip = false);
    });
    Store.settings.setShortcutTipShown(true);
  }

  Widget _shortcutTip() {
    return Positioned(
      left: 12,
      right: 12,
      bottom: MediaQuery.of(context).padding.bottom + 86,
      child: IgnorePointer(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: .7),
            borderRadius: BorderRadius.circular(10),
          ),
          child: const Text(
            '快捷键：空格 播放/暂停 · ←→ 快退/快进 · ↑↓ 音量 · M 静音\n'
            'N/P 下一集/上一集 · X/Z 倍速加减 · 1/2/3 设为 1x/2x/3x · D 弹幕 · L 锁定',
            textAlign: TextAlign.center,
            style: TextStyle(
                color: Colors.white70, fontSize: 11, height: 1.7,
                decoration: TextDecoration.none),
          ),
        ),
      ),
    );
  }

  /// 快捷键/操作反馈：屏幕中央的短暂提示
  Widget _hintOverlay(String text) {
    return Positioned.fill(
      child: IgnorePointer(
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: .68),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              text,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  decoration: TextDecoration.none),
            ),
          ),
        ),
      ),
    );
  }

  Widget _body() {
    switch (_stage) {
      case _Stage.resolving:
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(color: K.accent, strokeWidth: 2),
              const SizedBox(height: 16),
              Text(_statusText,
                  style: const TextStyle(color: Colors.white70, fontSize: 13)),
              const SizedBox(height: 8),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 48),
                child: Text(
                  '正在本地解析真实播放地址\n（与 Kazumi 同路：跑一次页面 JS，截获 m3u8 后交给内置播放器）',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white38, fontSize: 11, height: 1.6),
                ),
              ),
            ],
          ),
        );

      case _Stage.manualFallback:
        // 兜底：直接在 WebView 里显示播放器页面，让用户点播
        if (_isAndroid && _wvCtrl != null) {
          return wv.WebViewWidget(controller: _wvCtrl!);
        }
        return _failureView(
          title: '需要在浏览器里播放',
          message: '当前平台无法内置解析，播放页链接已复制到剪贴板。\n$_manualUrl',
        );

      case _Stage.failed:
        return _failureView(
          title: '解析失败',
          message: _error ?? '未知原因',
        );

      case _Stage.playing:
        final c = _controller;
        if (c == null || !c.initialized) {
          return const Center(
            child: CircularProgressIndicator(color: K.accent, strokeWidth: 2),
          );
        }
        final raw = c.aspectRatio;
        final screenW = MediaQuery.of(context).size.width;
        final screenH = MediaQuery.of(context).size.height;
        // 画面比例：0 原始 / 1 16:9 / 2 4:3 / 3 铺满（按屏幕比例填充，可裁切）
        final ar = _fitMode == 1
            ? 16 / 9
            : (_fitMode == 2 ? 4 / 3 : (_fitMode == 3 ? screenW / screenH : raw));
        return GestureDetector(
          onTap: _locked ? null : _toggleUi,
          // 双击：桌面端 = 全屏（PotPlayer / VLC / Kazumi 的一致习惯）；
          //       移动端 = 播放/暂停（手机播放器的通用习惯）。
          // 【v1.9.5】之前两端都是播放/暂停，桌面端用户按习惯双击却没反应，
          // 这也是「不会全屏」的一部分原因。
          onDoubleTap: _locked
              ? null
              : () {
                  if (_isAndroid || (!kIsWeb && Platform.isIOS)) {
                    c.isPlaying ? c.pause() : c.play();
                  } else {
                    _toggleFullscreen();
                  }
                },
          // 长按 2 倍速（松手恢复）
          onLongPressStart: _locked ? null : (_) => _onLongPressStart(),
          onLongPressEnd: _locked ? null : (_) => _onLongPressEnd(),
          onLongPressCancel: _locked ? null : _onLongPressEnd,
          // 滑屏快进/快退（拖动预览，松手 seek）
          onHorizontalDragStart: _locked ? null : (_) => _onSeekDragStart(),
          onHorizontalDragUpdate:
              _locked ? null : (d) => _onSeekDragUpdate(d.delta.dx, screenW),
          onHorizontalDragEnd: _locked ? null : (_) => _onSeekDragEnd(),
          onHorizontalDragCancel: _locked ? null : _onSeekDragEnd,
          // 右侧竖向拖动调音量
          onVerticalDragStart: _locked
              ? null
              : (d) => _onVolumeDragStart(d.localPosition.dx, screenW),
          onVerticalDragUpdate: _locked
              ? null
              : (d) => _onVolumeDragUpdate(
                  d.delta.dy, MediaQuery.of(context).size.height),
          onVerticalDragEnd: _locked ? null : (_) => _onVolumeDragEnd(),
          onVerticalDragCancel: _locked ? null : _onVolumeDragEnd,
          child: Center(
            child: AspectRatio(
              aspectRatio: ar,
              // 弹幕层叠在视频上（不拦手势，手势由外层 GestureDetector 管）
              child: Stack(
                fit: StackFit.expand,
                children: [
                  c.videoWidget(fit: BoxFit.contain),
                  // 弹幕层：时间轴由 _danmakuPosMs 驱动（canvas_danmaku
                  // 自身没有时间概念，见 danmaku_layer.dart 文件头说明）。
                  // 它内部已包 IgnorePointer，不会吞掉播放器手势。
                  if (_danmakus.isNotEmpty && Store.settings.danmakuEnabled)
                    Positioned.fill(
                      child: DanmakuLayer(
                        key: _danmakuKey,
                        entries: _danmakus,
                        positionMs: _danmakuPosMs,
                        style: _danmakuStyle,
                        playing: c.isPlaying,
                      ),
                    ),
                  // 缓冲指示（v1.5.0：播放中卡顿转圈可见）
                  ListenableBuilder(
                    listenable: c,
                    builder: (_, __) {
                      if (!c.isBuffering || c.hasError) return const SizedBox.shrink();
                      return const IgnorePointer(
                        child: Center(
                          child: SizedBox(
                            width: 42, height: 42,
                            child: CircularProgressIndicator(color: Colors.white70, strokeWidth: 2.5),
                          ),
                        ),
                      );
                    },
                  ),
                  // 长按 2× 徽标
                  if (_longPressBoost)
                    Positioned(
                      top: 46,
                      left: 0, right: 0,
                      child: IgnorePointer(
                        child: Center(
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: .6),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: const Text('2× 播放中',
                                style: TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w600)),
                          ),
                        ),
                      ),
                    ),
                  // 滑屏 seek 预览浮层
                  if (_seekDragging)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: Center(
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: .66),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  _seekPreviewMs >= _seekBaseMs
                                      ? Icons.fast_forward
                                      : Icons.fast_rewind,
                                  color: Colors.white, size: 26),
                                const SizedBox(height: 4),
                                Text(
                                  '${_fmt(Duration(milliseconds: _seekPreviewMs))} / ${_fmt(c.duration)}',
                                  style: const TextStyle(
                                      color: Colors.white, fontSize: 13,
                                      fontFamily: K.monoFamily, fontFamilyFallback: K.monoFallback),
                                ),
                                Text(
                                  '${_seekPreviewMs >= _seekBaseMs ? '+' : '-'}${_fmt(Duration(milliseconds: (_seekPreviewMs - _seekBaseMs).abs()))}',
                                  style: const TextStyle(color: Colors.white70, fontSize: 11.5),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
    }
  }

  /// 失败/兜底页。
  ///
  /// 【v1.9.3 · 修「解析失败只能关窗口重开」】
  /// 旧版这里**只有「重试 / 换线路 / 在浏览器打开」三个按钮，没有返回**。
  /// Windows 上用户碰上解析失败就只能关掉整个应用再开（Android 还能用手势返回，
  /// 桌面端没有这个手势）—— 用户明确反馈过这一点。
  ///
  /// 现在补齐：
  ///   - 顶部固定一条返回栏（← 返回），任何失败形态都有出口；
  ///   - 底部「关闭」按钮；
  ///   - `Esc` / `Backspace` 直接返回（见 `_onKey`）。
  Widget _failureView({required String title, required String message}) {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      child: Column(
        children: [
          // ── 返回栏（始终存在，保证「有路可退」）──
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 6, 12, 0),
            child: Row(
              children: [
                IconButton(
                  onPressed: _closePlayer,
                  icon: const Icon(Icons.arrow_back, color: Colors.white, size: 22),
                  tooltip: '返回（Esc）',
                ),
                const Text('返回',
                    style: TextStyle(color: Colors.white70, fontSize: 13)),
                const Spacer(),
                if (_rule != null)
                  Text(_rule!.name,
                      style: TextStyle(
                          color: Colors.white38, fontSize: 11.5, letterSpacing: .5)),
              ],
            ),
          ),
          Expanded(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(28, 8, 28, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error_outline, color: Colors.white54, size: 36),
                    const SizedBox(height: 14),
                    Text(title,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    Text(message,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            color: Colors.white60, fontSize: 12, height: 1.7)),
                    const SizedBox(height: 20),
                    // 主操作：换一条线路（最可能解决问题）
                    if (widget.alternatives.isNotEmpty)
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: _showAlternatives,
                          icon: const Icon(Icons.swap_horiz, size: 18),
                          label: Text('换线路（还有 ${widget.alternatives.length} 条）',
                              style: const TextStyle(fontSize: 13.5)),
                          style: FilledButton.styleFrom(
                            backgroundColor: K.accent,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(K.radiusSm)),
                          ),
                        ),
                      ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () => _boot(
                                overridePageUrl: _pageUrl,
                                overrideRule: _rule,
                                freshAttempt: true),
                            icon: const Icon(Icons.refresh, size: 17),
                            label: const Text('重试', style: TextStyle(fontSize: 13)),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.white,
                              side: BorderSide(color: cs.outline.withValues(alpha: .5)),
                              padding: const EdgeInsets.symmetric(vertical: 11),
                            ),
                          ),
                        ),
                        if ((_manualUrl ?? '').isNotEmpty) ...[
                          const SizedBox(width: 10),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () => _openExternal(_manualUrl!),
                              icon: const Icon(Icons.open_in_browser, size: 17),
                              label: const Text('浏览器打开',
                                  style: TextStyle(fontSize: 13)),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.white,
                                side: BorderSide(color: cs.outline.withValues(alpha: .5)),
                                padding: const EdgeInsets.symmetric(vertical: 11),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 18),
                    TextButton.icon(
                      onPressed: _closePlayer,
                      icon: const Icon(Icons.close, size: 16, color: Colors.white54),
                      label: const Text('关闭播放页',
                          style: TextStyle(color: Colors.white54, fontSize: 12.5)),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 关闭播放页并确保窗口状态被还原。
  ///
  /// 必须在这里主动退出全屏：直接 pop 的话窗口会留在无边框全屏状态，
  /// 用户回到列表页看到的是一个没有标题栏、关不掉的窗口（很难受）。
  void _closePlayer() {
    if (_windowFullscreen) {
      windowCtl.exitFullscreen();
      _windowFullscreen = false;
    }
    Navigator.of(context).maybePop();
  }

  /// 解析时的小窗 WebView：真实加载页面，用户能看到「确实在跑」
  Widget _miniWebView() {
    if (_wvCtrl == null) return const SizedBox.shrink();
    return IgnorePointer(
      child: Opacity(
        opacity: 0.001, // 视觉上不打扰，但必须真实渲染
        child: SizedBox(
          width: 160,
          height: 90,
          child: wv.WebViewWidget(controller: _wvCtrl!),
        ),
      ),
    );
  }

  Widget _manualBar() {
    return Positioned(
      left: 12,
      right: 12,
      bottom: MediaQuery.of(context).padding.bottom + 14,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: .78),
          borderRadius: BorderRadius.circular(K.radiusSm),
          border: Border.all(color: Colors.white24, width: .8),
        ),
        child: Row(
          children: [
            const Icon(Icons.info_outline, color: Colors.white70, size: 16),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                '已切换为网页播放；如未自动播放，请点页面上的播放按钮',
                style: TextStyle(color: Colors.white70, fontSize: 11.5),
              ),
            ),
            if (widget.alternatives.isNotEmpty)
              TextButton(
                onPressed: _showAlternatives,
                child: const Text('换线路', style: TextStyle(fontSize: 12)),
              ),
            IconButton(
              onPressed: _closePlayer,
              icon: const Icon(Icons.close, color: Colors.white70, size: 18),
            ),
          ],
        ),
      ),
    );
  }

  /// 锁定提示（锁屏后只留一个解锁入口）
  Widget _lockBadge() {
    return Positioned(
      right: 14,
      top: MediaQuery.of(context).padding.top + 14,
      child: GestureDetector(
        onTap: () => setState(() => _locked = false),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: .55),
            borderRadius: BorderRadius.circular(14),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lock_outline, size: 16, color: Colors.white70),
              SizedBox(width: 4),
              Text('已锁定 · 点击解锁',
                  style: TextStyle(color: Colors.white70, fontSize: 12)),
            ],
          ),
        ),
      ),
    );
  }

  /// 音量拖动提示层（居中显示）
  Widget _volumeHint() {
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: .62),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_volume > 0 ? Icons.volume_up : Icons.volume_off,
                size: 18, color: Colors.white),
            const SizedBox(width: 8),
            SizedBox(
              width: 90,
              child: LinearProgressIndicator(
                value: _volume,
                backgroundColor: Colors.white24,
                color: Colors.white,
                minHeight: 3,
              ),
            ),
            const SizedBox(width: 8),
            Text('${(_volume * 100).round()}%',
                style: const TextStyle(
                    color: Colors.white, fontSize: 12,
                    fontFamily: K.monoFamily, fontFamilyFallback: K.monoFallback)),
          ],
        ),
      ),
    );
  }

  Widget _topBar() {
    return Positioned(
      left: 0,
      right: 0,
      top: 0,
      child: Container(
        padding: EdgeInsets.only(
            top: MediaQuery.of(context).padding.top + 6, left: 6, right: 6, bottom: 14),
        decoration: BoxDecoration(
          gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.black.withValues(alpha: .72), Colors.transparent]),
        ),
        child: Row(
          children: [
            IconButton(
              onPressed: _closePlayer,
              icon: const Icon(Icons.arrow_back, color: Colors.white, size: 22),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.subject.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white, fontSize: 13.5, fontWeight: FontWeight.w600)),
                  Text(
                    '第 ${_epSort.toStringAsFixed(0)} 集${_epTitle.isNotEmpty ? " · $_epTitle" : ""}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white60, fontSize: 11.5),
                  ),
                  // 【v1.9.2】当前播放线路（Kazumi 也会把线路名显示出来）
                  if (widget.lines.length > 1 || _rule != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Text(
                        '${_rule?.name ?? ""}'
                        '${widget.lines.length > 1 ? " · ${_lineName}" : ""}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: K.accent.withValues(alpha: .85),
                            fontSize: 10.5),
                      ),
                    ),
                ],
              ),
            ),
            if (widget.alternatives.isNotEmpty)
              IconButton(
                onPressed: _showAlternatives,
                icon: const Icon(Icons.swap_horiz, color: Colors.white, size: 20),
                tooltip: '切换线路',
              ),
            // 【v1.5.0 · 对齐 Kazumi 顶栏刷新】用当前线路+当前集重新解析
            IconButton(
              onPressed: () => _boot(
                  overridePageUrl: _pageUrl, overrideRule: _rule, freshAttempt: true),
              icon: const Icon(Icons.refresh, color: Colors.white, size: 20),
              tooltip: '重新解析本集',
            ),
            if (_danmakus.isNotEmpty)
              IconButton(
                // 【v2.0.0 修】原来改的是 `_danmakuVisible` —— 那是**另一个**
                // 独立状态，只控制图标显隐，从不同步到 DanmakuLayer 真正读的
                // `_danmakuStyle.enabled`，所以「能开不能关」。
                // 现已合并为单一状态，按钮与 D 键共用 _toggleDanmaku()。
                onPressed: _toggleDanmaku,
                icon: Icon(
                  _danmakuStyle.enabled
                      ? Icons.subtitles
                      : Icons.subtitles_off_outlined,
                  color: Colors.white,
                  size: 20,
                ),
                tooltip: _danmakuStyle.enabled ? '关闭弹幕' : '打开弹幕',
              ),
            IconButton(
              onPressed: () =>
                  Store.progress.markWatched(widget.subject, widget.episodeSort, epId: widget.episodeId),
              icon: const Icon(Icons.check_circle_outline, color: Colors.white, size: 21),
              tooltip: '标记已看',
            ),
            IconButton(
              onPressed: _toggleOrientation,
              icon: Icon(
                  _landscape
                      ? Icons.screen_lock_portrait_outlined
                      : Icons.screen_lock_landscape_outlined,
                  color: Colors.white,
                  size: 21),
              tooltip: '横竖屏',
            ),
          ],
        ),
      ),
    );
  }

  /// 选集 + 切线路：Kazumi 播放页同款面板。
  ///
  /// 结构（对齐 Kazumi `EpisodeSelectionPanel`）：
  ///   ┌ 番剧名（大标题）
  ///   ├ 「播放线路」下拉按钮 —— 点开列出所有线路，每条显示「N 集」
  ///   ├ 「全部剧集 · N 集」工具条
  ///   └ 剧集列表（逐行，当前集高亮）
  void _showEpisodeSheet() {
    final eps = _currentEpisodes;
    if (eps.isEmpty && widget.lines.isEmpty) {
      _showHint('没有可切换的剧集');
      return;
    }
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      isScrollControlled: true,
      showDragHandle: true,
      constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.85),
      builder: (ctx) => _EpisodePanel(
        title: widget.subject.displayName.isNotEmpty
            ? widget.subject.displayName
            : widget.subject.name,
        sourceName: _rule?.name ?? '',
        lines: widget.lines,
        lineIndex: _lineIndex,
        episodes: List<PlayerEpisodeOption>.of(eps)
          ..sort((a, b) => a.sort.compareTo(b.sort)),
        currentSort: _epSort,
        onPickEpisode: (ep) {
          Navigator.pop(ctx);
          if (ep.sort != _epSort) _switchEpisode(ep);
        },
        onPickLine: (i) {
          Navigator.pop(ctx);
          _switchLine(i);
        },
      ),
    );
  }

  void _showAlternatives() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 14),
              child: Text('切换线路', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final a in widget.alternatives)
                    ListTile(
                      leading: Icon(
                        a.sourceName == _rule?.name
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                        size: 18,
                        color: a.sourceName == _rule?.name ? K.accent : null,
                      ),
                      title: Text(a.sourceName, style: const TextStyle(fontSize: 13.5)),
                      subtitle: Text(
                          '${a.episodeTitle} · ${a.rule.isDirectPlay ? '直链' : '网页解析'}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11)),
                      onTap: () {
                        Navigator.pop(ctx);
                        _switchTo(a.rule, a.pageUrl, a.episodeTitle, a.episodeSort);
                      },
                    ),
                ],
              ),
            ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }

  Widget _bottomBar() {
    final c = _controller;
    if (c == null) return const SizedBox.shrink();
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        padding: EdgeInsets.only(
            left: 12, right: 12, bottom: MediaQuery.of(context).padding.bottom + 12, top: 30),
        decoration: BoxDecoration(
          gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [Colors.black.withValues(alpha: .78), Colors.transparent]),
        ),
        child: ListenableBuilder(
          listenable: c,
          builder: (context, _) {
            final v = c;
            final pos = v.position;
            final dur = v.duration;
            final max = dur.inMilliseconds.toDouble().clamp(1.0, double.infinity).toDouble();
            final val = pos.inMilliseconds.toDouble().clamp(0.0, max).toDouble();
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Text(_fmt(pos),
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 11, fontFamily: K.monoFamily, fontFamilyFallback: K.monoFallback)),
                    Expanded(
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 2.5,
                          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5.5),
                          overlayShape: const RoundSliderOverlayShape(overlayRadius: 13),
                          activeTrackColor: K.accent,
                          inactiveTrackColor: Colors.white24,
                          thumbColor: K.accent,
                        ),
                        child: Slider(
                          value: val,
                          max: max,
                          onChanged: (x) => c.seekTo(Duration(milliseconds: x.toInt())),
                        ),
                      ),
                    ),
                    Text(_fmt(dur),
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 11, fontFamily: K.monoFamily, fontFamilyFallback: K.monoFallback)),
                  ],
                ),
                Row(
                  children: [
                    IconButton(
                      onPressed: () => c.seekTo(pos - const Duration(seconds: 15)),
                      icon: const Icon(Icons.replay_10, color: Colors.white, size: 24),
                    ),
                    IconButton(
                      onPressed: () => v.isPlaying ? c.pause() : c.play(),
                      icon: Icon(
                          v.isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled,
                          color: Colors.white,
                          size: 40),
                    ),
                    IconButton(
                      onPressed: () => c.seekTo(pos + const Duration(seconds: 15)),
                      icon: const Icon(Icons.forward_10, color: Colors.white, size: 24),
                    ),
                    const Spacer(),
                    // 上一集 / 下一集（Kazumi 同款快捷切集）
                    if (_currentEpisodes.isNotEmpty)
                      IconButton(
                        onPressed: () => _jumpEpisode(-1),
                        icon: const Icon(Icons.skip_previous, color: Colors.white, size: 22),
                        tooltip: '上一集 (P)',
                      ),
                    if (_currentEpisodes.isNotEmpty)
                      IconButton(
                        onPressed: () => _jumpEpisode(1),
                        icon: const Icon(Icons.skip_next, color: Colors.white, size: 22),
                        tooltip: '下一集 (N)',
                      ),
                    if (_currentEpisodes.isNotEmpty || widget.lines.isNotEmpty)
                      IconButton(
                        onPressed: _showEpisodeSheet,
                        icon: const Icon(Icons.view_list, color: Colors.white, size: 22),
                        tooltip: widget.lines.length > 1 ? '选集 / 切线路' : '选集',
                      ),
                    if (widget.alternatives.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(right: 2),
                        child: TextButton(
                          onPressed: _showAlternatives,
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          child: const Text('线路',
                              style: TextStyle(color: Colors.white, fontSize: 13)),
                        ),
                      ),
                    // 倍速菜单（Kazumi 同款档位：0.5 ~ 3.0）
                    PopupMenuButton<double>(
                      initialValue: v.speed,
                      color: const Color(0xFF1B1B1E),
                      iconSize: 18,
                      padding: EdgeInsets.zero,
                      onSelected: _setSpeed,
                      itemBuilder: (_) => _speedPresets
                          .map((s) => PopupMenuItem<double>(
                                value: s,
                                height: 34,
                                child: Text('${s.toStringAsFixed(2).replaceAll(RegExp(r'0+$|\\.$'), '')}×',
                                    style: TextStyle(
                                        color: s == v.speed
                                            ? K.accent
                                            : Colors.white,
                                        fontSize: 13)),
                              ))
                          .toList(),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                        child: Text('${v.speed.toStringAsFixed(1)}×',
                            style: const TextStyle(
                                color: Colors.white, fontFamily: K.monoFamily, fontFamilyFallback: K.monoFallback, fontSize: 13)),
                      ),
                    ),
                    // 画面比例（原始 / 16:9 / 4:3 / 铺满）
                    IconButton(
                      onPressed: _cycleFitMode,
                      icon: const Icon(Icons.aspect_ratio, color: Colors.white, size: 20),
                      tooltip: ['原始', '16:9', '4:3', '铺满'][_fitMode],
                    ),
                    // 锁屏（防误触）
                    // 【v1.9.5 · 关键交互补齐】全屏按钮
                    //
                    // 之前全屏**只能用 F 键**，界面上没有按钮 —— 用户不知道，
                    // 于是反馈「依旧不是全屏观看的 / 不会做就去照搬 Kazumi」。
                    // Kazumi 桌面端一直有全屏按钮，这属于基本交互。
                    IconButton(
                      onPressed: _toggleFullscreen,
                      icon: Icon(
                        _windowFullscreen || _landscape || _webviewFullscreen
                            ? Icons.fullscreen_exit
                            : Icons.fullscreen,
                        color: Colors.white,
                        size: 22,
                      ),
                      tooltip: (_windowFullscreen || _landscape || _webviewFullscreen)
                          ? '退出全屏 (F/Esc)'
                          : '全屏 (F)',
                    ),
                    IconButton(
                      onPressed: () => setState(() => _locked = true),
                      icon: const Icon(Icons.lock_open_outlined, color: Colors.white, size: 20),
                      tooltip: '锁定',
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.white24, width: .8),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(_rule?.name ?? 'HLS',
                          style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 9.5,
                              fontFamily: K.monoFamily, fontFamilyFallback: K.monoFallback,
                              letterSpacing: .6)),
                    ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  static String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }
}

/// 生命周期：退到后台时保存进度
class _LifecycleListener with WidgetsBindingObserver {
  VoidCallback? onPause;
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      onPause?.call();
    }
  }
}

// ═══════════════════ 选集 + 切线路面板（对齐 Kazumi `EpisodeSelectionPanel`） ═══════════════════

/// Kazumi 的播放页选集面板结构：
///   番剧名（大标题）
///   「播放线路」下拉按钮（显示当前线路名 + 集数，点开列出全部线路）
///   「全部剧集 · N 集」工具条
///   剧集列表（逐行，当前集高亮，可滚动）
///
/// 本实现保持同样信息层级，但用 K酱 的纸墨主题样式。
/// 选集面板（v1.9.3 完全重设计）
///
/// ## 设计目标（用户要求：简洁明了、符合逻辑、方便使用、排版重做）
///
/// 旧设计的问题（都被用户点出来了）：
///   1. **线路切换藏在「下拉按钮」里** —— 要先点一下展开、再点一次选择，两步；
///      而且展开后线路列表**和剧集列表抢同一块空间**，滚动位置会跳。
///   2. **剧集是一条一行** —— 24 集就要滚 24 行，长篇（60+ 集）根本翻不完。
///   3. 信息重复：番剧名 + 「播放线路」+ 「全部剧集 · N 集」三层标题堆在一起。
///
/// 新设计（一次做对，层次只有三层）：
///
/// ```
/// ┌──────────────────────────────────────────────┐
/// │ 番剧名                              DM84     │ ← 标题行（右侧标来源）
/// │ 播放线路   [线路1 · 28集] [线路2 · 28集]      │ ← 芯片横滑，一步切换
/// ├──────────────────────────────────────────────┤
/// │ 第 1 集                                  ▶   │ ← 当前集：整行高亮，最醒目
/// ├──────────────────────────────────────────────┤
/// │ [2] [3] [4] [5] [6] [7] [8] [9]              │ ← 其余集：网格，一屏看几十集
/// │ [10] [11] ...                                 │
/// └──────────────────────────────────────────────┘
/// ```
///
/// 关键改动：
///   - **线路用横向芯片**（不是下拉）：一眼看到有几条、当前是哪条、点一下就切；
///   - **当前集单独一整行**突出显示（它是最需要看清的信息）；
///   - **其余集用网格**（数字按钮）：一屏能看 30+ 集，长篇不用疯狂滚动；
///     集名有意义时（如「第3话 特别篇」）网格下方补一行完整集名；
///   - 去掉重复的「全部剧集」标题条。
class _EpisodePanel extends StatefulWidget {
  final String title;
  final String sourceName;
  final List<PlayerLine> lines;
  final int lineIndex;
  final List<PlayerEpisodeOption> episodes;
  final double currentSort;
  final void Function(PlayerEpisodeOption) onPickEpisode;
  final void Function(int) onPickLine;

  const _EpisodePanel({
    required this.title,
    required this.lines,
    required this.lineIndex,
    required this.episodes,
    required this.currentSort,
    required this.onPickEpisode,
    required this.onPickLine,
    this.sourceName = '',
  });

  @override
  State<_EpisodePanel> createState() => _EpisodePanelState();
}

class _EpisodePanelState extends State<_EpisodePanel> {
  /// 用户点选的集（用于在网格里预览完整集名）
  int? _preview;

  String _lineName(int i) {
    if (i < 0 || i >= widget.lines.length) return '播放线路1';
    final n = widget.lines[i].name.trim();
    return n.isEmpty ? '播放线路${i + 1}' : n;
  }

  /// 剧集按钮上的短标签：能解析出集号就只显示数字，否则显示原名的前几个字
  String _shortLabel(PlayerEpisodeOption ep) {
    final t = ep.title.trim();
    if (t.isEmpty) return '${ep.sort}';
    // 「第12话」「12」「第 12 集」这类 → 只留数字
    final m = RegExp(r'^第?\s*(\d+(?:\.\d+)?)\s*[集话話]?$').firstMatch(t);
    if (m != null) return m.group(1)!;
    // 否则截断
    return t.length > 6 ? '${t.substring(0, 6)}…' : t;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final cur = widget.lineIndex >= 0 && widget.lineIndex < widget.lines.length
        ? widget.lineIndex
        : 0;
    final eps = widget.episodes;
    // 当前集在列表里的下标
    final curIdx = eps.indexWhere((e) => e.sort == widget.currentSort.round());
    final current = curIdx >= 0 ? eps[curIdx] : null;
    // 其余集（当前集已经从网格里拿出去单独显示了）
    final rest = <PlayerEpisodeOption>[
      for (var i = 0; i < eps.length; i++)
        if (i != curIdx) eps[i]
    ];
    final previewEp = _preview != null
        ? eps.firstWhere((e) => e.sort == _preview, orElse: () => eps.first)
        : null;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ══════ 第 1 层：标题 + 来源 ══════
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  widget.title.isEmpty ? '选集' : widget.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700, height: 1.3),
                ),
              ),
              if (widget.sourceName.isNotEmpty) ...[
                const SizedBox(width: 10),
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      color: K.accent.withValues(alpha: .12),
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: Text(widget.sourceName,
                        style: TextStyle(
                            fontSize: 10.5,
                            color: K.accent,
                            fontWeight: FontWeight.w600)),
                  ),
                ),
              ],
            ],
          ),
        ),

        // ══════ 第 2 层：线路芯片（一步切换） ══════
        if (widget.lines.length > 1)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
                  child: Text('播放线路',
                      style: theme.textTheme.labelSmall?.copyWith(
                          fontSize: 11,
                          letterSpacing: .8,
                          color: cs.onSurfaceVariant)),
                ),
                SizedBox(
                  height: 38,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: widget.lines.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 8),
                    itemBuilder: (_, i) {
                      final on = i == cur;
                      final cnt = widget.lines[i].episodes.length;
                      return GestureDetector(
                        onTap: () {
                          if (!on) widget.onPickLine(i);
                        },
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 140),
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: on ? K.accent : cs.surfaceContainerHigh,
                            borderRadius: BorderRadius.circular(19),
                            border: Border.all(
                                color: on ? K.accent : cs.outlineVariant,
                                width: .9),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (on) ...[
                                const Icon(Icons.play_arrow_rounded,
                                    size: 15, color: Colors.white),
                                const SizedBox(width: 3),
                              ],
                              Text(
                                _lineName(i),
                                style: TextStyle(
                                  fontSize: 12.5,
                                  fontWeight:
                                      on ? FontWeight.w700 : FontWeight.w500,
                                  color: on ? Colors.white : cs.onSurface,
                                ),
                              ),
                              const SizedBox(width: 5),
                              Text(
                                '$cnt',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontFamily: K.monoFamily,
                                  fontFamilyFallback: K.monoFallback,
                                  color: on
                                      ? Colors.white70
                                      : cs.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),

        // ══════ 第 3 层：当前集（整行突出） ══════
        if (current != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: K.accent.withValues(alpha: .1),
                border: Border.all(color: K.accent, width: 1.2),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(Icons.play_circle_fill_rounded, color: K.accent, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('正在播放',
                            style: TextStyle(
                                fontSize: 10.5,
                                color: K.accent.withValues(alpha: .9),
                                height: 1.3)),
                        const SizedBox(height: 1),
                        Text(
                          current.title.trim().isEmpty
                              ? '第 ${current.sort} 集'
                              : current.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 14.5, fontWeight: FontWeight.w700),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

        if (rest.isNotEmpty) ...[
          const Divider(height: 1),
          // 预览行：点哪个集就在这显示完整集名（网格空间有限放不下文字）
          SizedBox(
            height: 26,
            child: Center(
              child: Text(
                previewEp != null
                    ? (previewEp.title.trim().isEmpty
                        ? '第 ${previewEp.sort} 集'
                        : previewEp.title)
                    : '选择要看的集',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 11.5,
                    color: previewEp != null
                        ? cs.onSurface
                        : cs.onSurfaceVariant),
              ),
            ),
          ),
          // ══════ 其余集：网格（一屏几十集） ══════
          Flexible(
            child: GridView.builder(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 78,
                childAspectRatio: 1.85,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
              ),
              itemCount: rest.length,
              itemBuilder: (_, i) {
                final ep = rest[i];
                final label = _shortLabel(ep);
                final numeric = double.tryParse(label) != null;
                final isPreview = _preview == ep.sort;
                return GestureDetector(
                  onTap: () {
                    setState(() => _preview = ep.sort);
                    widget.onPickEpisode(ep);
                  },
                  onLongPress: () => setState(() => _preview = ep.sort),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 120),
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    decoration: BoxDecoration(
                      color: isPreview
                          ? K.accent.withValues(alpha: .14)
                          : cs.surfaceContainerHigh,
                      border: Border.all(
                          color: isPreview ? K.accent : cs.outlineVariant,
                          width: isPreview ? 1.1 : .8),
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: numeric ? 13.5 : 10.5,
                        fontWeight: numeric ? FontWeight.w600 : FontWeight.w500,
                        fontFamily:
                            numeric ? K.monoFamily : null,
                        fontFamilyFallback:
                            numeric ? K.monoFallback : null,
                        color: isPreview ? K.accent : cs.onSurface,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ] else
          const SizedBox(height: 12),
      ],
    );
  }
}
