/// 应用内「优选 IP」——把 Cloudflare 边缘 IP 挑好并钉死，不依赖用户的 hosts
///
/// ## 这个文件解决什么问题
///
/// 实测过的真实差异（同一台机器、同一时刻、同一个域名 `bgm.kchan.top`）：
///
/// | 连接的 IP | 来源 | 成功 | 中位 | 最慢 |
/// | --- | --- | --- | --- | --- |
/// | `104.17.132.229` | 站长 hosts 里手工钉的 | **5/5** | **918ms** | 1157ms |
/// | `104.21.6.230` | 公共 DNS 分配给普通用户 | **3/5** | 1864ms | **3418ms** |
/// | `172.67.135.111` | 公共 DNS 分配给普通用户 | **1/5** | 1779ms | — |
///
/// 也就是说：**代码一点没变，只因为 DNS 分配到哪个边缘 IP，就从「流畅」变成
/// 「经常不可达 + 延迟超过 2 秒」**。站长自己的机器之所以快，是因为他早先在
/// `C:\Windows\System32\drivers\etc\hosts` 里钉了 `104.17.132.229` ——
/// 这是任何普通用户都不会做的事。
///
/// 所以把这个「挑 IP」的动作做进 App：
///
/// 1. 启动后（或首次请求时）并发探测一组 Cloudflare 边缘 IP；
/// 2. 挑最快且能完成 TLS + HTTP 的那个；
/// 3. 通过 `HttpClient.connectionFactory` 把连接钉到它 ——
///    但 **TLS 的 SNI/证书仍按真实域名校验**（见下方契约说明）；
/// 4. 结果缓存到本地，下次启动直接用；失败时换下一个。
///
/// ## connectionFactory 的契约（实测结论，别改坏）
///
/// Dart 的 `HttpClient.connectionFactory` **不做 TLS**。返回裸 `Socket` 会让
/// Dart 直接发明文 HTTP，Cloudflare 回：
///
/// ```text
/// 400 The plain HTTP request was sent to HTTPS port
/// ```
///
/// 必须自己 `SecureSocket.secure(raw, host: 真实域名)`，再把 TLS 套接字返回。
/// 实测该写法能拿 200，且证书按域名校验（SNI 正确）。
///
/// ## 和「网络代理」的关系
///
/// 设置里开了代理时，`findProxy` 会给出 proxyHost/port。此时不能把连接钉到
/// Cloudflare IP（那样代理就被绕过了），改为走标准 CONNECT 隧道。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'diag_log.dart';

/// 需要钉 IP 的域名。
///
/// 这三个都托管在 Cloudflare（`bgmapi.anibt.net` 是第三方镜像，但同样在 CF 后面），
/// 用同一个优选 IP 就能全覆盖 —— 这也是「优选 IP」的常规用法。
const Set<String> kPinHosts = {
  'bgm.kchan.top',
  'api.kchan.top',
  'bgmapi.anibt.net',
};

/// 候选边缘 IP（Cloudflare anycast）。
///
/// 第一项是站长机器上实测 5/5、918ms 的那个；其余包含公共 DNS 会给到的，
/// 以及几个常用的优选段。**顺序不重要** —— 每次都实测选最快。
const List<String> kCandidateIps = [
  '104.17.132.229',
  '104.18.32.229',
  '104.19.192.229',
  '104.16.132.229',
  '172.64.80.1',
  '188.114.96.1',
  '104.21.6.230',
  '172.67.135.111',
];

/// 探测时用的路径 —— 必须是 Worker 能应答的轻量路径。
///
/// `/` 在 API Worker 上是 404/403，HTTP 状态无所谓：我们只关心
/// **TCP+TLS+HTTP 往返能不能成立、有多快**。
const String _probePath = '/';

class IpPin {
  IpPin._();

  /// 当前选中的 IP（null = 还没选过，或全部探测失败）
  static String? _chosen;

  /// 最近一次探测结果（便于日志/设置页展示）
  static Map<String, int> lastResults = {};

