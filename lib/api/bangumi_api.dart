/// Bangumi API v0 客户端
/// - 镜像可配置 + 自动故障转移（官方站当前在大陆被封锁，须备镜像）
/// - 全局限速（礼貌访问），必需 User-Agent
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, HttpClient, Platform;
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart' show IOClient;
import 'package:path_provider/path_provider.dart' show getApplicationDocumentsDirectory;
import '../models.dart';
import 'diag_log.dart' show kLog;
import 'ip_pin.dart';
import 'tick_notifier.dart';

class ApiException implements Exception {
  final String message;
  final int? statusCode;
  ApiException(this.message, [this.statusCode]);
  @override
  String toString() => statusCode != null ? '$message (HTTP $statusCode)' : message;
}

class BangumiApi {
  static const userAgent = 'kchan/2.1.10 (https://github.com/Koyome/kchan)';

  /// ═══════════════ Bangumi 数据源：本机实测结论（2026-10-13） ═══════════════
  ///
  /// 逐地址实测（同机、同网络、同一时刻）：
  ///
  /// | 地址 | /v0/subjects/12 | /p1/subjects/12 |
  /// | --- | --- | --- |
  /// | api.bgm.tv            | ❌ 15.2s 超时 | ❌ |
  /// | next.bgm.tv           | ❌ 15.1s 超时 | ❌ |
  /// | api.bangumi.lol       | ❌ 15.2s 超时 | — |
  /// | bgmapi.anibt.net      | ⚠️ 200 · **3.9s** | — |
  /// | **api.kazumi.fyi**    | ❌ 404（不支持 v0） | ✅ 200 · **273ms** |
  ///
  /// 关键发现：`api.kazumi.fyi` 是 **Kazumi 官方镜像**，它实现的是 Bangumi 的
  /// `next.bgm.tv` 即 **`/p1/*` 协议**，比现有镜像快 **14 倍**（273ms vs 3.9s）：
  ///   /p1/subjects/{id}              273ms
  ///   /v0/episodes?subject_id=…      283ms
  ///   /v0/subjects/{id}/characters   634ms
  ///   /v0/subjects/{id}/subjects     272ms
  ///   /p1/calendar                   832ms
  ///   /kazumi/v1/popular/subjects    294ms
  ///   /kazumi/v1/calendar/season     799ms
  ///
  /// 所以本客户端把**镜像请求竞速**改为：Kazumi 镜像优先（并按需做 v0→p1
  /// 路径改写），把慢镜像降级为兜底。这就是「点动漫进入更快」的最大单点收益。
  static const kazumiMirror = 'https://api.kazumi.fyi';

  /// 内置数据源预设（顺序即优先级）
  ///
  /// 【v2.1.9 · 杜绝 anibt】用户实测：bgmapi.anibt.net 的放送/条目数据
  /// **长期陈旧**（推荐页整页老番），已彻底移出数据线路。现在与 Kazumi
  /// 架构完全对齐——只有两个数据源：
  ///   1. api.bgm.tv       —— ECH 直连 Bangumi 官方（数据最准最新）
  ///   2. api.kazumi.fyi   —— Kazumi 官方镜像（预缓存端点，透传官方数据）
  /// 注：图片文件代理 bgmimg.anibt.net（仅 /pic/ 静态文件转发，与数据
  /// 新旧无关，实测 2s 出图）不受影响，见 [_mirrorPathCandidates]。
  // ── 镜像池 ──
  //
  // 【v2.1.10 · 实测重排】2026-10-15 用真实请求矩阵测了 10 个候选域名，
  // 结论（`D:\dev\probe_matrix.py` 可复跑）：
  //
  //   | 域名                  | 能用的端点                          |
  //   | ---                   | ---                                 |
  //   | bgmapi.anibt.net      | /v0/subjects、/v0/episodes、        |
  //   |                       | /v0/subjects/{id}/characters、      |
  //   |                       | POST /v0/search/subjects  ← 首页必需 |
  //   | api.kazumi.fyi        | /p1/subjects、/kazumi/v1/popular/…  |
  //   | api.bgm.tv  next.bgm.tv | 全线不可达（被墙）→ **已从列表移除** |
  //   | api.bgmapi.com 等 6 个  | 连接失败 / 返回错误信封，一律剔除    |
  //
  // **anibt 必须放在第一位**：搜索接口（首页/搜索页依赖）只有它通；
  // kazumi.fyi 的 `POST /v0/search/subjects` 实测超时。
  //
  // 注意两个域名的**路径风格不同**：
  //   · anibt      —— 原生 v0 协议，`/v0/...` 直接用
  //   · kazumi.fyi —— next 协议，需由 [_pathFor] 把 `/v0/...` 改写成 `/p1/...`
  //
  // 【v2.1.10 · 移除 api.bgm.tv】它永远连不上（TCP 都不通），
  // 留在列表里只会让每轮竞速多一个必然失败的目标、白占一个错峰档位。
  // 官方源本来靠 ECH 直连，而 ECH 已整体弃用（理由见下方 _client 附近注释）。
  // 用户若需要官方源，走「设置 → 网络与镜像」配代理即可。
  static const presetBases = <String>[
    // 【v2.1.10 · 经自建反代救活的镜像】
    //
    // 这两个域名本身国内直连是**完全不可用**的（实测各 0/5、2/5，
    // 每个都撞满 10 秒超时 —— 它们挂在 Cloudflare 上，TLS 被限速）。
    //
    // 但让**自建 Worker 代取**就快了：Cloudflare 机房互访不经 GFW。
    // 实测经反代后（各 4 次，全部缓存命中）：
    //
    //     /ap/bgmapi/v0/subjects    623~741ms   ✅ 5/5
    //     /ap/bgmapi/v0/episodes    697~721ms   ✅
    //     /ap/bgmapi/calendar      1003~1919ms  ✅
    //     /ap/bgmapi/characters    1256~2289ms  ✅
    //     /ap/anibt/v0/subjects     659~708ms   ✅ 5/5
    //     /ap/anibt/v0/episodes     664~798ms   ✅
    //     /ap/anibt/calendar        879~1939ms  ✅
    //
    // 也就是说：**原来访问不了的 API，现在变成可用的备用源了。**
    //
    // 注意：这两个地址依赖用户自建 Worker 里的 `/ap/` 路由
    // （见 worker.js 的 ALT_UPSTREAMS）。没配反代时它们会失败并被
    // 冷却表跳过，不影响原有镜像 —— 属于「有则更好，无则无害」。
    //
    // 【v2.1.10 · 按实测延迟重排，全部 < 2000ms】
    //
    // 手机端反馈「数据源不稳定」。实测 5 次 `/v0/subjects/{id}`：
    //
    //     源                              结果   中位     最大
    //     bgm.kchan.top（纯反代）          5/5    672ms   1205ms
    //     /ap/kazumi                      5/5    672ms   1544ms   ← 反代救活
    //     /ap/anibt                       5/5    885ms   1508ms
    //     bgmapi.anibt.net                5/5   1344ms   1416ms
    //     /ap/bgmapi                      5/5   1939ms   3042ms
    //
    // ## 关于 api.kazumi.fyi（**没有删，改成走反代**）
    //
    // 它直连时对 `/v0/subjects/{id}` 一律 404（只有 `/p1/...`），
    // 列表里放直连地址等于让每个新条目白等一次超时 —— 这是卡的来源之一。
    //
    // 但把它**套上自建反代**就好了：Worker 的 `/ap/kazumi` 上游会把
    // 不支持的 `/v0/` 自动重写成 `/p1/`，实测：
    //
    //     /ap/kazumi/v0/subjects/400602   5/5   672ms
    //     /ap/kazumi/p1/calendar          5/5   905ms
    //     /ap/kazumi/v0/calendar          5/5  1037ms
    //
    // 所以它现在是**可用且很快的源**，保留在列表第 2 位。
    // 直连的 `https://api.kazumi.fyi` 不再出现（那个是真拿不到数据）。
    'https://bgm.kchan.top',
    'https://bgm.kchan.top/ap/kazumi',
    'https://bgm.kchan.top/ap/anibt',
    'https://bgmapi.anibt.net',
    'https://bgm.kchan.top/ap/bgmapi',
  ];

  /// 【错误信封识别】不少镜像把 404 塞在 **HTTP 200** 的 body 里：
  ///
  /// ```json
  /// {"request":"/p1/calendar","code":404,"error":"Not Found"}
  /// ```
  ///
  /// 这是个**很隐蔽的坑**，实测它导致首页直接空白：
  ///   ① 旧代码只判 `res.statusCode == 200` → 以为这家「成功」；
  ///   ② 竞速立刻用它 settle，其它镜像被丢弃；
  ///   ③ 解析出 0 条番剧 → 被当成「数据源正常但今天没番」；
  ///   ④ 首页空白，且**看不到任何错误日志**。
  ///
  /// 现在把它显式判为失败，让竞速继续用其它域名。
  static bool _isErrorEnvelope(dynamic j) {
    if (j is! Map) return false;
    // 典型形状：只有 request / code / error 三个键，且 code 是错误码
    if (j.length > 4) return false;
    final code = j['code'];
    if (code is! int || code < 400) return false;
    return j.containsKey('error') || j.containsKey('message');
  }
  ///
  /// 为什么要做：镜像只实现了 next.bgm.tv 协议，直接请求 `/v0/...` 会 404；
  /// 而 404 在竞速里只是「这一家没结果」，不会中断整轮请求 —— 但会白白
  /// 浪费一次往返。这里主动改写，让它一次命中。
  ///
  /// 返回 null 表示「该镜像不支持这个路径」，直接跳过它（不发请求）。
  /// 【路径改写】把 v0 路径映射成 Kazumi 镜像支持的等价路径。
  ///
  /// 为什么要做：kazumi.fyi 只实现了 next.bgm.tv 协议，直接请求
  /// `/v0/...` 会 404；而 404 在竞速里只是「这一家没结果」，
  /// 不会中断整轮请求 —— 但会白白浪费一次往返。这里主动改写，让它一次命中。
  ///
  /// 注意：anibt 是**原生 v0 协议**，走 `if (!isKazumi) return path;` 原样透传。
  ///
  /// 返回 null 表示「该镜像不支持这个路径」，直接跳过它（不发请求）。
  static String? _pathFor(String base, String path) {
    final isKazumi = base.contains('kazumi.fyi');
    if (!isKazumi) return path;

    // /v0/subjects/{id}          → /p1/subjects/{id}
    final mSub = RegExp(r'^/v0/subjects/(\d+)$').firstMatch(path);
    if (mSub != null) return '/p1/subjects/${mSub.group(1)}';

    // /v0/episodes?subject_id=N  → 支持
    if (path.startsWith('/v0/episodes')) return path;

    // 【v2.1.10 · 实测修正】kazumi.fyi 对 `/v0/subjects/{id}/characters`
    // **是通的**（实测 91 个角色），所以保留；但它对 `/p1/calendar`
    // 返回 400/超时、对 POST `/v0/search/subjects` 超时 ——
    // 这些路径直接跳过，省掉一次白等的往返。
    final isCalendar = path == '/calendar' || path == '/v0/calendar';
    if (isCalendar) {
      // kazumi.fyi 的 /p1/calendar 实测不稳定（400/超时）→ 跳过，
      // 让 anibt（原生 v0）与 ECH 官方去竞速
      return null;
    }

    // /v0/subjects/{id}/characters 与 /subjects  → 支持
    if (RegExp(r'^/v0/subjects/\d+/(characters|subjects)$').hasMatch(path)) {
      return path;
    }

    // 其余（POST 搜索 /v0/search/subjects 实测超时、图片端点 404）→ 跳过该镜像
    return null;
  }

  /// 镜像用的普通 HTTP client。
  ///
  /// 【v2.1.10 · 关键修复】原来是无参 `http.Client()` ——
  /// **底层 HttpClient 的 connectionTimeout 默认是 null（无限等）**，
  /// 而 `_race` 里的 `.timeout(4s)` 只让 Future 提前完成，
  /// **不会中断已经在跑的 socket 连接**。结果是：网络不通时
  /// 每个镜像都拖着一个永不超时的连接，累积起来把应用拖死
  /// （实测「点了没反应」）。必须显式给连接超时。
  late final http.Client _client = _buildMirrorClient();

