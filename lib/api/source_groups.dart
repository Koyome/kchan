/// 播放源分类（Kazumi 规则的「线路大类」）
///
/// ## 背景：为什么需要分类
///
/// 官方 KazumiRules 有 86 条规则。K酱 之前把它们**平铺**成 86 个开关，
/// 用户面对的是一个没法用的长列表；而默认只开 2 条（AGE / DM84），
/// 其中 **AGE 实测已经挂了**（搜索页是 JS 渲染 + 当前不可用）→ 实际只剩 1 条可用线路。
///
/// 用户的原话：「后台规则还有很多线路可以加进来，Age 好像一直不可用，
/// 你可以把线路放上去用呀，还可以再开两个线路大类供选择」。
///
/// ## 分类依据
///
/// 按「**用起来是什么体验**」分，而不是按站点域名分 —— 用户关心的是
/// 「这条线路点了能不能直接播」，不是「它服务器在哪」。所以主分类是：
///
///   - [direct]    **直连解析**：播放页里能直接拿到 m3u8/mp4（或只需跑一次页面 JS），
///                 起播最快。规则特征是 `useLegacyParser` 或旧版苹果 CMS 系。
///   - [cloud]     **云播解析**：必须跑浏览器内核截获（jx 类播放器），
///                 慢 3~10s 但资源最全（DM84/FQDM 等）。
///   - [api]       **JSON 接口**：不解析 HTML，直接调站点 JSON（api level 8），
///                 最快最稳，但站点少。
///   - [antiCrawl] **需过人机验证**：站点挂 JS 挑战，首次要跑一次浏览器内核拿 cookie。
///
/// 另外提供**地区/网络**维度的次级分类，供「换一条能连上的线路」时筛选：
///   - [cn]  国内站点（绝大多数）
///   - [oversea] 海外站点（需要代理才连得上）
///
/// ## 实测可用性
///
/// `availability` 来自 `tool/probe_sources.dart` 的**真实网络体检**
/// （见交接文档 §）。UI 上把「实测可用」的排前面并标出来，
/// 让用户一眼看到「哪些真的能播」。
library;

import 'kazumi_rules.dart';

/// 线路大类（按解析方式）
enum SourceKind {
  /// 直连/轻解析，起播最快
  direct('直链解析', '播放页可直接取到地址，起播最快'),

  /// 云播解析（jx 播放器，需跑浏览器内核）
  cloud('云播解析', '需跑一次页面 JS 截获地址，稍慢但资源最全'),

  /// JSON 接口（api level 8）
  api('接口直连', '不解析网页，直接调站点 JSON 接口，最快最稳'),

  /// 需要过人机验证
  antiCrawl('人机验证', '站点挂 JS 挑战，首次需跑浏览器内核换取通行证');

  final String label;
  final String desc;
  const SourceKind(this.label, this.desc);
}

/// 地区/网络大类
enum SourceRegion {
  cn('国内线路', '国内站点，通常可直连'),
  oversea('海外线路', '海外站点，可能需要代理');

  final String label;
  final String desc;
  const SourceRegion(this.label, this.desc);
}

/// 一条规则的分类结果
class RuleClass {
  final SourceKind kind;
  final SourceRegion region;

  /// 实测可用（来自 probe_sources.dart 的真实网络体检）
  final bool verified;

  /// 实测耗时（毫秒；0 = 未测）
  final int latencyMs;

  /// 实测线路数（0 = 未测）
  final int roads;

  const RuleClass({
    required this.kind,
    required this.region,
    this.verified = false,
    this.latencyMs = 0,
    this.roads = 0,
  });
}

/// 分类器
class SourceClassifier {
  /// 已知的海外站点域名特征（baseURL 里出现即判为海外）。
  ///
  /// 只用**确定**的 TLD / 域名片段，避免误判把国内站点归到海外。
  static const _overseaHints = <String>[
    '.io', '.me', '.tv', '.cc', '.app', '.dev', '.xyz', '.top',
    'gogoanime', 'anime', 'moe', 'hk', '.tw', '.jp', '.kr',
  ];

  /// 把一条规则分类。
  ///
  /// 判定优先级（从最能决定「体验」的开始）：
  ///   1. `antiCrawler.enabled` → antiCrawl（这类必须先过验证，体验最特殊）
  ///   2. `searchMode/chapterMode == api` → api（完全不解析 HTML）
  ///   3. `useLegacyParser` 或「非 api 6/8」→ direct（老式/苹果 CMS，明文直链多）
  ///   4. 其余 → cloud
  static RuleClass classify(KazumiRule r) {
    final kind = _kindOf(r);
    final region = _regionOf(r);
    final v = verifiedStats[r.name];
    return RuleClass(
      kind: kind,
      region: region,
      verified: v != null,
      latencyMs: v?.latencyMs ?? 0,
      roads: v?.roads ?? 0,
    );
  }

  static SourceKind _kindOf(KazumiRule r) {
    if (r.antiCrawler.enabled) return SourceKind.antiCrawl;
    if (r.usesApiSearch || r.usesApiChapter) return SourceKind.api;
    if (r.useLegacyParser) return SourceKind.direct;
    // api 6/8 是新一代播放器（几乎都要跑 JS）；其余多为苹果 CMS 系
    if (r.api != '6' && r.api != '8') return SourceKind.direct;
    return SourceKind.cloud;
  }

