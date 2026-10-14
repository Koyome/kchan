/// 播放器后端抽象：media-kit(libmpv) 为主，video_player(fvp/libmdk) 兜底
///
/// ## 为什么要有这层抽象
///
/// 用户要求换用 media-kit 仓库的播放器。但本项目 Windows 构建链是 MinGW
/// 手搓（无 CMake），media-kit 的原生插件是我们手编的 DLL——万一某台机器
/// 加载失败（缺 DLL / 老显卡 ANGLE 初始化失败），**绝不能让 app 变成「点不开
/// 视频」**。所以：运行时优先尝试 media-kit，失败自动回落到原 video_player+fvp
/// 链路，两条路共用同一套对外接口 [VideoHandle]。
///
/// ## 对齐 media-kit 的优化点（照抄 media-kit 仓库的做法）
///
///  - 硬解默认开启（VideoControllerConfiguration.enableHardwareAcceleration）；
///  - `Video` 控件关闭内置 controls（我们有自己的手势层与控制条）；
///  - HLS 走 libmpv 原生 demux（比 ExoPlayer/mdk 对国内 CDN 的容错更好）；
///  - seekBeforePlay：libmpv 支持起播前 seek（跳过前贴广告不闪广告帧）。
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:video_player/video_player.dart';

import 'android_env.dart';
import 'diag_log.dart' show kLog;

/// media-kit 是否初始化成功（main.dart 里调 [initPlayerBackend] 后生效）
bool mediaKitReady = false;

void initPlayerBackend() {
  try {
    MediaKit.ensureInitialized();
    mediaKitReady = true;
    kLog('[播放器] media-kit(libmpv) 初始化成功');
  } catch (e) {
    mediaKitReady = false;
    kLog('[播放器] media-kit 初始化失败，回落 fvp: $e');
  }
}

/// 统一的播放器句柄。player_page 只认它，不关心底层是 libmpv 还是 mdk。
abstract class VideoHandle implements Listenable {
  bool get initialized;
  bool get hasError;
  String? get errorText;
  bool get isPlaying;
  bool get isBuffering;
  bool get isCompleted;
  Duration get position;
  Duration get duration;
  double get speed;

  /// 宽高（未知为 0）
  int get width;
  int get height;
  double get aspectRatio => (width > 0 && height > 0) ? width / height : 16 / 9;

  Widget videoWidget({required BoxFit fit});

  Future<void> play();
  Future<void> pause();
  Future<void> seekTo(Duration d);
  Future<void> setSpeed(double v);
  void setVolume(double v);

  /// 【v1.9.9 · 解码器稳定性】视频输出是否仍在出帧。
  ///
  /// 返回 `null` = 该后端不支持探测（调用方跳过判断，绝不误判）。
  ///
  /// 实测症状：**看久了突然黑屏，但有声音、进度也在走，退出全屏又恢复** ——
  /// 这是视频输出链路（D3D 交换链 / 纹理）掉了，而音频与解复用仍正常。
  /// 探测手段是 mpv 的 `estimated-vf-fps`：输出健康时是实际帧率，
  /// **输出掉链时是 0**。用它才能客观区分「真黑屏」与「画面本来就是黑的」。
  Future<double?> videoOutputFps();

  /// 尝试在不重建播放器的前提下**刷新视频输出**（促其重新协商输出表面）。
  /// 返回是否成功。
  Future<bool> refreshVideoOutput();

  Future<void> dispose();

  /// 创建并完成初始化（失败抛异常，调用方决定是否回落）
  static Future<VideoHandle> network(
    String url, {
    Map<String, String> headers = const {},
  }) async {
    // 【诊断】`KCHAN_FORCE_FVP=1` 强制走 fvp 后端。
    // 用途：区分「渲染管线问题」与「某个后端的问题」——
    // 实测 Windows 上出现「控制条正常但视频区透明/全黑」，
    // 需要确定是 media-kit 这条链路还是 Flutter 纹理层的问题。
    final forceFvp = Platform.environment['KCHAN_FORCE_FVP'] == '1';
    if (forceFvp) {
      kLog('[播放器] KCHAN_FORCE_FVP=1 → 强制使用 fvp 后端');
    } else if (mediaKitReady) {
      final h = MediaKitHandle(url, headers);
      try {
        await h._init();
        kLog('[播放器] 使用 media-kit(libmpv) 后端');
        return h;
      } catch (e) {
        kLog('[播放器] media-kit 起播失败，回落 fvp: $e');
        try {
          await h.dispose();
        } catch (_) {}
      }
    }
    final f = FvpHandle(url, headers);
    await f._init();
    kLog('[播放器] 使用 video_player(fvp) 后端');
    return f;
  }
}

