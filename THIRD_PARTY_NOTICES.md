# 第三方组件与出处说明

K酱采用 [MIT 许可证](LICENSE)。以下是第三方组件的出处、许可和用途。

---

## 一、打包进仓库的内容

### KazumiRules — 内置规则库

| 项目 | 说明 |
| --- | --- |
| 来源 | <https://github.com/Predidit/KazumiRules> |
| 许可证 | **MIT** |
| 用在哪里 | `assets/rules/kazumi_rules.json`（86 条线路规则） |

### 字体

| 文件 | 说明 |
| --- | --- |
| `assets/fonts/sans-*.ttf`、`serif-*.ttf` | 思源黑体 / 思源宋体（Source Han Sans / Serif）衍生版本，SIL Open Font License 1.1 |

---

## 二、实现上参考 / 移植的项目

### media_kit — 全屏实现移植

| 项目 | 说明 |
| --- | --- |
| 来源 | <https://github.com/media-kit/media-kit> |
| 作者 | Hitesh Kumar Saini |
| 许可证 | **MIT** |
| 用在哪里 | `lib/api/window_ctl.dart` 的窗口全屏逻辑 |

全屏逻辑参考 media_kit 的 `windows/runner/fullscreen_utils.cpp`，用 Dart FFI 实现。进入全屏时保存窗口位置、调整样式并刷新边框，退出时还原。

### Kazumi — 规则格式与播放器交互

| 项目 | 说明 |
| --- | --- |
| 来源 | <https://github.com/Predidit/Kazumi> |
| 许可证 | **GPL-3.0** |
| 用在哪里 | 规则 JSON 格式、播放器交互约定、移动端播放参数 |

K酱自行实现播放逻辑，参考了 Kazumi 的规则格式、快捷键、线路切换和选集交互。Android 播放使用 libmpv 的公开配置项，包括硬解、视频输出、音频输出和变速参数。

---

## 三、通过 pub 依赖引入（不在仓库内，由 pub 解析）

| 包 | 许可证 | 用途 |
| --- | --- | --- |
| `media_kit` / `media_kit_video` | MIT | 播放内核（libmpv 绑定） |
| `fvp` | BSD-3-Clause | 备用播放内核（libmdk 绑定） |
| `video_player` | BSD-3-Clause | fvp 的接口层 |
| `cached_network_image` | MIT | 封面缓存 |
| `webview_flutter` | BSD-3-Clause | 云播地址解析 |
| `http` / `shared_preferences` / `path_provider` | BSD-3-Clause | 基础设施 |
| `html` | BSD-3-Clause | HTML 解析（XPath 规则） |
| `web_socket_channel` | BSD-3-Clause | Edge CDP 调试通道 |
| `crypto` | BSD-3-Clause | 弹幕接口签名 |
| `ffi` | BSD-2-Clause | FFI 内存分配辅助 |
| `flutter` / `flutter_localizations` | BSD-3-Clause | 框架 |

---

## 四、运行期动态库（随发行包分发，不在源码仓库）

| 库 | 许可证 | 说明 |
| --- | --- | --- |
| **libmpv** / mpv | LGPL-2.1+（启用 GPL 组件时为 GPL-2.0+） | 主播放内核 |
| **libmdk**（mdk.dll 等） | MIT | fvp 的后端 |
| **FFmpeg**（ffmpeg-9.dll） | LGPL-2.1+ / GPL-2.0+ | 编解码 |
| **libass** | ISC | 字幕渲染 |
| **Flutter engine**（flutter_windows.dll） | BSD-3-Clause | 运行时 |

libmpv 和 FFmpeg 的许可取决于编译选项。分发二进制时，请查看对应构建的许可条款，并按要求提供许可文本和源码获取方式。

---

## 五、内容免责

本项目**不提供、不存储、不代理任何视频内容**，只按用户配置的规则
聚合第三方站点的公开播放地址。所有媒体内容的版权归各自权利人所有。
本项目仅供个人学习与技术交流使用。
