/// 本地存储层：收藏 / 观看进度 / 历史 / 设置
/// 全部保存在本机（SharedPreferences + 文档目录 JSON），无登录、无云同步
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models.dart';
import '../api/bangumi_api.dart';
import '../api/source_groups.dart';
import '../api/video_sources.dart';
import '../api/system_proxy.dart';

/// 收藏状态（与 Bangumi 编号一致）
enum FavStatus {
  none(0, '未收藏'),
  wish(1, '想看'),
  collect(2, '看过'),
  doing(3, '在看'),
  onHold(4, '搁置'),
  dropped(5, '抛弃');

  final int code;
  final String label;
  const FavStatus(this.code, this.label);
  static FavStatus fromCode(int c) => FavStatus.values.firstWhere((e) => e.code == c, orElse: () => FavStatus.none);
}

class FavEntry {
  final Subject subject;
  FavStatus status;
  final int updatedAt;
  FavEntry({required this.subject, required this.status, required this.updatedAt});

  Map<String, dynamic> toJson() => {'subject': subject.toSnapshot(), 'status': status.code, 'updated_at': updatedAt};
  factory FavEntry.fromJson(Map<String, dynamic> j) => FavEntry(
        subject: Subject.fromSnapshot((j['subject'] as Map?)?.cast<String, dynamic>() ?? {}),
        status: FavStatus.fromCode((j['status'] as num?)?.toInt() ?? 0),
        updatedAt: (j['updated_at'] as num?)?.toInt() ?? 0,
      );
}

class ProgressEntry {
  final Subject subject;
  final Set<double> watchedSorts; // 已看集数（sort 值）
  double lastEpSort; // 最近一次观看的集
  int lastEpId;
  int lastPositionMs; // 该集观看到的位置
  int updatedAt;

  ProgressEntry({
    required this.subject,
    Set<double>? watched,
    this.lastEpSort = 0,
    this.lastEpId = 0,
    this.lastPositionMs = 0,
    this.updatedAt = 0,
  }) : watchedSorts = watched ?? <double>{};

  int get watchedCount => watchedSorts.length;

  Map<String, dynamic> toJson() => {
        'subject': subject.toSnapshot(),
        'watched': watchedSorts.toList(),
        'last_ep_sort': lastEpSort,
        'last_ep_id': lastEpId,
        'last_pos': lastPositionMs,
        'updated_at': updatedAt,
      };

  factory ProgressEntry.fromJson(Map<String, dynamic> j) => ProgressEntry(
        subject: Subject.fromSnapshot((j['subject'] as Map?)?.cast<String, dynamic>() ?? {}),
        watched: ((j['watched'] as List?) ?? const []).map((e) => (e as num).toDouble()).toSet(),
        lastEpSort: (j['last_ep_sort'] as num?)?.toDouble() ?? 0,
        lastEpId: (j['last_ep_id'] as num?)?.toInt() ?? 0,
        lastPositionMs: (j['last_pos'] as num?)?.toInt() ?? 0,
        updatedAt: (j['updated_at'] as num?)?.toInt() ?? 0,
      );
}

class HistoryEntry {
  final Subject subject;
  final int epId;
  final double epSort;
  final String epName;
  final String playUrl; // 上次解析出的播放地址（可能过期）
  final String sourceName;
  final String pageUrl; // 源站播放页（重新解析用）
  int positionMs;
  int durationMs;
  final int watchedAt;

  HistoryEntry({
    required this.subject,
    required this.epId,
    required this.epSort,
    this.epName = '',
    this.playUrl = '',
    this.sourceName = '',
    this.pageUrl = '',
    this.positionMs = 0,
    this.durationMs = 0,
    required this.watchedAt,
  });

  Map<String, dynamic> toJson() => {
        'subject': subject.toSnapshot(),
        'ep_id': epId,
        'ep_sort': epSort,
        'ep_name': epName,
        'play_url': playUrl,
        'source': sourceName,
        'page_url': pageUrl,
        'pos': positionMs,
        'dur': durationMs,
        'at': watchedAt,
      };

