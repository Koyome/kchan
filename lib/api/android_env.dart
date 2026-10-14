/// Android 运行环境探测（**不依赖任何原生插件**）
///
/// ## 为什么需要它
///
/// 对齐 Kazumi 的 Android 播放优化时，有几项**必须按设备能力/网络类型**决定：
///
/// | 决策 | 依据 | Kazumi 的做法 |
/// | --- | --- | --- |
/// | 渲染器 `vo` | **Android SDK 版本** | ≥34 用 `gpu-next`(Vulkan)，否则 `gpu` |
/// | 缓存大小 | **是否计费网络** | 计费网络用 2MB（省流量/防 OOM），否则 1500MB |
/// | 音频输出 | 固定 | `audiotrack`（不用默认的 `opensles`） |
///
/// ## 为什么不用 plugin 读这些
///
/// `device_info_plus` / `connectivity_plus` 都会引入新的原生插件；
/// 本项目的 Android 侧是**手工打补丁**的（`.flutter-plugins-dependencies` /
/// `GeneratedPluginRegistrant.java` 都手改过，见交接文档），
/// 加插件要同步改这些补丁文件，成本高且容易出错。
///
/// 而这两件事都有**零依赖**的读取方式：
///   - SDK 版本：`dart:io` 的 `Platform.operatingSystemVersion` 里就带
///     `"Android 14 (SDK 34)"` 这样的串（Flutter 引擎填的）；
///   - 是否计费：`ConnectivityManager.isActiveNetworkMetered`。这个要走 JNI，
///     代价较大，所以这里退一步：**默认按「移动网络优先省流量」处理**，
///     并允许用环境变量/设置覆盖（见 [meteredOverride]）。
library;

import 'dart:io' show Platform;

/// Android SDK 版本（取不到返回 0）
///
/// `Platform.operatingSystemVersion` 在 Android 上的典型值：
///   `"Android 14 (SDK 34)"`
/// 这里用正则把 SDK 号抠出来。取不到就返回 0，调用方按「老设备」处理。
int get androidSdkVersion {
  if (!Platform.isAndroid) return 0;
  final s = Platform.operatingSystemVersion;
  final m = RegExp(r'SDK\s+(\d+)').firstMatch(s);
  if (m != null) return int.tryParse(m.group(1)!) ?? 0;
  // 有些 ROM 只给 "Android 14"
  final m2 = RegExp(r'Android\s+(\d+)').firstMatch(s);
  if (m2 != null) {
    // Android 版本 → 粗略对应 SDK（只在拿不到 SDK 号时兜底）
    const map = {
      9: 28, 10: 29, 11: 30, 12: 31, 13: 33, 14: 34, 15: 35, 16: 36,
    };
    return map[int.tryParse(m2.group(1)!)] ?? 0;
  }
  return 0;
}

/// 是否按「计费网络」（移动数据）处理 → 决定缓存策略。
///
/// 无法零依赖读到 `isActiveNetworkMetered`，所以默认规则是：
/// **未知即视为计费**（保守，避免用户流量被吃光 / 低端机 OOM）。
/// 可通过 `KCHAN_UNMETERED=1` 强制关掉（排查用）。
bool get isMeteredNetwork {
  if (!Platform.isAndroid) return false;
  final env = Platform.environment['KCHAN_UNMETERED'];
  if (env == '1' || env == 'true') return false;
  return true;
}

/// 视频输出渲染器（对齐 Kazumi `androidVideoRenderer == 'auto'` 的逻辑）
///
/// - Android 14（SDK 34）及以上 → `gpu-next`（基于 Vulkan，着色器性能更好）
/// - 更低版本 → `gpu`（基于 OpenGL，兼容性更稳；避免老机型 Vulkan 支持不佳黑屏）
String get androidVideoRenderer {
  if (!Platform.isAndroid) return 'gpu';
  return androidSdkVersion >= 34 ? 'gpu-next' : 'gpu';
}

/// 缓存字节数（对齐 Kazumi `PlaybackCachePolicy`）
///
/// Windows 桌面端由原先的 1500MB 限为 64MB，避免切线时多实例
/// 前向 + 后向缓存同时占用大量内存；Android 保持原参数不变。
int get playerBufferBytes {
  if (!Platform.isAndroid) return 64 * 1024 * 1024;
  return isMeteredNetwork ? 2 * 1024 * 1024 : 1500 * 1024 * 1024;
}

/// 桌面后向缓存只需保留短距离回退容量；Android 保持旧值。
int get playerBackBufferBytes =>
    Platform.isAndroid ? playerBufferBytes : 8 * 1024 * 1024;

/// 供日志用的一段环境摘要
String describeAndroidEnv() {
  if (!Platform.isAndroid) {
    return 'desktop (buffer=${playerBufferBytes ~/ (1024 * 1024)}MB)';
  }
  return 'Android SDK=${androidSdkVersion} '
      'vo=$androidVideoRenderer '
      'metered=$isMeteredNetwork '
      'buffer=${playerBufferBytes ~/ (1024 * 1024)}MB';
}