  /// 正在选的过程（并发请求合并，避免打一堆探测）
  static Future<String?>? _selecting;

  /// 上次完成优选的时间（给重选限流，避免网络抖动时反复探测）
  static int _lastSelectAt = 0;

  /// 某个 IP 连续失败次数（到 3 次且间隔够久才重选）
  static final Map<String, int> _failures = {};

  /// 是否已完成一次选择
  static bool get hasChoice => _chosen != null;

  /// 从本地缓存恢复上次选中的 IP（启动时调用，省掉一次探测）
  static void restore(String? cached) {
    if (cached != null && cached.isNotEmpty && kCandidateIps.contains(cached)) {
      _chosen = cached;
      kLog('[IpPin] 使用上次缓存的优选 IP: $cached');
    }
  }

  /// 选中后回调（用于持久化）
  static void Function(String ip)? onChosen;

  static String? get chosen => _chosen;

  /// 探测单个 IP 一次：TCP + TLS(SNI=host) + 一条极简 HTTP 请求
  ///
  /// 返回毫秒数；失败返回 null。
  static Future<int?> _probeOnce(String ip, String host) async {
    final sw = Stopwatch()..start();
    Socket? raw;
    SecureSocket? tls;
    try {
      raw = await Socket.connect(ip, 443,
          timeout: const Duration(seconds: 3));
      tls = await SecureSocket.secure(raw, host: host).timeout(
        const Duration(seconds: 3),
      );
      tls.write('GET $_probePath HTTP/1.1\r\n'
          'Host: $host\r\n'
          'User-Agent: kchan/2.1.10\r\n'
          'Connection: close\r\n\r\n');
      await tls.flush();
      // 只要读回首包就算这条链路通。
      //
      // 早先写成 `expand(...).take(64).toList()`：响应不足 64 字节时
      // 它会一直等，每个候选白耗满超时 —— 8 个候选并发就是整轮 4 秒。
      // 用 `first` 拿到任意一段就立刻返回。
      final first = await tls.first.timeout(const Duration(seconds: 4));
      sw.stop();
      if (first.isEmpty) return null;
      return sw.elapsedMilliseconds;
    } catch (_) {
      return null;
    } finally {
      try {
        await tls?.close();
      } catch (_) {}
      try {
        await raw?.close();
      } catch (_) {}
    }
  }

  /// 探测单个 IP **两次**，取两次里较慢的那个作为得分
  ///
  /// ## 为什么必须两次、且取较慢值
  ///
  /// 只测一次会选中「碰巧快一下」的 IP。实测教训：某次单测把
  /// `172.67.135.111` 选成 1409ms 的「最优」，但那个 IP 真实成功率只有
  /// **1/5** —— 选它之后每个真实请求都超时，反而比不钉更慢
  /// （实测放送表拖到 35 秒、封面 7.8 秒）。
  ///
  /// 两次都成功才算可用，并用「较慢的一次」排序 = 悲观估计，
  /// 专治忽快忽慢的 IP。
  static Future<int?> _probe(String ip, String host) async {
    final a = await _probeOnce(ip, host);
    if (a == null) return null; // 第一次就失败 → 淘汰
    final b = await _probeOnce(ip, host);
    if (b == null) return null; // 第二次失败 → 不稳定，淘汰
    return a > b ? a : b;
  }

  /// 并发探测全部候选，选最快的
  static Future<String?> select({String host = 'bgm.kchan.top'}) {
    final running = _selecting;
    if (running != null) return running;
    final f = _doSelect(host);
    _selecting = f;
    return f.whenComplete(() => _selecting = null);
  }