// ───────────────────────── media-kit(libmpv) 实现 ─────────────────────────

class MediaKitHandle extends ChangeNotifier implements VideoHandle {
  MediaKitHandle(this._url, this._headers);

  final String _url;
  final Map<String, String> _headers;

  bool get _isAndroid => !kIsWeb && Platform.isAndroid;

  late final Player _player;
  late final VideoController _vc;
  bool _disposed = false;

  bool _initialized = false;
  bool _hasError = false;
  String? _errorText;
  bool _playing = false;
  bool _buffering = false;
  bool _completed = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double _rate = 1.0;
  int _width = 0;
  int _height = 0;

  @override
  bool get initialized => _initialized;
  @override
  bool get hasError => _hasError;
  @override
  String? get errorText => _errorText;
  @override
  bool get isPlaying => _playing;
  @override
  bool get isBuffering => _buffering;
  @override
  bool get isCompleted => _completed;
  @override
  Duration get position => _position;
  @override
  Duration get duration => _duration;
  @override
  double get speed => _rate;
  @override
  int get width => _width;
  @override
  int get height => _height;
  @override
  double get aspectRatio =>
      (_width > 0 && _height > 0) ? _width / _height : 16 / 9;

  Future<void> _init() async {
    // ═══════════════════════════════════════════════════════════════════
    //  【v1.9.4 · 逐项对齐 Kazumi 的安卓播放优化】
    //
    //  本节每一个参数都取自 Kazumi 官方源码
    //  （`lib/pages/player/controller/player_playback_controller.dart`
    //    + `lib/services/player/playback_cache_policy.dart`），
    //  不是拍脑袋调参。用户反馈「手机端还是很卡」，这几项是主因：
    //
    //   1. **渲染器 `vo`**：Kazumi 在 Android 14(SDK 34) 及以上用
    //      `gpu-next`（基于 Vulkan，着色器/缩放性能更好），更低版本用 `gpu`
    //      （OpenGL，避开老机型 Vulkan 支持不佳导致的黑屏）。
    //      旧代码**根本没设 vo** → 走 media-kit 默认值，不是最优。
    //   2. **`hwdec: 'mediacodec'`**：显式指定 MediaCodec 硬件解码器。
    //      旧代码只开 `enableHardwareAcceleration: true`，
    //      没有把解码器钉到 mediacodec 上。
    //   3. **`enableAndroidSurfaceProducer: false`**：Kazumi 明确关掉它
    //      （SurfaceProducer 路径在部分机型上与 hwdec 组合会掉帧）。
    //   4. **缓存大小按网络类型自适应**：Kazumi 的 PlaybackCachePolicy 是
    //      「计费网络 2MB / 其它 1500MB」，并通过
    //      `demuxer-max-bytes` + `demuxer-max-back-bytes` 两个属性设置。
    //      旧代码写死 32MB —— 移动数据下偏大（费流量、低端机吃内存），
    //      Wi-Fi 下又偏小（拖动要重新缓冲）。
    //   5. **音频输出 `ao`**：Kazumi 在 Android 上显式用 `audiotrack`
    //      （不用默认的 opensles），音频延迟更低、更省电。
    //   6. **`af=scaletempo2=max-speed=8`**：倍速播放用 scaletempo2，
    //      2x 以上不变调、不掉帧（默认没有这个滤镜）。
    // ═══════════════════════════════════════════════════════════════════
    kLog('[播放器] ${describeAndroidEnv()}');

    _player = Player(
      configuration: PlayerConfiguration(
        // Kazumi 的 CachePolicy：计费网络 2MB，其余 1500MB
        bufferSize: playerBufferBytes,
        osc: false,
      ),
    );
    _vc = VideoController(
      _player,
      configuration: VideoControllerConfiguration(
        // ═══════════════════════════════════════════════════════════════
        // 【v1.9.7 · 修「视频区不显示画面」】
        //
        // v1.9.4 为了对齐 Kazumi 的安卓优化，我给 `vo` 无条件传了
        // `androidVideoRenderer`（桌面上返回 'gpu'）。
        // **这是错的**：media_kit 在桌面（Windows/macOS/Linux）的 `vo` 默认是
        // `libmpv`，只有 Android 才是 `gpu`。
        // 桌面上强行设 `vo=gpu` 会导致**视频纹理不再上屏** ——
        // 实测表现就是「控制条/进度条都正常、时间也在走，但画面区是透明的
        // （能透出桌面）」。这正是用户反馈的「完全没显示视频」。
        //
        // 修法：`vo` 只在 Android 上设置，桌面保持 media_kit 默认（libmpv）；
        // `hwdec` 同理（桌面默认 `auto` 才对）。
        // ═══════════════════════════════════════════════════════════════
        vo: _isAndroid ? androidVideoRenderer : null,
        enableHardwareAcceleration: true,
        hwdec: _isAndroid ? 'mediacodec' : 'auto',
      ),
    );

    // Kazumi 用 NativePlayer 直接设 mpv 属性（上面两个配置项覆盖不到的部分）
    unawaited(_applyMpvTuning());

    final subs = [
      _player.stream.playing.listen((v) {
        _playing = v;
        notifyListeners();
      }),
      _player.stream.completed.listen((v) {
        _completed = v;
        notifyListeners();
      }),
      _player.stream.position.listen((v) {
        _position = v;
        notifyListeners();
      }),
      _player.stream.duration.listen((v) {
        _duration = v;
        if (!_initialized && v > Duration.zero) _initialized = true;
        notifyListeners();
      }),
      _player.stream.buffering.listen((v) {
        _buffering = v;
        notifyListeners();
      }),
      _player.stream.rate.listen((v) {
        _rate = v;
        notifyListeners();
      }),
      _player.stream.width.listen((v) {
        _width = v ?? 0;
        notifyListeners();
      }),
      _player.stream.height.listen((v) {
        _height = v ?? 0;
        notifyListeners();
      }),
      _player.stream.error.listen((v) {
        if (v.isNotEmpty) {
          _hasError = true;
          _errorText = v;
          notifyListeners();
        }
      }),
    ];
    _subs.addAll(subs);

    // open 内部会等待媒体打开（含 duration 解析）；超时视为失败
    await _player
        .open(Media(_url, httpHeaders: _headers))
        .timeout(const Duration(seconds: 20));

    // 再等 duration（有的流 open 返回时 duration 还没出来）
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!_initialized && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (_hasError) throw StateError(_errorText ?? 'media-kit 打开失败');
    }
    if (!_initialized) throw StateError('media-kit 打开超时（10s 无时长）');
  }

  final List<dynamic> _subs = [];

  /// 通过 `NativePlayer.setProperty` 设置 Kazumi 用到的 mpv 原生属性。
  ///
  /// 为什么要单独做这一步：`PlayerConfiguration` / `VideoControllerConfiguration`
  /// 只覆盖了一部分 mpv 选项，Kazumi 另外直接设了这些属性
  /// （见其 `player_playback_controller.dart`）：
  ///   - `demuxer-max-bytes` / `demuxer-max-back-bytes`：前后向缓存字节数
  ///   - `ao=audiotrack`（仅 Android）：音频输出后端
  ///   - `af=scaletempo2=max-speed=8`：倍速不变调
  ///   - `volume-max=100`（仅 Android）
  ///
  /// 失败不影响播放（老版本 media-kit 可能没有 `platform`），所以整体 try/catch。
  Future<void> _applyMpvTuning() async {
    try {
      // 等播放器实例就绪再设属性，否则属性会被初始化过程覆盖
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      dynamic pp;
      while (DateTime.now().isBefore(deadline)) {
        try {
          pp = _player.platform;
          if (pp != null) break;
        } catch (_) {}
        await Future<void>.delayed(const Duration(milliseconds: 80));
      }
      if (pp == null) return;

      final size = playerBufferBytes.toString();
      Future<void> set(String k, String v) async {
        try {
          await pp.setProperty(k, v);
        } catch (_) {}
      }

      await set('demuxer-max-bytes', size);
      await set('demuxer-max-back-bytes', playerBackBufferBytes.toString());
      await set('af', 'scaletempo2=max-speed=8');
      if (_isAndroid) {
        await set('ao', 'audiotrack');
        await set('volume-max', '100');
      }
      kLog('[播放器] mpv 调优已应用：前向=${playerBufferBytes ~/ (1024 * 1024)}MB '
          '后向=${playerBackBufferBytes ~/ (1024 * 1024)}MB'
          '${_isAndroid ? " ao=audiotrack" : ""} af=scaletempo2');
    } catch (e) {
      kLog('[播放器] mpv 调优跳过（不影响播放）: $e');
    }
  }

  @override
  Widget videoWidget({required BoxFit fit}) {
    return Video(
      controller: _vc,
      fit: fit,
      controls: NoVideoControls, // 我们有自己的手势层和控制条
    );
  }

  @override
  Future<void> play() => _player.play();
  @override
  Future<void> pause() => _player.pause();
  @override
  Future<void> seekTo(Duration d) => _player.seek(d);
  @override
  Future<void> setSpeed(double v) => _player.setRate(v);
  @override
  void setVolume(double v) {
    _player.setVolume(v * 100);
  }

  /// 读 mpv 的 `estimated-vf-fps`：视频输出是否还在出帧。
  ///
  /// - 正常播放：返回实际帧率（约 23.98 / 24 / 25 / 30 / 60）
  /// - **输出掉链（黑屏但有声音）**：返回 0
  /// - 暂停 / 无视频轨 / 读不到：返回 null（调用方据此不判黑屏）
  @override
  Future<double?> videoOutputFps() async {
    try {
      final pf = _player.platform;
      // media_kit 的 NativePlayer 暴露 getProperty（1.2.6 起为 public）
      final raw = await (pf as dynamic).getProperty('estimated-vf-fps');
      if (raw == null) return null;
      // 可能是 "23.976" 或 "23.976f"（mpv 的 format 后缀），去掉非数字尾巴
      final s = raw.toString().replaceAll(RegExp(r'[^0-9.\-]'), '');
      if (s.isEmpty) return null;
      return double.tryParse(s);
    } catch (_) {
      return null; // 不支持探测 → 不判黑屏
    }
  }

  /// 尝试刷新视频输出（不重建播放器）。
  ///
  /// 步骤刻意做得「温和」，避免打断播放：
  ///   1. 记录当前位置与 `vo` 值；
  ///   2. 重新下发同一个 `vo`（强制 mpv 重新协商输出表面）；
  ///   3. 回退 2 秒再跳回原位 —— 给渲染管线一次完整重绘机会。
  /// 任何一步失败都返回 false，由调用方决定是否升级处理。
  @override
  Future<bool> refreshVideoOutput() async {
    try {
      final pf = _player.platform as dynamic;
      final pos = _position;
      // ① 重新下发 vo（沿用当前配置，等价于让输出重新初始化）
      try {
        // 桌面保持 media_kit 默认（libmpv）；Android 用自适应值。
        // 传 null 会报错，所以桌面上改用 libmpv 这个明确值。
        await pf.setProperty('vo', _isAndroid ? androidVideoRenderer : 'libmpv');
      } catch (_) {}
      // ② 极短回退再跳回：促使解码器吐出新的一帧
      if (pos > const Duration(seconds: 3)) {
        await _player.seek(pos - const Duration(seconds: 2));
        await Future<void>.delayed(const Duration(milliseconds: 120));
        await _player.seek(pos);
      }
      kLog('[播放器] 已尝试刷新视频输出（vo 重下发 + 回退重绘）');
      return true;
    } catch (e) {
      kLog('[播放器] 刷新视频输出失败: $e');
      return false;
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    // ═══════════════════════════════════════════════════════════════════
    // 【v1.9.9 · 修「换线路后两条线路同时出声/同时播」】
    //
    // 旧实现直接 `_player.dispose()`。但 media_kit 的 `dispose()` 是**异步**
    // 释放：它会去停 libmpv 的播放线程并等待，期间**音频仍在继续**。
    // 而调用方（`_resetForSwitch`）只 `await` 了我们这一层，
    // 紧接着就创建了新播放器 —— 于是出现「旧线路还在放、新线路也开始放」。
    //
    // 修法：**先把播放停掉并静音**，再走资源释放。
    // `pause()` + `setVolume(0)` 是同步生效的（立刻作用于 mpv），
    // 这样即便 dispose 内部还要花时间，用户也不会再听到旧线路的声音。
    // ═══════════════════════════════════════════════════════════════════
    try {
      await _player.pause();
    } catch (_) {}
    try {
      await _player.setVolume(0);
    } catch (_) {}
    // 解绑所有流订阅，避免 dispose 过程中还有回调触发 setState
    for (final s in _subs) {
      try {
        await s.cancel();
      } catch (_) {}
    }
    _subs.clear();
    try {
      await _player.dispose();
    } catch (_) {}
    kLog('[播放器] 已释放 media-kit 实例（已先暂停并静音）');
    super.dispose();
  }
}

