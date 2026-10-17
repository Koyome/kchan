/// 追番库：收藏状态分页 + 进度 + 新一集更新提示
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../api/follow_updates.dart';
import '../store/local_store.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'detail_page.dart';

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});
  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  String _tab = '全部';
  bool _grid = true;
  bool _scanning = false;

  static const _tabs = ['全部', '在看', '想看', '看过', '搁置', '抛弃'];

  FavStatus? _statusFor(String tab) {
    switch (tab) {
      case '在看':
        return FavStatus.doing;
      case '想看':
        return FavStatus.wish;
      case '看过':
        return FavStatus.collect;
      case '搁置':
        return FavStatus.onHold;
      case '抛弃':
        return FavStatus.dropped;
      default:
        return null;
    }
  }

  @override
  void initState() {
    super.initState();
    // 进页面时补扫一次：启动那轮可能已过去几小时（软件常开的场景）。
    // 不 force —— 距上次不足 scanInterval 会被 scan() 自己节流掉，等于没成本。
    unawaited(FollowUpdateService.instance.scan());
  }

  /// 手动检测新一集
  Future<void> _scan() async {
    if (_scanning) return;
    setState(() => _scanning = true);
    try {
      final report = await FollowUpdateService.instance.scan(force: true);
      if (!mounted) return;
      final msg = report.updated > 0
          ? '${report.updated} 部番剧有新一集'
          : (report.failed > 0 ? '暂未检测到更新（${report.failed} 部没扫到）' : '暂未检测到更新');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('检测失败：$e')));
    } finally {
      if (mounted) setState(() => _scanning = false);
  }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: const Text('追番'),
        actions: [
          IconButton(
            onPressed: _scanning ? null : _scan,
            icon: _scanning
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh, size: 20),
            tooltip: '检测新一集',
          ),
          IconButton(
            onPressed: () => setState(() => _grid = !_grid),
            icon: Icon(_grid ? Icons.view_list_outlined : Icons.grid_view_outlined, size: 20),
            tooltip: _grid ? '列表' : '网格',
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: Listenable.merge([Store.favorites, Store.progress, Store.followUpdates]),
        builder: (context, _) {
          final target = _statusFor(_tab);
          final list = (target == null ? Store.favorites.map.values.toList() : Store.favorites.byStatus(target))
            ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

          return Column(
            children: [
              SizedBox(
                height: 46,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  itemCount: _tabs.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 7),
                  itemBuilder: (_, i) {
                    final t = _tabs[i];
                    final active = t == _tab;
                    final count = t == '全部' ? Store.favorites.map.length : Store.favorites.byStatus(_statusFor(t)!).length;
                    return GestureDetector(
                      onTap: () => setState(() => _tab = t),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
                        decoration: BoxDecoration(
                          color: active ? K.accent : Colors.transparent,
                          border: Border.all(color: active ? K.accent : Theme.of(context).colorScheme.outlineVariant, width: .9),
                          borderRadius: BorderRadius.circular(K.radiusSm),
                        ),
                        child: Text(
                          '$t${count > 0 ? " $count" : ""}',
                          style: TextStyle(fontSize: 12.5, color: active ? Colors.white : Theme.of(context).colorScheme.onSurface, height: 1.2),
                        ),
                      ),
                    );
                  },
                ),
              ),
              Expanded(
                child: list.isEmpty
                    ? const EmptyHint(
                        icon: Icons.bookmark_border,
                        title: '追番列表还是空的',
                        sub: '在番剧详情页选择「在看 / 想看」即可加入',
                      )
                    : (_grid ? _gridView(list) : _listView(list)),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _gridView(List<FavEntry> list) {
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 140,
        childAspectRatio: .52,
        mainAxisSpacing: 14,
        crossAxisSpacing: 12,
      ),
      itemCount: list.length,
      itemBuilder: (_, i) {
        final e = list[i];
        final prog = Store.progress.map[e.subject.id];
        final total = e.subject.totalEpisodes > 0 ? e.subject.totalEpisodes : e.subject.eps;
        final upd = Store.followUpdates.of(e.subject.id);
        final w = (MediaQuery.of(context).size.width - 32 - 12 * ((MediaQuery.of(context).size.width / 140).floor())) /
            (MediaQuery.of(context).size.width / 140).floor();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GestureDetector(
              onTap: () => _open(context, e),
              child: Stack(
                children: [
                  KCover(url: e.subject.images.cover, width: w.clamp(90, 160), height: w.clamp(90, 160) * 1.4, subjectId: e.subject.id),
                  Positioned(
                    left: 6,
                    top: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                      decoration: BoxDecoration(color: K.accent, borderRadius: BorderRadius.circular(4)),
                      child: Text(e.status.label, style: const TextStyle(fontSize: 9, color: Colors.white, height: 1.2)),
                    ),
                  ),
                  if (upd != null && upd.hasUpdate)
                    const Positioned(
                      right: 6,
                      top: 6,
                      child: _NewEpisodeDot(),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Text(e.subject.displayName, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontSize: 12.5)),
            if (upd != null && upd.hasUpdate)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text(
                  '更新至第 ${_fmtSort(upd.latestSort)} 集',
                  style: const TextStyle(fontSize: 10, color: K.accent, height: 1.3),
                ),
              )
            else if (total > 0 && prog != null)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text('${prog.watchedCount} / $total 集', style: Theme.of(context).textTheme.labelSmall?.copyWith(fontSize: 10)),
              ),
          ],
        );
      },
    );
  }

  Widget _listView(List<FavEntry> list) {
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 6),
      itemCount: list.length,
      separatorBuilder: (_, __) => const Divider(indent: 16, endIndent: 16),
      itemBuilder: (_, i) {
        final e = list[i];
        final prog = Store.progress.map[e.subject.id];
        final total = e.subject.totalEpisodes > 0 ? e.subject.totalEpisodes : e.subject.eps;
        final upd = Store.followUpdates.of(e.subject.id);
        final hasNew = upd != null && upd.hasUpdate;
        return ListTile(
          onTap: () => _open(context, e),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          leading: Stack(
            clipBehavior: Clip.none,
            children: [
              KCover(url: e.subject.images.cover, width: 48, height: 66, radius: 7, subjectId: e.subject.id),
              if (hasNew)
                const Positioned(
                  right: -3,
                  top: -3,
                  child: _NewEpisodeDot(size: 11),
                ),
            ],
          ),
          title: Text(e.subject.displayName, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14)),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Text(
              hasNew
                  ? '${e.status.label} · 更新至第 ${_fmtSort(upd.latestSort)} 集'
                  : '${e.status.label}${total > 0 && prog != null ? " · 已看 ${prog.watchedCount}/$total 集" : ""}',
              style: TextStyle(
                fontSize: 11.5,
                color: hasNew ? K.accent : null,
              ),
            ),
          ),
          trailing: const Icon(Icons.chevron_right, size: 19),
        );
      },
    );
  }

  /// 进入详情；进去即视为「已看到更新」，清掉红点
  Future<void> _open(BuildContext context, FavEntry e) async {
    Store.followUpdates.markSeen(e.subject.id);
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => DetailPage(subjectId: e.subject.id, initial: e.subject)));
  }

  static String _fmtSort(double v) => v == v.roundToDouble() ? '${v.toInt()}' : '$v';
}

/// 封面右上角的新集红点
class _NewEpisodeDot extends StatelessWidget {
  const _NewEpisodeDot({this.size = 9});
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: K.accent,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 1.2),
        ),
      );
}
