/// 弹幕获取总入口（多源调度）
///
/// ## 源的选择与优先级
///
/// | 源 | 凭证 | 状态 |
/// | --- | --- | --- |
/// | **哔哩哔哩** | 不需要 | 默认启用，实测可用 |
/// | **弹弹play** | AppId + AppSecret | 用户填了就启用 |
///
/// 用户要求「先接入其他免费开源的弹幕，给弹弹play 留位置方便审核之后添加」——
/// 所以：B站作为**默认可用源**（无需任何配置），
/// 弹弹play 凭证一旦填写就**自动参与调度且优先**（它的匹配质量更好），
/// 审核通过后无需改任何代码。
///
/// ## 失败处理原则
///
/// 弹幕是**附加功能**，任何失败都只记日志 + 返回空列表，
/// **绝不影响视频播放**。调用方拿到空列表就静默不显示弹幕层。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'danmaku_source.dart';
import 'diag_log.dart';

/// 兼容旧代码的条目类型（内部仍用于弹弹play 的解析）
class DanmakuEntry {
  final String message;
  final double time;
  final int type; // 1 滚动 / 4 底部 / 5 顶部
  final int color;
  final String source;

  const DanmakuEntry({
    required this.message,
    required this.time,
    required this.type,
    required this.color,
    this.source = '',
  });

  factory DanmakuEntry.fromJson(Map<String, dynamic> j) {
    final p = '${j['p'] ?? ''}'.split(',');
    return DanmakuEntry(
      message: '${j['m'] ?? ''}',
      time: double.tryParse(p.isNotEmpty ? p[0] : '') ?? 0,
      type: int.tryParse(p.length > 1 ? p[1] : '') ?? 1,
      color: int.tryParse(p.length > 2 ? p[2] : '') ?? 0xFFFFFF,
      source: p.length > 3 ? p[3] : '',
    );
  }

  /// 转成统一条目
  DanmakuItem toItem() => DanmakuItem(
        timeMs: (time * 1000).round(),
        text: message,
        mode: switch (type) {
          4 => DanmakuMode.bottom,
          5 => DanmakuMode.top,
          _ => DanmakuMode.scroll,
        },
        color: color & 0xFFFFFF,
        source: source.isEmpty ? 'dandanplay' : source,
      );
}

/// 弹弹play 开放平台凭证的**编译期默认值**
///
/// ## 为什么用 `String.fromEnvironment` 而不是直接写常量
///
/// 本项目的 GitHub 仓库是**公开**的。AppSecret 一旦提交上去，任何人都能拿去
/// 消耗配额，甚至导致应用被封。所以凭证**不写进源码**，而是在构建时注入：
///
/// ```powershell
/// flutter build windows --release `
///   --dart-define=DANDAN_APPID=xxx `
///   --dart-define=DANDAN_APPSECRET=xxx
/// ```
///
/// 好处：
///   · 源码里只有空字符串，推到公开仓库不泄露；
///   · 打出来的包凭证已固化进 app.so → 用户**开箱即用**，无需任何配置；
///   · 用户仍可在「设置 → 弹幕」填自己的凭证覆盖它。
///
/// ## 优先级
///
///   用户设置（设置页填写） > 编译期注入 > 空
///
/// 空值时该源不可用并自动跳过 —— 不报错、不影响播放。
class DandanCredentials {
  /// 编译期注入的 AppId（未注入时为空）
  static const String builtinAppId =
      String.fromEnvironment('DANDAN_APPID', defaultValue: '');

  /// 编译期注入的 AppSecret（未注入时为空）
  static const String builtinAppSecret =
      String.fromEnvironment('DANDAN_APPSECRET', defaultValue: '');

  /// 是否有内置凭证
  static bool get hasBuiltin =>
      builtinAppId.isNotEmpty && builtinAppSecret.isNotEmpty;

  /// 解析最终使用的凭证：用户填写优先，否则用内置
  static (String, String) resolve(String userAppId, String userSecret) {
    if (userAppId.trim().isNotEmpty && userSecret.trim().isNotEmpty) {
      return (userAppId.trim(), userSecret.trim());
    }
    return (builtinAppId, builtinAppSecret);
  }
}

