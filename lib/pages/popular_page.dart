/// 推荐首页：照搬 Kazumi 的 PopularPage 设计
///
///  - SliverAppBar：大标题「热门番组 + 下拉箭头」，点开是标签菜单
///    （日常/原创/校园/…，与 Kazumi `defaultAnimeTags` 一致）
///  - 内容：竖版封面卡片网格（3/5/6 列随宽度），数据源是 Bangumi
///    「热门番组」趋势榜（next.bgm.tv，镜像回退 rank 搜索）
///  - 滚动到底自动加载下一批（无限滚动）
library;

import 'package:flutter/material.dart';

import '../api/bangumi_api.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'detail_page.dart';

/// 与 Kazumi `defaultAnimeTags` 一致
const kDefaultAnimeTags = [
  '日常', '原创', '校园', '搞笑', '奇幻', '百合', '恋爱', '悬疑',
  '热血', '后宫', '机战', '轻改', '偶像', '治愈', '异世界', '战斗',
  '科幻', '冒险', '音乐', '运动',
];

class PopularPage extends StatefulWidget {
  const PopularPage({super.key});
  @override
  State<PopularPage> createState() => _PopularPageState();
}

class _PopularPageState extends State<PopularPage> {
  static const _pageSize = 24;

  final ScrollController _scroll = ScrollController();
  final List<Subject> _items = [];
  String _tag = ''; // 空 = 热门番组
  bool _loading = false;
  bool _exhausted = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _loadMore(init: true);
    // 【v1.9.2】中文名在后台补齐后无感刷新（首屏不再被中文名阻塞）
    BangumiApi.nameEnrichTick.addListener(_onNamesEnriched);
  }

  @override
  void dispose() {
    BangumiApi.nameEnrichTick.removeListener(_onNamesEnriched);
    _scroll.dispose();
    super.dispose();
  }

  /// 后台补完中文名：用缓存回填后轻量刷新（不发请求）。
  /// 就地改元素（`_items` 是 final 列表），避免整表重建导致滚动位置跳动。
  void _onNamesEnriched() {
    if (!mounted || _items.isEmpty) return;
    final filled = BangumiApi.refillChineseNames(_items);
    var changed = false;
    for (var i = 0; i < filled.length && i < _items.length; i++) {
      if (!identical(filled[i], _items[i])) {
        _items[i] = filled[i];
        changed = true;
      }
    }
    if (changed) setState(() {});
  }

  void _onScroll() {
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 240 &&
        !_loading &&
        !_exhausted) {
      _loadMore();
    }
  }

  Future<void> _loadMore({bool init = false}) async {
    if (_loading) return;
    setState(() {
      _loading = true;
      if (init) _error = null;
    });
    try {
      final offset = init ? 0 : _items.length;
      final List<Subject> batch = _tag.isEmpty
          ? await BangumiApiHolder.api.trends(limit: _pageSize, offset: offset)
          : await BangumiApiHolder.api.byTag(_tag, limit: _pageSize, offset: offset);
      if (!mounted) return;
      setState(() {
        if (init) _items.clear();
        final seen = _items.map((e) => e.id).toSet();
        _items.addAll(batch.where((e) => seen.add(e.id)));
        _exhausted = batch.length < _pageSize;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceFirst('ApiException: ', '');
        _loading = false;
      });
    }
  }

  Future<void> _selectTag(String tag) async {
    if (tag == _tag) return;
    _scroll.animateTo(0,
        duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    setState(() {
      _tag = tag;
      _items.clear();
      _exhausted = false;
    });
    await _loadMore(init: true);
  }

  Future<void> _refresh() async {
    setState(() => _exhausted = false);
    await _loadMore(init: true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: RefreshIndicator(
        color: K.accent,
        onRefresh: _refresh,
        child: CustomScrollView(
          controller: _scroll,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            _appBar(),
            SliverToBoxAdapter(
              child: AnimatedOpacity(
                opacity: _loading && _items.isNotEmpty ? 1 : 0,
                duration: const Duration(milliseconds: 250),
                child: const LinearProgressIndicator(minHeight: 2.5),
              ),
            ),
            if (_error != null && _items.isEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.only(top: 80),
                  child: ErrorBar(message: _error!, onRetry: () => _loadMore(init: true)),
                ),
              )
            else
              _grid(),
            const SliverToBoxAdapter(child: SizedBox(height: 28)),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.small(
        heroTag: 'popular_top',
        onPressed: () => _scroll.animateTo(0,
            duration: const Duration(milliseconds: 350), curve: Curves.easeOut),
        child: const Icon(Icons.arrow_upward, size: 19),
      ),
    );
  }

  Widget _appBar() {
    final theme = Theme.of(context);
    final title = _tag.isEmpty ? '热门番组' : _tag;
    return SliverAppBar(
      pinned: true,
      stretch: true,
      expandedHeight: 108,
      elevation: 0,
      titleSpacing: 0,
      centerTitle: false,
      backgroundColor: theme.colorScheme.surface,
      flexibleSpace: SafeArea(
        child: Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.only(left: 16, right: 60, bottom: 4),
            child: PopupMenuButton<String>(
              tooltip: '选择标签',
              onSelected: _selectTag,
              itemBuilder: (_) => [
                _tagItem('', '热门番组'),
                for (final t in kDefaultAnimeTags) _tagItem(t, t),
              ],
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      title,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.headlineMedium?.copyWith(
                        fontFamily: K.serifFamily,
                        fontFamilyFallback: K.serifFallback,
                        fontWeight: FontWeight.w700,
                        fontSize: 26,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(Icons.keyboard_arrow_down,
                      size: 24, color: theme.iconTheme.color),
                ],
              ),
            ),
          ),
        ),
      ),
      actions: [
        IconButton(
          onPressed: _loading ? null : _refresh,
          icon: _loading && _items.isEmpty
              ? const SizedBox(
                  width: 17, height: 17, child: CircularProgressIndicator(strokeWidth: 1.7))
              : const Icon(Icons.refresh, size: 20),
          tooltip: '刷新',
        ),
      ],
    );
  }

  PopupMenuItem<String> _tagItem(String value, String label) {
    final active = value == _tag;
    return PopupMenuItem<String>(
      value: value,
      child: Row(
        children: [
          Icon(active ? Icons.radio_button_checked : Icons.radio_button_unchecked,
              size: 16, color: active ? K.accent : null),
          const SizedBox(width: 8),
          Text(label),
        ],
      ),
    );
  }

  Widget _grid() {
    final count = _items.isEmpty && _loading ? 12 : _items.length;
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      sliver: SliverLayoutBuilder(
        builder: (context, constraints) {
          // 【v1.9.2 修排版】旧实现有两个真实问题：
          //  1. `cross` 用**整屏宽**算，但网格实际可用宽 = 屏宽 - padding(24) - 间距
          //     → 格子被压得比预期窄；
          //  2. `mainAxisExtent = width / cross / 0.65 + 34` 也基于整屏宽 →
          //     **算出来的高大 7%**，最后一行还会溢出到下一格。
          // 【v1.9.3】高度也改为按字体缩放计算，大字体下标题不再被裁。
          const gap = 10.0;
          final avail = constraints.crossAxisExtent;
          var cross = (avail / 118).round();
          if (cross < 2) cross = 2;
          if (cross > 8) cross = 8;
          final cellW = (avail - gap * (cross - 1)) / cross;
          return SliverGrid(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: cross,
              mainAxisSpacing: gap,
              crossAxisSpacing: gap,
              // 热门页卡片是「封面 + 单/双行标题」，没有日期行
              mainAxisExtent: cellW * 1.4 + 5 +
                  MediaQuery.textScalerOf(context).scale(12.0) * 1.3 * 2 + 6,
            ),
            delegate: SliverChildBuilderDelegate(
              (context, i) {
                if (_items.isEmpty) return const _SkeletonCard();
                return _SubjectCard(s: _items[i]);
              },
              childCount: count,
            ),
          );
        },
      ),
    );
  }
}

class _SkeletonCard extends StatelessWidget {
  const _SkeletonCard();
  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme.outlineVariant.withValues(alpha: .4);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: Container(decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(8)))),
        const SizedBox(height: 6),
        Container(height: 12, width: 90, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(4))),
      ],
    );
  }
}

class _SubjectCard extends StatelessWidget {
  final Subject s;
  const _SubjectCard({required this.s});

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => DetailPage(subjectId: s.id, initial: s)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                KCover(url: s.images.cover, radius: 8, subjectId: s.id),
                if (s.score > 0)
                  Positioned(
                    left: 5,
                    bottom: 5,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: .55),
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.star_rounded, size: 11, color: Colors.amber),
                          const SizedBox(width: 2),
                          Text(
                            s.score.toStringAsFixed(1),
                            style: const TextStyle(
                                color: Colors.white, fontSize: 10, fontWeight: FontWeight.w600, height: 1.2),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 5),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 1),
            child: Text(
              s.displayName,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: tt.bodySmall?.copyWith(fontSize: 12, height: 1.3),
            ),
          ),
        ],
      ),
    );
  }
}