  factory HistoryEntry.fromJson(Map<String, dynamic> j) => HistoryEntry(
        subject: Subject.fromSnapshot((j['subject'] as Map?)?.cast<String, dynamic>() ?? {}),
        epId: (j['ep_id'] as num?)?.toInt() ?? 0,
        epSort: (j['ep_sort'] as num?)?.toDouble() ?? 0,
        epName: j['ep_name']?.toString() ?? '',
        playUrl: j['play_url']?.toString() ?? '',
        sourceName: j['source']?.toString() ?? '',
        pageUrl: j['page_url']?.toString() ?? '',
        positionMs: (j['pos'] as num?)?.toInt() ?? 0,
        durationMs: (j['dur'] as num?)?.toInt() ?? 0,
        watchedAt: (j['at'] as num?)?.toInt() ?? 0,
      );
}

/// 全局设置
class SettingsStore extends ChangeNotifier {
  static const _kApiBases = 'api_bases';
  static const _kCustomBase = 'custom_base';
  static const _kImageProxyMode = 'img_proxy_mode';
  static const _kImageProxyPrefix = 'img_proxy_prefix';
  static const _kThemeMode = 'theme_mode'; // 0 系统 1 浅色 2 深色
  static const _kSearchHistory = 'search_history';
  static const _kAutoNext = 'auto_next';
  static const _kPlaybackSpeed = 'playback_speed'; // v1.8.0 倍速记忆
  static const _kShortcutTipShown = 'shortcut_tip_shown'; // v1.9.2 快捷键提示只显示一次
  static const _kSourceGroups = 'source_groups'; // v1.9.3 线路大类偏好
  static const _kSourceOverrides = 'source_overrides'; // v1.9.3 单源开关覆盖
  static const _kDanmakuEnabled = 'danmaku_enabled';
  static const _kDanmakuAppId = 'danmaku_app_id';
  static const _kDanmakuAppSecret = 'danmaku_app_secret';
  static const _kDanmakuOpacity = 'danmaku_opacity';
  static const _kDanmakuFontSize = 'danmaku_font_size';
  static const _kDanmakuApiBaseUrl = 'danmaku_api_base_url';
  // v1.4.0：网络出口（代理）设置
  static const _kProxyFollowSystem = 'proxy_follow_system';
  static const _kProxyManualEnabled = 'proxy_manual_enabled';
  static const _kProxyManualUrl = 'proxy_manual_url';
  // v2.1.0：规则库自动更新
  static const _kRulesAutoUpdate = 'rules_auto_update';
  static const _kRulesLastCheckMs = 'rules_last_check_ms';
  static const _kFollowAutoScan = 'follow_auto_scan';

  late SharedPreferences _sp;
  /// SharedPreferences 不可用时的降级标志：此时所有写入只留在内存，
  /// 应用仍能正常使用（只是重启后设置不保留），不会崩溃。
  bool _spReady = false;

  List<String> apiBases = List.of(BangumiApi.presetBases);
  String customBase = '';
  int imageProxyMode = 0;
  String imageProxyPrefix = '';
  int themeMode = 0;
  bool autoNext = true;
  /// v1.8.0：倍速记忆（默认 1.0）
  double playbackSpeed = 1.0;
  List<String> searchHistory = [];

  /// 弹幕（弹弹play开放平台）：默认开启；凭证由用户自填
  bool danmakuEnabled = true;
  String danmakuAppId = '';
  String danmakuAppSecret = '';
  /// 弹幕不透明度 0.1~1.0
  double danmakuOpacity = 1.0;
  /// 弹幕字号
  double danmakuFontSize = 16;
  /// 自建 danmu_api 聚合实例地址（空 = 未配置）
  String danmakuApiBaseUrl = '';

  /// 网络出口：是否跟随系统代理（Windows 读注册表）
  bool proxyFollowSystem = true;
  /// 手动代理开关
  bool proxyManualEnabled = false;
  /// 手动代理地址，如 `127.0.0.1:7890`
  String proxyManualUrl = '';

  /// 【v2.1.0】规则库自动更新：启动时在后台检查 KazumiRules 远程更新
  /// （失败不影响现有规则；关掉后仍可在设置页手动刷新）
  bool rulesAutoUpdate = true;

  /// 【v2.1.0】上次检查远程规则目录的时间戳（毫秒）。
  ///
  /// 落盘是为了让 [RuleUpdater.autoInterval] 的节流跨重启生效 ——
  /// 否则每次冷启动都会打一次远程仓库。
  int rulesLastCheckMs = 0;

  /// 【v2.1.0】追番更新检测：启动时在后台扫描「在看/想看」的番出新集没有
  /// （失败只是没提示，不影响追番列表与播放）
  bool followAutoScan = true;