/// 弹弹play 客户端（需要开放平台凭证）
class DandanplaySource implements DanmakuSource {
  DandanplaySource({this.appId = '', this.appSecret = '', http.Client? client})
      : _c = client ?? http.Client();

  static const _domain = 'https://api.dandanplay.net';
  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

  final http.Client _c;
  String appId;
  String appSecret;

  @override
  String get id => 'dandanplay';

  @override
  String get displayName => '弹弹play';

  @override
  bool get available => appId.trim().isNotEmpty && appSecret.trim().isNotEmpty;

  Map<String, String> _headers(String path) {
    final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final sig = base64Encode(
        sha256.convert(utf8.encode('$appId$ts$path$appSecret')).bytes);
    return {
      'User-Agent': _ua,
      'Accept': 'application/json',
      'X-Auth': '1',
      'X-AppId': appId,
      'X-Timestamp': '$ts',
      'X-Signature': sig,
    };
  }

  Future<Map<String, dynamic>> _get(String path,
      [Map<String, String>? q]) async {
    var uri = Uri.parse('$_domain$path');
    if (q != null && q.isNotEmpty) uri = uri.replace(queryParameters: q);
    final res = await _c
        .get(uri, headers: _headers(path))
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) {
      throw DanmakuException('弹幕接口异常 (HTTP ${res.statusCode})');
    }
    final j = jsonDecode(utf8.decode(res.bodyBytes));
    if (j is Map<String, dynamic>) {
      if (j['success'] == false) {
        throw DanmakuException('${j['errorMessage'] ?? '弹幕接口返回失败'}');
      }
      return j;
    }
    throw DanmakuException('弹幕接口数据异常');
  }

  Future<int?> matchEpisodeId(String animeTitle, double episode) async {
    if (!available || animeTitle.trim().isEmpty) return null;
    final j = await _get('/api/v2/search/episodes', {
      'anime': animeTitle.trim(),
      'episode': episode.toStringAsFixed(0),
    });
    final animes = j['animes'];
    if (animes is! List) return null;
    for (final a in animes) {
      if (a is! Map) continue;
      final eps = a['episodes'];
      if (eps is! List) continue;
      for (final e in eps) {
        if (e is! Map) continue;
        final id = (e['episodeId'] as num?)?.toInt();
        if (id != null && id > 0) return id;
      }
    }
    return null;
  }

  Future<List<DanmakuEntry>> comments(int episodeId) async {
    if (!available || episodeId <= 0) return const [];
    final j = await _get('/api/v2/comment/$episodeId', {
      'withRelated': 'true',
      'chConvert': '0',
    });
    final list = j['comments'];
    if (list is! List) return const [];
    final out = list
        .whereType<Map>()
        .map((e) => DanmakuEntry.fromJson(e.cast<String, dynamic>()))
        .where((e) => e.message.isNotEmpty)
        .toList()
      ..sort((a, b) => a.time.compareTo(b.time));
    return out;
  }

  @override
  Future<List<DanmakuItem>> fetch({
    required String animeTitle,
    required double episode,
  }) async {
    if (!available) return const [];
    try {
      final id = await matchEpisodeId(animeTitle, episode);
      if (id == null) {
        kLog('[弹幕/弹弹play] 未匹配到「$animeTitle」第 ${episode.toStringAsFixed(0)} 集');
        return const [];
      }
      final raw = await comments(id);
      kLog('[弹幕/弹弹play] 命中 episodeId=$id，${raw.length} 条');
      return raw.map((e) => e.toItem()).toList();
    } catch (e) {
      kLog('[弹幕/弹弹play] 拉取失败: $e');
      return const [];
    }
  }

  void dispose() => _c.close();
}

/// 弹幕调度器：按优先级依次尝试各源
class DanmakuApi {
  /// [appId] / [appSecret] 传用户在设置页填的值；留空则回退到
  /// 编译期注入的内置凭证（见 [DandanCredentials]）。
  DanmakuApi({
    String appId = '',
    String appSecret = '',
    this.danmuApiBaseUrl = '',
  }) {
    // 用户填了就用用户的，没填就用编译期注入的（打出来的包开箱即用）
    final (id, secret) = DandanCredentials.resolve(appId, appSecret);
    _dandan = DandanplaySource(appId: id, appSecret: secret);
    _bili = BilibiliDanmakuSource();
    _agg = DanmuApiSource(baseUrl: danmuApiBaseUrl);
  }

