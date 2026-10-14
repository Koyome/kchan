/// 搜索页：Bangumi 条目搜索
library;

import 'package:flutter/material.dart';

import '../api/bangumi_api.dart';
import '../models.dart';
import '../store/local_store.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'detail_page.dart';

class SearchPage extends StatefulWidget {
  const SearchPage({super.key});
  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _ctl = TextEditingController();
  final _scroll = ScrollController();

  List<Subject> _items = [];
  bool _loading = false;
  bool _loadingMore = false;
  bool _hasMore = true;
  int _offset = 0;
  String? _error;
  String _sort = 'match';
  String _keyword = '';
  bool _searched = false;

  static const _sorts = [('match', '匹配'), ('heat', '热度'), ('rank', '排名'), ('score', '评分')];

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 600 && !_loadingMore && _hasMore) {
        _more();
      }
    });
  }

  @override
  void dispose() {
    _ctl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _search({bool reset = true}) async {
    final kw = _ctl.text.trim();
    if (kw.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _loading = true;
      _error = null;
      _keyword = kw;
      _searched = true;
      if (reset) {
        _items = [];
        _offset = 0;
        _hasMore = true;
      }
    });
    Store.settings.addSearchHistory(kw);
    try {
      final r = await BangumiApiHolder.api.searchSubjects(kw, sort: _sort, offset: 0, limit: 24);
      if (!mounted) return;
      setState(() {
        _items = r.items;
        _offset = r.items.length;
        _hasMore = r.items.length < r.total && r.items.isNotEmpty;
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

  Future<void> _more() async {
    if (_loadingMore || !_hasMore || _keyword.isEmpty) return;
    setState(() => _loadingMore = true);
    try {
      final r = await BangumiApiHolder.api.searchSubjects(_keyword, sort: _sort, offset: _offset, limit: 24);
      if (!mounted) return;
      setState(() {
        _items = [..._items, ...r.items];
        _offset += r.items.length;
        _hasMore = r.items.isNotEmpty;
        _loadingMore = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: const Text('搜索'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(104),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                child: TextField(
                  controller: _ctl,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _search(),
                  decoration: InputDecoration(
                    hintText: '番剧名 / 关键词',
                    prefixIcon: const Icon(Icons.search, size: 19),
                    suffixIcon: _ctl.text.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.close, size: 17),
                            onPressed: () => setState(() => _ctl.clear()),
                          ),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              SizedBox(
                height: 34,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: _sorts.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 7),
                  itemBuilder: (_, i) {
                    final s = _sorts[i];
                    final active = _sort == s.$1;
                    return GestureDetector(
                      onTap: () {
                        setState(() => _sort = s.$1);
                        if (_searched) _search();
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
                        decoration: BoxDecoration(
                          color: active ? K.accent.withValues(alpha: .1) : Colors.transparent,
                          border: Border.all(color: active ? K.accent.withValues(alpha: .5) : cs.outlineVariant, width: .8),
                          borderRadius: BorderRadius.circular(K.radiusSm),
                        ),
                        child: Text('按${s.$2}', style: TextStyle(fontSize: 12, color: active ? K.accent : cs.onSurface.withValues(alpha: .7))),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 10),
            ],
          ),
        ),
      ),
      body: _buildBody(cs),
    );
  }

  Widget _buildBody(ColorScheme cs) {
    if (!_searched) {
      return AnimatedBuilder(
        animation: Store.settings,
        builder: (context, _) {
          final hist = Store.settings.searchHistory;
          if (hist.isEmpty) {
            return const EmptyHint(icon: Icons.search, title: '搜索番剧', sub: '数据来自 Bangumi 番组计划');
          }
          return ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
                child: Row(
                  children: [
                    Text('搜索历史', style: Theme.of(context).textTheme.labelSmall?.copyWith(fontSize: 11, letterSpacing: 1)),
                    const Spacer(),
                    TextButton(
                      onPressed: () => Store.settings.clearSearchHistory(),
                      style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: Size.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                      child: const Text('清空', style: TextStyle(fontSize: 11.5)),
                    ),
                  ],
                ),
              ),
              for (final h in hist)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.history, size: 18),
                  title: Text(h, style: const TextStyle(fontSize: 13.5)),
                  onTap: () {
                    _ctl.text = h;
                    _search();
                  },
                ),
            ],
          );
        },
      );
    }
    if (_loading) return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    if (_error != null) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [const SizedBox(height: 80), ErrorBar(message: _error!, onRetry: () => _search())],
      );
    }
    if (_items.isEmpty) return const EmptyHint(icon: Icons.sentiment_dissatisfied_outlined, title: '没有找到相关番剧', sub: '换个关键词试试');

    return LayoutBuilder(
      builder: (context, c) {
        // 【v1.9.2 修排版】旧实现在 itemBuilder 里手动算 width：
        //   `(w - 32 - 12 * (w/140).floor()) / (w/140).floor()`
        // 它把 padding(32) 减了、却把 crossAxisSpacing(12) 按整列数乘，
        // 算出的宽度和 GridView 实际分配的格子宽度不一致 →
        // 手机上卡片要么被裁、要么文字挤压换行。
        // 现在列数由委托决定，卡片宽度取 LayoutBuilder 的真实格子宽（严格相等）。
        //
        // 【v1.9.3】高度改用 mainAxisExtent（由 SubjectCard 按字体缩放算），
        // 而不是 childAspectRatio —— 否则用户把系统字号调大后标题会被裁。
        const gap = 12.0;
        final avail = c.maxWidth - 32;
        var cross = (avail / 150).round();
        if (cross < 2) cross = 2;
        if (cross > 8) cross = 8;
        final cellW = (avail - gap * (cross - 1)) / cross;
        final cellH = SubjectCard.gridHeightFor(context, cellW);

        return GridView.builder(
          controller: _scroll,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cross,
            mainAxisSpacing: 14,
            crossAxisSpacing: gap,
            mainAxisExtent: cellH,
          ),
          itemCount: _items.length + (_loadingMore ? cross : 0),
          itemBuilder: (_, i) {
            if (i >= _items.length) {
              return const Center(
                  child: SizedBox(
                      width: 18, height: 18,
                      child: CircularProgressIndicator(strokeWidth: 1.8)));
            }
            final s = _items[i];
            return SubjectCard(
              key: ValueKey('sub-${s.id}'),
              subject: s,
              width: cellW,
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => DetailPage(subjectId: s.id, initial: s))),
            );
          },
        );
      },
    );
  }
}