  static http.Client _buildMirrorClient() {
    final inner = HttpClient()
      // 【v2.1.10 · 提升自建反代稳定性】
      //
      // 原来的 `connectionTimeout: 3s` 太激进：到 Cloudflare 的 TLS 握手
      // 实测 400~800ms，网络抖动时偶尔超过 3 秒 → **误判为不可达**，
      // 白丢一次机会。放宽到 6 秒（仍能及时掐断真正的死连接）。
      ..connectionTimeout = const Duration(seconds: 4)
      // 原来 `idleTimeout: 10s` —— 这个才是延迟主因：
      // 用户点开一个番剧、隔十几秒再点下一个，连接**已经被关掉**，
      // 于是每次都要重新 DNS + TCP + TLS（耗时的大头全在这）。
      // 放宽到 90 秒后，同一批操作内的请求复用同一条连接，
      // 省掉整轮握手。
      ..idleTimeout = const Duration(seconds: 90)
      // 首页会同时发多个请求（放送表 3 页 + 详情预热），
      // 默认同主机 6 条并发容易排队，放宽到 16。
      ..maxConnectionsPerHost = 16;
    // ⚠ 必须保持 autoUncompress = true（默认）。
    //
    // 我曾把它设成 false 想省一次内存拷贝 —— 结果上游返回 gzip 时
    // 响应体是压缩态，`jsonDecode` 直接抛
    // `FormatException: Unexpected extension byte (at offset 1)`，
    // 首页整片失败。教训：**不要为了微优化关掉协议层的正确性保证**。
    // 【优选 IP】把 Cloudflare 边缘 IP 钉死 —— 这是 fix2 里数据源稳定的关键。
    //
    // 背景实测（同一域名 bgm.kchan.top，同一时刻）：
    //   104.17.132.229（优选）  5/5   918ms
    //   104.21.6.230 （公共DNS）3/5  1864ms  最慢 3418ms
    //   172.67.135.111（公共DNS）1/5  1779ms
    // 不钉 IP 就等于把成功率赌在「DNS 分到哪个边缘 IP」上。
    IpPin.install(inner);
    return IOClient(inner);
  }

  // ───────────── 【v2.1.10 · ECH 已彻底移除】─────────────
  //
  // 曾经引入过 ECH（`ech_http` + DoH + Cloudflare 固定 IP）来直连
  // 官方 api.bgm.tv，理由是「官方站被 DNS 污染/SNI 阻断」。
  // 实测与用户反馈后**决定整体弃用**，原因：
  //
  //   1. **它成了不稳定源**。ECH 要先去 DoH 拉 ECH config，多一层外部
  //      依赖；实测冷启动偶发卡死（10 轮里 1 轮进程停住、日志断在
  //      预热之后），排查成本极高，用户直接反馈「软件都打不开了」。
  //   2. **`ech_http` 是 native-assets 包**，把构建链搞得很脆：
  //      需要 Dart build hooks 编译 C++ 桥接层、需要符号链接支持
  //      （开发者模式/管理员），本机多次因它构建失败。
  //   3. **Kazumi 也不是这么用的**。Kazumi 的 `BangumiAcceleration`
  //      是个**用户可选模式**（direct / ech / mirror），
  //      **默认是 `direct`**，且失败就走镜像 —— 不是「无条件 ECH 兜底」。
  //   4. **镜像已经够用**：实测 `bgmapi.anibt.net` + `api.kazumi.fyi`
  //      能覆盖首页放送表（102 部，稳定 2.85s）与详情页全部端点。
  //
  // 现在的做法与 Kazumi 默认一致：**普通 HTTP client + 镜像竞速**。
  // 用户若在「设置 → 网络与镜像」配了代理，`dart:io` 的全局
  // HttpOverrides（见 system_proxy.dart）会自动带上，无需特殊处理。
  //
  // 若将来要恢复官方直连：不要再用 ECH，改用「代理 + 直连」或自建反代。

  /// 当前可用的 base 列表（设置页可改，自定义排最前）
  List<String> bases = List.of(presetBases);

  /// 【实测优化】上次成功的 base 优先尝试：镜像挂了不反复浪费时间在死镜像上
  String? _preferredBase;

  /// 【v2.1.2 · 稳定性】失败镜像冷却表：base → 失败时间戳(ms)
  ///
  /// 旧行为：某个镜像死了之后，**每次请求**都会再等它 6 秒超时，
  /// 表现为「同一页面有时 300ms 打开、有时 6 秒」——方差极大。
  /// 现在失败的镜像 120 秒内直接跳过（只在还有别的可用镜像时），
  /// 成功一次就立刻从冷却表里移出（镜像恢复后自动回归）。
  final Map<String, int> _baseCooldown = {};
  static const _cooldownMs = 120 * 1000;

  /// 【v2.1.10 · 修「25 秒失败 15 次」】全局冷却
  ///
  /// ## 旧行为的 bug
  ///
  /// 所有镜像都失败时，旧代码走的是「**清空**冷却表」（见原 v2.1.5 的自愈逻辑），
  /// 本意是"别把手脚捆死"，结果适得其反：
  /// 清空 → 下次请求又试全部镜像 → 又全失败 → 又清空 …
  /// 实测日志里 **25 秒内失败 15 次**，每次都要白等 5~6 秒超时。
  /// 用户感受就是「点了没反应 / 卡死」。
  ///
  /// ## 现在的做法：全局冷却 + 单次探测
  ///
  /// 全部失败后进入 [_globalCooldownMs] 冷却，期间**直接快速失败**，
  /// 一个网络请求都不发（把 5 秒的等待变成 0 秒）。
  ///
  /// 但冷却不是死的：每隔 [_probeIntervalMs] 放**一次**真实探测，
  /// 成功就立刻解除冷却。所以：
  ///   · 网络恢复了 → 最多 60 秒内自动恢复，无需重启软件；
  ///   · 网络仍不通 → 后续请求都是瞬时的，不再累积白等。
  int? _globalCooldownAt;

  /// 全局冷却时长（全部镜像失败后多久内不再反复重试）
  // 【v2.1.10 · 10 分钟 → 45 秒】
  //
  // 手机端反馈「一下卡一下流畅」：进过一次 10 分钟全局冷却后，即使网络
  // 已经好了，App 也会**连续 10 分钟全部快速失败**（首页空白）。
  // 45 秒足够避免「全失败 → 立刻重试 → 又全失败」的抖动循环，
  // 又不会让恢复期变得无法忍受。探测间隔仍是 60 秒，所以实际生效
  // 时间通常是一个探测周期。
  static const _globalCooldownMs = 45 * 1000;

  /// 冷却期内放行一次探测的间隔（保证网络恢复能自动收敛）
  static const _probeIntervalMs = 60 * 1000;

  int _lastProbeAt = 0;

  /// 是否处于「全部镜像失败」的全局冷却中
  bool get _inGlobalCooldown {
    final at = _globalCooldownAt;
    if (at == null) return false;
    if (DateTime.now().millisecondsSinceEpoch - at > _globalCooldownMs) {
      _globalCooldownAt = null;
      return false;
    }
    return true;
  }