  Future<void> init() async {
    // SharedPreferences 依赖原生插件。若插件未注册（例如 APK 打包时
    // GeneratedPluginRegistrant 缺失）会抛 MissingPluginException，
    // 这里必须吞掉并降级，否则后续所有 _sp.xxx 都会抛
    // LateInitializationError 导致界面崩溃。
    try {
      _sp = await SharedPreferences.getInstance();
      _spReady = true;
    } catch (e) {
      debugPrint('SharedPreferences unavailable, fallback to memory: $e');
      _spReady = false;
    }
    if (_spReady) {
      customBase = _sp.getString(_kCustomBase) ?? '';
      apiBases = _sp.getStringList(_kApiBases) ?? List.of(BangumiApi.presetBases);
      imageProxyMode = _sp.getInt(_kImageProxyMode) ?? 0;
      imageProxyPrefix = _sp.getString(_kImageProxyPrefix) ?? '';
      themeMode = _sp.getInt(_kThemeMode) ?? 0;
      autoNext = _sp.getBool(_kAutoNext) ?? true;
      playbackSpeed = _sp.getDouble(_kPlaybackSpeed) ?? 1.0;
      shortcutTipShown = _sp.getBool(_kShortcutTipShown) ?? false;
      // 线路大类偏好 / 单源覆盖（解析失败时保持默认）
      try {
        final sg = _sp.getString(_kSourceGroups);
        if (sg != null && sg.isNotEmpty) {
          sourceGroupsJson = jsonDecode(sg) as Map<String, dynamic>;
        }
      } catch (_) {
        sourceGroupsJson = const {};
      }
      try {
        final so = _sp.getString(_kSourceOverrides);
        if (so != null && so.isNotEmpty) {
          final m = jsonDecode(so) as Map<String, dynamic>;
          sourceOverrides = {
            for (final e in m.entries) e.key: e.value == true
          };
        }
      } catch (_) {
        sourceOverrides = const {};
      }
      searchHistory = _sp.getStringList(_kSearchHistory) ?? [];
      danmakuEnabled = _sp.getBool(_kDanmakuEnabled) ?? true;
      danmakuAppId = _sp.getString(_kDanmakuAppId) ?? '';
      danmakuAppSecret = _sp.getString(_kDanmakuAppSecret) ?? '';
    danmakuOpacity = (_sp.getDouble(_kDanmakuOpacity) ?? 1.0).clamp(0.1, 1.0);
    danmakuFontSize = (_sp.getDouble(_kDanmakuFontSize) ?? 16).clamp(10.0, 40.0);
    danmakuApiBaseUrl = _sp.getString(_kDanmakuApiBaseUrl) ?? '';
      proxyFollowSystem = _sp.getBool(_kProxyFollowSystem) ?? true;
      proxyManualEnabled = _sp.getBool(_kProxyManualEnabled) ?? false;
      proxyManualUrl = _sp.getString(_kProxyManualUrl) ?? '';
      rulesAutoUpdate = _sp.getBool(_kRulesAutoUpdate) ?? true;
      rulesLastCheckMs = _sp.getInt(_kRulesLastCheckMs) ?? 0;
      followAutoScan = _sp.getBool(_kFollowAutoScan) ?? true;
    }
    _apply();
  }

  /// 安全写入：SharedPreferences 不可用时静默跳过（仅内存态）。
  Future<void> _w(Future<void> Function() f) async {
    if (!_spReady) return;
    try {
      await f();
    } catch (e) {
      debugPrint('settings write failed: $e');
    }
  }

  void _apply() {
    final list = <String>[
      if (customBase.trim().isNotEmpty) customBase.trim(),
      ...apiBases,
    ];
    // 去重保序
    final seen = <String>{};
    final bases = list
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty && seen.add(e))
        .toList();
    BangumiApiHolder.api.bases = bases;
    // 【v1.9.1】把自定义图片反代同时接到新的候选链上。
    //
    // 背景：老代码只设了 `ImageProxy.customPrefix`（mode=2 用的「前缀拼接」写法），
    // 而 v1.9.1 的候选链走的是 `customImageBase` —— 结果是**设置页填了图片反代
    // 也完全不起作用**（用户看到「填了还是慢/还是不显示图」的直接原因）。
    // 这里两个字段一起设，两种写法都能生效。
    ImageProxy.mode = imageProxyMode;
    ImageProxy.customPrefix = imageProxyPrefix;
    ImageProxy.customImageBase = imageProxyPrefix;
    proxySettings.followSystem = proxyFollowSystem;
    proxySettings.manualEnabled = proxyManualEnabled;
    proxySettings.manualUrl = proxyManualUrl;

