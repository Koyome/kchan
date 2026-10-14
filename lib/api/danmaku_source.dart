/// 弹幕源抽象 + 多源实现
///
/// ## 为什么做多源
///
/// 用户要求「先接入其他免费开源的弹幕，给弹弹play 留位置」。
/// 实测（2026-10-14，无凭证）：
///
/// | 源 | 结果 |
/// | --- | --- |
/// | 弹弹play | **HTTP 403** —— 官方要求 AppId/AppSecret 签名，无凭证完全不可用 |
/// | BiliBili | **可用** —— 需先访问首页取 `buvid3` cookie，之后全链路通畅 |
/// | AcFun | HTTP 404（接口已变更） |
/// | 巴哈姆特 | 超时（大陆网络不可达） |
///
/// 所以默认源是 **BiliBili**（无需任何凭证、弹幕池最大），
/// 弹弹play 作为**第二源**保留，用户填了 AppId/AppSecret 就自动启用，
/// 审核通过后无需改代码。
///
/// ## B站链路（三步，全部无凭证）
///
/// 1. `GET /x/web-interface/search/type?search_type=media_bangumi&keyword=<番名>`
///    → 取 `season_id`
/// 2. `GET /pgc/view/web/season?season_id=<id>` → 剧集列表，取对应集的 `cid`
/// 3. `GET /x/v2/dm/web/seg.so?type=1&oid=<cid>&segment_index=<n>`
///    → **protobuf** 分片，逐段拉到空为止
///
/// ### 关于 protobuf
///
/// 旧版 XML 端点 `list.so` **已废弃**（实测返回 0 条），必须用 protobuf。
/// 但不引入 protobuf 依赖 —— 只按需读几个字段，
/// 手写一个最小 wire-format 解析器即可（见下方 `_ProtoReader`），
/// 未知字段按 wire type 跳过。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'diag_log.dart';

/// 弹幕展示模式（统一到 canvas_danmaku 的语义）
enum DanmakuMode {
  /// 从右往左滚动
  scroll,

  /// 顶部静止
  top,

  /// 底部静止
  bottom,
}

/// 统一后的弹幕条目
class DanmakuItem {
  /// 出现在视频中的时间（毫秒）
  final int timeMs;
  final String text;
  final DanmakuMode mode;

  /// 0xRRGGBB
  final int color;

  /// 来源标识（'bilibili' / 'dandanplay'），便于日志与调试
  final String source;

  const DanmakuItem({
    required this.timeMs,
    required this.text,
    required this.mode,
    required this.color,
    this.source = '',
  });
}

/// 弹幕源接口
abstract class DanmakuSource {
  String get id;
  String get displayName;

  /// 是否可用（凭证类源需要配置齐全）
  bool get available;

  /// 拉取一集弹幕。失败返回空列表，**绝不抛异常影响播放**。
  Future<List<DanmakuItem>> fetch({
    required String animeTitle,
    required double episode,
  });
}

// ═══════════════════════════════════════════════════════════════════════════
//  BiliBili 源
// ═══════════════════════════════════════════════════════════════════════════

class BilibiliDanmakuSource implements DanmakuSource {
  BilibiliDanmakuSource({http.Client? client}) : _c = client ?? http.Client();

  final http.Client _c;

  @override
  String get id => 'bilibili';

  @override
  String get displayName => '哔哩哔哩';

  @override
  bool get available => true; // 无需凭证

  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

  /// 预热得到的 cookie（buvid3 等）。
  ///
  /// 【关键 · 实测】不先访问一次首页、拿不到 `buvid3` 时，
  /// 搜索接口会返回 **HTTP 412 `request was banned`**。
  /// 这正是很多实现「B站接口用不了」的根因。
  String? _cookie;
  bool _warmed = false;

  final Map<String, String> _base = {
    'Referer': 'https://www.bilibili.com/',
    'Origin': 'https://www.bilibili.com',
  };

  Map<String, String> get _headers => {
        ..._base,
        'User-Agent': _ua,
        'Accept': 'application/json, text/plain, */*',
        'Accept-Language': 'zh-CN,zh;q=0.9',
        if (_cookie != null) 'Cookie': _cookie!,
      };