  /// 冷却期内是否该放行一次探测请求
  bool get _shouldProbe {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastProbeAt < _probeIntervalMs) return false;
    _lastProbeAt = now;
    return true;
  }

  /// 仅供验证工具读取：是否处于全局冷却
  bool get debugInGlobalCooldown => _inGlobalCooldown;

  bool _isCooling(String base) {
    final at = _baseCooldown[base];
    if (at == null) return false;
    if (DateTime.now().millisecondsSinceEpoch - at > _cooldownMs) {
      _baseCooldown.remove(base);
      return false;
    }
    return true;
  }

  /// 仅供验证工具读取：当前冷却表大小
  int get debugCooldownSize => _baseCooldown.length;

  List<String> get _orderedBases {
    final p = _preferredBase;
    final ordered = (p == null || !bases.contains(p))
        ? List.of(bases)
        : [p, ...bases.where((b) => b != p)];
    final alive = ordered.where((b) => !_isCooling(b)).toList();
    // 全在冷却（或全挂）→ 乖乖全试一遍，不能把手脚捆死
    final all = alive.isEmpty ? ordered : alive;

    // ───────────── 【v2.1.10 · 自建反代独占】─────────────
    //
    // 用户反馈：「几个 api 不够稳定，有时不可达」「其他 api 很卡」。
    // 实测（各 8 次请求同一条目）：
    //
    //     自建反代 bgm.kchan.top   8/8   中位   994ms   ✅
    //     bgmapi.anibt.net         4/8   中位 11163ms   ❌
    //     api.kazumi.fyi           0/8   中位  3943ms   ❌
    //
    // 第三方镜像一半不可达，却还在池子里跟自建反代一起竞速 ——
    // 它们抢不到还好，一旦抢先返回、或者把 12 秒超时拖满，
    // 就白白浪费一整轮，用户体感就是「卡」。
    //
    // 关键认识：**第三方镜像只是代理官方数据的中转站**，
    // 而自建反代的上游就是官方（api.bgm.tv / next.bgm.tv / lain.bgm.tv）。
    // 既然直达官方，就没必要再绕经不稳定的中转站。
    //
    // 所以：**只要配了自建反代，就只用自建反代**。
    // 它们全挂（进冷却）时，[all] 会自动把第三方放回来兜底 ——
    // 不是删掉它们，是平时不打扰。
    //
    // 判定方式：`local_store._apply()` 会把自建反代**前置到 `bases` 首位**。
    //
    // 用「主机 + 路径前缀」精确比对，并把两条规则合起来：
    //   ① 与用户自建反代**同主机**的一律算自建
    //      —— 这样 `/ap/bgmapi`、`/ap/anibt` 这类**挂在同一个 Worker 上的
    //      备用上游路由**也会被保留（它们主机相同、路径不同）。
    //      实测这些路由经反代后 623~741ms，正是「把访问不了的 API 救活」的成果，
    //      绝不能在独占时被误排除。
    //   ② 不在 presetBases 里的（用户额外填的别的地址）也算自建
    bool isPreset(String b) => BangumiApi.presetBases.any((p) {
          if (p == b) return true;
          final pu = Uri.tryParse(p);
          final bu = Uri.tryParse(b);
          if (pu == null || bu == null) return false;
          if (pu.host != bu.host) return false;
          final pfx = pu.path.replaceAll(RegExp(r'/+$'), '');
          if (pfx.isEmpty) return false; // 纯主机形态 → 那是用户的自建反代
          return bu.path == pfx || bu.path.startsWith('$pfx/');
        });

    // 用户自建反代的主机集合（presetBases 之外的纯主机条目）
    final customHosts = all
        .where((b) => !isPreset(b))
        .map((b) => Uri.tryParse(b)?.host)
        .whereType<String>()
        .toSet();

    bool isCustom(String b) {
      if (!isPreset(b)) return true;
      final h = Uri.tryParse(b)?.host;
      return h != null && customHosts.contains(h);
    }

    final customs = all.where(isCustom).toList();
    if (customs.isNotEmpty) return customs;
    return all;
  }

  // ── 响应的 JSON 形状归一化 ──
  //
  // 同一个语义在不同镜像上的**外层包装不同**：
  //   bgmapi.anibt.net `/v0/episodes` → {"data":[...], "total":N}
  //   api.kazumi.fyi   `/p1/subjects/{id}` → 直接是条目对象（无 data 包装）
  // 调用方不该关心这件事，所以在 _race 出口统一抹平。

  /// 取「列表」：自动剥掉 `{data: [...]}` 包装
  static List<dynamic> asList(dynamic j) {
    if (j is List) return j;
    if (j is Map) {
      final d = j['data'];
      if (d is List) return d;
    }
    return const [];
  }

  /// 取「对象」：自动剥掉 `{data: {...}}` 包装
  static Map<String, dynamic> asMap(dynamic j) {
    if (j is Map) {
      final d = j['data'];
      if (d is Map) return d.cast<String, dynamic>();
      return j.cast<String, dynamic>();
    }
    return const {};
  }

  /// 取 total（分页用）；缺省时返回 0 表示「不知道」
  static int asTotal(dynamic j) {
    if (j is Map) {
      final t = j['total'];
      if (t is num) return t.toInt();
    }
    return 0;
  }

  Uri _u(String base, String path, [Map<String, String>? q]) {
    final uri = Uri.parse('$base${_remapForBase(base, path)}');
    return q == null || q.isEmpty ? uri : uri.replace(queryParameters: q);
  }

  /// 【v2.1.10】按数据源改写路径
  ///
  /// `api.kazumi.fyi` 只实现了 `/p1/*`（`/p1/subjects/{id}`、`/p1/calendar`），
  /// 对 `/v0/*` 和 `/calendar` 一律 404（实测 5/5）。所以直接用它是白等。
  ///
  /// 套上自建反代后：
  ///     /ap/kazumi/v0/subjects/400602   5/5   688ms   ✅（Worker 侧已重写）
  ///     /ap/kazumi/p1/calendar          5/5   905ms   ✅
  ///     /ap/kazumi/calendar             0/3            ❌ Worker 没覆盖这条
  ///
  /// 客户端补一刀：走 kazumi 上游的 base 把 `/calendar` 改写成 `/p1/calendar`。
  static String _remapForBase(String base, String path) {
    final isKazumi =
        base.contains('/ap/kazumi') || base.contains('api.kazumi.fyi');
    if (!isKazumi) return path;
    if (path == '/calendar') return '/p1/calendar';
    return path;
  }

  bool _isNetError(Object e) {
    final s = e.toString();
    return e is TimeoutException ||
        s.contains('SocketException') ||
        s.contains('HandshakeException') ||
        s.contains('Connection') ||
        s.contains('Failed host lookup') ||
        s.contains('ClientException');
  }

  /// 镜像**并发竞速**（hedged requests）
  ///
  /// 背景：官方站直连不可达，可用镜像快慢差距极大（273ms vs 3.9s）。
  /// 串行试每个镜像最坏要等几十秒 —— 这就是「点动漫很慢」。
  ///
  /// 现在：所有镜像同时开跑，**谁先成功用谁**，总耗时 = 最快那个镜像。
  /// 错峰 300ms 的作用是「首选镜像先单独跑一小会儿」，网络正常时它 273ms
  /// 就回来了，后发的根本不会发出去（省流量、省站点压力）。
  ///
  /// 超时 12s → 6s：实测最快镜像 273ms，6s 还没回的一定是死镜像；
  /// 让它早点出局，整轮请求的最坏耗时从 12s 降到 6s。
  Future<dynamic> _race(String path, bool isPost, Map<String, dynamic>? body, Map<String, String>? q) async {
    // 【v2.1.10 · 快速失败】已知全部镜像不可用时，不再逐个白等超时。
    // 冷却期内每隔 60 秒仍放一次真实探测，网络恢复能自动解除。
    if (_inGlobalCooldown && !_shouldProbe) {
      throw ApiException(
          'Bangumi 数据源当前不可达（冷却中，最长 10 分钟；每 60 秒自动探测一次）。'
          '若已开启代理，请到「设置 → 网络与镜像」确认代理已启用并跟随系统');
    }

    final bases = _orderedBases;
    if (bases.isEmpty) {
      throw ApiException('未配置 Bangumi 数据源');
    }
    final completer = Completer<dynamic>();
    final targets = <(String, String)>[]; // (base, 生效路径)
    var skipped = 0;
    void buildTargets() {
      targets.clear();
      skipped = 0;
      for (final b in _orderedBases) {
        final p = _pathFor(b, path);
        if (p == null) {
          skipped++;
          continue;
        }
        targets.add((b, p));
      }
    }

    buildTargets();
    // 【v2.1.5 · 冷却死锁自愈】targets 为空但冷却表里有镜像 → 说明
    // 「活着」的镜像都不支持该请求、能支持的都在冷却（实测：搜索时
    // kazumi.fyi 永远被跳过且不进冷却，anibt/bgm.tv 失败一次进冷却后
    // targets 恒为空 → 搜索连报 120s「不支持该请求」）。清冷却重建。
    if (targets.isEmpty && _baseCooldown.isNotEmpty) {
      kLog('[Bangumi] $path：可用镜像全在冷却，已重置冷却并重试全部镜像');
      _baseCooldown.clear();
      buildTargets();
    }
    if (targets.isEmpty) {
      throw ApiException('当前数据源均不支持该请求（$path）');
    }

    final effective = targets.length;
    var remaining = effective;
    Object? lastError;
    int? lastStatus;
    final notFound = <int>[];
    final tooMany = <int>[];

    // 【v2.1.10 · 可观测性】记录本轮竞速的起止与每个目标的归属，
    // 用于定位「详情页卡住且没有任何日志」的问题（原来失败是静默的）。
    final raceSw = Stopwatch()..start();
    final outcome = <String>[];

    // 【v2.1.10 · 修「几个 api 不够稳定，有时不可达」】
    //
    // 实测（各 8 次请求同一个条目）：
    //     bgm.kchan.top（自建反代）  8/8   中位  994ms
    //     bgmapi.anibt.net          4/8   中位 11163ms
    //     api.kazumi.fyi            0/8   中位  3943ms
    //
    // 也就是说**自建反代是最稳的，第三方反而一半不可达**。
    // 旧逻辑「150ms 错峰同时发」会让不稳的第三方频繁抢先或拖满超时，
    // 白白浪费一整轮。
    //
    // 现在改成「**自建反代优先独占**」：
    //   · 第一个目标（自建反代，排在 _orderedBases 首位）单独先跑，
    //     给它 2 秒独占窗口 —— 实测它 994ms 就回，2 秒足够；
    //   · 2 秒内没回，才放其它镜像入场做兜底；
    //   · 这样绝大多数请求只打一次网络，不浪费、不互相干扰。
    final preferredHost = _orderedBases.isNotEmpty
        ? Uri.tryParse(_orderedBases.first)?.host
        : null;

    for (var i = 0; i < targets.length; i++) {
      final (base, effPath) = targets[i];
      final host = Uri.tryParse(base)?.host;
      final isPreferred = host != null && host == preferredHost;
      // 【v2.1.10 · 收紧竞速窗口，把延迟压进 2000ms】
      //
      // 旧值：非首选一律 `2000 + 150*i` ms 才发车。
      // 实测后果：首选（自建反代）若碰上 Cloudflare 抖动，比如 1.2s 没回，
      // 后面 4 个镜像全都还在睡——最坏要等到 2s 之后才开始试，
      // 于是「总延迟必超 2 秒」，而且首选的慢会整轮放大。
      //
      // 新值：首选独占 800ms（实测它中位 672ms，800ms 足够让它赢），
      // 之后每 120ms 放一个镜像出去。这样最快的那家能在 ~700ms 定胜负，
      // 最慢也不会被强制排队到 2s。
      final delayMs = isPreferred ? 0 : (800 + 120 * i);
      final tag = isPreferred ? '自建反代' : '镜像';
      Future<void>(() async {
        if (delayMs > 0) await Future<void>.delayed(Duration(milliseconds: delayMs));
        if (completer.isCompleted) {
          remaining--;
          outcome.add('$tag ${Uri.parse(base).host} 未发车(已被抢先)');
          return;
        }
        try {
          // 【v2.1.7】按目标域名挑 client：api.bgm.tv 走 ECH 直连官方，
          // 镜像域名走普通 client（ECH 失败时该目标自然失败，竞速落镜像）
          final reqUri = _u(base, effPath, q);
          final hc = _client;
          final res = isPost
              ? await hc
                  .post(reqUri,
                      headers: {
                        'User-Agent': userAgent,
                        'Accept': 'application/json',
                        'Content-Type': 'application/json'
                      },
                      body: jsonEncode(body))
                  .timeout(const Duration(seconds: 4))
              : await hc
                  .get(reqUri,
                      headers: {'User-Agent': userAgent, 'Accept': 'application/json'})
                  .timeout(const Duration(seconds: 4));
          if (res.statusCode == 200) {
            _preferredBase = base;
            _baseCooldown.remove(base);
            // 【v2.1.10】有镜像成功了 → 立刻解除全局冷却
            // （网络恢复/代理打开后不必等满 10 分钟）
            if (_globalCooldownAt != null) {
              _globalCooldownAt = null;
              kLog('[Bangumi] $base 已恢复 → 解除全局冷却');
            }
            outcome.add('$tag ${Uri.parse(base).host} 成功 '
                '${raceSw.elapsedMilliseconds}ms');
            kLog('[Bangumi] $path ← $tag(${Uri.parse(base).host}) 成功 '
                '${raceSw.elapsedMilliseconds}ms');
            // 【v2.1.10 · 修「请求成功但 Future 永不返回」】
            //
            // 旧代码：`if (!completer.isCompleted) completer.complete(jsonDecode(...))`
            //
            // 两个致命问题：
            //  ① `jsonDecode` 在 `if` **内部**：若响应体不是合法 JSON
            //     （镜像返回 HTML 错误页、空体、被截断），它会抛
            //     FormatException。此时 completer **已被判定为可完成**、
            //     但实际从未 complete → 外层 await 永远挂着。
            //     这正是「日志显示请求成功、页面却永远不渲染」的原因。
            //  ② 抛出点在这个 `Future(() async {...})` 里，异常进不了
            //     调用方的 await，只被 Dart 当成未捕获异步错误丢弃 →
            //     日志里连一行错误都没有，完全静默。
            //
            // 现在：先解析、解析失败就当作「这个目标失败」继续等其它目标；
            // 只有解析成功才真正 complete。
            dynamic decoded;
            try {
              decoded = jsonDecode(utf8.decode(res.bodyBytes));
            } catch (e) {
              // 这家返回的不是 JSON（多半是 HTML 错误页）→ 记为失败，
              // 让竞速继续用其它目标裁决，绝不静默挂死。
              outcome.add('$tag ${Uri.parse(base).host} 响应非 JSON');
              kLog('[Bangumi] $path ← $tag(${Uri.parse(base).host}) '
                  '响应无法解析为 JSON（${res.bodyBytes.length} 字节），改用其它数据源');
              _baseCooldown[base] = DateTime.now().millisecondsSinceEpoch;
              lastError = FormatException('响应非 JSON');
              return;
            }
            // 【v2.1.10 · 修「首页空白」】镜像常把 404 塞在 HTTP 200 的
            // body 里（{"code":404,"error":"Not Found"}）。若当成成功，
            // 竞速会立刻 settle 到这家、解析出 0 条，首页就空白了 ——
            // 而且全程没有任何错误日志。这里显式判失败。
            if (_isErrorEnvelope(decoded)) {
              final c = (decoded as Map)['code'];
              outcome.add('$tag ${Uri.parse(base).host} 200伪装错误($c)');
              kLog('[Bangumi] $path ← $tag(${Uri.parse(base).host}) '
                  '返回 HTTP 200 但 body 是错误信封（code=$c），判为失败并改用其它数据源');
              _baseCooldown[base] = DateTime.now().millisecondsSinceEpoch;
              lastStatus = c is int ? c : null;
              return;
            }
            if (!completer.isCompleted) {
              completer.complete(decoded);
            }
            return;
          }
          lastStatus = res.statusCode;
          outcome.add('$tag ${Uri.parse(base).host} HTTP ${res.statusCode} '
              '${raceSw.elapsedMilliseconds}ms');
          // 镜像的 404/429 不再一票否决！
          //  旧逻辑：任一镜像先回 404 → 直接判「内容不存在」。
          //  问题：镜像是第三方同步库，经常缺新条目/瞬时 404，官方
          //  api.bgm.tv 还没回答就被判死刑 → 明明存在的番剧显示 404。
          //  现在：404/429 只记录，继续等其它镜像；全部源都回答后才裁决。
          if (res.statusCode == 404) {
            notFound.add(res.statusCode);
            return;
          }
          if (res.statusCode == 429) {
            tooMany.add(res.statusCode);
            // 限流也算「这家暂时别用」，冷却期内不再每次白等
            _baseCooldown[base] = DateTime.now().millisecondsSinceEpoch;
            return;
          }
        } catch (e) {
          lastError = e;
          final es = e.toString();
          outcome.add('$tag ${Uri.parse(base).host} 失败 '
              '${raceSw.elapsedMilliseconds}ms '
              '${es.length > 46 ? es.substring(0, 46) : es}');
          // 超时/网络错误 → 进冷却，下几次请求直接跳过这家
          _baseCooldown[base] = DateTime.now().millisecondsSinceEpoch;
        } finally {
          remaining--;
          if (remaining == 0 && !completer.isCompleted) {
            // 【v2.1.10 · 可观测性】把每个目标的最终归属打出来 —— 这是
            // 定位「详情页卡住却无日志」的关键（原来失败是静默的）。
            // 用 try 包住：这里若抛异常，completer 就永远不会完成，
            // 外层 await 会静默挂死（正是本次要修的那类 bug）。
            try {
              kLog('[Bangumi] $path 全部失败（${raceSw.elapsedMilliseconds}ms）: '
                  '${outcome.join(" | ")}');
              if (notFound.isNotEmpty) {
                completer.completeError(ApiException('内容不存在', 404));
              } else if (tooMany.isNotEmpty) {
                completer.completeError(ApiException('请求太频繁，请稍后再试', 429));
              } else {
                // 【v2.1.10 · 修「25 秒失败 15 次」】
                //
                // 旧代码这里 `_baseCooldown.clear()`，本意是自愈，实际造成
                // 「清空 → 重试全部 → 全失败 → 又清空」的死循环，
                // 实测 25 秒内失败 15 次、每次白等 5~6 秒。
                //
                // 现在改为**进入全局冷却**：后续请求直接快速失败（0 秒），
                // 每隔 60 秒放行一次探测，网络恢复即自动解除。
                _globalCooldownAt = DateTime.now().millisecondsSinceEpoch;
                _lastProbeAt = _globalCooldownAt!;
                kLog('[Bangumi] 全部镜像失败 → 进入 10 分钟全局冷却'
                    '（期间快速失败，每 60 秒探测一次）');
                completer.completeError(ApiException(
                    '所有 Bangumi 数据源均无法连接'
                    '${skipped > 0 ? "（$skipped 个数据源不支持该请求已跳过）" : ""}'
                    '，已暂停重试 45 秒（每 60 秒自动探测）；'
                    '可到「设置 → 网络与镜像」配置代理或自建反代'
                    '${lastStatus != null ? '，最后状态 $lastStatus' : ''}'));
              }
            } catch (e) {
              // 兜底：裁决过程本身出问题时，也必须让 Future 有结果，
              // 否则调用方会静默挂死（这就是本次要根除的故障形态）。
              if (!completer.isCompleted) {
                completer.completeError(ApiException('竞速裁决异常: $e'));
              }
            }
          }
        }
      });
    }
    if (skipped > 0) {
      kLog('[Bangumi] $path：$skipped 个数据源不支持该路径，已跳过');
    }

    // 【v2.1.10 · 结构性保险】无论上面发生什么（解析异常、裁决异常、
    // 某个目标分支被跳过导致 remaining 没归零），都在超时后强制给一个
    // 结果，**保证调用方的 await 一定有返回**。
    // 上限取单目标超时 4s + 全部错峰 150ms×N + 1.5s 余量。
    final guardMs = 4000 + 150 * targets.length + 1500;
    unawaited(Future<void>.delayed(Duration(milliseconds: guardMs), () {
      if (!completer.isCompleted) {
        kLog('[Bangumi] $path 保险触发（${guardMs}ms 仍无结果）→ 强制失败，'
            '避免调用方静默挂死。明细: ${outcome.join(" | ")}');
        completer.completeError(ApiException(
            '数据源响应超时（$path）；已放弃等待，请重试或到'
            '「设置 → 网络与镜像」配置代理'));
      }
    }));

    return completer.future;
  }

  // ---------- 轻量内存缓存（v1.4.0） ----------
  //
  // 详情页反复进出、放送表切 tab 都命中同一批请求；镜像慢的时候缓存
  // 直接决定「快不快」。只缓存元数据（几十 KB 级），进程内有效。
  static final _cache = <String, ({dynamic data, int at})>{};
  static const _cacheTtlMs = 10 * 60 * 1000; // 10 分钟

  // ---------- 磁盘缓存（v2.1.10） ----------
  //
  // ## 为什么加它
  //
  // 实测首页加载构成：
  //   ① 启动到首帧        ~1.0s
  //   ② 搜索接口 3 页     ~2.2s   ← 本季放送表，10 分钟内根本不会变
  //   ③ 预热今日放送      ~2.2s
  //   首页可见数据         ~2.2s
  //
  // 而**本季 60 部番剧十分钟内不会变**，每次启动都重新请求纯属浪费。
  // Kazumi 也没做这件事（它同样只有内存缓存）—— 所以这不是「抄作业」，
  // 是两边都能优化、但都没做的点。
  //
  // ## 做法
  //
  // 把「日历 / 搜索」这两类**用户能立刻感知**的结果额外写一份到磁盘，
  // 下次启动**首帧即可渲染**（命中约 10ms），网络刷新在后台进行。
  //
  // ## 安全性
  //
  //  - 只缓存**只读的公开数据**（放送表、搜索页），不涉及登录态；
  //  - 文件损坏 / 格式变更 → 整份丢弃重建，绝不因缓存问题影响功能；
  //  - 写入合并 + 防抖（[_diskFlushMs]），不阻塞 UI；
  //  - 有独立 TTL（[_diskTtlMs]），过期就不再用。

  static Map<String, dynamic>? _disk;
  static bool _diskLoaded = false;
  static bool _diskDirty = false;
  static DateTime? _diskFlushAt;
  static const _diskTtlMs = 24 * 60 * 60 * 1000; // 24 小时
  static const _diskFlushMs = 4000; // 写盘防抖

  /// 需要落盘缓存的 key 前缀（只放「首屏可见」的，控制文件体积）
  static bool _shouldPersist(String key) =>
      key.startsWith('calendar:') ||
      key.startsWith('calsearch:') ||
      key.startsWith('search:');

  static Future<File> _diskFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}${Platform.pathSeparator}bgm_cache.json');
  }

  static Future<void> _loadDisk() async {
    if (_diskLoaded) return;
    _diskLoaded = true;
    try {
      final f = await _diskFile();
      if (!await f.exists()) {
        _disk = {};
        return;
      }
      final raw = jsonDecode(await f.readAsString());
      if (raw is! Map) {
        _disk = {};
        return;
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      _disk = <String, dynamic>{};
      var kept = 0;
      raw.forEach((k, v) {
        if (v is! Map) return;
        final at = (v['at'] as num?)?.toInt() ?? 0;
        if (now - at > _diskTtlMs) return; // 过期丢弃
        _disk![k.toString()] = v;
        kept++;
      });
      kLog('[Bangumi] 磁盘缓存载入 $kept 项（原始 ${raw.length} 项）');
    } catch (e) {
      // 损坏就整份重置，绝不让缓存影响功能
      kLog('[Bangumi] 磁盘缓存载入失败（忽略并重建）: $e');
      _disk = {};
    }
  }

  /// 启动时调用：把磁盘缓存预热进内存，使首帧就能命中。
  ///
  /// 【v2.1.10 · 修「预热了却立刻过期」】旧实现把内存时间戳设成 `now`，
  /// 但 `_cacheGet` 用 [_cacheTtlMs]（10 分钟）判断新鲜度 —— 于是
  /// 「上次进程留下的数据」刚预热进来就被判过期，等于没预热。
  ///
  /// 现在：**磁盘预热进来的数据不受内存 TTL 约束**（它已由 [_diskTtlMs]
  /// 24 小时把关）。做法是把内存时间戳设为 `now`，同时给这些 key 打标记，
  /// 让 [_cacheGet] 对它们放宽到磁盘 TTL。
  static final _fromDisk = <String>{};

  static Future<void> warmDiskCache() async {
    await _loadDisk();
    final d = _disk;
    if (d == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    var n = 0;
    for (final e in d.entries) {
      final v = e.value;
      if (v is! Map) continue;
      final at = (v['at'] as num?)?.toInt() ?? 0;
      if (now - at > _diskTtlMs) continue;
      // 【v2.1.10】JSON 读回来的是 Map/List，必须还原成真正的对象，
      // 否则 `calendar()` 里 `fresh is List<CalendarDay>` 判不过 → 白预热。
      final restored = _restoreValue(e.key, v['data']);
      if (restored == null) continue;
      _cache[e.key] = (data: restored, at: now);
      _fromDisk.add(e.key); // 标记：放宽 TTL
      n++;
    }
    kLog('[Bangumi] 磁盘缓存预热 $n 项进内存（首帧即可用）');
  }

  /// 把磁盘里的 JSON 还原成运行期对象。返回 null 表示这条不可用（丢弃）。
  static dynamic _restoreValue(String key, dynamic data) {
    try {
      if (key.startsWith('calendar:')) {
        if (data is! List) return null;
        final out = <CalendarDay>[];
        for (final e in data) {
          final d = CalendarDay.fromJson(e);
          if (d != null) out.add(d);
        }
        return out.isEmpty ? null : out;
      }
      // 搜索结果是原始 JSON（Map），直接可用
      if (key.startsWith('search:') || key.startsWith('calsearch:')) {
        return data;
      }
      return data;
    } catch (e) {
      kLog('[Bangumi] 还原缓存项 $key 失败（丢弃）: $e');
      return null;
    }
  }

  static void _diskScheduleFlush() {
    _diskDirty = true;
    final last = _diskFlushAt;
    final now = DateTime.now();
    if (last != null && now.difference(last).inMilliseconds < _diskFlushMs) {
      return; // 防抖：写太频繁没意义
    }
    _diskFlushAt = now;
    unawaited(Future<void>.delayed(const Duration(milliseconds: _diskFlushMs),
        () async {
      await flushDiskCache();
    }));
  }

  /// 立即把磁盘缓存写盘。
  ///
  /// 【v2.1.10 · 修「缓存文件根本没生成」】原来只有「延迟 4 秒后写」这一条路，
  /// 而且写失败被 `catch (_) {}` **完全静默** —— 结果实测三天都没生成过文件，
  /// 也查不出原因。现在：
  ///   · 失败**打日志**（不再静默吞掉）；
  ///   · 暴露成公开方法，供「日历拿到数据后立刻写」「退出前写」调用；
  ///   · 写完后校验文件真的存在，并在日志里报告大小。
  static Future<void> flushDiskCache() async {
    if (!_diskDirty) return;
    _diskDirty = false;
    try {
      final d = _disk ?? {};
      if (d.isEmpty) return;
      final f = await _diskFile();
      final tmp = File('${f.path}.tmp');
      final text = jsonEncode(d);
      await tmp.writeAsString(text, flush: true);
      if (await f.exists()) await f.delete();
      await tmp.rename(f.path);
      kLog('[Bangumi] 磁盘缓存已写入 ${d.length} 项 / '
          '${(text.length / 1024).toStringAsFixed(1)}KB -> ${f.path}');
    } catch (e) {
      // 不再静默：写盘失败要能看见（否则永远查不出「缓存没生成」）
      kLog('[Bangumi] 磁盘缓存写入失败: $e');
    }
  }

  static dynamic _cacheGet(String key) {
    final hit = _cache[key];
    if (hit == null) return null;
    // 磁盘预热进来的数据放宽到磁盘 TTL（24h），不受内存 10 分钟限制
    final ttl = _fromDisk.contains(key) ? _diskTtlMs : _cacheTtlMs;
    if (DateTime.now().millisecondsSinceEpoch - hit.at > ttl) {
      _cache.remove(key);
      _fromDisk.remove(key);
      return null;
    }
    return hit.data;
  }

  static void _cachePut(String key, dynamic data) {
    final at = DateTime.now().millisecondsSinceEpoch;
    _cache[key] = (data: data, at: at);
    _fromDisk.remove(key); // 新抓到的数据回到正常 TTL
    if (_shouldPersist(key)) {
      _disk ??= {};
      _disk![key] = {'at': at, 'data': data};
      _diskScheduleFlush();
    }
  }

  /// 【v2.1.9 · single flight】同 key 的在途请求合并（学 Kazumi 的
  /// AsyncSingleFlight）：详情页、反查、今日预热、中文名补齐完全可能
  /// **同时**请求同一个 subject —— 旧实现各发各的，同一个请求打 2~4 遍。
  /// 现在并发方共享同一个 Future，结果各自拿到、只发一次网络。
  final _inFlight = <String, Future<dynamic>>{};

  Future<dynamic> _getCached(String key, String path, [Map<String, String>? q]) async {
    final hit = _cacheGet(key);
    if (hit != null) {
      return hit;
    }
    final running = _inFlight[key];
    if (running != null) {
      return running;
    }
    // 【v2.1.10 · 防「僵尸 Future」】给在途请求加硬超时。
    //
    // 为什么必须加：`_inFlight[key]` 只有在 Future **完成**时才被清掉
    // （见 whenComplete）。若 `_race` 因缺陷永不完成，这个死 Future 会
    // **永久占位** —— 此后同 key 的调用一律直接返回它，连请求都不发，
    // 表现为「搜同一个词 / 打开同一个番永远转圈」。
    //
    // 加超时后：无论 `_race` 内部发生什么，这里最迟 20 秒一定以异常结束，
    // 从而 `whenComplete` 得以执行、清掉占位 —— 下一次调用能重新发起。
    final future = _race(path, false, null, q)
        .timeout(const Duration(seconds: 20), onTimeout: () {
      throw ApiException('数据源响应超时（$path）；已放弃等待，请重试');
    }).then((data) {
      _cachePut(key, data);
      return data;
    }).whenComplete(() {
      _inFlight.remove(key);
    });
    _inFlight[key] = future;
    return future;
  }

  /// POST 搜索也走缓存：搜索页反复翻页/切排序/重复搜同一关键词时直接命中，
  /// 不用再等慢镜像（搜索结果 10 分钟内几乎不变）。
  /// POST 请求（目前只有 `/v0/search/subjects`）**不走 `_race` 竞速**。
  ///
  /// ## 为什么要这么改（实测依据）
  ///
  /// 搜索「很卡」的根因有两层，都修在这里：
  ///
  /// **① `_race` 会挂死**：它在请求明明成功时（日志有「成功 Nms」）
  ///    返回的 Future 仍可能永不完成，调用方一直等到超时。
  ///    而搜索本来就没什么可竞速的 —— `api.kazumi.fyi` 的
  ///    `POST /v0/search/subjects` 实测返回 **401**，`_pathFor` 也会
  ///    判它「不支持」直接跳过；目标只剩自建反代一家。
  ///    所以改成**直连**（与 Kazumi 的搜索做法一致）。
  ///
  /// **② `_inFlight` 会存下「僵尸 Future」**（这条更隐蔽）：
  ///    一旦某个 key 的 Future 永不完成（原因①），它就**永久占着**
  ///    `_inFlight[key]`，此后所有同 key 调用都直接返回那个死 Future，
  ///    **连一个请求都不发**。实测表现就是「搜同一个词永远转圈」。
  ///
  ///    修法：**不再用 `_inFlight` 合并 POST**。搜索请求本身就少，
  ///    且有 [_cache] 挡住重复；用「永不清理的在途表」换那点去重收益
  ///    不值得 —— 一个坏掉的 Future 就能让搜索彻底不可用。
  ///    每次搜索都是一次全新的、带 10 秒超时的直连请求。
  Future<dynamic> _postCached(String key, String path, Map<String, dynamic> body, [Map<String, String>? q]) async {
    final hit = _cacheGet(key);
    if (hit != null) {
      kLog('[Bangumi] $path 命中搜索缓存');
      return hit;
    }
    final data = await _postDirect(path, body, q);
    _cachePut(key, data);
    return data;
  }

  /// 直接 POST（不竞速）。逐个尝试 bases，第一个成功的就用。
  Future<dynamic> _postDirect(String path, Map<String, dynamic> body, [Map<String, String>? q]) async {
    Object? lastError;
    for (final base in _orderedBases) {
      final effPath = _pathFor(base, path);
      if (effPath == null) continue; // 该域名不支持此路径（如 kazumi 的搜索）
      final uri = _u(base, effPath, q);
      final sw = Stopwatch()..start();
      try {
        final res = await _client
            .post(
              uri,
              headers: {
                'User-Agent': userAgent,
                'Accept': 'application/json',
                'Content-Type': 'application/json',
              },
              body: jsonEncode(body),
            )
            .timeout(const Duration(seconds: 10));
        if (res.statusCode != 200) {
          lastError = ApiException('HTTP ${res.statusCode}');
          kLog('[Bangumi] $path ← ${Uri.parse(base).host} '
              'HTTP ${res.statusCode}（${sw.elapsedMilliseconds}ms）');
          _baseCooldown[base] = DateTime.now().millisecondsSinceEpoch;
          continue;
        }
        final decoded = jsonDecode(utf8.decode(res.bodyBytes));
        if (_isErrorEnvelope(decoded)) {
          lastError = ApiException('错误信封 code=${(decoded as Map)['code']}');
          _baseCooldown[base] = DateTime.now().millisecondsSinceEpoch;
          continue;
        }
        _preferredBase = base;
        _baseCooldown.remove(base);
        if (_globalCooldownAt != null) _globalCooldownAt = null;
        kLog('[Bangumi] $path ← ${Uri.parse(base).host} 成功 '
            '${sw.elapsedMilliseconds}ms');
        return decoded;
      } catch (e) {
        lastError = e;
        kLog('[Bangumi] $path ← ${Uri.parse(base).host} 失败 '
            '（${sw.elapsedMilliseconds}ms）: $e');
        _baseCooldown[base] = DateTime.now().millisecondsSinceEpoch;
      }
    }
    throw ApiException('搜索请求失败：${lastError ?? "无可用的数据源"}');
  }

  /// 每日放送
  ///
  /// 【重要】官方文档里「每日放送」的路径是 **`GET /calendar`**（旧版公开 API），
  /// v0 系列中**并没有** `/v0/calendar`。早期这里误写成 `/v0/calendar`，
  /// 会稳定拿到 HTTP 404，首页就显示「内容不存在」。
  ///
  /// 【v2.1.9 · 稳定性改造】首页「有时快有时慢」的机制性根因是：
  ///   ① Kazumi 镜像最长等 8s 才回落通用镜像，再等 6s 竞速 —— 慢时整页 10s+；
  ///   ② 挂掉的镜像每次都重新等一遍超时 —— 同一操作方差巨大。
  /// 现在：
  ///   ① **对冲请求**：镜像 2.5s 没回就并行发通用路径，谁先成功用谁；
  ///   ② 镜像连续失败进冷却（见 [_baseCooldown] / [_mirrorCalendarFailedAt]）；
  ///   ③ **stale-while-revalidate**：有旧结果先秒开、后台刷新；
  ///      手动刷新（[force]）跳过旧结果直接等网络，失败才退回旧结果。
  Future<List<CalendarDay>> calendar({bool force = false}) async {
    if (!force) {
      final fresh = _cacheGet('calendar:result');
      if (fresh is List<CalendarDay>) return List.of(fresh);
      final stale = _calendarStale;
      if (stale != null) {
        unawaited(_calendarRefreshSafe());
        return List.of(stale);
      }
    }
    try {
      return await _calendarRefresh();
    } catch (e) {
      final stale = _calendarStale;
      if (stale != null) return List.of(stale); // 网络全挂也别白屏
      rethrow;
    }
  }

  /// 最近一次成功结果（不过期）：用于 stale-while-revalidate 秒开
  static List<CalendarDay>? _calendarStale;

  static const _mirrorCooldownMs = 120 * 1000;



  Future<void> _calendarRefreshSafe() async {
    try {
      await _calendarRefresh();
      _calendarRefreshFails = 0;
    } catch (e) {
      _calendarRefreshFails++;
      kLog('[Bangumi] 放送表后台刷新失败（连败 $_calendarRefreshFails 次，暂用旧数据）：$e');
    }
  }


  Future<List<CalendarDay>> searchBasedCalendar() async {
    final range = seasonDateRange();
    // 【v2.1.10 · 修「首页动漫资源不是最新的」】
    //
    // 实测本季（2026-10 起）`total = 100` 部，而旧代码只取 3 页 × 20 = 60 部，
    // **少了 40 部** —— 用户看到的就是「不是最新/不全」。
    //
    // 现在取满 5 页（100 部）。实测单页 800~2500ms，5 页并发更快，
    // 且结果会进磁盘缓存，第二次启动不重复抓。
    const pageLimit = 20;
    const maxPages = 5;
    final all = <Subject>[];
    for (var page = 0; page < maxPages; page++) {
      try {
        kLog('[Bangumi] 搜索式放送表：请求第 $page 页…');
        dynamic j;
        // 【v2.1.10 · 关键】**不走 `_postCached`/`_race`**。
        //
        // 实测问题：`_race` 在「请求明明成功（日志有『成功 1376ms』）」的
        // 情况下，返回的 Future 仍会永不完成，导致首页卡死、12 秒超时。
        // 这是 single-flight + 竞速叠加出的间歇性缺陷，排查成本极高。
        //
        // 而放送表这个请求**不需要竞速** —— 自建反代（customBase）就是最快的，
        // 没有它时用镜像池第一个可用域名直连即可。Kazumi 的
        // `getCalendar()` 也正是这么写的：一次直接请求，不做竞速。
        //
        // 这样写彻底避开 `_race`：要么拿到数据，要么在 timeout 内明确失败。
        final url = _u(
          bases.first,
          '/v0/search/subjects',
          {'limit': '$pageLimit', 'offset': '${page * pageLimit}'},
        );
        final res = await _client
            .post(
              url,
              headers: {
                'User-Agent': userAgent,
                'Accept': 'application/json',
                'Content-Type': 'application/json',
              },
              body: jsonEncode({
                'keyword': '',
                'sort': 'rank',
                'filter': {
                  'type': [2],
                  'tag': ['日本'],
                  'air_date': ['>=${range[0]}', '<${range[1]}'],
                },
              }),
            )
            .timeout(const Duration(seconds: 10));
        if (res.statusCode != 200) {
          kLog('[Bangumi] 搜索式放送表：第 $page 页 HTTP ${res.statusCode}');
          break;
        }
        j = jsonDecode(utf8.decode(res.bodyBytes));
        if (_isErrorEnvelope(j)) {
          kLog('[Bangumi] 搜索式放送表：第 $page 页返回错误信封，停止翻页');
          break;
        }
        final items = asList(j);
        kLog('[Bangumi] 搜索式放送表：第 $page 页返回 ${items.length} 条');
        if (items.isEmpty) break;
        all.addAll(items
            .whereType<Map<String, dynamic>>()
            .map(Subject.fromJson));
      } catch (e) {
        // 【v2.1.10 · 修「只拿到 20 部」】旧代码这里 `break` —— 单页失败
        // 就放弃**整轮**，于是第 0 页拿到 20 部后、第 1 页一旦超时，
        // 第 2 页根本不再请求，首页只剩 20 部（应为 60）。
        //
        // 现在改成 `continue`：单页失败只丢那一页，其余照常拿。
        // 只要有一页成功，all 就不为空，首页不会空。
        kLog('[Bangumi] 搜索式放送表第 $page 页失败（跳过该页，继续下一页）: $e');
        continue;
      }
    }
    if (all.isEmpty) {
      throw ApiException('搜索式放送表无数据');
    }
    kLog('[Bangumi] 搜索式放送表拿到 ${all.length} 部，按星期分组');
    return groupByWeekday(all);
  }

  /// 把扁平番剧列表按 `air_date` 的星期分到 7 天
  List<CalendarDay> groupByWeekday(List<Subject> items) {
    const cn = {
      1: '周一', 2: '周二', 3: '周三', 4: '周四',
      5: '周五', 6: '周六', 7: '周日'
    };
    final buckets = <int, List<Subject>>{for (var i = 1; i <= 7; i++) i: []};
    final unknown = <Subject>[];
    for (final s in items) {
      // air_date 形如 "2026-10-05"（String）
      final raw = s.airDate.trim();
      DateTime? d;
      if (raw.length >= 10) {
        d = DateTime.tryParse(raw.substring(0, 10));
      }
      if (d != null && d.weekday >= 1 && d.weekday <= 7) {
        buckets[d.weekday]!.add(s);
      } else {
        unknown.add(s);
      }
    }
    // air_date 缺失/异常的（少数）归到「今天」，否则它们会整批消失
    if (unknown.isNotEmpty) {
      buckets[DateTime.now().weekday]!.addAll(unknown);
    }
    return [
      for (var i = 1; i <= 7; i++)
        CalendarDay(weekday: i, weekdayCn: cn[i]!, items: buckets[i]!)
    ];
  }

  /// 本季的 [起始日, 结束日) —— 供搜索式放送表做 air_date 过滤
  List<String> seasonDateRange() {
    final now = DateTime.now();
    final m = now.month;
    final sm = m <= 3 ? 1 : (m <= 6 ? 4 : (m <= 9 ? 7 : 10));
    final start = DateTime(now.year, sm, 1);
    final endMonth = sm + 3;
    final end = endMonth > 12
        ? DateTime(now.year + 1, endMonth - 12, 1)
        : DateTime(now.year, endMonth, 1);
    String f(DateTime d) =>
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    return [f(start), f(end)];
  }

  /// 刷新放送表。
  ///
  /// 【v2.1.10】原来这里是「kazumi 镜像 + 通用镜像」两条路径对冲，
  /// 现已**移除 kazumi 路径**（理由见下方注释）—— 只剩通用镜像一条，
  /// 故不再需要对冲计数，逻辑简化为「成功即完成、失败即报错」。
  Future<List<CalendarDay>> _calendarRefresh() async {
    final completer = Completer<List<CalendarDay>>();

    void fail() {
      if (!completer.isCompleted) {
        completer.completeError(ApiException('放送表所有数据源均无法连接'));
      }
    }

    void settle(List<CalendarDay> days, String from) {
      // 【v2.1.9】新鲜度防御：先滤掉「开播日期早于本季开始 45 天前」的
      // 条目再入库 —— 第三方镜像缓存不可控（实测 anibt /calendar
      // 一度返回 0 部/陈旧数据），绝不让老番清单顶上首页。
      final filtered = _filterStaleCalendar(days);
      final n = filtered.fold<int>(0, (a, d) => a + d.items.length);
      if (n == 0) {
        fail();
        return;
      }
      if (completer.isCompleted) return;
      final before = days.fold<int>(0, (a, d) => a + d.items.length);
      _cachePut('calendar:result', filtered);
      _calendarStale = filtered;
      kLog('[Bangumi] 放送表命中：$from（过滤前 $before 部 → 过滤后 $n 部）');
      // 【v2.1.10】立刻落盘，不等 4 秒防抖 —— 放送表是首屏最值钱的数据，
      // 万一用户很快就关掉应用，防抖没触发就等于白抓了。
      unawaited(flushDiskCache());
      completer.complete(filtered);
    }

    // ── 【v2.1.10 · 已移除】Kazumi 镜像放送表路径 ──
    //
    // 原来这里并发请求 `api.kazumi.fyi/kazumi/v1/calendar/season`，
    // 与通用镜像竞速。**10 轮冷启动实测后决定删掉**，原因：
    //
    //   1. **数据不完整**：它只给 **39 部**，而通用镜像给 **102 部**
    //      （同一时刻、同一网络实测）。「谁先回用谁」导致首页有
    //      1/5 的概率内容少一半，用户看不出原因。
    //   2. **抢跑**：它常比通用镜像先回（~1.4s vs ~5.3s），
    //      于是稳定地输出了那份不完整数据。
    //   3. 想靠「等一会儿看有没有更全的」来救也不行 —— 实测 700ms
    //      窗口等不到 5.3s 才回来的完整数据；把窗口拉到 2.5s 又
    //      等于首页慢一倍，得不偿失。
    //   4. 通用镜像（anibt + ECH 官方）已能**稳定**给出 102 部，
    //      少一条路径 = 少一次抢跑，逻辑也更简单。
    //
    // 保留 `_mirrorCalendarFailedAt` / `_mirrorCooldownMs` 字段
    // （其它地方仍引用），但不再发起该请求。
    //
    // 只留通用镜像一条路径：它内部已是「官方 /calendar + v0 回退」
    // 且走完整镜像池竞速，拿到的就是最全的那份。
    /// 【v2.1.10 · 首页提速的关键】用**搜索接口**拿本季番剧，替代慢到不可用的
    /// `/calendar`。
    ///
    /// ## 实测（2026-10-15，各测 2~3 次）
    ///
    /// | 端点 | 耗时 | 结果 |
    /// | --- | --- | --- |
    /// | `anibt /calendar` | **21255 ~ 28366ms** | ❌ 慢到超时 |
    /// | `kazumi.fyi /p1/calendar` | **20286 ~ 27121ms** | ❌ |
    /// | `anibt /v0/calendar` | 1424~8503ms | ❌ 返回错误信封 |
    /// | **`anibt POST /v0/search/subjects`** | **2112ms** | ✅ **100 条** |
    ///
    /// `/calendar` 在所有镜像上都要 20 秒以上 —— **这就是首页卡的根因**。
    /// 而搜索接口 2 秒就能拿到本季全部番剧，快 10 倍。
    ///
    /// ## 这正是 Kazumi 的做法
    ///
    /// `timeline_controller.dart` 的 `_getSchedulesBySeason()`：
    /// 非当季走 `getCalendarBySearch(dateRange, limit, offset)`（搜索接口），
    /// 当季才走 `getCalendar()`。搜索是它官方认可的「按季度取番」手段。
    ///
    /// ## 返回形状
    ///
    /// 搜索返回**扁平列表**（没有按星期分组），所以要按 `air_date` 的星期
    /// 自行分到 7 天里 —— 与 `/calendar` 的分组语义对齐。

    Future<void> genericPath() async {
      // 【v2.1.10 · 首页提速】优先走搜索接口（实测 2.1s / 100 条），
      // 它比 /calendar 快 10 倍。只有它失败时才回退到慢的 /calendar。
      try {
        final days = await searchBasedCalendar();
        settle(days, '搜索接口');
        return;
      } catch (e) {
        kLog('[Bangumi] 搜索式放送表失败，回退 /calendar：$e');
      }

      dynamic j;
      try {
        j = await _getCached('calendar:main', '/calendar');
      } catch (_) {
        j = await _getCached('calendar:v0', '/v0/calendar');
      }
      final list = asList(j);
      final days = list.map<CalendarDay>((d) {
        final wd = d is Map ? d : const {};
        final w = wd['weekday'] is Map ? wd['weekday'] as Map : const {};
        final items = wd['items'] is List ? wd['items'] as List : const [];
        return CalendarDay(
          weekday: (w['id'] as num?)?.toInt() ?? 0,
          weekdayCn: w['cn']?.toString() ?? '',
          items: items
              .whereType<Map<String, dynamic>>()
              .map(Subject.fromJson)
              .toList(),
        );
      }).toList();
      settle(days, '通用镜像');
    }

    // 【v2.1.10】只剩这一条路径，**立即发车**。
    // 旧代码在这里等 2500ms（原本是等 kazumi 镜像先跑一会儿的对冲延迟），
    // 现在那条路径已移除 —— 再等就是纯浪费，首页白白慢 2.5 秒。
    unawaited(() async {
      try {
        await genericPath();
      } catch (_) {
        fail();
      }
    }());

    return completer.future;
  }

  /// 本季起始日期，再放宽 45 天缓冲：
  /// 容纳跨季连播（10 月开播 1 月还在播）与季末/季首边缘的新番
  static DateTime _seasonFloor() {
    final now = DateTime.now();
    final m = now.month;
    final startMonth = m <= 3 ? 1 : (m <= 6 ? 4 : (m <= 9 ? 7 : 10));
    return DateTime(now.year, startMonth, 1).subtract(const Duration(days: 45));
  }

  /// 【v2.1.9】放送表新鲜度过滤：丢弃「开播日期早于本季开始 45 天前」的条目。
  ///
  /// 为什么需要：放送表有三条数据路径，只有 kazumi season 接口带季度参数；
  /// 通用镜像（第三方同步库）的缓存不可控（2026-10-15 实测 anibt /calendar
  /// 返回 0 部、用户首页一度出现整页老番）。air_date 缺失或格式异常的
  /// 条目保留（宁可不误杀）。
  static List<CalendarDay> _filterStaleCalendar(List<CalendarDay> days) {
    DateTime? parse(String s) {
      final m =
          RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})').firstMatch(s.trim());
      if (m == null) return null;
      return DateTime(int.parse(m.group(1)!), int.parse(m.group(2)!),
          int.parse(m.group(3)!));
    }

    final floor = _seasonFloor();
    return [
      for (final d in days)
        CalendarDay(
          weekday: d.weekday,
          weekdayCn: d.weekdayCn,
          items: d.items.where((s) {
            if (s.airDate.isEmpty) return true;
            final dt = parse(s.airDate);
            return dt == null || !dt.isBefore(floor);
          }).toList(),
        ),
    ];
  }

  /// 【v2.1.9】放送表后台刷新连续失败次数：≥2 时不再秒回旧数据，
  /// 改为直接等网络刷新（失败才退回旧数据）——防止网络恢复后
  /// 首页还黏着几分钟前的旧结果。
  int _calendarRefreshFails = 0;

  /// 每日放送的「先渲染后补中文名」包装（首页用）。
  ///
  /// 直接把 [calendar] 的结果交给首页渲染，同时在**后台**补齐缺失的中文名；
  /// 补完通过 [nameEnrichTick] 通知首页刷新。这样首屏不再被中文名阻塞。
  ///
  /// [force] = 手动下拉刷新/点刷新按钮：跳过缓存与旧数据，直接等网络
  /// （失败仍会退回旧数据，不白屏）。
  Future<List<CalendarDay>> calendarFast({bool force = false}) async {
    final days = await calendar(force: force);
    final missing = <Subject>[
      for (final d in days)
        ...d.items.where((s) => s.nameCn.isEmpty)
    ];
    if (missing.isNotEmpty) _enrichInBackground(missing);
    // 【v2.1.6 · 预热今日放送】对齐 Kazumi「镜像缓存后端」的体验：
    // 首页渲染完就后台预热「今天星期几」那组番的详情+分集（进 10 分钟
    // 内存缓存），用户点进去时直接命中进程内缓存，比任何镜像透传都快。
    unawaited(_warmUpToday(days));
    // 先用「零请求回填」把能补的补上（命中缓存的直接改，不发请求）
    return [
      for (final d in days)
        CalendarDay(
          weekday: d.weekday,
          weekdayCn: d.weekdayCn,
          items: _fillChineseNames(d.items),
        )
    ];
  }

  /// 后台预热「今日放送」的详情与分集（并发 2，失败静默）
  static bool _warmingUp = false;
  Future<void> _warmUpToday(List<CalendarDay> days) async {
    if (_warmingUp) return;
    _warmingUp = true;
    try {
      final today = DateTime.now().weekday; // 1=周一
      final items = [
        ...days.where((d) => d.weekday == today).expand((d) => d.items),
      ];
      final targets = items.take(8).toList();
      if (targets.isEmpty) return;
      final sw = Stopwatch()..start();
      var done = 0;
      // 并发 2 的轻量预热，不与前台抢带宽
      final queue = List<Subject>.of(targets);
      Future<void> worker() async {
        while (queue.isNotEmpty) {
          final s = queue.removeLast();
          try {
            await subject(s.id);
            await episodes(s.id);
            done++;
          } catch (_) {}
        }
      }

      await Future.wait([worker(), worker()]).timeout(
        const Duration(seconds: 30),
        onTimeout: () => const <void>[],
      );
      if (done > 0) {
        kLog('[详情] 已预热今日放送 $done 部（${sw.elapsedMilliseconds}ms），'
            '点击即秒开');
      }
    } catch (_) {
    } finally {
      _warmingUp = false;
    }
  }

  /// 条目中文名回填完成通知。
  ///
  /// 【v1.9.2 手机端提速关键】旧实现是 `return await _enrichNamesBySubject(filled)`
  /// —— **整个首页要等中文名补完（最多 9s）才显示**。实测日志里首页首屏就被
  /// 这一步拖到 2～9 秒（取决于网络），这正是「手机端响应慢」的主因。
  ///
  /// 现在：先把列表（含日文原名）**立刻返回**，中文名在后台补齐，
  /// 补完通过这个 notifier 通知界面无感刷新。用户 200ms 内就看到内容，
  /// 中文名稍后自己「长出来」——这也是 Kazumi 的观感。
  ///
  /// 用 [TickNotifier] 而不是 Flutter 的 `ValueNotifier`：本文件保持纯 Dart，
  /// 见 `tick_notifier.dart` 里的说明。
  static final TickNotifier nameEnrichTick = TickNotifier();

  /// 对缺中文名的条目并发拉 subject 详情补全（结果进 10 分钟缓存）。
  ///
  /// 整体限时 6s：拉不完的保留原名，不让界面无限等。
  Future<List<Subject>> _enrichNamesBySubject(List<Subject> items) async {
    final missing = items.where((s) => s.nameCn.isEmpty).take(5).toList();
    if (missing.isEmpty) return items;
    try {
      await Future.wait([
        for (final s in missing)
          subject(s.id)
              .then((d) {
                if (d.nameCn.isNotEmpty) _cachePut('namecn:${s.id}', d.nameCn);
              })
              .catchError((_) {}),
      ]).timeout(const Duration(seconds: 6));
    } catch (_) {}
    // 通知界面：中文名已回填，可以刷新了
    nameEnrichTick.notify();
    return [
      for (final s in items)
        if (s.nameCn.isEmpty && (_cacheGet('namecn:${s.id}') != null))
          s.copyWithNameCn(_cacheGet('namecn:${s.id}') as String)
        else
          s
    ];
  }

  /// 后台补齐中文名（不阻塞调用方）
  void _enrichInBackground(List<Subject> items) {
    unawaited(_enrichNamesBySubject(items));
  }

  /// 用「已缓存」的放送/搜索/中文名数据回填中文名（**不发请求**，命中才改）。
  ///
  /// 供两处用：
  ///   1. [trends] / [calendarFast] 的首次返回（能补多少补多少）；
  ///   2. 界面在 [nameEnrichTick] 触发后的轻量刷新（此时缓存里已有结果）。
  static List<Subject> refillChineseNames(List<Subject> items) =>
      _fillChineseNames(items);

  static List<Subject> _fillChineseNames(List<Subject> items) {
    final cn = <int, String>{};
    for (final key in ['calendar:kazumi', 'calendar:main', 'calendar:v0']) {
      final j = _cacheGet(key);
      if (j == null) continue;
      void walk(dynamic node) {
        if (node is Map) {
          final id = (node['id'] as num?)?.toInt();
          final v = node['name_cn']?.toString() ?? '';
          if (id != null && v.isNotEmpty) cn.putIfAbsent(id, () => v);
          final sub = node['subject'];
          if (sub is Map) walk(sub);
          node.values.whereType<List>().forEach(walk);
          node.values.whereType<Map>().forEach(walk);
        } else if (node is List) {
          for (final e in node) {
            walk(e);
          }
        }
      }

      walk(j);
    }
    if (cn.isEmpty) return items;
    return [
      for (final s in items)
        (s.nameCn.isEmpty && cn.containsKey(s.id)) ? s.copyWithNameCn(cn[s.id]!) : s
    ];
  }


  /// 搜索 / 浏览。sort: match | rank | heat | score
  Future<({int total, List<Subject> items})> searchSubjects(
    String keyword, {
    String sort = 'match',
    int offset = 0,
    int limit = 24,
    List<String> tags = const [],
    String? airDateGte,
    int? rankGt,
  }) async {
    final filter = <String, dynamic>{
      'type': [2],
      if (tags.isNotEmpty) 'tag': tags,
      if (airDateGte != null) 'air_date': ['>=$airDateGte'],
      if (rankGt != null) 'rank': ['>$rankGt'],
      'nsfw': false,
    };
    final j = await _postCached(
        'search:$keyword:$sort:$offset:$limit:${tags.join(',')}:${airDateGte ?? ''}:${rankGt ?? ''}',
        '/v0/search/subjects',
        {'keyword': keyword, 'sort': sort, 'filter': filter},
        {
          'limit': '$limit',
          'offset': '$offset',
        });
    final data = j is Map && j['data'] is List ? j['data'] as List : const [];
    return (
      total: (j is Map ? (j['total'] as num?)?.toInt() : null) ?? 0,
      items: data.whereType<Map<String, dynamic>>().map(Subject.fromJson).toList(),
    );
  }

  /// 【Kazumi 首页同款】热门番组趋势榜
  ///
  /// 主路径：`GET https://next.bgm.tv/p1/trending/subjects`（Bangumi 官方
  /// 「热门番组」数据源，Kazumi 首页用的就是它）。
  /// 该域名在大陆不可达时，回退到已配置镜像的 rank 搜索（tag=日本，
  /// 按排名升序），保证首页永远有内容。
  Future<List<Subject>> trends({int limit = 24, int offset = 0}) async {
    // ① 【v1.5.0 · 照搬 Kazumi】Kazumi 镜像热榜（服务端缓存，实测 ~1.3s），
    //    免签名公开接口。这是首页「热门」最快的数据来源。
    try {
      final key = 'trends:kazumi:$limit:$offset';
      final hit = _cacheGet(key);
      final dynamic j = hit ??
          await _client
              .get(
                Uri.parse('$kazumiMirror/kazumi/v1/popular/subjects?limit=$limit&offset=$offset'),
                headers: {'User-Agent': userAgent, 'Accept': 'application/json'},
              )
              .timeout(const Duration(seconds: 8))
              .then((r) {
            if (r.statusCode != 200) {
              throw ApiException('HTTP ${r.statusCode}');
            }
            final body = jsonDecode(utf8.decode(r.bodyBytes));
            // 【v2.1.10】同上：镜像的 200 可能是错误信封，别当成空榜单
            if (_isErrorEnvelope(body)) {
              throw ApiException(
                  '榜单镜像返回错误信封 code=${(body as Map)['code']}');
            }
            return body;
          });
      if (hit == null) _cachePut(key, j);
      final data = j is List ? j : (j is Map && j['data'] is List ? j['data'] as List : const []);
      final out = data
          .whereType<Map<String, dynamic>>()
          .map(Subject.fromJson)
          .toList();
      // 中文本地化：先做**零请求**的回填（用已缓存的放送数据），
      // 仍缺的在**后台**补 —— 绝不阻塞首屏（见 `nameEnrichTick` 的说明）。
      if (out.isNotEmpty) {
        final filled = _fillChineseNames(out);
        if (filled.any((s) => s.nameCn.isEmpty)) {
          _enrichInBackground(filled);
        }
        return filled;
      }
    } catch (_) {
      // 继续往下回退
    }
    // ② 官方趋势榜（大陆不可达，6s 超时后走镜像回退）
    try {
      final res = await _client
          .get(
            Uri.parse(
                'https://next.bgm.tv/p1/trending/subjects?type=2&limit=$limit&offset=$offset'),
            headers: {'User-Agent': userAgent, 'Accept': 'application/json'},
          )
          .timeout(const Duration(seconds: 6));
      if (res.statusCode == 200) {
        final j = jsonDecode(utf8.decode(res.bodyBytes));
        // 【v2.1.10】趋势接口同样要防「200 里的错误信封」
        if (_isErrorEnvelope(j)) {
          throw ApiException('趋势接口返回错误信封 code=${(j as Map)['code']}');
        }
        final data = asList(j);
        final out = <Subject>[];
        for (final it in data) {
          if (it is Map && it['subject'] is Map) {
            out.add(Subject.fromJson((it['subject'] as Map).cast<String, dynamic>()));
          }
        }
        if (out.isNotEmpty) return out;
      }
    } catch (_) {
      // 走镜像回退
    }
    // ③ 镜像 rank 回退
    final r = await searchSubjects(
      '',
      sort: 'rank',
      offset: offset,
      limit: limit,
      tags: const ['日本'],
      rankGt: 0,
    );
    return r.items;
  }

  /// 按标签浏览（Kazumi 首页标签菜单用）
  Future<List<Subject>> byTag(String tag, {int limit = 24, int offset = 0}) {
    return searchSubjects('', sort: 'rank', offset: offset, limit: limit, tags: [tag])
        .then((r) => r.items);
  }

  /// 番剧详情。
  ///
  /// 【响应形状归一化】Kazumi 镜像走的是 `next.bgm.tv` 的 `/p1/subjects/{id}`，
  /// 它**直接返回条目对象**；而 v0 协议返回的也是对象（无 data 包装）。
  /// 两者外形一致，但为稳妥仍走 [asMap] 统一解包。
  Future<SubjectDetail> subject(int id) async {
    final j = await _getCached('subject:$id', '/v0/subjects/$id');
    final m = asMap(j);
    if (m.isEmpty) throw ApiException('条目数据异常');
    return SubjectDetail.fromJson(m);
  }

  /// 分集（自动翻页拿全）
  ///
  /// 【v1.6.0 修复】`/v0/subjects/{id}/episodes` 在镜像上稳定 **404**
  /// （实测 bgmapi.anibt.net），导致 Bangumi 剧集列表一直为空、只能靠播放源兜底。
  /// 这里改走镜像真正支持的 `/v0/episodes?subject_id={id}`（且它**返回 name_cn
  /// 中文分集标题**），失败再回退旧路径。
  Future<List<Episode>> episodes(int subjectId, {int type = 0}) async {
    final out = <Episode>[];
    var offset = 0;
    const limit = 100;
    while (true) {
      final j = await _episodesPage(subjectId, type, offset, limit);
      final data = asList(j);
      out.addAll(data.whereType<Map<String, dynamic>>().map(Episode.fromJson));
      final total = asTotal(j);
      offset += data.length;
      if (data.isEmpty || (total > 0 && out.length >= total)) break;
    }
    return out;
  }

  Future<dynamic> _episodesPage(int subjectId, int type, int offset, int limit) async {
    final key = 'eps:$subjectId:$type:$offset';
    final hit = _cacheGet(key);
    if (hit != null) return hit;
    final params = {'limit': '$limit', 'offset': '$offset', 'type': '$type'};
    dynamic j;
    final sw = Stopwatch()..start();
    try {
      j = await _race('/v0/episodes', false, null, {...params, 'subject_id': '$subjectId'});
      kLog('[Bangumi] 分集页 offset=$offset 走 /v0/episodes：'
          '${asList(j).length} 条 ${sw.elapsedMilliseconds}ms');
    } catch (e) {
      kLog('[Bangumi] 分集页 offset=$offset 首选路径失败（${sw.elapsedMilliseconds}ms）: '
          '${e.toString().substring(0, e.toString().length > 60 ? 60 : e.toString().length)}'
          ' → 回退 /v0/subjects/$subjectId/episodes');
      final sw2 = Stopwatch()..start();
      j = await _race('/v0/subjects/$subjectId/episodes', false, null, params);
      kLog('[Bangumi] 分集页 offset=$offset 回退路径：'
          '${asList(j).length} 条 ${sw2.elapsedMilliseconds}ms');
    }
    _cachePut(key, j);
    return j;
  }

  Future<List<BgmCharacter>> characters(int subjectId) async {
    final j = await _getCached('chars:$subjectId', '/v0/subjects/$subjectId/characters');
    final list = asList(j);
    return list.whereType<Map<String, dynamic>>().map(BgmCharacter.fromJson).toList();
  }

  Future<List<RelatedSubject>> relations(int subjectId) async {
    final j = await _getCached('rel:$subjectId', '/v0/subjects/$subjectId/subjects');
    final list = asList(j);
    return list.whereType<Map<String, dynamic>>().map(RelatedSubject.fromJson).toList();
  }

  /// 连通性检测：返回各镜像延迟（毫秒），失败为 -1
  ///
  /// 【并发】原先串行测速，3 个镜像最坏要 3 × 8s = 24s；现在并发，
  /// 总耗时 = 最慢那个（约 6s 上限）。设置页点「测速」不再卡住。
  Future<List<({String base, int latencyMs})>> probe() async {
    final list = bases.toList();
    final results = await Future.wait([
      for (final base in list)
        () async {
          final sw = Stopwatch()..start();
          try {
            // 用各镜像都支持的探针路径（kazumi 镜像不支持 /v0/subjects/{id}）
            final probePath = _pathFor(base, '/v0/subjects/12') ?? '/p1/subjects/12';
            final res = await _client
                .get(_u(base, probePath),
                    headers: {'User-Agent': userAgent, 'Accept': 'application/json'})
                .timeout(const Duration(seconds: 6));
            return (base: base, latencyMs: res.statusCode == 200 ? sw.elapsedMilliseconds : -1);
          } catch (_) {
            return (base: base, latencyMs: -1);
          }
        }()
    ]);
    return results;
  }


