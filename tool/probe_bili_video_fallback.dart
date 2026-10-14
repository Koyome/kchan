/// 验证「B站普通投稿」这条回退路是否可用（严格校验版）
///
/// ## 背景
///
/// 「进击的巨人」等番不在 B站**番剧库**里，但 B站有大量用户投稿的单集视频，
/// 每个都有自己的弹幕池。若能可靠地找到「第 N 集」对应的单集视频，
/// 就能给这些番补上弹幕。
///
/// ## 风险（必须严格校验，否则比没有弹幕更糟）
///
/// 初版探测看到视频搜索前排全是**合集/解说/reaction**
/// （时长 108 分钟、2209 分钟）。把弹幕同步到那种视频上，
/// 时间轴完全对不上，满屏无关内容 —— 比没有弹幕更糟。
///
/// ## 校验规则
///
/// 1. 时长必须落在**单集合理区间**（3~45 分钟）—— 直接排除合集与短视频
/// 2. 标题必须含**集号特征**（`第N集` / `第N话` / `EP n` / `【n】` 等）
/// 3. 标题不应含**排除特征**（合集/解说/reaction/预告/OP/ED/MAD/混剪…）
/// 4. 打分取最优，且必须有实际弹幕
///
/// 跑法：`dart run tool/probe_bili_video_fallback.dart`
library;

import 'dart:convert';
import 'dart:io';

const _ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

late HttpClient _client;
String? _cookie;

Future<Map<String, dynamic>?> getJson(String url) async {
  try {
    final req = await _client.getUrl(Uri.parse(url));
    req.headers.set('User-Agent', _ua);
    req.headers.set('Accept', 'application/json, text/plain, */*');
    req.headers.set('Accept-Language', 'zh-CN,zh;q=0.9');
    req.headers.set('Referer', 'https://www.bilibili.com/');
    req.headers.set('Origin', 'https://www.bilibili.com');
    if (_cookie != null) req.headers.set('Cookie', _cookie!);
    final res = await req.close();
    final body = await res.transform(utf8.decoder).join();
    final sc = res.headers['set-cookie'];
    if (sc != null && sc.isNotEmpty) {
      _cookie = sc.map((s) => s.split(';').first.trim()).join('; ');
    }
    if (res.statusCode != 200) return null;
    return jsonDecode(body) as Map<String, dynamic>;
  } catch (_) {
    return null;
  }
}

/// 排除特征：出现即判定为「不是单集正片」
final _badWords = RegExp(
    r'合集|全集|全\d+[集话]|解说|reaction|反应|预告|PV|OP|ED|MAD|混剪|'
    r'剪辑|盘点|排行|排名|吐槽|影评|杂谈|直播|录播|花絮|片段|赏析|'
    r'一口气|分钟|看完|通关|流程|攻略|鼓谱|翻奏|钢琴|吉他|'
    r'第\d+季.*第\d+季|季全|完结',
    caseSensitive: false);

/// 集号特征：必须命中
final _epWords = RegExp(
    r'第\s*\d+\s*[集话話]|EP\s*\d+|E\d{1,3}\b|\[\d{1,3}\]|【\d{1,3}】|'
    r'\d{1,3}\s*[集话話]',
    caseSensitive: false);

class Cand {
  Cand(this.bvid, this.title, this.durationSec, this.score);
  final String bvid;
  final String title;
  final int durationSec;
  final int score;
}

Future<void> main() async {
  _client = HttpClient();
  await getJson('https://www.bilibili.com/');

  for (final (title, ep) in [('进击的巨人', 1), ('Code Geass 反叛的鲁路修R2', 1),
                             ('钢之炼金术师 FA', 1)]) {
    stdout.writeln('\n${'=' * 76}');
    stdout.writeln('  「$title」第 $ep 集 —— 尝试普通投稿回退');
    stdout.writeln('=' * 76);
    final kw = '$title 第$ep集';
    final j = await getJson(
        'https://api.bilibili.com/x/web-interface/search/type'
        '?search_type=video&keyword=${Uri.encodeQueryComponent(kw)}');
    final res = ((j?['data'] as Map?)?['result'] as List?) ?? const [];
    stdout.writeln('  搜索命中 ${res.length} 条');

    final cands = <Cand>[];
    for (final r in res) {
      if (r is! Map) continue;
      final t = '${r['title'] ?? ''}'.replaceAll(RegExp(r'<[^>]*>'), '');
      final dur = '${r['duration'] ?? ''}';
      final parts = dur.split(':').map(int.tryParse).toList();
      var sec = 0;
      if (parts.length == 2) {
        sec = (parts[0] ?? 0) * 60 + (parts[1] ?? 0);
      } else if (parts.length == 3) {
        sec = (parts[0] ?? 0) * 3600 + (parts[1] ?? 0) * 60 + (parts[2] ?? 0);
      }
      final bvid = '${r['bvid'] ?? ''}';
      if (bvid.isEmpty) continue;

      var score = 0;
      final durOk = sec >= 180 && sec <= 2700; // 3~45 分钟
      final hasEp = _epWords.hasMatch(t);
      final isBad = _badWords.hasMatch(t);
      if (durOk) score += 2;
      if (hasEp) score += 2;
      if (isBad) score -= 10;
      // 集号与目标集一致再加分
      final m = RegExp(r'第\s*(\d+)\s*[集话話]').firstMatch(t);
      if (m != null && int.tryParse(m.group(1)!) == ep) score += 3;

      cands.add(Cand(bvid, t, sec, score));
    }
    cands.sort((a, b) => b.score.compareTo(a.score));
    stdout.writeln('  候选（按时长/集号/排除词打分，前 6）:');
    for (final c in cands.take(6)) {
      final mm = (c.durationSec ~/ 60).toString().padLeft(2, '0');
      final ss = (c.durationSec % 60).toString().padLeft(2, '0');
      final mark = c.score >= 5 ? ' [通过]' : c.score >= 2 ? ' [边缘]' : ' [否决]';
      stdout.writeln('    score=${c.score.toString().padLeft(3)}$mark '
          '${mm}:${ss}  ${c.bvid}  ${c.title}');
    }
    final best = cands.where((c) => c.score >= 5).toList();
    stdout.writeln('  → 严格通过 ${best.length} 条');
    if (best.isEmpty) {
      stdout.writeln('     结论：**无法可靠匹配**，应保持「无弹幕」而不是硬凑');
    }
  }
  _client.close(force: true);
}
