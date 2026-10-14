// 生成 .flutter-plugins-dependencies（Flutter Gradle 插件依赖此文件）。
// 直接读取每个 pub cache 包的 pubspec.yaml，判断其是否声明 flutter.plugin 及 platform。
import 'dart:convert';
import 'dart:io';

String pubCacheRoot() {
  final env = Platform.environment;
  final cand = <String>[
    if (env['PUB_CACHE'] != null) env['PUB_CACHE']!,
    '${env['LOCALAPPDATA'] ?? ''}\\Pub\\Cache',
    '${env['USERPROFILE'] ?? ''}\\AppData\\Local\\Pub\\Cache',
  ];
  for (final c in cand) {
    if (Directory('$c\\hosted\\pub.flutter-io.cn').existsSync()) {
      return '$c\\hosted\\pub.flutter-io.cn';
    }
    if (Directory('$c\\hosted\\pub.dev').existsSync()) {
      return '$c\\hosted\\pub.dev';
    }
  }
  throw StateError('pub cache not found');
}

/// 极简 YAML 读取（只取本场景需要层级）
class MiniYaml {
  final List<String> lines;
  MiniYaml(this.lines);

  /// 返回 flutter: 节点下 plugin: 节点的 platforms 与 dependencies
  Map<String, dynamic> parse() {
    final out = <String, dynamic>{};
    int? flutterIdx;
    for (var i = 0; i < lines.length; i++) {
      if (RegExp(r'^flutter:\s*$').hasMatch(lines[i])) {
        flutterIdx = i;
        break;
      }
    }
    if (flutterIdx == null) return out;
    // 解析 flutter 段（直到下一个顶层键）
    final seg = <String>[];
    for (var i = flutterIdx + 1; i < lines.length; i++) {
      final l = lines[i];
      if (l.trim().isEmpty) continue;
      if (!l.startsWith(' ') && !l.startsWith('\t')) break;
      seg.add(l);
    }
    // 是否声明了 plugin:
    final pluginLine = seg.indexWhere((l) => RegExp(r'^\s{2}plugin:\s*$').hasMatch(l));
    if (pluginLine >= 0) {
      final platforms = <String, Map<String, String>>{};
      String? cur;
      for (var i = pluginLine + 1; i < seg.length; i++) {
        final l = seg[i];
        final m = RegExp(r'^(\s+)([a-z_0-9]+):\s*$').firstMatch(l);
        if (m != null && m.group(1)!.length == 4) {
          cur = m.group(2)!;
          if (cur == 'platforms') {
            cur = null;
            continue;
          }
          platforms[cur!] = {};
        } else {
          final kv = RegExp(r'^\s+([a-zA-Z_0-9]+):\s*(.+?)\s*$').firstMatch(l);
          if (kv != null && cur != null && m == null) {
            platforms[cur]![kv.group(1)!] = kv.group(2)!.replaceAll(RegExp(r'^["\x27]|["\x27]$'), '');
          }
        }
      }
      out['platforms'] = platforms;
    }
    return out;
  }
}

void main(List<String> args) {
  final projRoot = args.isNotEmpty ? args[0] : r'D:\dev\scaffold';
  final pkgsDir = pubCacheRoot();
  final pkgConfig =
      jsonDecode(File('$projRoot\\.dart_tool\\package_config.json').readAsStringSync())
          as Map<String, dynamic>;

  final plugins = <Map<String, dynamic>>[];
  final graph = <Map<String, dynamic>>[];

  for (final p in (pkgConfig['packages'] as List)) {
    final name = p['name'] as String;
    final rootUri = (p['rootUri'] as String).replaceFirst('file:///', '');
    var dirPath = Uri.decodeFull(rootUri).replaceAll('/', '\\');
    // 排除自身
    if (name == 'kchan') continue;
    final pubspec = File('$dirPath\\pubspec.yaml');
    if (!pubspec.existsSync()) continue;

    final y = MiniYaml(pubspec.readAsLinesSync()).parse();
    final platforms = (y['platforms'] as Map<String, Map<String, String>>?) ?? {};
    if (platforms.isEmpty) continue;

    final hasAndroid = platforms.containsKey('android');
    final androidDef = platforms['android'] ?? const <String, String>{};
    // 有 default_package 的纯 wrapper 也属于 android 插件（native_build=false）
    final deps = <String>[];
    // 读取 dependencies 里同样是插件的名字（简化：只标注直接的 plugin 依赖）
    if (hasAndroid) {
      plugins.add({
        'name': name,
        'path': dirPath,
        'dependencies': deps,
        'native_build': androidDef.containsKey('pluginClass'),
        if (androidDef.containsKey('sharedDarwinSource'))
          'shared_darwin_source': true,
      });
    }
    graph.add({'name': name, 'dependencies': deps});
  }

  final payload = <String, dynamic>{
    'info': 'This is a generated file; do not edit or check into version control.',
    'plugins': {
      'ios': <dynamic>[],
      'android': plugins,
      'windows': <dynamic>[],
      'linux': <dynamic>[],
      'macos': <dynamic>[],
      'web': <dynamic>[],
    },
    'dependencyGraph': graph,
    'date_created': DateTime.now().toIso8601String(),
    'version': '1.0.0',
  };

  File('$projRoot\\.flutter-plugins-dependencies')
      .writeAsStringSync(jsonEncode(payload));
  print('wrote .flutter-plugins-dependencies');
  for (final pl in plugins) {
    print('  android plugin: ${pl['name']}  native_build=${pl['native_build']}');
  }
}