  /// 访问首页取 cookie。只需一次。
  Future<void> _warmUp() async {
    if (_warmed) return;
    _warmed = true;
    try {
      final r = await _c.get(
        Uri.parse('https://www.bilibili.com/'),
        headers: {'User-Agent': _ua},
      ).timeout(const Duration(seconds: 12));
      final raw = r.headers['set-cookie'];
      if (raw != null && raw.isNotEmpty) {
        // 只取 name=value 部分
        final pairs = raw
            .split(RegExp(r',(?=\s*\w+=)'))
            .map((s) => s.split(';').first.trim())
            .where((s) => s.contains('='))
            .toList();
        if (pairs.isNotEmpty) {
          _cookie = pairs.join('; ');
          kLog('[弹幕/B站] 已获取反爬 cookie（${pairs.length} 项）');
        }
      }
    } catch (e) {
      kLog('[弹幕/B站] 预热失败（继续尝试）: $e');
    }
  }

  Future<dynamic> _getJson(String url, {Duration timeout = const Duration(seconds: 15)}) async {
    final r = await _c
        .get(Uri.parse(url), headers: _headers)
        .timeout(timeout);
    if (r.statusCode != 200) {
      throw HttpException('HTTP ${r.statusCode}');
    }
    return jsonDecode(utf8.decode(r.bodyBytes));
  }

  @override
  Future<List<DanmakuItem>> fetch({
    required String animeTitle,
    required double episode,
  }) async {
    final title = animeTitle.trim();
    if (title.isEmpty) return const [];
    await _warmUp();
    try {
      final cid = await _findCid(title, episode);
      if (cid == null) {
        kLog('[弹幕/B站] 未匹配到「$title」第 ${episode.toStringAsFixed(0)} 集');
        return const [];
      }
      kLog('[弹幕/B站] 命中 cid=$cid，开始拉取分片');
      return await _fetchSegments(cid);
    } catch (e) {
      kLog('[弹幕/B站] 拉取失败: $e');
      return const [];
    }
  }

  /// 搜索番剧 → 取 season_id → 取该集 cid
  ///
  /// ## 为什么要多关键词变体
  ///
  /// Bangumi 的标题常带副标题/季数后缀，而 B站番剧库用的是自己的命名。
  /// 实测：`Code Geass 反叛的鲁路修R2` 直接搜 **0 命中**，
  /// 但把后缀去掉（`Code Geass 反叛的鲁路修`）就能命中。
  /// 所以先试原始标题，再逐级「去后缀」重试。
  ///
  /// ## 为什么**不**回退到 `search_type=video`
  ///
  /// 试过：普通视频搜索确实有结果，但排在前面的全是**合集/解说/reaction**
  /// （实测时长 108 分钟、2209 分钟），而且搜索结果里 **没有 `cid`**，
  /// 还得为每个候选再请求一次详情。
  /// 更关键的是：**匹配错番的弹幕比没有弹幕更糟** —— 时间轴完全对不上，
  /// 满屏无关内容。所以这里严格只在**番剧库**里找，宁可返回空。
  Future<int?> _findCid(String title, double episode) async {
    for (final variant in _titleVariants(title)) {
      final seasonId = await _searchSeasonId(variant, title);
      if (seasonId == null) continue;
      final cid = await _cidInSeason(seasonId, episode);
      if (cid != null) {
        if (variant != title) {
          kLog('[弹幕/B站] 「$title」用变体「$variant」命中 season=$seasonId');
        }
        return cid;
      }
    }
    return null;
  }

  /// 生成搜索用的标题变体（从最精确到最宽松）
  static List<String> _titleVariants(String raw) {
    final t = raw.trim();
    final out = <String>[t];
    var s = t;

    // ① 去掉季数/续作后缀（R2 / 第二季 / 2nd Season / 最终季 …）
    final stripped = s
        .replaceAll(
            RegExp(r'\s*(第[一二三四五六七八九十\d]+季|最终季|完[结结]季)\s*$'), '')
        .replaceAll(
            RegExp(r'\s*(R2|S\d+|Season\s*\d+|\d+(st|nd|rd|th)\s*Season)\s*$',
                caseSensitive: false),
            '')
        .trim();
    if (stripped.isNotEmpty && stripped != s) {
      out.add(stripped);
      s = stripped;
    }

    // ② 去掉后半段副标题（冒号/破折号/空格分隔）—— 只保留前半，
    //    但要求前半至少 3 个字，避免退化成一个无意义的短词
    final cut = s.split(RegExp(r'[:：\-–—]')).first.trim();
    if (cut.length >= 3 && cut != s) {
      out.add(cut);
      s = cut;
    }

    // ③ 去掉尾部「中配版 / 国语版 / 粤语版」之类的配音标注
    final dub = s.replaceAll(
        RegExp(r'\s*[（(]?(中配版|台配版|国语版|粤语版|日语版)[)）]?\s*$'), '').trim();
    if (dub.length >= 3 && dub != s) out.add(dub);

    return out.toSet().toList();
  }

