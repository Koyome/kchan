/// Bangumi 数据源性能对照：旧镜像顺序（bgmapi 优先） vs 新镜像顺序（kazumi.fyi 优先）
///
/// 运行：dart run tool/bench_bangumi.dart
///
/// 为什么要这个基准：`api.bgm.tv` / `next.bgm.tv` 在本机 15s 超时，
/// 旧代码把它们放进竞速列表，**最坏情况下每个请求都要等 6s 才裁决**。
/// 而首页/详情页会连续发 4 个请求 → 感知上就是「点进去卡十几秒」。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

const ua = 'kchan-bench/1.0';

/// 旧顺序（v1.9.0 的 presetBases）
const oldBases = <String>[
  'https://bgmapi.anibt.net',
  'https://api.bgm.tv',
  'https://api.bangumi.lol',
];

/// 新顺序（v1.9.1）
const newBases = <String>[
  'https://api.kazumi.fyi',
  'https://bgmapi.anibt.net',
  'https://api.bgm.tv',
];

/// 路径改写（与 lib/api/bangumi_api.dart 的 _pathFor 一致）
String? pathFor(String base, String path) {
  final isKazumi = base.contains('kazumi.fyi');
  if (!isKazumi) return path;
  final mSub = RegExp(r'^/v0/subjects/(\d+)$').firstMatch(path);
  if (mSub != null) return '/p1/subjects/${mSub.group(1)}';
  if (path.startsWith('/v0/episodes')) return path;
  if (RegExp(r'^/v0/subjects/\d+/(characters|subjects)$').hasMatch(path)) {
    return path;
  }
  if (path == '/calendar' || path == '/v0/calendar') return '/p1/calendar';
  return null;
}

/// 复刻 _race：错峰 300ms、超时 6s、谁先 200 用谁
Future<({int ms, String? via, int? status})> race(
  List<String> bases,
  String path, {
  Duration timeout = const Duration(seconds: 6),
  bool rewrite = false,
}) async {
  final client = http.Client();
  final sw = Stopwatch()..start();
  final completer = Completer<({int ms, String? via, int? status})>();
  final targets = <(String, String)>[];
  for (final b in bases) {
    final p = rewrite ? pathFor(b, path) : path;
    if (p == null) continue;
    targets.add((b, p));
  }
  if (targets.isEmpty) {
    return (ms: -1, via: null, status: null);
  }
  var remaining = targets.length;
  for (var i = 0; i < targets.length; i++) {
    final (base, effPath) = targets[i];
    final delay = i == 0 ? 0 : 300 * i;
    unawaited(() async {
      try {
        if (delay > 0) {
          await Future<void>.delayed(Duration(milliseconds: delay));
        }
        if (completer.isCompleted) return;
        final res = await client
            .get(Uri.parse('$base$effPath'),
                headers: {'User-Agent': ua, 'Accept': 'application/json'})
            .timeout(timeout);
        if (res.statusCode == 200) {
          if (!completer.isCompleted) {
            completer.complete((ms: sw.elapsedMilliseconds, via: base, status: 200));
          }
          return;
        }
        if (res.statusCode == 404 || res.statusCode == 401 || res.statusCode == 405) {
          // 该镜像不支持此路径，记录但不否决
        }
      } catch (_) {
        // 超时/网络错误
      } finally {
        remaining--;
        if (remaining == 0 && !completer.isCompleted) {
          completer.complete((ms: sw.elapsedMilliseconds, via: null, status: null));
        }
      }
    }());
  }
  final r = await completer.future;
  client.close();
  return r;
}

void report(String label, ({int ms, String? via, int? status}) r) {
  final via = r.via == null ? '（全部失败）' : r.via!.replaceFirst('https://', '');
  stdout.writeln('  ${label.padRight(34)} ${r.ms.toString().padLeft(6)} ms   '
      '${r.via == null ? "✗" : "✓"} $via');
}

Future<void> main() async {
  stdout.writeln('══ Bangumi 数据源竞速对照 ══\n');

  // 模拟「打开一个番剧详情页」的 4 个请求
  const scenario = <(String, String)>[
    ('条目元数据', '/v0/subjects/12'),
    ('分集列表', '/v0/episodes?subject_id=12&limit=100&offset=0&type=0'),
    ('角色', '/v0/subjects/12/characters'),
    ('相关条目', '/v0/subjects/12/subjects'),
  ];

  for (final cfg in [
    (label: '旧：bgmapi 优先（无路径改写）', bases: oldBases, rewrite: false),
    (label: '新：kazumi.fyi 优先 + 路径改写', bases: newBases, rewrite: true),
  ]) {
    stdout.writeln('【${cfg.label}】');
    var worst = 0;
    for (final (name, path) in scenario) {
      final r = await race(cfg.bases, path,
          rewrite: cfg.rewrite, timeout: const Duration(seconds: 6));
      report(name, r);
      if (r.ms > worst) worst = r.ms;
    }
    stdout.writeln('  → 串行总耗时（最坏）: $worst ms\n');
  }

  stdout.writeln('══ 说明 ══');
  stdout.writeln('  详情页的 4 个请求在新代码里是**并发**发出的，');
  stdout.writeln('  所以实际首屏等待 ≈ 最慢的那一个，而不是四项之和。');
  stdout.writeln('  旧代码的元数据请求还要先等完才发后面 3 个（1+3 两波）。');
}