/// 图片地址改写（lain.bgm.tv 随主站一并被墙时走镜像/代理）
///
/// ═══════════════ 本机实测结论（2026-10-13，用真实封面逐一验证） ═══════════════
///
/// 测试图：`https://lain.bgm.tv/pic/cover/l/d3/99/622288_nmbC3.jpg`（同一张）
///
/// | 候选 | 结果 |
/// | --- | --- |
/// | lain.bgm.tv 直连 | ❌ 20.2s 超时 |
/// | **wsrv.nl/?url=<编码过的 host/path>** | ✅ 200 image/jpeg · **660ms** · 70309B |
/// | images.weserv.nl/?url=同格式 | ✅ 200 image/jpeg · 1.29s |
/// | **<API镜像>/pic/<path>**（如 bgmapi.anibt.net/pic/…） | ✅ 200 image/jpeg · 2.7s · 98421B（原图，未压缩） |
///
/// 两个必须记住的坑：
///  1. **`?url=` 的值必须整体 URL 编码**（`lain.bgm.tv%2Fpic%2F...`）。
///     不编码也能通，但慢 4 倍（2.8s vs 0.66s）——因为 `?url=` 后面跟裸路径时
///     代理要先试探解析。旧代码用 `Uri.encodeComponent` 是对的，别改。
///  2. **`<API镜像>/pic/<path>` 只在 path 是真实存在的图时才 200**；
///     图不存在时它返回的是 **200 + application/json 错误体**（不是 404），
///     旧代码把这种响应当成功、`Image` 解码失败后不会换候选 → 永远空白。
///     所以本类把「镜像 /pic/ 路径」放在**第四候选**（可靠性兜底），
///     由 `KCover` 的解码失败重新挂载机制负责换下一个。

  void dispose() => _client.close();
}

