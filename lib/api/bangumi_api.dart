/// Bangumi API v0 客户端
/// - 镜像可配置 + 自动故障转移（官方站当前在大陆被封锁，须备镜像）
/// - 全局限速（礼貌访问），必需 User-Agent
library;

import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models.dart';
import 'diag_log.dart' show kLog;
import 'tick_notifier.dart';

class ApiException implements Exception {
  final String message;
  final int? statusCode;
  ApiException(this.message, [this.statusCode]);
  @override
  String toString() => statusCode != null ? '$message (HTTP $statusCode)' : message;
}

class BangumiApi {
  static const userAgent = 'kchan/1.9.9 (https://github.com/Koyome/kchan)';

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

  /// 内置镜像预设（顺序即优先级；官方站被墙时用户可切换）
  ///
  /// 顺序按**实测速度**排，不再按「官方优先」：
  ///   1. api.kazumi.fyi   —— 273ms（但只认 /p1 与 /kazumi/v1，见 _pathFor）
  ///   2. bgmapi.anibt.net —— 3.9s（v0 协议完整，兜底）
  ///   3. api.bgm.tv       —— 理论上最全，实测不可达，留作代理环境下的首选
  static const presetBases = <String>[
    'https://api.kazumi.fyi',
    'https://bgmapi.anibt.net',
    'https://api.bgm.tv',
  ];

  /// 【路径改写】把 v0 路径映射成 Kazumi 镜像支持的等价路径。
  ///
  /// 为什么要做：镜像只实现了 next.bgm.tv 协议，直接请求 `/v0/...` 会 404；
  /// 而 404 在竞速里只是「这一家没结果」，不会中断整轮请求 —— 但会白白
  /// 浪费一次往返。这里主动改写，让它一次命中。
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

    // /v0/subjects/{id}/characters 与 /subjects  → 支持
    if (RegExp(r'^/v0/subjects/\d+/(characters|subjects)$').hasMatch(path)) {
      return path;
    }

    // /calendar  → /p1/calendar
    if (path == '/calendar' || path == '/v0/calendar') return '/p1/calendar';