    // 【v1.9.3】把「线路大类」与「单源开关」同步到 SourceRegistry，
    // 这样详情页的 active 列表会同时尊重这两类设置。
    SourceRegistry.invalidate(); // 规则/设置变了 → 重建源列表
    SourceRegistry.groupPrefs = SourceGroupPrefs.fromJson(sourceGroupsJson);

    // 【v1.9.4 · 修「手机端线路和电脑端不同步」的关键一步】
    //
    // `sourceOverrides` 是「用户开关过哪些源」的**全量快照**。
    // 老版本（v1.9.0）默认只开 AGE + DM84；用户哪怕从没动过设置，
    // 升级后也会带着这份旧快照，于是新的默认线路（7sefun/FQDM/…）永远不生效
    // —— 表现就是「手机端线路和电脑端不一样、像落后一个版本」。
    //
    // 修法：若快照里的「启用集合」恰好等于**历史某个默认集合**
    // （说明用户从没自定义过），就丢掉它、改用当前默认。
    // 只认已知的旧默认，用户真正自定义过的组合不会被误删。
    var overrides = sourceOverrides;
    if (overrides.isNotEmpty && _looksLikeLegacyDefaults(overrides)) {
      debugPrint('[设置] 检测到旧版默认线路快照 → 升级为当前默认线路');
      overrides = const {};
      sourceOverrides = const {};
      unawaited(_w(() => _sp.remove(_kSourceOverrides)));
    }
    for (final e in overrides.entries) {
      SourceRegistry.setEnabled(e.key, e.value);
    }
  }

  /// 这份开关快照是不是「历史版本的默认值」（说明用户没自定义过）
  ///
  /// 已知历史默认：
  ///   v1.9.0 / v1.9.1 → 只开 {AGE, DM84}（AGE 后来实测已失效）
  ///   更早内测        → 只开 {AGE}
  static bool _looksLikeLegacyDefaults(Map<String, bool> o) {
    final on = o.entries.where((e) => e.value).map((e) => e.key).toSet();
    if (on.isEmpty) return false;
    const legacyV190 = {'AGE', 'DM84'};
    if (on.length == legacyV190.length && on.containsAll(legacyV190)) {
      return true;
    }
    if (on.length == 1 && on.contains('AGE')) return true;
    return false;
  }

  /// 【v2.1.0】规则库自动更新开关
  Future<void> setRulesAutoUpdate(bool v) async {
    rulesAutoUpdate = v;
    await _w(() => _sp.setBool(_kRulesAutoUpdate, v));
    notifyListeners();
  }

  /// 【v2.1.0】记录上次检查远程规则目录的时间
  Future<void> setRulesLastCheckMs(int ms) async {
    rulesLastCheckMs = ms;
    await _w(() => _sp.setInt(_kRulesLastCheckMs, ms));
  }

  /// 【v2.1.0】追番更新检测开关
  Future<void> setFollowAutoScan(bool v) async {
    followAutoScan = v;
    await _w(() => _sp.setBool(_kFollowAutoScan, v));
    notifyListeners();
  }

  /// 设置网络出口（代理）
  Future<void> setProxy({
    required bool followSystem,
    required bool manualEnabled,
    required String manualUrl,
  }) async {
    proxyFollowSystem = followSystem;
    proxyManualEnabled = manualEnabled;
    proxyManualUrl = manualUrl;
    await _w(() async {
      await _sp.setBool(_kProxyFollowSystem, followSystem);
      await _sp.setBool(_kProxyManualEnabled, manualEnabled);
      await _sp.setString(_kProxyManualUrl, manualUrl);
    });
    _apply();
    notifyListeners();
  }

  Future<void> setApiBases(List<String> bases, {String? custom}) async {
    apiBases = bases;
    if (custom != null) customBase = custom;
    await _w(() async {
      await _sp.setStringList(_kApiBases, apiBases);
      await _sp.setString(_kCustomBase, customBase);
    });
    _apply();
    notifyListeners();
  }

  Future<void> setImageProxy(int mode, String prefix) async {
    imageProxyMode = mode;
    imageProxyPrefix = prefix;
    await _w(() async {
      await _sp.setInt(_kImageProxyMode, mode);
      await _sp.setString(_kImageProxyPrefix, prefix);
    });
    _apply();
    notifyListeners();
  }

  Future<void> setThemeMode(int mode) async {
    themeMode = mode;
    await _w(() => _sp.setInt(_kThemeMode, mode));
    notifyListeners();
  }

  Future<void> setAutoNext(bool v) async {
    autoNext = v;
    await _w(() => _sp.setBool(_kAutoNext, v));
  }

  Future<void> setPlaybackSpeed(double v) async {
    playbackSpeed = v;
    await _w(() => _sp.setDouble(_kPlaybackSpeed, v));
    notifyListeners();
  }

  /// 【v1.9.2】桌面端快捷键提示是否已经展示过（只提示一次，不反复打扰）
  bool shortcutTipShown = false;

  /// 【v1.9.3】播放源「线路大类」开关（按解析方式 × 地区）
  Map<String, dynamic> sourceGroupsJson = const {};

  /// 【v1.9.3】用户对单条源的开关覆盖（源名 → 是否启用）
  Map<String, bool> sourceOverrides = const {};

  Future<void> setShortcutTipShown(bool v) async {
    if (shortcutTipShown == v) return;
    shortcutTipShown = v;
    await _w(() => _sp.setBool(_kShortcutTipShown, v));
  }

  /// 保存线路大类偏好
  Future<void> setSourceGroups(Map<String, dynamic> json) async {
    sourceGroupsJson = json;
    await _w(() => _sp.setString(_kSourceGroups, jsonEncode(json)));
  }

  /// 保存单条源的开关覆盖
  Future<void> setSourceOverrides(Map<String, bool> map) async {
    sourceOverrides = map;
    await _w(() => _sp.setString(_kSourceOverrides, jsonEncode(map)));
  }

  Future<void> setDanmakuEnabled(bool v) async {
    danmakuEnabled = v;
    await _w(() => _sp.setBool(_kDanmakuEnabled, v));
    notifyListeners();
  }

  Future<void> setDanmakuCredentials(String appId, String appSecret) async {
    danmakuAppId = appId.trim();
    danmakuAppSecret = appSecret.trim();
    await _w(() async {
      await _sp.setString(_kDanmakuAppId, danmakuAppId);
      await _sp.setString(_kDanmakuAppSecret, danmakuAppSecret);
    });
    notifyListeners();
  }

  /// 设置弹幕不透明度（0.1~1.0）
  Future<void> setDanmakuOpacity(double v) async {
    danmakuOpacity = v.clamp(0.1, 1.0);
    notifyListeners();
    await _w(() => _sp.setDouble(_kDanmakuOpacity, danmakuOpacity));
  }

  /// 设置自建 danmu_api 聚合实例地址
  Future<void> setDanmakuApiBaseUrl(String v) async {
    danmakuApiBaseUrl = v.trim();
    notifyListeners();
    await _w(() => _sp.setString(_kDanmakuApiBaseUrl, danmakuApiBaseUrl));
  }

  /// 设置弹幕字号（10~40）
  Future<void> setDanmakuFontSize(double v) async {
    danmakuFontSize = v.clamp(10.0, 40.0);
    notifyListeners();
    await _w(() => _sp.setDouble(_kDanmakuFontSize, danmakuFontSize));
  }

  Future<void> addSearchHistory(String kw) async {
    if (kw.trim().isEmpty) return;
    searchHistory.remove(kw);
    searchHistory.insert(0, kw);
    if (searchHistory.length > 20) searchHistory = searchHistory.sublist(0, 20);
    await _w(() => _sp.setStringList(_kSearchHistory, searchHistory));
    notifyListeners();
  }

  Future<void> clearSearchHistory() async {
    searchHistory = [];
    await _w(() => _sp.setStringList(_kSearchHistory, []));
    notifyListeners();
  }
}