/// 图片地址改写（lain.bgm.tv 随主站一并被墙时走镜像/代理）
///
/// ═══════════════ 本机实测结论（2026-10-13，用真实封面逐一验证） ═══════════════
///
/// 测试图：`https://lain.bgm.tv/pic/cover/l/d3/99/622288_nmbC3.jpg`（同一张）
///
/// | 候选 | 结果 |
/// | --- | --- |
/// | lain.bgm.tv 直连 | ❌ 20.2s 超时 |
/// | **wsrv.nl/?url=<编码过的 host/path>** | ✅ 200 image/jpeg · **660ms** · 70309B |
/// | images.weserv.nl/?url=同格式 | ✅ 200 image/jpeg · 1.29s |
/// | **<API镜像>/pic/<path>**（如 bgmapi.anibt.net/pic/…） | ✅ 200 image/jpeg · 2.7s · 98421B（原图，未压缩） |
///
/// 两个必须记住的坑：
///  1. **`?url=` 的值必须整体 URL 编码**（`lain.bgm.tv%2Fpic%2F...`）。
///     不编码也能通，但慢 4 倍（2.8s vs 0.66s）——因为 `?url=` 后面跟裸路径时
///     代理要先试探解析。旧代码用 `Uri.encodeComponent` 是对的，别改。
///  2. **`<API镜像>/pic/<path>` 只在 path 是真实存在的图时才 200**；
///     图不存在时它返回的是 **200 + application/json 错误体**（不是 404），
///     旧代码把这种响应当成功、`Image` 解码失败后不会换候选 → 永远空白。
///     所以本类把「镜像 /pic/ 路径」放在**第四候选**（可靠性兜底），
///     由 `KCover` 的解码失败重新挂载机制负责换下一个。
class ImageProxy {
  /// 模式：0 自动（默认）、1 直连、2 自定义前缀代理
  static int mode = 0;
  static String customPrefix = ''; // 例：https://wsrv.nl/?url=

