/// 弹弹play（dandanplay）开放平台弹幕 API
///
/// ## 接入说明（对齐 Kazumi）
///
/// - 接口域：`https://api.dandanplay.net`
/// - 鉴权：开放平台应用的 AppId / AppSecret，每个请求带签名头：
///   `X-AppId`、`X-Timestamp`（秒）、`X-Signature`、
///   另有 `X-Auth: 1`（Kazumi 同款）。
///   签名算法（与 Kazumi `utils/crypto.dart` 完全一致）：
///   `base64( sha256( appId + timestamp + path + appSecret ) )`
/// - 凭证由用户在「设置 → 弹幕」里自行填写（弹弹play开放平台注册应用
///   即可获得），本地存储、不内置任何人的凭证。
///
/// ## 弹幕匹配流程
///
///  1. `GET /api/v2/search/episodes?anime=<番名>&episode=<集数>`
///     直接按「番名+集数」命中 episodeId（v2 接口，绕开 25 条上限）
///  2. `GET /api/v2/comment/<episodeId>?withRelated=true&chConvert=0`
///     拉全部弹幕（含关联弹幕）
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'diag_log.dart';

/// 一条弹幕
class DanmakuEntry {
  /// 内容
  final String message;

  /// 出现时间（秒）
  final double time;

  /// 类型：1 滚动（从右往左）、4 底部、5 顶部
  final int type;

  /// 颜色（RGB，0xRRGGBB）
  final int color;

  /// 来源（如 [BiliBili]、[Gamer]）
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
}

/// 弹幕 API 客户端
class DanmakuApi {
  static const _domain = 'https://api.dandanplay.net';
  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

  final http.Client _c = http.Client();

  String appId;
  String appSecret;

  DanmakuApi({this.appId = '', this.appSecret = ''});

  bool get configured => appId.isNotEmpty && appSecret.isNotEmpty;

  Map<String, String> _headers(String path) {
    final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final data = '$appId$ts$path$appSecret';
    final sig = base64Encode(sha256.convert(utf8.encode(data)).bytes);
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

  /// 按「番名 + 集数」直接匹配 episodeId。
  ///
  /// [animeTitle] 用 Bangumi 的中文名（没有就用原名）；
  /// [episode] 为第几集（1 起）。
  /// 返回 null 表示没匹配到。
  Future<int?> matchEpisodeId(String animeTitle, double episode) async {
    if (!configured || animeTitle.trim().isEmpty) return null;
    try {
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
    } catch (e) {
      kLog('[Danmaku] 匹配剧集失败: $e');
      return null;
    }
  }

  /// 拉取一集的全部弹幕
  Future<List<DanmakuEntry>> comments(int episodeId) async {
    if (!configured || episodeId <= 0) return const [];
    try {
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
          .toList();
      out.sort((a, b) => a.time.compareTo(b.time));
      return out;
    } catch (e) {
      kLog('[Danmaku] 拉取弹幕失败: $e');
      return const [];
    }
  }

  /// 一步完成「匹配 + 拉取」
  Future<List<DanmakuEntry>> fetch(String animeTitle, double episode) async {
    final id = await matchEpisodeId(animeTitle, episode);
    if (id == null) return const [];
    return comments(id);
  }

  void dispose() => _c.close();
}

class DanmakuException implements Exception {
  final String message;
  const DanmakuException(this.message);
  @override
  String toString() => message;
}
