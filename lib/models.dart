/// Bangumi 数据模型（v0 API 形状，手写解析，无 codegen）
library;

class BgmImages {
  final String large;
  final String common;
  final String medium;
  final String small;
  final String grid;
  const BgmImages({this.large = '', this.common = '', this.medium = '', this.small = '', this.grid = ''});

  factory BgmImages.fromJson(Map<String, dynamic>? j) => BgmImages(
        large: j?['large']?.toString() ?? '',
        common: j?['common']?.toString() ?? '',
        medium: j?['medium']?.toString() ?? '',
        small: j?['small']?.toString() ?? '',
        grid: j?['grid']?.toString() ?? '',
      );

  /// 封面首选 common（清晰且体积小），回退 large/medium
  String get cover => common.isNotEmpty ? common : (large.isNotEmpty ? large : medium);

  Map<String, dynamic> toJson() => {'large': large, 'common': common, 'medium': medium, 'small': small, 'grid': grid};
}

/// 条目（列表/搜索/日历用，轻量）
class Subject {
  final int id;
  final String name;
  final String nameCn;
  final BgmImages images;
  final String airDate;
  final int airWeekday;
  final double score;
  final int rank;
  final int total; // 评分人数
  final int eps; // 已放送话数（列表字段）
  final int totalEpisodes; // 总话数
  final List<String> tags;

  const Subject({
    required this.id,
    this.name = '',
    this.nameCn = '',
    this.images = const BgmImages(),
    this.airDate = '',
    this.airWeekday = 0,
    this.score = 0,
    this.rank = 0,
    this.total = 0,
    this.eps = 0,
    this.totalEpisodes = 0,
    this.tags = const [],
  });

  String get displayName => nameCn.isNotEmpty ? nameCn : name;

  /// 补中文名（镜像热榜接口不返回 name_cn，用放送/搜索数据回填时用）
  Subject copyWithNameCn(String cn) => Subject(
        id: id,
        name: name,
        nameCn: cn,
        images: images,
        airDate: airDate,
        airWeekday: airWeekday,
        score: score,
        rank: rank,
        total: total,
        eps: eps,
        totalEpisodes: totalEpisodes,
        tags: tags,
      );

  factory Subject.fromJson(Map<String, dynamic> j) {
    final rating = j['rating'] is Map ? j['rating'] as Map<String, dynamic> : const <String, dynamic>{};
    final rawTags = j['tags'];
    return Subject(
      id: (j['id'] as num?)?.toInt() ?? 0,
      name: j['name']?.toString() ?? '',
      nameCn: j['name_cn']?.toString() ?? '',
      images: BgmImages.fromJson(j['images'] is Map ? j['images'] as Map<String, dynamic> : null),
      airDate: j['air_date']?.toString() ?? j['date']?.toString() ?? '',
      airWeekday: (j['air_weekday'] as num?)?.toInt() ?? 0,
      score: (rating['score'] as num?)?.toDouble() ?? 0,
      rank: (rating['rank'] as num?)?.toInt() ?? 0,
      total: (rating['total'] as num?)?.toInt() ?? 0,
      eps: (j['eps'] as num?)?.toInt() ?? 0,
      totalEpisodes: (j['total_episodes'] as num?)?.toInt() ?? 0,
      tags: rawTags is List
          ? rawTags.map((e) => e is Map ? e['name']?.toString() ?? '' : e.toString()).where((s) => s.isNotEmpty).toList()
          : const [],
    );
  }

  /// 本地快照（收藏/进度里存的最小信息）
  Map<String, dynamic> toSnapshot() => {
        'id': id,
        'name': name,
        'name_cn': nameCn,
        'image': images.cover,
        'air_date': airDate,
        'air_weekday': airWeekday,
        'score': score,
        'eps': eps,
        'total_episodes': totalEpisodes,
      };

  factory Subject.fromSnapshot(Map<String, dynamic> j) => Subject(
        id: (j['id'] as num?)?.toInt() ?? 0,
        name: j['name']?.toString() ?? '',
        nameCn: j['name_cn']?.toString() ?? '',
        images: BgmImages(common: j['image']?.toString() ?? ''),
        airDate: j['air_date']?.toString() ?? '',
        airWeekday: (j['air_weekday'] as num?)?.toInt() ?? 0,
        score: (j['score'] as num?)?.toDouble() ?? 0,
        eps: (j['eps'] as num?)?.toInt() ?? 0,
        totalEpisodes: (j['total_episodes'] as num?)?.toInt() ?? 0,
      );
}