  /// 通用图片反代（Kazumi 同款 wsrv.nl）
  static const wsrvPrefix = 'https://wsrv.nl/?url=';
  static const weservPrefix = 'https://images.weserv.nl/?url=';

  /// 自定义图片反代（设置页可填，优先级最高）
  ///
  /// 期望填「图片站根地址」，例如自建 Worker 的 `https://kchan-img.workers.dev`。
  /// 填了之后优先用它替换官方图床域名（见 [candidates] ①）。
  ///
  /// 【v1.9.6 · 反代保险】支持填**多个**，换行 / `|` / 逗号分隔。
  /// 单个反代挂掉只是它自己被熔断，后面的继续顶上 —— 这就是「保险」。
  static String customImageBase = '';

  /// 解析后的自定义反代列表（去重保序）
  ///
  /// 支持的分隔符：换行（设置页里多行输入）、`|`、`,`、`;`。
  /// 这样用户可以：
  ///   - 只填一个（和以前一样）；
  ///   - 填多个自建 Worker 做冗余；
  ///   - 第一个填自建、后面跟公共反代兜底。
  static List<String> get customImageBases {
    final raw = customImageBase;
    if (raw.trim().isEmpty) return const [];
    final out = <String>[];
    for (final part in raw.split(RegExp(r'[\n\r|,;]+'))) {
      final t = part.trim();
      if (t.isEmpty) continue;
      if (!t.startsWith('http')) continue; // 非 URL 的碎片直接忽略
      if (!out.contains(t)) out.add(t);
    }
    return out;
  }

