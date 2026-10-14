/// 取一批真实的 Bangumi 条目 id（供 smoke_play.ps1 冒烟测试用）
///
/// 运行：dart run tool/get_smoke_ids.dart
/// 输出：每行 `id<TAB>名称`，可直接喂给 smoke_play.ps1 -IdsFile
library;

import 'dart:io';

import 'package:kchan/api/bangumi_api.dart';

Future<void> main() async {
  final api = BangumiApi();
  final out = <String>{};

  // ① 热门榜（一次拿一批不同番剧）
  try {
    final hot = await api.trends(limit: 24);
    for (final s in hot) {
      out.add('${s.id}\t${s.displayName}');
    }
    stdout.writeln('热门榜: ${hot.length} 条');
  } catch (e) {
    stderr.writeln('热门榜失败: $e');
  }

  // ② 再按几个关键词补充（覆盖不同年代/类型）
  for (final kw in ['进击的巨人', 'CLANNAD', '孤独摇滚', '赛马娘']) {
    try {
      final r = await api.searchSubjects(kw, limit: 2);
      for (final s in r.items) {
        out.add('${s.id}\t${s.displayName}');
      }
    } catch (e) {
      stderr.writeln('搜索 $kw 失败: $e');
    }
  }

  final list = out.toList();
  File(r'D:\dev\smoke_ids.txt').writeAsStringSync(list.join('\n'));
  for (final l in list) {
    stdout.writeln(l);
  }
  stdout.writeln('\n共 ${list.length} 条，已写入 D:\\dev\\smoke_ids.txt');
}
