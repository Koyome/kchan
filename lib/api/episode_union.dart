/// 【v2.1.3】并集选集算法（详情页与验证工具共用同一份实现）
///
/// ## 为什么要有这个文件
///
/// 旧实现把「哪一集能点」绑定在**当前选中的源**上：源没收到第 3 集时第 3 格
/// 就是「?」，用户以为软件没更新。Kazumi 的做法是分集列表直接来自源、源有
/// 几集就列几集；本文件把两者合起来 —— **格子 = Bangumi 分集 ∪ 各源实际
/// 收录的集**，每格只要能**从任意一条源**找到就标记为可播，并按「不用用户
/// 思考」的规则排出最优源。
///
/// ## 为什么独立成文件
///
/// `lib/pages/detail_page.dart` 是 Flutter 代码，测试脚本跑不动。
/// 把纯逻辑抽到这里后，`tool/verify_new_episode.dart` 验证的就是**详情页
/// 正在跑的那份算法本身**（同一份代码），而不是另写的复制品。
///
/// 纯 Dart：不 import flutter。
library;

import '../models.dart' show Episode;
import 'video_sources.dart' show SourceEpisode;

/// 一个源（构建并集格子的输入）
class UnionSource {
  final String id;
  final String name;

  /// 可直链播放（Windows 上 jx 类源无法内置解析，排序时要降权）
  final bool directPlay;

  /// 实测延迟（ms）；0 = 未测过（按 5s 计，避免未知源抢到最前）
  final int latencyMs;

  /// 每条线路各自的分集（空 = 用 [episodes]）
  final List<List<SourceEpisode>> roads;

  /// 各线路合并后的分集
  final List<SourceEpisode> episodes;

  const UnionSource({
    required this.id,
    required this.name,
    this.directPlay = false,
    this.latencyMs = 0,
    this.roads = const [],
    this.episodes = const [],
  });
}

/// 一格的「可播候选」：哪条源能播这一集
class UnionChoice<T> {
  /// 调用方自定义的挂载数据（详情页挂 AggregatedSource，工具挂名字）
  final T tag;
  final UnionSource source;
  final SourceEpisode ep;

  /// 落在该源的哪条播放线路（0 = 线路1）
  final int lineIndex;
  const UnionChoice(this.tag, this.source, this.ep, this.lineIndex);
}

/// 分集格子里的一格（Bangumi 集 ∪ 源集合集的并集单元）
class UnionTile<T> {
  final int key;

  /// Bangumi 分集（null = 源已收录但 Bangumi 数据还没有的集，新番常见）
  final Episode? bgm;

  /// 展示标题（Bangumi 名优先，否则源集名）
  final String title;
  final List<UnionChoice<T>> choices;

  UnionTile({
    required this.key,
    required this.bgm,
    required this.title,
    List<UnionChoice<T>>? choices,
  }) : choices = choices ?? [];

  /// 展示用集号文本
  String get labelText => bgm?.sortLabel ?? '$key';

  /// 展示排序值（进度记录用）
  double get label => bgm?.sort ?? key.toDouble();

  /// 最优候选（null = 所有源都没收录这一集）
  UnionChoice<T>? get best => choices.isEmpty ? null : choices.first;
}

/// 排序提示（让「你刚选过的源」稳住，不来回跳）
class UnionRankHints {
  /// 用户**显式点选**的源 id（最高优先）
  final String selectedSourceId;

  /// 当前生效源 id（次优先）
  final String currentSourceId;
  const UnionRankHints({this.selectedSourceId = '', this.currentSourceId = ''});
}

/// 构建并集分集格子。
///
/// 集数归位的优先级：
///   ① 源集号与 Bangumi sort 相同 → 同一格；
///   ② 与 Bangumi 绝对话数（ep）相同 → 同一格（源用全局编号时）；
///   ③ 都没匹配上 → 作为「源专属集」新增一格
///      （源已更到第 13 集而 Bangumi 数据还停在 12 集时，正是这一条兜住）。
///
/// 每格内的候选源排序（「不用用户思考」的核心）：
///   ① 用户显式点选的源 → ② 当前生效源 → ③ 可直链播放的源
///   → ④ 实测延迟低的 → ⑤ 线路号小的。
List<UnionTile<T>> buildEpisodeUnion<T>({
  required List<Episode> bgmEpisodes,
  required List<(UnionSource, T)> sources,
  UnionRankHints hints = const UnionRankHints(),
}) {
  final tiles = <int, UnionTile<T>>{};
  for (final e in bgmEpisodes) {
    final k = e.sort.round();
    tiles.putIfAbsent(
        k,
        () => UnionTile<T>(
            key: k,
            bgm: e,
            title: e.displayName.isNotEmpty ? e.displayName : e.name));
  }
  final absToKey = <int, int>{};
  for (final e in bgmEpisodes) {
    if (e.ep > 0) absToKey.putIfAbsent(e.ep, () => e.sort.round());
  }

  for (final (src, tag) in sources) {
    // roads 为空时用合并列表（lineIndex 恒为 0）
    if (src.roads.isEmpty) {
      for (final se in src.episodes) {
        _place(tiles, absToKey, src, tag, se, 0);
      }
    } else {
      for (var li = 0; li < src.roads.length; li++) {
        for (final se in src.roads[li]) {
          _place(tiles, absToKey, src, tag, se, li);
        }
      }
    }
  }

  int score(UnionChoice<T> c) {
    var s = 0;
    if (hints.selectedSourceId.isNotEmpty &&
        c.source.id == hints.selectedSourceId) {
      s -= 1000;
    }
    if (hints.currentSourceId.isNotEmpty &&
        c.source.id == hints.currentSourceId) {
      s -= 500;
    }
    if (!c.source.directPlay) s += 200;
    s += c.source.latencyMs == 0 ? 5 : (c.source.latencyMs / 1000).round();
    return s;
  }

  for (final t in tiles.values) {
    t.choices.sort((a, b) {
      final d = score(a).compareTo(score(b));
      if (d != 0) return d;
      return a.lineIndex.compareTo(b.lineIndex);
    });
  }

  return tiles.values.toList()..sort((a, b) => a.key.compareTo(b.key));
}

void _place<T>(
  Map<int, UnionTile<T>> tiles,
  Map<int, int> absToKey,
  UnionSource src,
  T tag,
  SourceEpisode se,
  int lineIndex,
) {
  int key;
  if (tiles.containsKey(se.sort)) {
    key = se.sort;
  } else if (absToKey.containsKey(se.sort)) {
    key = absToKey[se.sort]!;
  } else {
    key = se.sort;
    tiles[key] = UnionTile<T>(key: key, bgm: null, title: se.title);
  }
  tiles[key]!.choices.add(UnionChoice<T>(tag, src, se, lineIndex));
}
