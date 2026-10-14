/// 封面候选链体检：对真实条目打印候选地址并逐个实测
///
/// 运行：dart run tool/probe_covers.dart [subjectId...]
///
/// 用途：手机上「封面空白」时，先在这里确认到底是
/// 「候选地址不全」/「网络不通」/「探测方式不对」，而不是靠猜。
library;

import 'dart:async';
import 'dart:io';

import 'package:kchan/api/bangumi_api.dart';

const _kProbeTimeout = Duration(seconds: 8);
final _client = HttpClient()
  ..connectionTimeout = const Duration(seconds: 6)
  ..idleTimeout = const Duration(seconds: 15)
  ..maxConnectionsPerHost = 6;

Future<String> probe(String url, String method) async {
  final sw = Stopwatch()..start();
  try {
    final uri = Uri.parse(url);
    final req = method == 'HEAD'
        ? await _client.openUrl('HEAD', uri).timeout(_kProbeTimeout)
        : await _client.getUrl(uri).timeout(_kProbeTimeout);
    req.headers.set('Accept', 'image/*,*/*');
    if (method == 'GET') req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1');
    final res = await req.close().timeout(_kProbeTimeout);
    final code = res.statusCode;
    final ct = (res.headers.contentType?.mimeType ?? '').toLowerCase();
    unawaited(res.drain<void>().catchError((_) {}));
    sw.stop();
    return '$method ${sw.elapsedMilliseconds}ms $code ct="$ct"'
        '${ct.startsWith('image/') ? '  OK' : ''}';
  } catch (e) {
    sw.stop();
    return '$method ${sw.elapsedMilliseconds}ms 失败: '
        '${e.toString().split('\n').first}';
  }
}

Future<void> main(List<String> argv) async {
  final ids = argv.isEmpty
      ? <int>[572613, 8, 253, 400602]
      : [for (final a in argv) int.tryParse(a) ?? 0];

  for (final id in ids) {
    stdout.writeln('== subject $id ==');
    try {
      final s = await BangumiApiHolder.api.subject(id);
      stdout.writeln('  ${s.displayName}');
      stdout.writeln('  images = ${s.images}');
      final candidates = ImageProxy.candidates(s.images.cover, subjectId: id);
      stdout.writeln('  候选链（${candidates.length} 个）:');
      for (var i = 0; i < candidates.length; i++) {
        final c = candidates[i];
        stdout.writeln('   [$i] ${c.length > 105 ? '${c.substring(0, 105)}...' : c}');
        stdout.writeln('       ${await probe(c, 'HEAD')}');
      }
    } catch (e) {
      stdout.writeln('  异常: $e');
    }
    stdout.writeln('');
  }
}
