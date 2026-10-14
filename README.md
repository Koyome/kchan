# Kchan · 追番客户端

> 轻量的番剧聚合播放器：浏览每日放送与热门榜、搜索番剧、
> 聚合多个第三方站点的公开播放地址、本地播放（倍速 / 选线路 / 选集 / 弹幕 / 全屏）。
>
> 元数据来自 [Bangumi 番组计划](https://bgm.tv)，
> 播放规则对齐 [KazumiRules](https://github.com/Predidit/KazumiRules)，
> **所有记录只保存在本机**。

**当前版本：v1.9.9** ｜ Windows + Android ｜ Flutter

---

## 功能

- **番剧浏览** — 每日放送（按星期）、热门榜、搜索、追番、历史
- **多线路聚合** — 86 条规则；按真实网络体检选出可用线路，
  「快车道」先跑最快的 3 条并立即上屏，其余后台补充
- **跨源自动切换** — 当前源解析失败/播放出错时自动换下一条，全部试完才报错
- **本地播放** — media_kit(libmpv) 为主，fvp(libmdk) 运行期兜底；
  倍速、画面比例、锁屏、静音、快捷键
- **全屏** — 真·无边框铺满、盖住任务栏，退出精确还原窗口
- **弹幕** — 弹弹play 弹幕接入（SHA-256 签名）
- **图片反代** — 支持填多个代理地址，按顺序自动降级 + 独立熔断
- **看门狗** — 检测视频输出掉帧（有声音没画面）并自动恢复

---

## 快速开始（开发者）

### 环境

| 依赖 | 版本 |
| --- | --- |
| Flutter | 3.47.x（stable） |
| Dart SDK | `^3.9.0` |

### 运行

```bash
flutter pub get
flutter run -d windows     # 或 -d android
```

### 构建

```bash
# Windows
flutter build windows --release

# Android
flutter build apk --release
```

> ⚠️ **Windows 构建注意**：`media_kit` 与 `fvp` 需要各自的原生运行库
> （`libmpv-2.dll`、`mdk.dll`、`fvp.dll` 等）。`flutter build windows` 会自动
> 从 pub 包拷贝，请勿手动删改 `windows/` 下的 CMake 配置。

---

## 项目结构

```
lib/
├── main.dart                    启动流程（首帧即刻可见，规则加载异步补齐）
├── theme.dart                   配色与版本号
├── models.dart                  数据模型
├── api/
│   ├── bangumi_api.dart         Bangumi 元数据 + 图片反代候选链
│   ├── kazumi_rules.dart        规则引擎（解析 86 条线路规则）
│   ├── xpath_lite.dart          自研轻量 XPath（替代 DOM→XML 往返）
│   ├── jsonpath_lite.dart       受限 JSONPath
│   ├── play_resolver.dart       地址解析 + 注入广告扫描
│   ├── edge_cdp_resolver.dart   Windows 侧无头 Edge + CDP 解析
│   ├── android_webview_resolver.dart  Android 侧 WebView 解析
│   ├── player_backend.dart      播放后端抽象（media_kit / fvp）
│   ├── window_ctl.dart          Windows 全屏与窗口控制（纯 Dart FFI）
│   ├── system_proxy.dart        读取系统代理（dart:ffi）
│   ├── source_groups.dart       线路分类与实测状态
│   └── danmaku_api.dart         弹幕接口
├── pages/                       首页 / 热门 / 搜索 / 详情 / 播放 / 设置 / 追番 / 历史
├── store/local_store.dart       本地持久化
└── widgets/                     通用组件（封面、弹幕层）
```

### 几个值得说明的设计

**`xpath_lite.dart`** — 规则里的 XPath 原本用 `html` 包解析成 DOM 再转 XML 往返，
实测解析一次 109ms。换成自研的轻量引擎后降到 **21.5ms**，
覆盖规则库实际用到的语法子集。

**`window_ctl.dart`** — Windows 全屏完全用 Dart FFI 实现，没有改任何 C++。
关键顺序是「**先改尺寸 → 再清样式位 → 最后 `SWP_FRAMECHANGED`**」；
把三者塞进同一个 `SetWindowPos` 会导致视频 surface 失配（画面区透明）。

**启动流程** — 规则库加载（86 条，约 2–12ms）放在首帧回调里而不是 `main()` 里，
保证窗口第一时间出现，且设置页/详情页读线路列表时规则已就绪。

**看门狗** — 每 3 秒读 mpv 的 `estimated-vf-fps`：输出健康时是实际帧率，
掉链时是 `0`。连续 2 次为 0 判定为黑屏，先尝试轻刷输出，
无效则重建播放器并回到原进度。

---

## 命令行自检工具

`tool/` 下是开发期用的验证脚本（纯 Dart，可 `dart run` 直接执行）：

```bash
# 规则解析自检（不联网）—— 59 个用例
dart run tool/rules_selftest.dart

# 真实抓包验证规则（联网）—— 18 个用例
dart run tool/verify_rules_real.dart

# 线路体检：逐条测可用性、耗时、线路数，输出 JSON
dart run tool/probe_sources.dart --json source_health.json

# 封面反代可用性探测
dart run tool/probe_covers.dart

# 解析链真机验证（用真实 Parser + Resolver）
dart run tool/verify_playback.dart
```

---

## 诊断

诊断日志：`%TEMP%\kchan_diag.log`（运行期实时写入，可边跑边看）

| 日志行 | 含义 |
| --- | --- |
| `[启动] 规则库就绪：86 条（Nms）` | 规则加载完成，正常应在 50ms 内 |
| `[聚合] 共 6 条线路：快车道 3 条 …` | 本次聚合的线路分组 |
| `[源搜索] <源> kw="…" 命中 N 条 Nms` | 某线路的搜索耗时与命中数 |
| `[播放] <源> 解析成功 <url>` | 拿到播放地址 |
| `[播放] 预检 通过` | 起播前连通性检查通过 |
| `[封面] 命中 N/M（Nms）` | 封面候选链第 N 个命中 |
| `[看门狗] 心跳 #N: position=Ns fps=X` | 视频输出健康度 |
| `[窗口] 全屏后: … DWM边框(L0 T0 R0 B0)` | 四边为 0 表示无边框全屏 |

### 环境变量开关

| 变量 | 作用 |
| --- | --- |
| `KCHAN_LOG_NAME` | 指定诊断日志文件名（多实例/自动化排查用） |
| `KCHAN_FS_STRIP=0` | 全屏时**不**清除标题栏样式位（逃生开关） |
| `KCHAN_FORCE_FVP=1` | 强制使用 fvp 后端（区分渲染问题与后端问题） |
| `KCHAN_E2E_SUBJECT=<id>` | 启动后直接打开该番剧详情并自动播放 |
| `KCHAN_E2E_PAGE=<page>` | 启动后直接打开指定页面（home/popular/search/settings） |
| `KCHAN_E2E_FULLSCREEN=roundtrip` | 启动后自动做一次全屏往返并记录几何 |

---

## 免责声明

- 本项目**不提供、不存储、不代理任何视频内容**，只按用户配置的规则
  聚合第三方站点的**公开**播放地址；可用性取决于那些站点本身。
- 所有媒体内容的版权归各自权利人所有。
- 本项目仅供**个人学习与技术交流**使用，请勿用于商业用途。
- 收藏 / 进度 / 历史 / 设置全部保存在本机，不收集任何个人信息。

---

## 致谢

- [KazumiRules](https://github.com/Predidit/KazumiRules)（MIT）— 内置规则库
- [Kazumi](https://github.com/Predidit/Kazumi)（GPL-3.0）— 同领域的优秀项目，
  本项目的规则格式与交互约定对标它
- [media_kit](https://github.com/media-kit/media-kit)（MIT）— 播放内核；
  全屏实现参考其 `fullscreen_utils.cpp`
- [fvp](https://github.com/wang-bin/fvp)（BSD-3-Clause）— 备用播放后端
- [Bangumi 番组计划](https://bgm.tv) — 元数据

详细出处与许可证见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

---

## 许可证

[MIT](LICENSE) © 2026 Koyome