/// 条目详情（含 infobox）
class SubjectDetail extends Subject {
  final String summary;
  final Map<String, String> infobox; // 扁平化后的键值
  final List<String> aliases;
  final String platform;
  final bool series;
  final int wishCount, doingCount, collectCount, onHoldCount, droppedCount;

  const SubjectDetail({
    required super.id,
    super.name,
    super.nameCn,
    super.images,
    super.airDate,
    super.airWeekday,
    super.score,
    super.rank,
    super.total,
    super.eps,
    super.totalEpisodes,
    super.tags,
    this.summary = '',
    this.infobox = const {},
    this.aliases = const [],
    this.platform = '',
    this.series = false,
    this.wishCount = 0,
    this.doingCount = 0,
    this.collectCount = 0,
    this.onHoldCount = 0,
    this.droppedCount = 0,
  });

  static List<String> _flattenValue(dynamic v) {
    if (v is String) return [v];
    if (v is List) {
      return v.map((e) {
        if (e is Map) {
          final k = e['k']?.toString() ?? '';
          final val = e['v']?.toString() ?? '';
          return k.isNotEmpty ? '$k: $val' : val;
        }
        return e.toString();
      }).toList();
    }
    return [v?.toString() ?? ''];
  }

  factory SubjectDetail.fromJson(Map<String, dynamic> j) {
    final base = Subject.fromJson(j);
    final box = <String, String>{};
    final aliases = <String>[];
    final rawBox = j['infobox'];
    if (rawBox is List) {
      for (final e in rawBox) {
        if (e is! Map) continue;
        final k = e['key']?.toString() ?? '';
        if (k.isEmpty) continue;
        final vals = _flattenValue(e['value']);
        if (k == '别名') {
          aliases.addAll(vals.where((v) => v.isNotEmpty));
        } else {
          box[k] = vals.join(' / ');
        }
      }
    }
    final coll = j['collection'] is Map ? j['collection'] as Map<String, dynamic> : const <String, dynamic>{};
    return SubjectDetail(
      id: base.id,
      name: base.name,
      nameCn: base.nameCn,
      images: base.images,
      airDate: base.airDate,
      airWeekday: base.airWeekday,
      score: base.score,
      rank: base.rank,
      total: base.total,
      eps: base.eps,
      totalEpisodes: base.totalEpisodes,
      tags: base.tags,
      summary: (j['summary']?.toString() ?? '').trim(),
      infobox: box,
      aliases: aliases,
      platform: j['platform']?.toString() ?? '',
      series: j['series'] == true,
      wishCount: (coll['wish'] as num?)?.toInt() ?? 0,
      doingCount: (coll['doing'] as num?)?.toInt() ?? 0,
      collectCount: (coll['collect'] as num?)?.toInt() ?? 0,
      onHoldCount: (coll['on_hold'] as num?)?.toInt() ?? 0,
      droppedCount: (coll['dropped'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 分集
class Episode {
  final int id;
  final double sort; // 展示用集数（可含 .5）
  final int ep; // 绝对话数
  final String name;
  final String nameCn;
  final String airdate;
  final String duration; // "24m" / "00:24:00"
  final String comment; // 讨论数
  final String desc;
  final int type; // 0 本篇 1 SP 2 OP 3 ED

  const Episode({
    required this.id,
    this.sort = 0,
    this.ep = 0,
    this.name = '',
    this.nameCn = '',
    this.airdate = '',
    this.duration = '',
    this.comment = '',
    this.desc = '',
    this.type = 0,
  });

  String get displayName {
    final cn = nameCn.trim();
    if (cn.isNotEmpty) return cn;
    return name.trim();
  }

  String get sortLabel {
    if (sort == sort.roundToDouble()) return sort.toInt().toString();
    return sort.toString();
  }

  factory Episode.fromJson(Map<String, dynamic> j) => Episode(
        id: (j['id'] as num?)?.toInt() ?? 0,
        sort: (j['sort'] as num?)?.toDouble() ?? 0,
        ep: (j['ep'] as num?)?.toInt() ?? 0,
        name: j['name']?.toString() ?? '',
        nameCn: j['name_cn']?.toString() ?? '',
        airdate: j['airdate']?.toString() ?? '',
        duration: j['duration']?.toString() ?? '',
        comment: j['comment']?.toString() ?? '',
        desc: j['desc']?.toString() ?? '',
        type: (j['type'] as num?)?.toInt() ?? 0,
      );
}

/// 角色
class BgmCharacter {
  final int id;
  final String name;
  final String image;
  final String relation; // 主角/配角
  final List<String> actors; // CV 名
  const BgmCharacter({required this.id, this.name = '', this.image = '', this.relation = '', this.actors = const []});

  factory BgmCharacter.fromJson(Map<String, dynamic> j) {
    final actorsRaw = j['actors'];
    return BgmCharacter(
      id: (j['id'] as num?)?.toInt() ?? 0,
      name: j['name']?.toString() ?? '',
      image: j['images'] is Map ? (j['images']['medium']?.toString() ?? j['images']['small']?.toString() ?? '') : '',
      relation: j['relation']?.toString() ?? '',
      actors: actorsRaw is List ? actorsRaw.map((a) => a is Map ? a['name']?.toString() ?? '' : '').where((s) => s.isNotEmpty).toList() : const [],
    );
  }
}

/// 关联条目（前传/续作等）
class RelatedSubject {
  final int id;
  final String name;
  final String nameCn;
  final String image;
  final String relation;
  const RelatedSubject({required this.id, this.name = '', this.nameCn = '', this.image = '', this.relation = ''});

  String get displayName => nameCn.isNotEmpty ? nameCn : name;

  factory RelatedSubject.fromJson(Map<String, dynamic> j) => RelatedSubject(
        id: (j['id'] as num?)?.toInt() ?? 0,
        name: j['name']?.toString() ?? '',
        nameCn: j['name_cn']?.toString() ?? '',
        image: j['images'] is Map ? (j['images']['medium']?.toString() ?? '') : '',
        relation: j['relation']?.toString() ?? '',
      );
}

/// 每日放送（一天）
class CalendarDay {
  final int weekday; // 1-7
  final String weekdayCn;
  final List<Subject> items;
  const CalendarDay({required this.weekday, required this.weekdayCn, this.items = const []});
}

/// 追番更新快照：一部番「上次扫到的最新集数」
///
/// 追番检测的全部依据就是拿源站当前最新集数和这里的 [latestSort] 比：
/// 变大了 = 出新集了。
///
/// 【v2.1.0】为什么需要它：翻遍 Kazumi 源码，**没有**追番更新检测——
/// 它靠「打开番剧时实时 queryChapterRoads()」拿到最新集，是实时查询而非
/// 后台比对，收藏卡片上也没有红点/集数快照。所以这里没有可抄的实现，
/// 只能自己存基线再比对。
///
/// 首次扫描只记录基线、不提示（否则一装上就整页红点）。
/// 见 `FollowUpdateService.scan` 里 `baseline == null` 的分支。
class FollowUpdateEntry {
  final int subjectId;

  /// 已知的最新集数（sort 值）
  final double latestSort;

  /// 上次扫描时间（毫秒）
  final int scannedAt;

  /// **首次发现新集**的时间（毫秒）。0 = 没有待看更新。
  /// 用户点进去看过之后清 0，红点消失。
  final int newSince;

  /// 上次扫出这个结果的源（诊断用）
  final String sourceName;

  const FollowUpdateEntry({
    required this.subjectId,
    this.latestSort = 0,
    this.scannedAt = 0,
    this.newSince = 0,
    this.sourceName = '',
  });

  bool get hasUpdate => newSince > 0;

  FollowUpdateEntry copyWith({
    double? latestSort,
    int? scannedAt,
    int? newSince,
    String? sourceName,
  }) =>
      FollowUpdateEntry(
        subjectId: subjectId,
        latestSort: latestSort ?? this.latestSort,
        scannedAt: scannedAt ?? this.scannedAt,
        newSince: newSince ?? this.newSince,
        sourceName: sourceName ?? this.sourceName,
      );

  Map<String, dynamic> toJson() => {
        'subject_id': subjectId,
        'latest_sort': latestSort,
        'scanned_at': scannedAt,
        'new_since': newSince,
        'source': sourceName,
      };

  factory FollowUpdateEntry.fromJson(Map<String, dynamic> j) => FollowUpdateEntry(
        subjectId: (j['subject_id'] as num?)?.toInt() ?? 0,
        latestSort: (j['latest_sort'] as num?)?.toDouble() ?? 0,
        scannedAt: (j['scanned_at'] as num?)?.toInt() ?? 0,
        newSince: (j['new_since'] as num?)?.toInt() ?? 0,
        sourceName: j['source']?.toString() ?? '',
      );
}