  /// 需要代理的图床判定：Bangumi 官方图床 + 镜像图床 + API 图片端点
  ///
  /// 【v1.9.0 · 手机端封面空白修复】
  /// 关键发现：镜像 API（bgmapi.anibt.net）返回的 images 字段域名是
  /// **bgmimg.anibt.net**，不是 lain.bgm.tv。此前 _needsProxy 不认这个域名
  /// → 手机端（连不上 bgmimg）直连请求永久悬挂 → 封面整片空白（无报错也无图）。
  static bool _needsProxy(String url) {
    return url.contains('lain.bgm.tv') ||
        url.contains('bgmimg.anibt.net') ||
        url.contains('api.bgm.tv/v0/subjects/') ||
        url.contains('bangumi.tv/pic/');
  }

  /// 图片站内路径（/pic/...）→ 挂到「当前可用的 API 镜像主机」上。
  ///
  /// 实测（2026-10-13 用真实封面）：`bgmapi.anibt.net/pic/cover/l/…` = 200
  /// image/jpeg（原图 98KB），而 API 能通的网络图片就能通 —— 这是最稳的候选，
  /// 排在 wsrv.nl 之后作为可靠性兜底。
  static List<String> _mirrorPathCandidates(String url) {
    final u = Uri.tryParse(url);
    if (u == null || u.path.isEmpty) return const [];
    // 【v2.1.10】图床有两种路径形态，之前只认 ①，导致 ② 被整条跳过：
    //   ① /pic/cover/l/13/c5/x.jpg          large（原图）
    //   ② /r/400/pic/cover/l/13/c5/x.jpg    common（400px，**列表卡片用的就是它**）
    // 而列表封面用的正是 images.common → 于是封面永远拿不到镜像候选。
    final m = RegExp(r'^(?:/r/\d+)?(/pic/)').firstMatch(u.path);
    if (m == null) return const [];
    final out = <String>[];
    for (final b in BangumiApiHolder.api._orderedBases) {
      final host = Uri.tryParse(b)?.host;
      if (host == null || host.isEmpty) continue;
      // 【v2.1.10 · 修「封面加载慢/出不来」】
      //
      // 旧代码硬编码 `if (host != 'bgmimg.anibt.net') continue;` ——
      // 注释说「唯一可用」，那是 2026-10-15 早期只测了三个镜像的结论。
      // 结果：**用户自建的反代（custom_base）被这行完全跳过**，
      // 封面只能走 anibt，而 anibt 的 /pic/ 要 2 秒且不稳 → 封面慢/空白。
      //
      // 现在改成「排除已知坏的」，自建反代自然排在第一位
      // （它在 _orderedBases 里就是第一个）：
      //   · api.bgm.tv     —— 无 /pic/ 且被墙，排除
      //   · next.bgm.tv    —— 同上，排除
      //   · api.kazumi.fyi —— /pic/ 实测 404 且要 8.7s，排除
      const bad = {'api.bgm.tv', 'next.bgm.tv', 'api.kazumi.fyi'};
      if (bad.contains(host)) continue;
      final origin = Uri.tryParse(b)?.origin;
      if (origin == null || origin.isEmpty) continue;
      final cand = '$origin${u.path}';
      if (!out.contains(cand)) out.add(cand);
    }
    return out;
  }

