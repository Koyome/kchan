/// 观看历史
library;

import 'package:flutter/material.dart';

import '../api/video_sources.dart';
import '../store/local_store.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'detail_page.dart';
import 'player_page.dart';

class HistoryPage extends StatelessWidget {
  const HistoryPage({super.key});

  static String _ago(int ts) {
    if (ts == 0) return '';
    final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ts));
    if (d.inMinutes < 1) return '刚刚';
    if (d.inMinutes < 60) return '${d.inMinutes} 分钟前';
    if (d.inHours < 24) return '${d.inHours} 小时前';
    if (d.inDays < 30) return '${d.inDays} 天前';
    return '${(d.inDays / 30).floor()} 个月前';
  }

  static String _progress(HistoryEntry e) {
    if (e.durationMs <= 0) return '';
    final p = (e.positionMs / e.durationMs * 100).clamp(0, 100).toStringAsFixed(0);
    return '$p%';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: const Text('观看历史'),
        actions: [
          AnimatedBuilder(
            animation: Store.history,
            builder: (context, _) => Store.history.items.isEmpty
                ? const SizedBox.shrink()
                : IconButton(
                    tooltip: '清空历史',
                    icon: const Icon(Icons.delete_sweep_outlined, size: 20),
                    onPressed: () async {
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: const Text('清空观看历史？'),
                          content: const Text('仅清除本机的历史记录，不影响收藏与进度。'),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
                            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('清空')),
                          ],
                        ),
                      );
                      if (ok == true) Store.history.clear();
                    },
                  ),
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: Store.history,
        builder: (context, _) {
          final items = Store.history.items;
          if (items.isEmpty) {
            return const EmptyHint(icon: Icons.history, title: '还没有观看记录', sub: '开始追番后这里会显示最近看过的剧集');
          }
          return ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 6),
            itemCount: items.length,
            separatorBuilder: (_, __) => const Divider(indent: 16, endIndent: 16),
            itemBuilder: (context, i) {
              final e = items[i];
              final pct = _progress(e);
              return InkWell(
                onTap: () async {
                  // 有可用直链则直接续播，否则回到详情页重新解析
                  if (e.playUrl.isNotEmpty) {
                    VideoSource? src;
                    for (final s in SourceRegistry.sources) {
                      if (s.name == e.sourceName) {
                        src = s;
                        break;
                      }
                    }
                    await Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => PlayerPage(
                        subject: e.subject,
                        rule: src?.rule,
                        pageUrl: e.pageUrl.isEmpty ? null : e.pageUrl,
                        episodeTitle: e.epName.isNotEmpty ? e.epName : '第 ${e.epSort.toStringAsFixed(0)} 集',
                        episodeSort: e.epSort,
                        episodeId: e.epId,
                        playUrl: e.playUrl,
                        startPositionMs: e.positionMs,
                      ),
                    ));
                  } else {
                    Navigator.of(context).push(MaterialPageRoute(builder: (_) => DetailPage(subjectId: e.subject.id, initial: e.subject)));
                  }
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      KCover(url: e.subject.images.cover, width: 52, height: 72, radius: 7, subjectId: e.subject.id),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(e.subject.displayName, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14)),
                            const SizedBox(height: 3),
                            Text(
                              '第 ${e.epSort.toStringAsFixed(0)} 集${e.epName.isNotEmpty && e.epName != e.subject.displayName ? " · ${e.epName}" : ""}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 12),
                            ),
                            const SizedBox(height: 6),
                            Row(
                              children: [
                                if (e.sourceName.isNotEmpty)
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                                    decoration: BoxDecoration(
                                      border: Border.all(color: Theme.of(context).colorScheme.outlineVariant, width: .8),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(e.sourceName.toUpperCase(),
                                        style: const TextStyle(fontFamily: K.monoFamily, fontFamilyFallback: K.monoFallback, fontSize: 9, letterSpacing: .5, height: 1.3)),
                                  ),
                                const SizedBox(width: 8),
                                if (pct.isNotEmpty) Text('已看 $pct', style: Theme.of(context).textTheme.labelSmall?.copyWith(fontSize: 10)),
                                const Spacer(),
                                Text(_ago(e.watchedAt), style: Theme.of(context).textTheme.labelSmall?.copyWith(fontSize: 10)),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const Icon(Icons.play_circle_outline, size: 22, color: K.accent),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
