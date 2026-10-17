/// 首页：每日放送时间轴（Kazumi 首页布局）+ 热门/本季
library;

import 'package:flutter/material.dart';

import '../api/bangumi_api.dart';
import '../models.dart';
import '../store/local_store.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'detail_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<CalendarDay>? _days;
  String? _error;
  bool _loading = false;
  int _selectedDay = DateTime.now().weekday; // 1=周一

  @override
  void initState() {
    super.initState();
    _load();
    // 【v1.9.2】中文名在后台补齐后无感刷新（不再阻塞首屏）
    BangumiApi.nameEnrichTick.addListener(_onNamesEnriched);
  }

  @override
  void dispose() {
    BangumiApi.nameEnrichTick.removeListener(_onNamesEnriched);
    super.dispose();
  }

  /// 后台补完中文名：用缓存回填后轻量刷新（不发请求）
  void _onNamesEnriched() {
    if (!mounted || _days == null) return;
    setState(() {
      _days = [
        for (final d in _days!)
          CalendarDay(
            weekday: d.weekday,
            weekdayCn: d.weekdayCn,
            items: BangumiApi.refillChineseNames(d.items),
          )
      ];
    });
  }

  Future<void> _load({bool force = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final days = await BangumiApiHolder.api.calendarFast(force: force);
      // 按周一到周日排序，去掉空组
      days.sort((a, b) => a.weekday.compareTo(b.weekday));
      if (!mounted) return;
      setState(() {
        _days = days.where((d) => d.items.isNotEmpty).toList();
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

  static const _weekLabels = ['一', '二', '三', '四', '五', '六', '日'];

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 18,
        title: Row(
          children: [
            Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(color: K.accent, borderRadius: BorderRadius.circular(7)),
              alignment: Alignment.center,
              child: const Text('K',
                  style: TextStyle(
                      color: Colors.white,
                      fontFamily: K.serifFamily,
                      fontFamilyFallback: K.serifFallback,
                      fontSize: 15.5,
                      fontWeight: FontWeight.w600,
                      height: 1.12)),
            ),
            const SizedBox(width: 9),
            const Text('K酱'),
            const SizedBox(width: 8),
            Text('追番 · 放送表', style: Theme.of(context).textTheme.labelSmall?.copyWith(fontSize: 10)),
          ],
        ),
        actions: [
          IconButton(
            onPressed: _loading ? null : () => _load(force: true),
            icon: _loading
                ? const SizedBox(width: 17, height: 17, child: CircularProgressIndicator(strokeWidth: 1.7))
                : const Icon(Icons.refresh, size: 20),
            tooltip: '刷新',
          ),
        ],
      ),
      body: RefreshIndicator(
        color: K.accent,
        onRefresh: () => _load(force: true),
        child: _buildBody(cs),
      ),
    );
  }

  Widget _buildBody(ColorScheme cs) {
    if (_error != null) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const SizedBox(height: 100),
          ErrorBar(message: _error!, onRetry: _load),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              '提示：Bangumi 官方接口在中国大陆可能被封锁。可到「设置 → 数据源」切换镜像或配置代理。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      );
    }
    if (_days == null) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_days!.isEmpty) {
      return const EmptyHint(icon: Icons.calendar_today_outlined, title: '这周还没有放送数据');
    }

    final days = _days!;
    final cur = days.firstWhere((d) => d.weekday == _selectedDay, orElse: () => days.first);

    return CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        SliverToBoxAdapter(child: _weekTabs(days)),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
            child: Row(
              children: [
                Text('星期${cur.weekdayCn.isNotEmpty ? cur.weekdayCn : _weekLabels[cur.weekday - 1]}',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(width: 8),
                Text('${cur.items.length} 部', style: Theme.of(context).textTheme.labelSmall),
              ],
            ),
          ),
        ),
        SliverList.separated(
          itemCount: cur.items.length,
          separatorBuilder: (_, __) => const Divider(indent: 16, endIndent: 16),
          itemBuilder: (_, i) => _row(cur.items[i]),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 28)),
      ],
    );
  }

  Widget _weekTabs(List<CalendarDay> days) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: 52,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        itemCount: days.length,
        separatorBuilder: (_, __) => const SizedBox(width: 7),
        itemBuilder: (_, i) {
          final d = days[i];
          final active = d.weekday == _selectedDay;
          final isToday = d.weekday == DateTime.now().weekday;
          return GestureDetector(
            onTap: () => setState(() => _selectedDay = d.weekday),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 170),
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 4),
              decoration: BoxDecoration(
                color: active ? K.accent : Colors.transparent,
                border: Border.all(color: active ? K.accent : cs.outlineVariant, width: .9),
                borderRadius: BorderRadius.circular(K.radiusSm),
              ),
              child: Row(
                children: [
                  Text(
                    '周${d.weekdayCn.isNotEmpty ? d.weekdayCn : _weekLabels[d.weekday - 1]}',
                    style: TextStyle(fontSize: 12.5, color: active ? Colors.white : cs.onSurface, height: 1.2),
                  ),
                  if (isToday) ...[
                    const SizedBox(width: 5),
                    Container(width: 4, height: 4, decoration: BoxDecoration(color: active ? Colors.white : K.accent, shape: BoxShape.circle)),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _row(Subject s) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => DetailPage(subjectId: s.id, initial: s))),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            KCover(url: s.images.cover, width: 62, height: 87, radius: 8, subjectId: s.id),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(s.displayName, maxLines: 2, overflow: TextOverflow.ellipsis, style: tt.bodyLarge?.copyWith(fontSize: 14.5, height: 1.35)),
                  if (s.name.isNotEmpty && s.displayName != s.name)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(s.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: tt.labelSmall?.copyWith(fontSize: 10.5, letterSpacing: .2)),
                    ),
                  const SizedBox(height: 7),
                  Row(
                    children: [
                      if (s.score > 0) ...[
                        Icon(Icons.star_rounded, size: 13, color: K.accent.withValues(alpha: .8)),
                        const SizedBox(width: 3),
                        Text(s.score.toStringAsFixed(1), style: const TextStyle(fontFamily: K.monoFamily, fontFamilyFallback: K.monoFallback, fontSize: 12, fontWeight: FontWeight.w600)),
                        const SizedBox(width: 10),
                      ],
                      if (s.airDate.isNotEmpty) Text(s.airDate, style: tt.labelSmall?.copyWith(fontSize: 10.5)),
                      const Spacer(),
                      _favTag(s),
                    ],
                  ),
                  if (s.tags.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(s.tags.take(4).join(' · '),
                          maxLines: 1, overflow: TextOverflow.ellipsis, style: tt.labelSmall?.copyWith(fontSize: 10, color: cs.onSurface.withValues(alpha: .42))),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _favTag(Subject s) {
    return AnimatedBuilder(
      animation: Store.favorites,
      builder: (context, _) {
        final st = Store.favorites.statusOf(s.id);
        if (st == FavStatus.none) return const SizedBox.shrink();
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(color: K.accent, borderRadius: BorderRadius.circular(4)),
          child: Text(st.label, style: const TextStyle(fontSize: 9.5, color: Colors.white, height: 1.25)),
        );
      },
    );
  }
}