  /// 自建 danmu_api 聚合实例地址（空 = 未配置）。
  ///
  /// 这是**覆盖率的关键**：B站单源只能覆盖约 85%，
  /// 自建聚合实例后（聚合爱优腾芒哔咪人韩巴等十多个源）可显著提升。
  final String danmuApiBaseUrl;

  late final DandanplaySource _dandan;
  late final BilibiliDanmakuSource _bili;
  late final DanmuApiSource _agg;

  /// 是否已配置弹弹play（用于设置页提示）
  bool get configured => _dandan.available;

  /// 当前启用的源名字（日志/UI 用）
  List<String> get enabledSourceNames => [
        if (_agg.available) _agg.displayName,
        if (_dandan.available) _dandan.displayName,
        if (_bili.available) _bili.displayName,
      ];

  /// 「匹配 + 拉取」一步完成。
  ///
  /// 按顺序尝试各源，**第一个返回非空结果的就用它**；
  /// 全部失败返回空列表（调用方静默处理，不影响播放）。
  Future<List<DanmakuItem>> fetchAll(
    String animeTitle,
    double episode, {
    void Function(String message)? onNotice,
  }) async {
    final title = animeTitle.trim();
    if (title.isEmpty) return const [];
    // 优先级（实测依据）：
    //   1. danmu_api 聚合实例 —— 覆盖最广（含 Gamer 等 B站没有的源）；
    //      但它是用户自建、响应较慢，所以仅在配置后参与
    //   2. 弹弹play —— 索引质量好（需开放平台凭证）
    //   3. B站直连 —— 免配置、快，但只覆盖其番剧库
    // 【v2.0.0 · 顺序优化】快的放前面：B站直连命中约 85% 且只需 0.4~2.4s，
    // 聚合实例要 1~5s。原先聚合优先会让每部番都白等几秒才回落到 B站。
    // 优先级（用户指定 + 实测依据）：
    //
    //   1. **弹弹play** —— 覆盖最广，且实测**比 B站 还快**：
    //      真实凭证压测 8 部番，合计中位数 **1622ms**
    //      （匹配 457ms + 拉取 1135ms），命中 8/8。
    //      含 B站**没有上架**的番（实测《进击的巨人》2342 条、
    //      《我推的孩子》714 条 —— B站直连对这两部是 0 条）。
    //      放第一还能省掉「B站先失败一次再回退」的双倍等待。
    //   2. **B站直连** —— 免配置兜底；凭证失效/额度用尽时仍保证有弹幕。
    //      注意它只覆盖番剧库约 85%，且未收录的番要等一次搜索超时才失败，
    //      所以不宜再放第一。
    //   3. **danmu_api 聚合实例** —— 用户自建才有，响应 1~5s，最慢，放最后。
    final sources = <DanmakuSource>[
      if (_dandan.available) _dandan,
      if (_bili.available) _bili,
      if (_agg.available) _agg,
    ];
    if (sources.isEmpty) {
      onNotice?.call('未配置可用的弹幕源');
      return const [];
    }
    for (final s in sources) {
      try {
        final items = await s.fetch(animeTitle: title, episode: episode);
        if (items.isNotEmpty) {
          kLog('[弹幕] 使用「${s.displayName}」共 ${items.length} 条');
          return items;
        }
      } catch (e) {
        // 单个源失败不影响其它源
        kLog('[弹幕] 「${s.displayName}」异常: $e');
      }
    }
    // 全部源都没有结果 —— 友好提示，且**不影响播放**
    final names = sources.map((s) => s.displayName).join('、');
    kLog('[弹幕] 所有源（$names）均无结果');
    onNotice?.call('未找到「$title」第 ${episode.toStringAsFixed(0)} 集的弹幕');
    return const [];
  }

  void dispose() {
    _dandan.dispose();
    _bili.dispose();
    _agg.dispose();
  }
}

class DanmakuException implements Exception {
  final String message;
  const DanmakuException(this.message);
  @override
  String toString() => message;
}