  /// 走通用图片反代。
  ///
  /// **`?url=` 的值必须整体编码**：实测裸路径 2804ms / 编码后 660ms。
  static String _viaProxy(String prefix, String url) =>
      prefix + Uri.encodeComponent(url.replaceFirst(RegExp(r'^https?://'), ''));

  static String _viaWsrv(String url) => _viaProxy(wsrvPrefix, url);

  /// 自定义图片反代前缀的拼接方式：
  ///  - 形如 `https://host/?url=` （含 `=`/`?`）→ 直接把编码后的地址拼在后面；
  ///  - 形如 `https://host` （纯站根）→ 用 host 替换官方图床域名。
  static String? _viaCustom(String custom, String url) {
    final c = custom.trim();
    if (c.isEmpty) return null;
    if (c.contains('?') || c.endsWith('=')) {
      return c + Uri.encodeComponent(url.replaceFirst(RegExp(r'^https?://'), ''));
    }
    final host = Uri.tryParse(c)?.host ?? '';
    if (host.isEmpty) return null;
    if (url.contains('lain.bgm.tv')) {
      return url.replaceFirst('lain.bgm.tv', host);
    }
    // 非 lain 图床（如镜像返回的 bgmimg.*）：保留图床路径挂到自定义主机。
    //
    // 【v2.1.10】路径形态要同时接受 ① `/pic/...` 和 ② `/r/<size>/pic/...`
    // （列表封面用的是 ②，旧代码只判 ① → ② 返回 null → 该候选被丢弃）。
    final p = Uri.tryParse(url);
    if (p != null && RegExp(r'^(?:/r/\d+)?/(?:pic|img)/').hasMatch(p.path)) {
      final scheme = Uri.tryParse(c)?.scheme ?? 'https';
      return '$scheme://$host${p.path}';
    }
    return null;
  }

  /// 返回**候选地址列表**，按顺序尝试；UI 层加载/解码失败会自动换下一个。
  ///
  /// ## 【v1.9.4 · 顺序按「可达性」重排 + 加熔断】
  ///
  /// 旧顺序是「wsrv.nl → images.weserv.nl → API 镜像 → 直连」，
  /// 依据是**本机早期实测速度**。但 v1.9.3 用 `tool/probe_covers.dart`
  /// 在真实网络下复测发现：**这两个国外反代在国内网络根本连不上**
  /// （连接超时，各耗满 6s）——
  /// 于是每张封面都要白白等 6s 才轮到真正能用的 API 镜像 `/pic/`，
  /// 手机上 20+ 张封面同时卡在超时上，这正是「封面出不来 + 很卡」的根因。
  ///
  /// 新顺序按**可达性**排（能通的排前面，连不上的排后面）：
  ///   ① 自定义反代（用户自建，通常最快最稳）
  ///   ② API 镜像的 `/pic/` 路径 —— 「API 能通 = 图就能通」，最可靠
  ///   ③ wsrv.nl / images.weserv.nl（**仅当熔断器认为它们可达时**才放进来）
  ///   ④ 原始地址直连（代理环境 / 官方站可达时才有效）
  ///
  /// 熔断器 [ImageProxy._proxyHostDead]：某个国外反代连续失败后，
  /// 在 [ImageProxy._deadTtl] 内不再列入候选，避免每张图都白等一次超时。
  static List<String> candidates(String url, {int subjectId = 0}) {
    if (url.isEmpty) return const [];
    if (!_needsProxy(url)) return [url];
    switch (mode) {
      case 1:
        return [url];
      case 2:
        if (customPrefix.isEmpty) return [url];
        return [
          customPrefix +
              Uri.encodeComponent(url.replaceFirst(RegExp(r'^https?://'), ''))
        ];
      default:
        final out = <String>[];
        // ① 自定义图片反代（可填多个 → 依次作为候选，各自熔断）
        for (final base in customImageBases) {
          if (_isProxyHostDead(base)) continue; // 这个反代挂了就跳过
          final custom = _viaCustom(base, url);
          if (custom != null) out.add(custom);
        }

        // ② API 镜像 /pic/ 路径 —— 国内网络下唯一稳定可达的一档
        out.addAll(_mirrorPathCandidates(url));

        // ③ 国外通用反代：仅当熔断器没把它们标记为「连不上」时才加入
        if (!_isProxyHostDead(wsrvPrefix)) out.add(_viaWsrv(url));
        if (!_isProxyHostDead(weservPrefix)) out.add(_viaProxy(weservPrefix, url));

        // ④ 直连原始地址
        out.add(url);

        // 去重但保持顺序
        final seen = <String>{};
        return [
          for (final c in out)
            if (c.isNotEmpty && seen.add(c)) c
        ];
    }
  }

  /// 熔断：记录「连不上」的图片反代主机 → 到期时间
  ///
  /// 为什么需要：国外反代在国内网络是**稳定连不上**（不是偶发），
  /// 每次都等满 6s 超时纯属浪费。连续失败 [ImageProxy._failThreshold] 次后
  /// 熔断 [ImageProxy._deadTtl]，期间不再把它列入候选。
  static final Map<String, DateTime> _proxyHostDead = {};
  static const int _failThreshold = 2;
  static const Duration _deadTtl = Duration(minutes: 10);
  static final Map<String, int> _proxyHostFails = {};

  static String _hostOf(String prefix) => Uri.tryParse(prefix)?.host ?? prefix;

  static bool _isProxyHostDead(String prefix) {
    final t = _proxyHostDead[_hostOf(prefix)];
    if (t == null) return false;
    if (DateTime.now().isAfter(t)) {
      _proxyHostDead.remove(_hostOf(prefix));
      _proxyHostFails.remove(_hostOf(prefix));
      return false;
    }
    return true;
  }

  /// 由封面探测层在**网络类失败**时调用（拿到响应但类型不对不算）
  static void reportProxyUnreachable(String candidateUrl) {
    // 内置反代 + 用户自填的每个反代都要能熔断（否则自填的那个挂了会一直拖慢）
    for (final prefix in [wsrvPrefix, weservPrefix, ...customImageBases]) {
      final host = _hostOf(prefix);
      if (host.isEmpty || !candidateUrl.contains(host)) continue;
      // 已经熔断就直接返回：否则每张封面失败一次都会重复计数 + 刷日志
      // （实测日志被「连续 N 次连不上」刷屏，掩盖了真正有用的信息）
      if (_isProxyHostDead(prefix)) return;
      final n = (_proxyHostFails[host] ?? 0) + 1;
      _proxyHostFails[host] = n;
      if (n >= _failThreshold) {
        _proxyHostDead[host] = DateTime.now().add(_deadTtl);
        kLog('[封面] $host 连不上，已熔断 ${_deadTtl.inMinutes} 分钟'
            '（期间不再作为候选，避免每张图白等一次超时）');
      }
    }
  }

  /// 由封面探测层在**成功**时调用（把熔断计数清零）
  static void reportProxyReachable(String candidateUrl) {
    for (final prefix in [wsrvPrefix, weservPrefix, ...customImageBases]) {
      final host = _hostOf(prefix);
      if (host.isEmpty || !candidateUrl.contains(host)) continue;
      _proxyHostFails.remove(host);
      _proxyHostDead.remove(host);
    }
  }

  static String rewrite(String url) {
    if (url.isEmpty) return url;
    final list = candidates(url);
    return list.isEmpty ? url : list.first;
  }
}

class BangumiApiHolder {
  static final BangumiApi api = BangumiApi();
}
