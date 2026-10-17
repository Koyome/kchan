// 播放解析的「解析逻辑」确定性单测 —— 不发网络请求
//
// 解析链分两段：
//   ① 把播放页抓下来            ← 网络（靠 IpPin / http 修复保证）
//   ② 从页面 HTML 里提取真实地址 ← 纯逻辑（本文件验证）
//
// ② 是决定「能不能解析出来」的核心。这里用真实站点的 HTML 形态做断言，
// 避免「网络通了但提取不出来」这种隐性失败。
//
//   flutter test test/resolver_parse_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:kchan/api/play_resolver.dart';

void main() {
  group('AppleCMS / MacPlayer 形态', () {
    // 这是最常见的番剧站播放页形态：地址被 percent-encode 后放在
    // player_aaaa 的 url 字段里，纯 HTTP 直接就能解出来（最快路径）。
    const htmlWithMacPlayer = '''
<!DOCTYPE html><html><head><title>葬送的芙莉莲 第01集</title></head><body>
<div id="player"></div>
<script type="text/javascript">
  var player_aaaa={"flag":"play","encrypt":0,"trysee":0,
  "url":"https%3A%2F%2Fvip.ffzy-play.com%2F20231007%2F1234%2Findex.m3u8",
  "from":"ffzy"};
</script>
</body></html>''';

    test('extractPlayerConfig 能取出 player_aaaa 配置', () {
      final cfg = DirectHttpResolver.extractPlayerConfig(htmlWithMacPlayer);
      // ignore: avoid_print
      print('extractPlayerConfig => $cfg');
      expect(cfg, isNotNull);
      expect(cfg!['url'], isNotNull);
    });

    test('decodePlayerUrl 能把 percent-encode 的地址还原成 m3u8', () {
      const raw =
          'https%3A%2F%2Fvip.ffzy-play.com%2F20231007%2F1234%2Findex.m3u8';
      final decoded = DirectHttpResolver.decodePlayerUrl(raw);
      // ignore: avoid_print
      print('decodePlayerUrl => $decoded');
      expect(decoded, startsWith('https://'));
      expect(decoded, contains('index.m3u8'));
      expect(decoded, isNot(contains('%2F')));
    });
  });

  group('scanMedia：从任意文本里扫媒体地址', () {
    test('能扫出 m3u8 / mp4，并跳过明显噪音', () {
      const text = '''
        随便一些文字
        var u = "https://vip.example.com/a/b/index.m3u8?token=abc";
        另一个: https://cdn.example.net/v/1080p.mp4
        无关: https://example.com/style.css
      ''';
      final hits = scanMedia(text);
      // ignore: avoid_print
      print('scanMedia => $hits');
      expect(hits.any((u) => u.contains('index.m3u8')), isTrue,
          reason: '必须能扫出 m3u8');
      expect(hits.any((u) => u.contains('.mp4')), isTrue,
          reason: '必须能扫出 mp4');
      expect(hits.any((u) => u.contains('.css')), isFalse,
          reason: '样式表不是媒体地址');
    });
  });

  group('广告过滤', () {
    test('adkwai 广告 mp4 必须被判为广告', () {
      const ad = 'https://v1.adkwai.com/video/adVideoLp/2024/01.mp4';
      expect(looksLikeAdUrl(ad), isTrue,
          reason: '实测这类地址能播但播的是广告，必须拦掉');
    });

    test('正常 CDN 的 m3u8 不能误判为广告', () {
      const normal = 'https://vip.ffzy-play.com/20231007/1234/index.m3u8';
      expect(looksLikeAdUrl(normal), isFalse);
    });
  });

  group('iframe 里藏地址的形态（jx 云播）', () {
    test('decodeVideoSource 能从 iframe src 的 query 里取回真实地址', () {
      // 形态：播放器 iframe 的 url 参数里套了一层 percent-encode
      const iframe =
          'https://player.example.com/?url=https%3A%2F%2Fcdn.example.com%2Fv%2Findex.m3u8';
      final decoded = decodeVideoSource(iframe);
      // ignore: avoid_print
      print('decodeVideoSource => $decoded');
      expect(decoded, contains('index.m3u8'));
      expect(hasNestedVideoSource(iframe), isTrue);
    });

    test('已是纯地址时不应再解包', () {
      const direct =
          'https://cdn.example.com/v/index.m3u8';
      expect(decodeVideoSource(direct), direct);
      expect(hasNestedVideoSource(direct), isFalse);
    });
  });
}
