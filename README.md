# K酱

K酱是用 Flutter 开发的追番播放器。番剧资料来自 [Bangumi 番组计划](https://bgm.tv)，播放线路使用 [KazumiRules](https://github.com/Predidit/KazumiRules) 格式的规则。

## 下载

| 平台 | 当前版本 | 安装方式 |
| --- | --- | --- |
| Android | v2.3.2 b47 | [ARM64 精简包](https://dl.kchan.top/Kchan-Android-v2.3.2-b47-arm64-v8a.apk) · [通用 APK](https://dl.kchan.top/Kchan-Android-v2.3.2-b47-mobile-parity.apk) |
| iOS / iPadOS | v2.3.2 b59 | 下载 [IPA](https://dl.kchan.top/Kchan-iOS-v2.3.2-b59_no_sign.ipa) 后，按 [官网教程](https://kchan.top/ios-guide/) 自签安装 |
| Windows | v2.3.2 | 下载 [ZIP](https://dl.kchan.top/Kchan-Windows-v2.3.2.zip)，解压后运行 `kchan.exe` |

[官网](https://kchan.top/) · [历史版本和更新日志](https://github.com/Koyome/kchan/releases)

## 功能

- 查看放送表、热门番剧和 Bangumi 评分，按名称或标签搜索番剧。
- 支持多线路播放、选集、倍速、弹幕和全屏。解析失败时可尝试其他线路。
- 管理追番和观看记录。Android 登录后可同步追番与观看进度。
- Windows 支持快捷键和无边框全屏。

## 开发

环境为 Flutter 3.47.x、Dart SDK `^3.9.0`。本仓库的默认分支包含 Android 和 Windows 源码。

```bash
flutter pub get
flutter run -d windows
flutter build windows --release
flutter build apk --release
```

调试 Android 时，连接设备后用 `flutter devices` 查看设备 ID，再传给 `flutter run -d`。Windows 构建所需的 `libmpv-2.dll`、`mdk.dll` 和 `fvp.dll` 由插件打包。

| 路径 | 内容 |
| --- | --- |
| `lib/pages/`、`lib/widgets/` | 页面和通用组件 |
| `lib/api/bangumi_api.dart` | Bangumi 数据与封面请求 |
| `lib/api/kazumi_rules.dart` | 线路规则与 XPath、JSONPath 解析 |
| `lib/api/play_resolver.dart` | 播放地址解析与广告过滤 |
| `lib/api/player_backend.dart` | 播放后端，依赖 media_kit 和 fvp |
| `lib/api/window_ctl.dart` | Windows 窗口与全屏 |
| `lib/store/local_store.dart` | 本地存储 |

### 自检

| 命令 | 用途 |
| --- | --- |
| `dart run tool/rules_selftest.dart` | 离线规则解析测试 |
| `dart run tool/verify_rules_real.dart` | 用线路响应验证规则 |
| `dart run tool/probe_sources.dart --json source_health.json` | 测试线路可用性并导出结果 |
| `dart run tool/verify_rule_update.dart` | 检查规则在线更新 |
| `dart run tool/probe_newanime.dart` | 用当季番剧测试搜索和分集 |
| `dart run tool/verify_follow_updates.dart` | 检查追番更新 |
| `dart run tool/probe_covers.dart` | 检查封面代理 |
| `dart run tool/verify_playback.dart` | 检查播放地址解析 |

Windows 诊断日志位于 `%TEMP%\kchan_diag.log`，可按 `[源搜索]`、`[规则更新]`、`[播放]` 或 `[窗口]` 查找相关记录。

| 环境变量 | 用途 |
| --- | --- |
| `KCHAN_LOG_NAME` | 指定日志文件名 |
| `KCHAN_FS_STRIP=0` | 全屏时保留标题栏样式位，排查视频渲染问题 |
| `KCHAN_FORCE_FVP=1` | 强制使用 fvp 后端 |
| `KCHAN_E2E_SUBJECT` | 启动时打开指定 Bangumi 条目并播放 |
| `KCHAN_E2E_PAGE` | 启动时打开指定页面 |
| `KCHAN_E2E_FULLSCREEN=roundtrip` | 自动执行一次全屏往返并记录窗口状态 |

## 内容与许可

K酱根据规则读取第三方站点的公开播放地址，不提供、存储或代理视频。媒体版权归各自权利人所有。项目供个人学习与技术交流使用，请勿用于商业用途。

项目采用 [MIT 许可证](LICENSE)，第三方组件和出处见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

感谢 [Bangumi](https://bgm.tv)、[Kazumi](https://github.com/Predidit/Kazumi)、[KazumiRules](https://github.com/Predidit/KazumiRules)、[弹弹play](https://www.dandanplay.com/)、[media_kit](https://github.com/media-kit/media-kit) 和 [fvp](https://github.com/wang-bin/fvp)。