/// JSON 文件型存储的基类
abstract class _JsonFileStore extends ChangeNotifier {
  late File _file;
  Timer? _saveTimer;
  bool _loaded = false;

  String get fileName;

  Future<void> init(Directory dir) async {
    _file = File('${dir.path}${Platform.pathSeparator}$fileName');
    try {
      if (await _file.exists()) {
        final text = await _file.readAsString();
        if (text.trim().isNotEmpty) load(jsonDecode(text));
      }
    } catch (_) {/* 文件损坏则从空开始 */}
    _loaded = true;
  }

  void load(dynamic json);

  dynamic dump();

  void scheduleSave() {
    if (!_loaded) return;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 400), () async {
      try {
        await _file.writeAsString(jsonEncode(dump()), flush: true);
      } catch (_) {}
    });
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    super.dispose();
  }
}

class FavoritesStore extends _JsonFileStore {
  @override
  String get fileName => 'favorites.json';
  final Map<int, FavEntry> map = {};

  @override
  void load(dynamic json) {
    if (json is Map) {
      for (final e in json.entries) {
        final id = int.tryParse(e.key.toString());
        if (id == null || e.value is! Map) continue;
        map[id] = FavEntry.fromJson((e.value as Map).cast<String, dynamic>());
      }
    }
  }

