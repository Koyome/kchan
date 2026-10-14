import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kchan/api/android_env.dart';
import 'package:kchan/api/play_resolver.dart';

void main() {
  test('播放器缓存有界，后向缓存显著小于前向缓存', () {
    expect(playerBufferBytes, greaterThan(0));
    if (Platform.isWindows) {
      expect(playerBufferBytes, lessThanOrEqualTo(64 * 1024 * 1024));
      expect(playerBackBufferBytes, lessThan(playerBufferBytes));
    }
  });

  test('扫描主列表时传递媒体请求头并识别前贴区间', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var receivedHeaders = 0;
    server.listen((request) async {
      if (request.headers.value('Referer') == 'https://source.example/' &&
          request.headers.value('User-Agent') == 'Kchan-test') {
        receivedHeaders++;
      }
      request.response.headers.contentType = ContentType('application', 'vnd.apple.mpegurl');
      if (request.uri.path == '/master.m3u8') {
        request.response.write('#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000\nmedia.m3u8\n');
      } else {
        request.response.write('#EXTM3U\n#EXTINF:3.1,\nmain.ts\n'
            '#EXT-X-DISCONTINUITY\n#EXTINF:4,\nad1.ts\n'
            '#EXTINF:4,\nad2.ts\n#EXT-X-DISCONTINUITY\n'
            '#EXTINF:3.2,\nmain2.ts\n');
      }
      await request.response.close();
    });
    try {
      final result = await withAdRanges(
        ResolvedStream(
          url: 'http://127.0.0.1:${server.port}/master.m3u8',
          type: 'application/x-mpegURL',
          headers: const {'User-Agent': 'Kchan-test'},
        ),
        'https://source.example/',
      );
      expect(result.adRanges, [(startMs: 3100, endMs: 11100)]);
      expect(receivedHeaders, 2);
    } finally {
      await server.close(force: true);
    }
  });

  test('循环主列表不无限递归', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var requests = 0;
    server.listen((request) async {
      requests++;
      request.response.write('#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000\nloop.m3u8\n');
      await request.response.close();
    });
    try {
      final ranges = await scanInjectedAds(
        'http://127.0.0.1:${server.port}/loop.m3u8', const {},
      );
      expect(ranges, isEmpty);
      expect(requests, 2);
    } finally {
      await server.close(force: true);
    }
  });
}