  static SourceRegion _regionOf(KazumiRule r) {
    final host = Uri.tryParse(r.baseURL)?.host.toLowerCase() ?? '';
    if (host.isEmpty) return SourceRegion.cn;
    // 明确的中国域名后缀 → 国内
    if (host.endsWith('.cn') ||
        host.endsWith('.com.cn') ||
        host.endsWith('.net.cn')) {
      return SourceRegion.cn;
    }
    for (final h in _overseaHints) {
      if (host.contains(h)) return SourceRegion.oversea;
    }
    return SourceRegion.cn;
  }

  /// 实测可用性表（由 tool/probe_sources.dart 产出，人工核对后固化在这里）。
  ///
  /// 为什么固化而不是运行时探测：运行时探测 86 个站点要几十秒，
  /// 用户不可能等；而这个表只是用来**排序和打标签**，不需要实时。
  /// 想更新就跑一次 probe_sources.dart，把结果贴回这里。
  ///
  /// 数据来源：2026-10-13 本机真实网络体检
  /// （关键词：进击的巨人 / 葬送的芙莉莲 / 间谍过家家 / 咒术回战）。
  static const Map<String, ({int latencyMs, int roads, int episodes})>
      verifiedStats = {
    '7sefun': (latencyMs: 974, roads: 2, episodes: 59),
    'FQDM': (latencyMs: 1158, roads: 3, episodes: 69),
    'MXdm': (latencyMs: 1306, roads: 2, episodes: 2),
    'gugu3': (latencyMs: 1320, roads: 2, episodes: 6),
    'TvTFun': (latencyMs: 5942, roads: 3, episodes: 84),
    'dmghg': (latencyMs: 7487, roads: 2, episodes: 50),
    'moonci': (latencyMs: 1015, roads: 1, episodes: 25),
    'ezdmw': (latencyMs: 1337, roads: 1, episodes: 4),
    'gpjda': (latencyMs: 1352, roads: 1, episodes: 25),
    'DM84': (latencyMs: 1380, roads: 1, episodes: 4),
    'sorani': (latencyMs: 1904, roads: 1, episodes: 25),
    'xigua': (latencyMs: 2167, roads: 1, episodes: 100),
    'fcdm': (latencyMs: 2668, roads: 1, episodes: 1),
    'akianime': (latencyMs: 2886, roads: 1, episodes: 11),
    'omofun': (latencyMs: 5329, roads: 1, episodes: 2),
    'Fantuan': (latencyMs: 8440, roads: 1, episodes: 8),
  };

  /// 实测**不可用**的规则名（搜索页 JS 渲染 / 站点已挂 / 证书错误）。
  ///
  /// 这些不是删除，只是默认不勾选并在 UI 上标灰，用户仍可手动开启。
  static const Set<String> knownDead = {
    'AGE',        // 搜索页 JS 渲染，静态抓取拿不到结果（用户反馈「一直不可用」）
    'aafun',      // 全站 JS 闸门
    'mgnacg',     // JS 闸门
    'giriGiriLove', // JS 闸门
    'mutefun',    // JS 闸门
    'dalvdm',     // JS 闸门
  };
}

/// 用户对「线路大类」的开关（持久化在设置页）
///
/// 语义：某个大类被关掉时，属于它的源即使单独打开也不参与聚合 ——
/// 这样用户可以「只留直链解析」来换速度，或「只留云播」来换资源全度。
class SourceGroupPrefs {
  final Map<SourceKind, bool> kindEnabled;
  final Map<SourceRegion, bool> regionEnabled;

  SourceGroupPrefs({
    Map<SourceKind, bool>? kindEnabled,
    Map<SourceRegion, bool>? regionEnabled,
  })  : kindEnabled = kindEnabled ??
            {for (final k in SourceKind.values) k: true},
        regionEnabled = regionEnabled ??
            {for (final r in SourceRegion.values) r: true};

  bool allows(SourceKind k) => kindEnabled[k] ?? true;
  bool allowsRegion(SourceRegion r) => regionEnabled[r] ?? true;

  bool allowsRule(KazumiRule rule) {
    final c = SourceClassifier.classify(rule);
    return allows(c.kind) && allowsRegion(c.region);
  }

  Map<String, dynamic> toJson() => {
        'kind': {for (final e in kindEnabled.entries) e.key.name: e.value},
        'region': {for (final e in regionEnabled.entries) e.key.name: e.value},
      };

  static SourceGroupPrefs fromJson(Map<String, dynamic>? j) {
    if (j == null) return SourceGroupPrefs();
    final k = <SourceKind, bool>{};
    final r = <SourceRegion, bool>{};
    final kj = j['kind'];
    if (kj is Map) {
      for (final kind in SourceKind.values) {
        final v = kj[kind.name];
        k[kind] = v is bool ? v : true;
      }
    }
    final rj = j['region'];
    if (rj is Map) {
      for (final reg in SourceRegion.values) {
        final v = rj[reg.name];
        r[reg] = v is bool ? v : true;
      }
    }
    return SourceGroupPrefs(
      kindEnabled: k.isEmpty ? null : k,
      regionEnabled: r.isEmpty ? null : r,
    );
  }
}