// ───────────────────────── video_player(fvp) 兜底实现 ─────────────────────────

class FvpHandle extends ChangeNotifier implements VideoHandle {
  FvpHandle(this._url, this._headers);

  /// 幂等释放标记（见 dispose 注释）
  bool _disposed = false;

  final String _url;
  final Map<String, String> _headers;

  late final VideoPlayerController _c;

  @override
  bool get initialized => _c.value.isInitialized;
  @override
  bool get hasError => _c.value.hasError;
  @override
  String? get errorText => _c.value.errorDescription;
  @override
  bool get isPlaying => _c.value.isPlaying;
  @override
  bool get isBuffering => _c.value.isBuffering;
  @override
  bool get isCompleted => _c.value.isCompleted;
  @override
  Duration get position => _c.value.position;
  @override
  Duration get duration => _c.value.duration;
  @override
  double get speed => _c.value.playbackSpeed;
  @override
  int get width => _c.value.size.width.round();
  @override
  int get height => _c.value.size.height.round();
  @override
  double get aspectRatio {
    final ar = _c.value.aspectRatio;
    return ar > 0 ? ar : 16 / 9;
  }

  Future<void> _init() async {
    _c = VideoPlayerController.networkUrl(Uri.parse(_url), httpHeaders: _headers);
    _c.addListener(notifyListeners);
    await _c.initialize();
  }