  /// 在番剧库里搜一个关键词，返回最合适的 season_id
  Future<int?> _searchSeasonId(String keyword, String originalTitle) async {
    final q = Uri.encodeQueryComponent(keyword);
    final j = await _getJson(
        'https://api.bilibili.com/x/web-interface/search/type'
        '?search_type=media_bangumi&keyword=$q');
    final results = ((j['data'] ?? const {})['result'] ?? const []) as List;
    if (results.isEmpty) return null;

    // 优先标题完全匹配（去掉 B站 返回里的 <em> 高亮标签）
    for (final r in results) {
      if (r is! Map) continue;
      if (_stripTags('${r['title'] ?? ''}') == originalTitle) {
        final id = (r['season_id'] as num?)?.toInt();
        if (id != null && id > 0) return id;
      }
    }
    // 否则取第一条（番剧库里的条目本身可信度较高）
    for (final r in results) {
      if (r is! Map) continue;
      final id = (r['season_id'] as num?)?.toInt();
      if (id != null && id > 0) return id;
    }
    return null;
  }

  /// 在某一季里按集号找 cid
  Future<int?> _cidInSeason(int seasonId, double episode) async {
    final season = await _getJson(
        'https://api.bilibili.com/pgc/view/web/season?season_id=$seasonId');
    final eps = ((season['result'] ?? const {})['episodes'] ?? const []) as List;
    if (eps.isEmpty) return null;

    // 【安全护栏】集数明显对不上就放弃 —— 避免把第 1 集匹配到别的季。
    // 例如搜到的是 12 集的季，却要找第 25 集 → 多半是配错了季。
    final want = episode.round();
    if (want >= 1 && want > eps.length) {
      kLog('[弹幕/B站] season=$seasonId 只有 ${eps.length} 集，'
          '与要的第 $want 集不符，放弃该候选');
      return null;
    }

    // ① 按 order 精确匹配
    for (final e in eps) {
      if (e is! Map) continue;
      if ((e['order'] as num?)?.toInt() == want) {
        final cid = (e['cid'] as num?)?.toInt();
        if (cid != null && cid > 0) return cid;
      }
    }
    // ② 按标题里的数字匹配（如「第1话」「1.」）
    for (final e in eps) {
      if (e is! Map) continue;
      final m = RegExp(r'(\d+)').firstMatch('${e['title'] ?? ''}');
      if (m != null && int.tryParse(m.group(1)!) == want) {
        final cid = (e['cid'] as num?)?.toInt();
        if (cid != null && cid > 0) return cid;
      }
    }
    // ③ 退化为按序号取
    if (want >= 1 && want <= eps.length) {
      final e = eps[want - 1];
      if (e is Map) {
        final cid = (e['cid'] as num?)?.toInt();
        if (cid != null && cid > 0) return cid;
      }
    }
    return null;
  }

  static String _stripTags(String s) =>
      s.replaceAll(RegExp(r'<[^>]*>'), '').trim();