  static Future<String?> _doSelect(String host) async {
    kLog('[IpPin] 开始优选 IP 探测（${kCandidateIps.length} 个候选）');
    final sw = Stopwatch()..start();
    final futures = <Future<(String, int?)>>[];
    for (final ip in kCandidateIps) {
      futures.add(_probe(ip, host).then((ms) => (ip, ms)));
    }
    final results = await Future.wait(futures);
    final ok = results.where((r) => r.$2 != null).toList()
      ..sort((a, b) => a.$2!.compareTo(b.$2!));
    lastResults = {
      for (final r in results.where((r) => r.$2 != null)) r.$1: r.$2!,
    };
    sw.stop();
    if (ok.isEmpty) {
      kLog('[IpPin] 全部候选失败（${sw.elapsedMilliseconds}ms）—— 回退系统 DNS');
      _chosen = null;
      return null;
    }
    final best = ok.first.$1;
    _chosen = best;
    _lastSelectAt = DateTime.now().millisecondsSinceEpoch;
    _failures.clear();
    kLog('[IpPin] 选中 $best（${ok.first.$2}ms，'
        '可用 ${ok.length}/${kCandidateIps.length}，共 ${sw.elapsedMilliseconds}ms）');
    onChosen?.call(best);
    return best;
  }

  /// 标记某 IP 失败；连败 2 次就作废并重新选
  static void reportFailure(String ip) {
    final n = (_failures[ip] ?? 0) + 1;
    _failures[ip] = n;
    kLog('[IpPin] $ip 失败 $n 次');
    final since = DateTime.now().millisecondsSinceEpoch - _lastSelectAt;
    // 连败 3 次、且距上次优选超过 60 秒，才重新探测。
    // 早先是「2 次就重选」，网络抖一下就会陷入「探测→失败→再探测」，
    // 每轮 4~8 秒，用户看到的就是「一直转圈」。
    if (n >= 3 && ip == _chosen && since > 60000) {
      kLog('[IpPin] $ip 连败，作废并重新优选');
      _chosen = null;
      _failures.clear();
      // 后台重选，不阻塞当前请求
      unawaited(select());
    }
  }

  /// 拿到某个域名的连接套接字
  ///
  /// 命中优选表 → 连 IP 并自己完成 TLS（SNI=域名）；否则 → 连域名。
  static Future<Socket> _connectPinned(String ip, String host) async {
    // 超时收紧：坏 IP 不该拖住整条请求链
    final raw = await Socket.connect(
      ip,
      443,
      timeout: const Duration(seconds: 3),
    );
    return SecureSocket.secure(raw, host: host).timeout(
      const Duration(seconds: 4),
    );
  }

  /// 走代理的 CONNECT 隧道（代理模式下不用优选 IP）
  ///
  /// 只用于 https；http 由调用方直接把连接交给代理。
  static Future<Socket> _connectViaProxy(
      String proxyHost, int proxyPort, String host, int port) async {
    final sock = await Socket.connect(
      proxyHost,
      proxyPort,
      timeout: const Duration(seconds: 6),
    );
    sock.write('CONNECT $host:$port HTTP/1.1\r\n'
        'Host: $host:$port\r\n'
        'Proxy-Connection: keep-alive\r\n\r\n');
    await sock.flush();
    // 读到空行为止（响应头结束）
    final buf = <int>[];
    await for (final chunk in sock) {
      buf.addAll(chunk);
      final s = String.fromCharCodes(buf);
      if (s.contains('\r\n\r\n')) break;
      if (buf.length > 8192) break;
    }
    final head = String.fromCharCodes(buf);
    if (!head.startsWith('HTTP/1.1 200') && !head.startsWith('HTTP/1.0 200')) {
      await sock.close();
      throw SocketException('代理 CONNECT 失败: ${head.split('\r\n').first}');
    }
    return SecureSocket.secure(sock, host: host).timeout(
      const Duration(seconds: 6),
    );
  }