    // 其余（POST 搜索 /v0/search/subjects 会 401、图片端点 404）→ 跳过该镜像
    return null;
  }

  final http.Client _client = http.Client();

  /// 当前可用的 base 列表（设置页可改，自定义排最前）
  List<String> bases = List.of(presetBases);

  /// 【实测优化】上次成功的 base 优先尝试：镜像挂了不反复浪费时间在死镜像上
  String? _preferredBase;

  List<String> get _orderedBases {
    final p = _preferredBase;
    if (p == null || !bases.contains(p)) return bases;
    return [p, ...bases.where((b) => b != p)];
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
    final uri = Uri.parse('$base$path');
    return q == null || q.isEmpty ? uri : uri.replace(queryParameters: q);
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
    final bases = _orderedBases;
    if (bases.isEmpty) {
      throw ApiException('未配置 Bangumi 数据源');
    }
    final completer = Completer<dynamic>();
    final targets = <(String, String)>[]; // (base, 生效路径)
    var skipped = 0;
    for (var i = 0; i < bases.length; i++) {
      final p = _pathFor(bases[i], path);
      if (p == null) {
        skipped++;
        continue;
      }
      targets.add((bases[i], p));
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

    for (var i = 0; i < targets.length; i++) {
      final (base, effPath) = targets[i];
      final delayMs = i == 0 ? 0 : 300 * i; // 首选镜像立即发，其余错峰
      Future<void>(() async {
        if (delayMs > 0) await Future<void>.delayed(Duration(milliseconds: delayMs));
        if (completer.isCompleted) {
          remaining--;
          return;
        }
        try {
          final res = isPost
              ? await _client
                  .post(_u(base, effPath, q),
                      headers: {
                        'User-Agent': userAgent,
                        'Accept': 'application/json',
                        'Content-Type': 'application/json'
                      },
                      body: jsonEncode(body))
                  .timeout(const Duration(seconds: 6))
              : await _client
                  .get(_u(base, effPath, q),
                      headers: {'User-Agent': userAgent, 'Accept': 'application/json'})
                  .timeout(const Duration(seconds: 6));
          if (res.statusCode == 200) {
            _preferredBase = base;
            if (!completer.isCompleted) {
              completer.complete(jsonDecode(utf8.decode(res.bodyBytes)));
            }
            return;
          }
          lastStatus = res.statusCode;
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
            return;
          }
        } catch (e) {
          lastError = e;
        } finally {
          remaining--;
          if (remaining == 0 && !completer.isCompleted) {
            if (notFound.isNotEmpty) {
              completer.completeError(ApiException('内容不存在', 404));
            } else if (tooMany.isNotEmpty) {
              completer.completeError(ApiException('请求太频繁，请稍后再试', 429));
            } else {
              completer.completeError(ApiException(
                  '所有 Bangumi 数据源均无法连接（可到「设置 → 网络与镜像」配置代理或自建反代）'
                  '${lastStatus != null ? '，最后状态 $lastStatus' : ''}'));
            }
          }
        }
      });
    }
    if (skipped > 0) {
      kLog('[Bangumi] $path：$skipped 个数据源不支持该路径，已跳过');
    }
    return completer.future;
  }

  /// GET JSON（镜像并发竞速）
  Future<dynamic> _get(String path, [Map<String, String>? q]) =>
      _race(path, false, null, q);

  // ---------- 轻量内存缓存（v1.4.0） ----------
  //
  // 详情页反复进出、放送表切 tab 都命中同一批请求；镜像慢的时候缓存
  // 直接决定「快不快」。只缓存元数据（几十 KB 级），进程内有效。
  static final _cache = <String, ({dynamic data, int at})>{};
  static const _cacheTtlMs = 10 * 60 * 1000; // 10 分钟

  static dynamic _cacheGet(String key) {
    final hit = _cache[key];
    if (hit == null) return null;
    if (DateTime.now().millisecondsSinceEpoch - hit.at > _cacheTtlMs) {
      _cache.remove(key);
      return null;
    }
    return hit.data;
  }

  static void _cachePut(String key, dynamic data) {
    _cache[key] = (data: data, at: DateTime.now().millisecondsSinceEpoch);
  }

  Future<dynamic> _getCached(String key, String path, [Map<String, String>? q]) async {
    final hit = _cacheGet(key);
    if (hit != null) return hit;
    final data = await _race(path, false, null, q);
    _cachePut(key, data);
    return data;
  }

  /// POST 搜索也走缓存：搜索页反复翻页/切排序/重复搜同一关键词时直接命中，
  /// 不用再等慢镜像（搜索结果 10 分钟内几乎不变）。
  Future<dynamic> _postCached(String key, String path, Map<String, dynamic> body, [Map<String, String>? q]) async {
    final hit = _cacheGet(key);
    if (hit != null) return hit;
    final data = await _race(path, true, body, q);
    _cachePut(key, data);
    return data;
  }

  // ---------- 业务接口 ----------

  /// 每日放送
  ///
  /// 【重要】官方文档里「每日放送」的路径是 **`GET /calendar`**（旧版公开 API），
  /// v0 系列中**并没有** `/v0/calendar`。早期这里误写成 `/v0/calendar`，
  /// 会稳定拿到 HTTP 404，首页就显示「内容不存在」。
  /// 现在改为：先按官方路径 `/calendar` 请求，失败再回退试 `/v0/calendar`
  /// （个别第三方镜像自行实现了 v0 版本），两条都失败才抛错。
  Future<List<CalendarDay>> calendar() async {
    // ① 【v1.5.0 · 照搬 Kazumi】先试 Kazumi 镜像的服务端缓存接口（~1.4s），
    //    比任何 /calendar 透传镜像都快一个数量级。
    try {
      final hit = _cacheGet('calendar:kazumi');
      final dynamic j = hit ??
          await _client
              .get(
                Uri.parse('$kazumiMirror/kazumi/v1/calendar/season?${_seasonRange()}'),
                headers: {'User-Agent': userAgent, 'Accept': 'application/json'},
              )
              .timeout(const Duration(seconds: 8))
              .then((r) => r.statusCode == 200
                  ? jsonDecode(utf8.decode(r.bodyBytes))
                  : throw ApiException('HTTP ${r.statusCode}'));
      if (hit == null) _cachePut('calendar:kazumi', j);
      if (j is Map) {
        final days = <CalendarDay>[];
        // 镜像返回 {"1":[{subject:…}…],…,"7":[…]}，键是 weekday id
        const wdNames = {1: '周一', 2: '周二', 3: '周三', 4: '周四', 5: '周五', 6: '周六', 7: '周日'};
        for (var i = 1; i <= 7; i++) {
          final list = j['$i'] is List ? j['$i'] as List : const [];
          final items = <Subject>[];
          for (final it in list) {
            final sub = it is Map ? it['subject'] : null;
            if (sub is Map) {
              items.add(Subject.fromJson(sub.cast<String, dynamic>()));
            }
          }
          days.add(CalendarDay(weekday: i, weekdayCn: wdNames[i] ?? '', items: items));
        }
        if (days.any((d) => d.items.isNotEmpty)) return days;
      }
    } catch (_) {
      // 走下方通用镜像路径
    }
    // ② 通用路径：先按官方路径 `/calendar` 请求，失败再回退试 `/v0/calendar`
    dynamic j;
    try {
      j = await _getCached('calendar:main', '/calendar');
    } catch (_) {
      j = await _getCached('calendar:v0', '/v0/calendar');
    }
    final list = asList(j);
    return list.map<CalendarDay>((d) {
      final wd = d is Map ? d : const {};
      final w = wd['weekday'] is Map ? wd['weekday'] as Map : const {};
      final items = wd['items'] is List ? wd['items'] as List : const [];
      return CalendarDay(
        weekday: (w['id'] as num?)?.toInt() ?? 0,
        weekdayCn: w['cn']?.toString() ?? '',
        items: items.whereType<Map<String, dynamic>>().map(Subject.fromJson).toList(),
      );
    }).toList();
  }

  /// 每日放送的「先渲染后补中文名」包装（首页用）。
  ///
  /// 直接把 [calendar] 的结果交给首页渲染，同时在**后台**补齐缺失的中文名；
  /// 补完通过 [nameEnrichTick] 通知首页刷新。这样首屏不再被中文名阻塞。
  Future<List<CalendarDay>> calendarFast() async {
    final days = await calendar();
    final missing = <Subject>[
      for (final d in days)
        ...d.items.where((s) => s.nameCn.isEmpty)
    ];
    if (missing.isNotEmpty) _enrichInBackground(missing);
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
    final missing = items.where((s) => s.nameCn.isEmpty).take(14).toList();
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

  /// 本季度日期范围（镜像 season calendar 接口要求 start/end）
  static String _seasonRange() {
    final now = DateTime.now();
    final m = now.month;
    final startMonth = m <= 3 ? 1 : (m <= 6 ? 4 : (m <= 9 ? 7 : 10));
    final start = DateTime(now.year, startMonth, 1);
    final end = DateTime(now.year, startMonth + 3, 1).subtract(const Duration(days: 1));
    String f(DateTime d) =>
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    return 'start=${f(start)}&end=${f(end)}';
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
              .then((r) => r.statusCode == 200
                  ? jsonDecode(utf8.decode(r.bodyBytes))
                  : throw ApiException('HTTP ${r.statusCode}'));
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
    try {
      j = await _race('/v0/episodes', false, null, {...params, 'subject_id': '$subjectId'});
    } catch (_) {
      j = await _race('/v0/subjects/$subjectId/episodes', false, null, params);
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
    if (u == null || u.path.isEmpty || !u.path.startsWith('/pic/')) {
      return const [];
    }
    final out = <String>[];
    for (final b in BangumiApiHolder.api._orderedBases) {
      final host = Uri.tryParse(b)?.origin;
      if (host == null || host.isEmpty) continue;
      final cand = '$host${u.path}';
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
    // 非 lain 图床（如镜像返回的 bgmimg.*）：保留 /pic/ 路径挂到自定义主机
    final p = Uri.tryParse(url);
    if (p != null && p.path.startsWith('/pic/')) {
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