  /// 逐段拉 protobuf 弹幕，直到某段为空或达到上限
  Future<List<DanmakuItem>> _fetchSegments(int cid) async {
    final out = <DanmakuItem>[];
    const maxSegments = 12; // 每段约 6 分钟，12 段足够覆盖单集
    for (var i = 1; i <= maxSegments; i++) {
      final url = 'https://api.bilibili.com/x/v2/dm/web/seg.so'
          '?type=1&oid=$cid&segment_index=$i';
      final r = await _c
          .get(Uri.parse(url), headers: _headers)
          .timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) break;
      final bytes = r.bodyBytes;
      if (bytes.isEmpty) break;
      final items = _parseProtobuf(bytes);
      if (items.isEmpty) break;
      out.addAll(items);
    }
    out.sort((a, b) => a.timeMs.compareTo(b.timeMs));
    kLog('[弹幕/B站] 拉取完成：${out.length} 条');
    return out;
  }

  /// 解析 `DmSegMobileReply`（只取需要的字段）
  ///
  /// ```proto
  /// message DmSegMobileReply { repeated DanmakuElem elems = 1; }
  /// message DanmakuElem {
  ///   int64  id       = 1;
  ///   int32  progress = 2;  // 出现时间，**毫秒**
  ///   int32  mode     = 3;  // 1/2/3 滚动, 4 底部, 5 顶部, 6 逆向, 7 高级
  ///   int32  fontsize = 4;
  ///   uint32 color    = 5;  // 十进制 RGB，0 表示白色
  ///   string midHash  = 6;
  ///   string content  = 7;
  /// }
  /// ```
  List<DanmakuItem> _parseProtobuf(Uint8List bytes) {
    final out = <DanmakuItem>[];
    final top = _ProtoReader(bytes);
    while (top.hasMore) {
      final tag = top.readTag();
      if (tag == null) break;
      if (tag.field == 1 && tag.wire == 2) {
        final sub = top.readBytes();
        if (sub == null) break;
        final item = _parseElem(sub);
        if (item != null) out.add(item);
      } else {
        top.skip(tag.wire);
      }
    }
    return out;
  }

  DanmakuItem? _parseElem(Uint8List bytes) {
    final r = _ProtoReader(bytes);
    var progress = 0;
    var mode = 1;
    var color = 0xFFFFFF;
    String? content;
    while (r.hasMore) {
      final tag = r.readTag();
      if (tag == null) break;
      switch (tag.field) {
        case 2: // progress (ms)
          if (tag.wire == 0) progress = r.readVarint() ?? 0;
          else r.skip(tag.wire);
          break;
        case 3: // mode
          if (tag.wire == 0) mode = r.readVarint() ?? 1;
          else r.skip(tag.wire);
          break;
        case 5: // color
          if (tag.wire == 0) {
            final c = r.readVarint() ?? 0;
            // B站里 0 表示白色
            color = c == 0 ? 0xFFFFFF : (c & 0xFFFFFF);
          } else {
            r.skip(tag.wire);
          }
          break;
        case 7: // content
          if (tag.wire == 2) content = r.readString();
          else r.skip(tag.wire);
          break;
        default:
          r.skip(tag.wire);
      }
    }
    if (content == null || content.isEmpty) return null;
    return DanmakuItem(
      timeMs: progress,
      text: content,
      mode: switch (mode) {
        4 => DanmakuMode.bottom,
        5 => DanmakuMode.top,
        _ => DanmakuMode.scroll, // 1/2/3 以及 6/7 都按滚动显示
      },
      color: color,
      source: 'bilibili',
    );
  }

  void dispose() => _c.close();
}

// ═══════════════════════════════════════════════════════════════════════════
//  极简 protobuf wire-format 读取器
// ═══════════════════════════════════════════════════════════════════════════

class _Tag {
  const _Tag(this.field, this.wire);
  final int field;
  final int wire;
}

class _ProtoReader {
  _ProtoReader(this._b);
  final Uint8List _b;
  int _i = 0;

  bool get hasMore => _i < _b.length;

  int? readVarint() {
    var shift = 0;
    var result = 0;
    while (_i < _b.length) {
      final byte = _b[_i++];
      result |= (byte & 0x7F) << shift;
      if ((byte & 0x80) == 0) return result;
      shift += 7;
      if (shift > 63) return null; // 畸形数据，避免死循环
    }
    return null;
  }

  _Tag? readTag() {
    final key = readVarint();
    if (key == null) return null;
    return _Tag(key >> 3, key & 0x7);
  }

  Uint8List? readBytes() {
    final len = readVarint();
    if (len == null || len < 0 || _i + len > _b.length) return null;
    final out = Uint8List.sublistView(_b, _i, _i + len);
    _i += len;
    return out;
  }

  String? readString() {
    final b = readBytes();
    if (b == null) return null;
    return utf8.decode(b, allowMalformed: true);
  }

  /// 按 wire type 跳过未知字段
  void skip(int wire) {
    switch (wire) {
      case 0:
        readVarint();
        break;
      case 1:
        _i += 8;
        break;
      case 2:
        readBytes();
        break;
      case 5:
        _i += 4;
        break;
      default:
        _i = _b.length; // 无法识别 → 结束，避免读到错位数据
    }
    if (_i > _b.length) _i = _b.length;
  }
}