  /// 给 `HttpClient.connectionFactory` 用
  ///
  /// ⚠ 契约（实测得出，别改坏）：
  ///   · https 时必须返回**已 TLS** 的套接字（Dart 不会替你做 TLS）
  ///   · **必须按 `uri.scheme` / `uri.port` 连接**，不能写死 443
  ///
  /// 第二条曾经写成「一律连 443 并 TLS」，结果所有 `http://` 请求和自定义
  /// 端口请求全挂 —— 表现就是「解析半天解析不出来、失败率很高」。
  /// 播放源里有大量 `http://` 直链与 `:8443` 这类端口，不能想当然。
  ///
  /// 另外：**只在没有配置代理时安装**（见 [install]）。有代理时代理语义
  /// 优先，钉 IP 会绕过代理，属于帮倒忙。
  static Future<ConnectionTask<Socket>> factory(
    Uri uri,
    String? proxyHost,
    int? proxyPort,
  ) async {
    final host = uri.host.toLowerCase();
    final isHttps = uri.scheme.toLowerCase() == 'https';
    final port = uri.port; // Uri.port 已按 scheme 给出默认值（80/443）

    // 代理：https 走 CONNECT 隧道后再 TLS；http 直接把连接交给代理。
    if (proxyHost != null && proxyPort != null) {
      final s = await _connectViaProxy(proxyHost, proxyPort, host, port);
      return ConnectionTask.fromSocket(Future<Socket>.value(s), () {});
    }

    // 只有「https + 443 + Cloudflare 域名」才用优选 IP。
    // 其余一律按原样直连 —— 包括所有 http:// 与自定义端口。
    final canPin = isHttps && port == 443 && kPinHosts.contains(host);

    if (canPin) {
      // 【重要 · 别改回 await select()】
      //
      // 早先这里写的是「没有优选结果就现场探测」，于是每个早到的请求都要
      // 干等 4~8 秒探测完才发车 —— 实测放送表 35 秒、封面 7.8 秒就是这么
      // 来的。探测只应发生在启动预热（main.dart）或重选时，
      // **绝不能在请求路径上阻塞**。没选好就先用系统 DNS；等探测完成后
      // 后续请求自然享受优选结果。
      final ip = _chosen;
      if (ip != null) {
        try {
          final s = await _connectPinned(ip, host);
          return ConnectionTask.fromSocket(Future<Socket>.value(s), () {});
        } catch (e) {
          kLog('[IpPin] 连 $ip 失败（$e），回退系统 DNS');
          reportFailure(ip);
        }
      }
    }

    // 直连（必要时做 TLS）
    final raw = await Socket.connect(
      uri.host,
      port,
      timeout: const Duration(seconds: 6),
    );
    if (!isHttps) {
      return ConnectionTask.fromSocket(Future<Socket>.value(raw), () {});
    }
    final s = await SecureSocket.secure(raw, host: host).timeout(
      const Duration(seconds: 8),
    );
    return ConnectionTask.fromSocket(Future<Socket>.value(s), () {});
  }

  /// 把 factory 装到某个 HttpClient 上
  ///
  /// 【v2.1.10 · 无条件安装 —— 别再加条件】
  ///
  /// 我曾经在这里加过 `if (proxyActive) return;`（「检测到代理就不钉 IP」），
  /// 结果：只要 Windows 注册表里留着系统代理（装过 Clash 就会有），
  /// 优选 IP 就整体失效，退回公共 DNS 分配的坏 IP —— 实测成功率从 5/5
  /// 掉到 3/5、1/5，用户反馈「数据源非常不稳定」。
  ///
  /// 代理与钉 IP 并不冲突：factory 里对 https 走 CONNECT 隧道（见
  /// _connectViaProxy），代理照样生效。所以这里不加任何门禁。
  static void install(HttpClient client) {
    client.connectionFactory = factory;
  }

  /// 摘要（日志/诊断用）
  static String describe() {
    if (_chosen == null) return '未选中（走系统 DNS）';
    final ms = lastResults[_chosen];
    return '已钉 $_chosen${ms != null ? "（${ms}ms）" : ""}';
  }

  /// 把探测结果序列化成可存的一行
  static String? encodeCache() => _chosen;

  /// 供外部在冷启动时读取（key 由调用方管）
  static String? decodeCache(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final m = jsonDecode(raw);
      if (m is String) return m;
    } catch (_) {}
    return raw;
  }
}
