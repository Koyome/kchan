# 第三方组件与出处说明

本项目的许可证为 **MIT**（见 [LICENSE](LICENSE)）。
下面逐项说明所用第三方组件的来源与许可证 —— 所有许可证均**通过 GitHub API 实际查询确认**，
不是凭印象填写的。

---

## 一、打包进仓库的内容

### KazumiRules — 内置规则库

| 项目 | 说明 |
| --- | --- |
| 来源 | <https://github.com/Predidit/KazumiRules> |
| 许可证 | **MIT** |
| 用在哪里 | `assets/rules/kazumi_rules.json`（86 条线路规则） |

这是本项目唯一**整份复制**进仓库的第三方内容。MIT 允许再分发，
本文件即为保留的出处声明。

### 字体

| 文件 | 说明 |
| --- | --- |
| `assets/fonts/sans-*.ttf`、`serif-*.ttf` | 思源黑体 / 思源宋体（Source Han Sans / Serif）衍生版本，SIL Open Font License 1.1 |

OFL-1.1 允许随软件分发，保留本声明即可。

---

## 二、实现上参考 / 移植的项目

### media_kit — 全屏实现移植

| 项目 | 说明 |
| --- | --- |
| 来源 | <https://github.com/media-kit/media-kit> |
| 作者 | Hitesh Kumar Saini |
| 许可证 | **MIT** |
| 用在哪里 | `lib/api/window_ctl.dart` 的窗口全屏逻辑 |

**具体说明**：该文件的全屏做法（保存 `GetWindowPlacement().rcNormalPosition`、
清除 `WS_CAPTION∣WS_BORDER∣WS_THICKFRAME`、`SetWindowPos` 配合 `SWP_FRAMECHANGED`、
退出时还原）是照着 media_kit 的
`windows/runner/fullscreen_utils.cpp` 逐条对应的。

之所以用 **Dart FFI 重新实现**而不是直接调用它：本项目开发机的 MinGW 工具链损坏，
无法重新链接 `kchan.exe`，因此**无法修改任何 C++ 代码**，所有 Windows 原生能力
只能走 FFI。

MIT 允许此用法，此处保留出处与作者署名。

### Kazumi — 玩法与规则格式对标

| 项目 | 说明 |
| --- | --- |
| 来源 | <https://github.com/Predidit/Kazumi> |
| 许可证 | **GPL-3.0** |
| 用在哪里 | 规则 JSON 格式、播放器交互约定、移动端播放参数 |

**重要说明**：本项目**没有复制 Kazumi 的源代码**。
实际借鉴的是：

1. **规则文件格式**（`xpath` / `api` 两种 mode、`useWebView`、`useLegacyParser` 等字段）
   —— 格式本身是对接 KazumiRules 所必需的，而 KazumiRules 是 MIT；
2. **播放器参数选择**（Android 用 `hwdec=mediacodec`、`vo` 按 SDK 版本取 `gpu-next`/`gpu`、
   缓存按流量类型取 2MB/1500MB、`ao=audiotrack`、`af=scaletempo2`）——
   这些是 libmpv 的公开配置项；
3. **交互约定**（快捷键位、多线路聚合与跨源自动切换、选集面板结构）。

Kazumi 应用本身是 GPL-3.0。本项目与其**没有代码级的派生关系**，
因此以 MIT 发布。如果你认为上述边界需要更保守的处理
（例如完全不参考其交互约定），请提 issue。

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

> ⚠️ **分发预编译包时请注意**：libmpv 与 FFmpeg 的许可证取决于其编译选项
> （是否启用 GPL 组件）。若要以 MIT 分发**源码**没有问题；
> 但**分发二进制包**时，mpv/FFmpeg 的许可条款仍然适用，
> 建议在发行包内一并附上它们的许可证文本与源码获取方式。

---

## 五、内容免责

本项目**不提供、不存储、不代理任何视频内容**，只按用户配置的规则
聚合第三方站点的公开播放地址。所有媒体内容的版权归各自权利人所有。
本项目仅供个人学习与技术交流使用。