  @override
  dynamic dump() => map.map((k, v) => MapEntry('$k', v.toJson()));

  FavStatus statusOf(int subjectId) => map[subjectId]?.status ?? FavStatus.none;

  void setStatus(Subject s, FavStatus st) {
    if (st == FavStatus.none) {
      map.remove(s.id);
    } else {
      final merged = s is SubjectDetail ? Subject.fromSnapshot(s.toSnapshot()) : s;
      map[s.id] = FavEntry(subject: merged, status: st, updatedAt: DateTime.now().millisecondsSinceEpoch);
    }
    scheduleSave();
    notifyListeners();
  }

  /// 需要检测更新的番剧：只看「在看」和「想看」
  ///
  /// 「看过 / 搁置 / 抛弃」不扫——省请求，也避免给已完结的老番刷红点。
  /// 取消收藏后自动从这里消失，无需手动清理快照。
  List<Subject> trackedSubjects() {
    final list = <FavEntry>[
      for (final e in map.values)
        if (e.status == FavStatus.doing || e.status == FavStatus.wish) e,
    ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return [for (final e in list) e.subject];
  }

  List<FavEntry> byStatus(FavStatus st) {
    final list = map.values.where((e) => e.status == st).toList();
    list.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return list;
  }

  void clear() {
    map.clear();
    scheduleSave();
    notifyListeners();
  }
}

class ProgressStore extends _JsonFileStore {
  @override
  String get fileName => 'progress.json';
  final Map<int, ProgressEntry> map = {};

  @override
  void load(dynamic json) {
    if (json is Map) {
      for (final e in json.entries) {
        final id = int.tryParse(e.key.toString());
        if (id == null || e.value is! Map) continue;
        map[id] = ProgressEntry.fromJson((e.value as Map).cast<String, dynamic>());
      }
    }
  }

  @override
  dynamic dump() => map.map((k, v) => MapEntry('$k', v.toJson()));

  ProgressEntry of(Subject s) => map[s.id] ?? ProgressEntry(subject: s is SubjectDetail ? Subject.fromSnapshot(s.toSnapshot()) : s);

  bool isWatched(int subjectId, double sort) => map[subjectId]?.watchedSorts.contains(sort) ?? false;

  void markWatched(Subject s, double sort, {int epId = 0}) {
    final e = of(s);
    e.watchedSorts.add(sort);
    if (epId != 0) {
      e.lastEpId = epId;
      e.lastEpSort = sort;
    }
    e.updatedAt = DateTime.now().millisecondsSinceEpoch;
    map[s.id] = e;
    scheduleSave();
    notifyListeners();
  }

  void unmarkWatched(Subject s, double sort) {
    final e = of(s);
    e.watchedSorts.remove(sort);
    map[s.id] = e;
    scheduleSave();
    notifyListeners();
  }

  void updatePosition(Subject s, double sort, int epId, int positionMs) {
    final e = of(s);
    e.lastEpSort = sort;
    e.lastEpId = epId;
    e.lastPositionMs = positionMs;
    e.updatedAt = DateTime.now().millisecondsSinceEpoch;
    map[s.id] = e;
    scheduleSave();
    // 位置更新太频繁，不 notify 全页面
  }

  void clear() {
    map.clear();
    scheduleSave();
    notifyListeners();
  }
}

class HistoryStore extends _JsonFileStore {
  @override
  String get fileName => 'history.json';
  static const maxItems = 300;
  final List<HistoryEntry> items = [];