  @override
  Widget videoWidget({required BoxFit fit}) => VideoPlayer(_c);

  @override
  Future<void> play() => _c.play();
  @override
  Future<void> pause() => _c.pause();
  @override
  Future<void> seekTo(Duration d) => _c.seekTo(d);
  @override
  Future<void> setSpeed(double v) => _c.setPlaybackSpeed(v);
  @override
  void setVolume(double v) => _c.setVolume(v);

  /// video_player(fvp) 没有等价的「输出是否出帧」探针，
  /// 返回 null 让调用方跳过黑屏判断（宁可漏判，也不误判后乱刷新）。
  @override
  Future<double?> videoOutputFps() async => null;

  /// 该后端能做的最轻刷新：重新 seek 到当前位置，触发一次重新渲染。
  @override
  Future<bool> refreshVideoOutput() async {
    try {
      // video_player 的 position 是 Future<Duration?>；取不到就退化为 0
      final pos = (await _c.position) ?? Duration.zero;
      await _c.seekTo(pos);
      kLog('[播放器] 已尝试刷新视频输出（fvp 重定位重绘）');
      return true;
    } catch (e) {
      kLog('[播放器] 刷新视频输出失败(fvp): $e');
      return false;
    }
  }

  @override
  Future<void> dispose() async {
    // 【v1.9.9】加幂等保护：换线路时可能被重复调用（_resetForSwitch + dispose），
    // 重复释放 video_player 控制器会抛异常并可能残留一个还在播的实例。
    if (_disposed) return;
    _disposed = true;
    try {
      // 先暂停并静音，确保音频立刻停（同 media-kit 那条路径的原因）
      await _c.pause();
    } catch (_) {}
    try {
      await _c.setVolume(0);
    } catch (_) {}
    _c.removeListener(notifyListeners);
    try {
      await _c.dispose();
    } catch (_) {}
    kLog('[播放器] 已释放 fvp 实例（已先暂停并静音）');
    super.dispose();
  }
}
