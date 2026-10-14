// 生成 flutter_assets 目录（release），不依赖 package:flutter（纯 dart:io）。
//
// AssetManifest.bin 采用 Flutter StandardMessageCodec 编码：
//   value 类型字节 + 数据；Map 以 (key,value)... + 结束符 0 结尾。
//   本 app 未声明自定义 asset，仅含 MaterialIcons 一条，结构固定。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const String kAssetManifestFilename = 'AssetManifest.bin';
const String kAssetManifestBinJsonFilename = 'AssetManifest.bin.json';
const String kFontManifestFilename = 'FontManifest.json';
const String materialIconsFont = 'fonts/MaterialIcons-Regular.otf';

/// 极简 StandardMessageCodec 写入器（只覆盖本场景用到的类型）
class _Writer {
  final BytesBuilder b = BytesBuilder();

  void byte(int v) => b.addByte(v & 0xFF);

  void i32(int v) {
    final d = ByteData(4)..setInt32(0, v, Endian.big);
    b.add(d.buffer.asUint8List());
  }

  void i64(int v) {
    final d = ByteData(8)..setInt64(0, v, Endian.big);
    b.add(d.buffer.asUint8List());
  }

  void f64(double v) {
    final d = ByteData(8)..setFloat64(0, v, Endian.big);
    b.add(d.buffer.asUint8List());
  }

  /// StandardMessageCodec.writeSize —— 变长编码（<254 单字节）
  void size(int v) {
    if (v < 254) {
      byte(v);
    } else if (v <= 0xFFFF) {
      byte(254);
      final d = ByteData(2)..setUint16(0, v, Endian.big);
      b.add(d.buffer.asUint8List());
    } else {
      byte(255);
      final d = ByteData(4)..setUint32(0, v, Endian.big);
      b.add(d.buffer.asUint8List());
    }
  }

  void str(String s) {
    final u = utf8.encode(s);
    byte(7); // kString
    size(u.length);
    b.add(u);
  }

  void list(List<Object?> items) {
    byte(12); // kList
    size(items.length);
    for (final it in items) {
      value(it);
    }
  }

  void map(Map<Object?, Object?> m) {
    byte(13); // kMap
    size(m.length);
    m.forEach((k, v) {
      value(k);
      value(v);
    });
  }

  void value(Object? v) {
    if (v == null) {
      byte(0); // kNull
    } else if (v is bool) {
      byte(v ? 1 : 2);
    } else if (v is int) {
      byte(3); // kInt32
      i32(v);
    } else if (v is double) {
      byte(6); // kFloat64
      f64(v);
    } else if (v is String) {
      str(v);
    } else if (v is List) {
      list(v);
    } else if (v is Map) {
      map(v);
    } else {
      throw ArgumentError('unsupported type: ${v.runtimeType}');
    }
  }

  Uint8List take() => b.takeBytes();
}

Future<void> main(List<String> args) async {
  final outDir = args.isNotEmpty ? args[0] : r'D:\dev\scaffold\build\flutter_assets';
  final flutterRoot = args.length > 1 ? args[1] : r'D:\dev\flutter';
  final projRoot = args.length > 2 ? args[2] : r'D:\dev\scaffold';
  final sep = Platform.pathSeparator;

  final dir = Directory(outDir);
  if (dir.existsSync()) dir.deleteSync(recursive: true);
  dir.createSync(recursive: true);

  // 1) AssetManifest.bin
  final manifest = <Object?, Object?>{
    materialIconsFont: <Object?>[
      <Object?, Object?>{'asset': materialIconsFont},
    ],
  };
  final w = _Writer()..value(manifest);
  final bytes = w.take();
  File('$outDir$sep$kAssetManifestFilename').writeAsBytesSync(bytes);
  print('wrote $kAssetManifestFilename (${bytes.length} bytes)');

  // 2) AssetManifest.bin.json
  File('$outDir$sep$kAssetManifestBinJsonFilename').writeAsStringSync(jsonEncode({
    materialIconsFont: [
      {'asset': materialIconsFont},
    ],
  }));
  print('wrote $kAssetManifestBinJsonFilename');

  // 3) FontManifest.json
  File('$outDir$sep$kFontManifestFilename').writeAsStringSync(jsonEncode([
    {
      'family': 'MaterialIcons',
      'fonts': [
        {'asset': materialIconsFont},
      ],
    },
  ]));
  print('wrote $kFontManifestFilename');

  // 4) fonts/MaterialIcons-Regular.otf
  final fontRel = <String>[
    'bin',
    'cache',
    'dart-sdk',
    'bin',
    'resources',
    'devtools',
    'assets',
    'fonts',
    'MaterialIcons-Regular.otf',
  ];
  final src = File([flutterRoot, ...fontRel].join(sep));
  if (!src.existsSync()) {
    stderr.writeln('ERROR: MaterialIcons-Regular.otf 未找到: ${src.path}');
    exit(3);
  }
  final fontDir = Directory('$outDir${sep}fonts')..createSync(recursive: true);
  src.copySync('${fontDir.path}${sep}MaterialIcons-Regular.otf');
  print('copied MaterialIcons-Regular.otf (${src.lengthSync()} bytes)');

  // 5) NOTICES.Z
  final notice = File('$projRoot${sep}NOTICES');
  final noticeBytes =
      notice.existsSync() ? notice.readAsBytesSync() : utf8.encode('K酱\n');
  final gz = gzip.encode(noticeBytes);
  File('$outDir${sep}NOTICES.Z').writeAsBytesSync(gz);
  print('wrote NOTICES.Z (${gz.length} bytes)');

  print('--- flutter_assets ---');
  await for (final e in dir.list(recursive: true)) {
    if (e is File) {
      print('  ${e.path.substring(outDir.length + 1)}  ${e.lengthSync()}');
    }
  }
}