  @override
  void load(dynamic json) {
    if (json is List) {
      items.addAll(json.whereType<Map>().map((e) => HistoryEntry.fromJson(e.cast<String, dynamic>())));
    }
  }

  @override
  dynamic dump() => items.map((e) => e.toJson()).toList();

  void push(HistoryEntry entry) {
    // 同番同集去重，移到最前
    items.removeWhere((e) => e.subject.id == entry.subject.id && e.epSort == entry.epSort);
    items.insert(0, entry);
    if (items.length > maxItems) items.removeRange(maxItems, items.length);
    scheduleSave();
    notifyListeners();
  }

  void touchPosition(int subjectId, double epSort, int positionMs, int durationMs) {
    final idx = items.indexWhere((e) => e.subject.id == subjectId && e.epSort == epSort);
    if (idx >= 0) {
      items[idx].positionMs = positionMs;
      if (durationMs > 0) items[idx].durationMs = durationMs;
      scheduleSave();
    }
  }

  void clear() {
    items.clear();
    scheduleSave();
    notifyListeners();
  }
}

/// 追番更新快照表
///
/// 只存「每部番上次扫到的最新集数」，不存剧集列表（列表每次进详情页都会实时拉）。
/// 由 `FollowUpdateService` 读写，UI 只读。
class FollowUpdatesStore extends _JsonFileStore {
  @override
  String get fileName => 'follow_updates.json';

  static const _kMaxTracked = 500;

  final Map<int, FollowUpdateEntry> map = {};

  @override
  void load(dynamic json) {
    if (json is Map) {
      for (final e in json.entries) {
        final id = int.tryParse(e.key.toString());
        if (id == null || e.value is! Map) continue;
        map[id] = FollowUpdateEntry.fromJson((e.value as Map).cast<String, dynamic>());
      }
    }
  }

  @override
  dynamic dump() => map.map((k, v) => MapEntry('$k', v.toJson()));

  FollowUpdateEntry? of(int subjectId) => map[subjectId];

  bool hasUpdate(int subjectId) => (map[subjectId]?.newSince ?? 0) > 0;

  /// 待看更新的番数（红点数）
  int get pendingCount => map.values.where((e) => e.hasUpdate).length;

  /// 写入/更新快照。
  ///
  /// 直接存 [e]：`newSince`（新集发现时间）由 `FollowUpdateService.scan`
  /// 统一判定后写进 entry，这里不再重算——两处各算一遍必然不一致。
  void put(FollowUpdateEntry e) {
    map[e.subjectId] = e;
    _trim();
    scheduleSave();
    notifyListeners();
  }

  /// 用户已看过最新集 → 清掉红点
  void markSeen(int subjectId) {
    final e = map[subjectId];
    if (e == null || e.newSince == 0) return;
    map[subjectId] = FollowUpdateEntry(
      subjectId: e.subjectId,
      latestSort: e.latestSort,
      scannedAt: e.scannedAt,
      newSince: 0,
      sourceName: e.sourceName,
    );
    scheduleSave();
    notifyListeners();
  }

  void remove(int subjectId) {
    if (map.remove(subjectId) == null) return;
    scheduleSave();
    notifyListeners();
  }

  void clear() {
    map.clear();
    scheduleSave();
    notifyListeners();
  }

  /// 防止收藏过多导致文件无限膨胀：丢掉最久没扫的
  void _trim() {
    if (map.length <= _kMaxTracked) return;
    final sorted = map.values.toList()..sort((a, b) => a.scannedAt.compareTo(b.scannedAt));
    for (final e in sorted.take(map.length - _kMaxTracked)) {
      map.remove(e.subjectId);
    }
  }
}

/// 聚合根：所有本地存储
class Store {
  static final settings = SettingsStore();
  static final favorites = FavoritesStore();
  static final progress = ProgressStore();
  static final history = HistoryStore();
  static final followUpdates = FollowUpdatesStore();

  static Future<void> init() async {
    await settings.init();
    Directory? dir;
    try {
      dir = await getApplicationDocumentsDirectory();
    } catch (_) {
      dir = null;
    }
    dir ??= Directory.systemTemp;
    await Future.wait([
      favorites.init(dir),
      progress.init(dir),
      history.init(dir),
      followUpdates.init(dir),
    ]);
  }

  static Future<void> clearAllUserData() async {
    favorites.clear();
    progress.clear();
    history.clear();
    followUpdates.clear();
  }
}
