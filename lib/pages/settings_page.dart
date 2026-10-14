/// 设置页：数据源镜像 / 图片代理 / 播放源 / 外观 / 数据管理 / 关于
library;

import 'package:flutter/material.dart';

import '../api/bangumi_api.dart';
import '../api/kazumi_rules.dart' show RuleRegistry;
import '../api/source_groups.dart';
import '../api/system_proxy.dart';
import '../api/video_sources.dart';
import '../store/local_store.dart';
import '../theme.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _customBaseCtl = TextEditingController();
  final _imgPrefixCtl = TextEditingController();
  final _danmakuIdCtl = TextEditingController();
  final _danmakuAggCtl = TextEditingController();
  final _danmakuSecretCtl = TextEditingController();
  final _proxyUrlCtl = TextEditingController();
  bool _probing = false;
  List<({String base, int latencyMs})>? _probeResult;

  /// 设置页里已展开的「线路大类」（v1.9.3）
  final Set<SourceKind> _expandedKinds = {};

  /// 把当前的源开关 + 线路大类偏好写回本地存储。
  ///
  /// 【为什么要显式保存】`SourceRegistry` 是静态状态，改完只活在内存里；
  /// 不落盘的话重启就回到默认，用户会以为「设置了没用」。
  Future<void> _persistSourcePrefs() async {
    final all = SourceRegistry.sources;
    final overrides = <String, bool>{
      for (final s in all) s.name: s.enabled,
    };
    await Store.settings.setSourceOverrides(overrides);
    await Store.settings.setSourceGroups(SourceRegistry.groupPrefs.toJson());
  }

  @override
  void initState() {
    super.initState();
    _customBaseCtl.text = Store.settings.customBase;
    _imgPrefixCtl.text = Store.settings.imageProxyPrefix;
    _danmakuAggCtl.text = Store.settings.danmakuApiBaseUrl;
    _danmakuIdCtl.text = Store.settings.danmakuAppId;
    _danmakuSecretCtl.text = Store.settings.danmakuAppSecret;
    _proxyUrlCtl.text = Store.settings.proxyManualUrl;
  }

  @override
  void dispose() {
    _customBaseCtl.dispose();
    _imgPrefixCtl.dispose();
    _danmakuAggCtl.dispose();
    _danmakuIdCtl.dispose();
    _danmakuSecretCtl.dispose();
    _proxyUrlCtl.dispose();
    super.dispose();
  }

  Future<void> _probe() async {
    setState(() {
      _probing = true;
      _probeResult = null;
    });
    final r = await BangumiApiHolder.api.probe();
    if (!mounted) return;
    setState(() {
      _probeResult = r;
      _probing = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(titleSpacing: 16, title: const Text('设置')),
      body: AnimatedBuilder(
        animation: Store.settings,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            // ---- 数据源 ----
            K.sectionLabel('数据源', cs.onSurface),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '番剧元数据来自 Bangumi。其官方接口 api.bgm.tv / next.bgm.tv '
                    '在中国大陆实测**完全不可达**（15s 超时）。\n'
                    '内置顺序按 2026-10-13 本机实测速度排列，最快的排最前，'
                    '请求时多个镜像**同时竞速、谁先成功用谁**。\n'
                    '自建反代请填在下方（会自动排在第一位）。',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(height: 1.6),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _customBaseCtl,
                    decoration: const InputDecoration(
                      labelText: '自建反代 / 自定义镜像（优先使用）',
                      hintText: 'https://kchan-bgm.<你的子域>.workers.dev',
                      helperText: '填根地址即可（不要带 /v0）。同一个 Worker 同时反代 API 与封面图片',
                      prefixIcon: Icon(Icons.dns_outlined, size: 18),
                    ),
                    onSubmitted: (v) => Store.settings.setApiBases(Store.settings.apiBases, custom: v.trim()),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      FilledButton(
                        onPressed: () => Store.settings.setApiBases(Store.settings.apiBases, custom: _customBaseCtl.text.trim()),
                        child: const Text('保存'),
                      ),
                      const SizedBox(width: 10),
                      OutlinedButton.icon(
                        onPressed: _probing ? null : _probe,
                        icon: _probing
                            ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.6))
                            : const Icon(Icons.network_check, size: 17),
                        label: const Text('连通性检测'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text('当前请求顺序', style: Theme.of(context).textTheme.labelSmall?.copyWith(fontSize: 10.5, letterSpacing: 1)),
                  const SizedBox(height: 6),
                  for (final b in BangumiApiHolder.api.bases)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 5),
                      child: Row(
                        children: [
                          Icon(Icons.circle, size: 6, color: cs.outline),
                          const SizedBox(width: 8),
                          Expanded(child: Text(b, style: const TextStyle(fontFamily: K.monoFamily, fontFamilyFallback: K.monoFallback, fontSize: 11.5))),
                          if (_probeResult != null)
                            ..._latencyBadge(b),
                        ],
                      ),
                    ),
                  const SizedBox(height: 6),
                  Text(
                    '注：api.kazumi.fyi 只实现了 next.bgm.tv 的 /p1 协议，'
                    'K酱 会自动改写路径（/v0/subjects/{id} → /p1/subjects/{id}）；'
                    '搜索（POST）与封面它不支持，会由其它镜像与图片反代接管。',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(fontSize: 10, height: 1.6),
                  ),
                ],
              ),
            ),

            // ---- 网络与代理 ----
            K.sectionLabel('网络出口（代理）', cs.onSurface),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('api.bgm.tv / next.bgm.tv 与部分线路站点在大陆不可直连。'
                      '开着 Clash 等系统代理时打开「跟随系统代理」即可让全部请求走代理'
                      '（与 Kazumi 的行为一致）。',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(height: 1.6)),
                  const SizedBox(height: 8),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('跟随系统代理'),
                    subtitle: Text(systemProxyDescription),
                    value: Store.settings.proxyFollowSystem,
                    onChanged: (v) => Store.settings.setProxy(
                        followSystem: v,
                        manualEnabled: Store.settings.proxyManualEnabled,
                        manualUrl: _proxyUrlCtl.text.trim()),
                  ),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('手动指定代理'),
                    subtitle: const Text('例：127.0.0.1:7890（优先级高于系统代理）'),
                    value: Store.settings.proxyManualEnabled,
                    onChanged: (v) => Store.settings.setProxy(
                        followSystem: Store.settings.proxyFollowSystem,
                        manualEnabled: v,
                        manualUrl: _proxyUrlCtl.text.trim()),
                  ),
                  if (Store.settings.proxyManualEnabled) ...[
                    const SizedBox(height: 6),
                    TextField(
                      controller: _proxyUrlCtl,
                      decoration: const InputDecoration(
                        labelText: '代理地址',
                        hintText: '127.0.0.1:7890',
                        prefixIcon: Icon(Icons.shuffle_on_outlined, size: 18),
                      ),
                      onSubmitted: (v) => Store.settings.setProxy(
                          followSystem: Store.settings.proxyFollowSystem,
                          manualEnabled: true,
                          manualUrl: v.trim()),
                    ),
                  ],
                ],
              ),
            ),

            // ---- 图片 ----
            K.sectionLabel('封面图片', cs.onSurface),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Bangumi 图床 lain.bgm.tv 实测**20s 超时**（同样被封锁）。\n'
                      '「自动镜像」按实测速度依次尝试：'
                      'wsrv.nl（660ms）→ images.weserv.nl（1.3s）→ API 镜像的 /pic/ 路径（2.7s）→ 直连。'
                      '任一张图加载失败会自动换下一个候选。\n'
                      '有自建反代时选「自定义代理」并填入地址（同一个 Worker 即可，它会自动走图片分支）。',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(height: 1.6)),
                  const SizedBox(height: 10),
                  SegmentedButton<int>(
                    segments: const [
                      ButtonSegment(value: 0, label: Text('自动镜像')),
                      ButtonSegment(value: 1, label: Text('直连')),
                      ButtonSegment(value: 2, label: Text('自定义代理')),
                    ],
                    selected: {Store.settings.imageProxyMode},
                    onSelectionChanged: (s) => Store.settings.setImageProxy(s.first, _imgPrefixCtl.text.trim()),
                  ),
                  if (Store.settings.imageProxyMode == 2) ...[
                    const SizedBox(height: 10),
                    TextField(
                      controller: _imgPrefixCtl,
                      maxLines: 3,
                      minLines: 1,
                      keyboardType: TextInputType.multiline,
                      decoration: const InputDecoration(
                        labelText: '图片反代地址（可填多个，做冗余保险）',
                        hintText: 'https://kchan-bgm.你的子域.workers.dev\n'
                            'https://wsrv.nl/?url=',
                        helperText: '一行一个。按顺序尝试，某个挂了会自动跳到下一个'
                            '（各自独立熔断 10 分钟），所以第一个填自建、'
                            '后面跟公共反代最稳。\n'
                            '填「站根地址」或「?url= 前缀」两种写法都支持。',
                        helperMaxLines: 4,
                        prefixIcon: Icon(Icons.image_outlined, size: 18),
                      ),
                      onSubmitted: (v) => Store.settings.setImageProxy(2, v.trim()),
                    ),
                    const SizedBox(height: 8),
                    // 保存按钮：多行输入没法靠回车提交（回车是换行）
                    Align(
                      alignment: Alignment.centerLeft,
                      child: FilledButton.icon(
                        onPressed: () {
                          Store.settings
                              .setImageProxy(2, _imgPrefixCtl.text.trim());
                          final n = ImageProxy.customImageBases.length;
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                              content: Text(n == 0
                                  ? '已保存（但没有解析出有效地址，请检查是否以 http 开头）'
                                  : '已保存 $n 个图片反代，按顺序自动降级')));
                        },
                        icon: const Icon(Icons.save_outlined, size: 17),
                        label: const Text('保存反代列表'),
                      ),
                    ),
                  ],
                ],
              ),
            ),

            // ---- 播放源 ----
            K.sectionLabel('播放源（线路）', cs.onSurface),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('K酱本身不存储任何视频，仅聚合各第三方站点的公开播放地址。',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(height: 1.6)),
                  const SizedBox(height: 10),
                  _sourceGroupSection(cs),
                ],
              ),
            ),

            // ---- 弹幕 ----
            K.sectionLabel('弹幕', cs.onSurface),
            SwitchListTile(
              title: const Text('播放时加载弹幕', style: TextStyle(fontSize: 14)),
              subtitle: Text(
                Store.settings.danmakuAppId.isEmpty
                    // 默认走 B站：无需任何配置，实测可用
                    ? '当前来源：哔哩哔哩（免配置）\n'
                        '填入下方弹弹play凭证后会优先使用它'
                    : '当前来源：弹弹play（已配置）+ 哔哩哔哩兜底',
                style: const TextStyle(fontSize: 11.5),
              ),
              value: Store.settings.danmakuEnabled,
              activeThumbColor: K.accent,
              onChanged: (v) => Store.settings.setDanmakuEnabled(v),
            ),
            // ---- 弹幕聚合实例（覆盖率关键）----
            //
            // 为什么放在最前面：B站单源实测只覆盖约 85%
            // （进击的巨人 / 我推的孩子 / Code Geass R2 等版权受限的番拿不到）。
            // 自建 danmu_api 聚合实例后，这些番都能拿到弹幕。
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
              child: Text(
                '弹幕聚合实例（强烈建议 · 免费）',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Store.settings.danmakuApiBaseUrl.isNotEmpty
                        ? K.accent
                        : cs.onSurface.withValues(alpha: 0.75)),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
              child: Text(
                Store.settings.danmakuApiBaseUrl.isNotEmpty
                    ? '已配置：聚合「爱优腾芒哔巴」等十多个源的弹幕，覆盖率最高'
                    : '默认只用 B站（免配置），但其番剧库只收录约八成作品，'
                        '进击的巨人 / 我推的孩子 / Code Geass 这类会没有弹幕。\n'
                        '部署一个免费聚合实例即可让这些番也有弹幕：'
                        '打开 github.com/huangxd-/danmu_api 按 README 一键部署到 '
                        'Vercel / Netlify / Cloudflare，然后把地址填在下面。',
                style: TextStyle(
                    fontSize: 11,
                    height: 1.5,
                    color: cs.onSurface.withValues(alpha: 0.55)),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _danmakuAggCtl,
                      decoration: const InputDecoration(
                        labelText: '聚合实例地址',
                        hintText: 'https://你的实例.vercel.app',
                        prefixIcon: Icon(Icons.hub_outlined, size: 18),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: FilledButton(
                      onPressed: () async {
                        await Store.settings
                            .setDanmakuApiBaseUrl(_danmakuAggCtl.text);
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(_danmakuAggCtl.text.trim().isEmpty
                                ? '已清空，只用 B站弹幕'
                                : '已保存，下次播放生效'),
                          ),
                        );
                        setState(() {});
                      },
                      child: const Text('保存'),
                    ),
                  ),
                ],
              ),
            ),
            if (Store.settings.danmakuEnabled)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 不透明度
                    Row(
                      children: [
                        const SizedBox(
                            width: 64,
                            child: Text('不透明度',
                                style: TextStyle(fontSize: 12.5))),
                        Expanded(
                          child: Slider(
                            value: Store.settings.danmakuOpacity,
                            min: 0.1,
                            max: 1.0,
                            divisions: 18,
                            label:
                                '${(Store.settings.danmakuOpacity * 100).round()}%',
                            activeColor: K.accent,
                            onChanged: (v) => Store.settings.setDanmakuOpacity(v),
                          ),
                        ),
                        SizedBox(
                          width: 44,
                          child: Text(
                            '${(Store.settings.danmakuOpacity * 100).round()}%',
                            style: const TextStyle(fontSize: 12),
                            textAlign: TextAlign.right,
                          ),
                        ),
                      ],
                    ),
                    // 字号
                    Row(
                      children: [
                        const SizedBox(
                            width: 64,
                            child: Text('弹幕字号',
                                style: TextStyle(fontSize: 12.5))),
                        Expanded(
                          child: Slider(
                            value: Store.settings.danmakuFontSize,
                            min: 10,
                            max: 40,
                            divisions: 30,
                            label:
                                '${Store.settings.danmakuFontSize.round()}',
                            activeColor: K.accent,
                            onChanged: (v) =>
                                Store.settings.setDanmakuFontSize(v),
                          ),
                        ),
                        SizedBox(
                          width: 44,
                          child: Text(
                            '${Store.settings.danmakuFontSize.round()}',
                            style: const TextStyle(fontSize: 12),
                            textAlign: TextAlign.right,
                          ),
                        ),
                      ],
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 4, bottom: 8),
                      child: Text(
                        '说明：B站弹幕只覆盖其番剧库已收录的作品；'
                        '未收录的番会显示「未找到弹幕」，不影响播放。',
                        style: TextStyle(
                            fontSize: 11,
                            color: cs.onSurface.withValues(alpha: 0.55)),
                      ),
                    ),
                  ],
                ),
              ),

            // ---- 弹弹play 凭证（可选，审核通过后填入即生效）----
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Text(
                '弹弹play（可选 · 待审核）',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface.withValues(alpha: 0.75)),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
              child: Text(
                '弹弹play 接口需要开放平台凭证（实测无凭证一律 403）。'
                '到 doc.dandanplay.com/open 注册应用，把两项填在这里即可启用；'
                '未填写时自动只用 B站。',
                style: TextStyle(
                    fontSize: 11,
                    color: cs.onSurface.withValues(alpha: 0.55)),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                children: [
                  TextField(
                    controller: _danmakuIdCtl,
                    decoration: const InputDecoration(
                      labelText: 'AppId',
                      hintText: '弹弹play开放平台 AppId',
                      prefixIcon: Icon(Icons.key_outlined, size: 18),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _danmakuSecretCtl,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'AppSecret',
                      hintText: '弹弹play开放平台 AppSecret',
                      prefixIcon: Icon(Icons.lock_outline, size: 18),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton(
                      onPressed: () {
                        Store.settings.setDanmakuCredentials(
                            _danmakuIdCtl.text, _danmakuSecretCtl.text);
                        ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('弹幕凭证已保存')));
                      },
                      child: const Text('保存凭证'),
                    ),
                  ),
                ],
              ),
            ),

            // ---- 播放 ----
            K.sectionLabel('播放', cs.onSurface),
            SwitchListTile(
              title: const Text('播完自动标记已看', style: TextStyle(fontSize: 14)),
              subtitle: const Text('观看进度超过 80% 或播放结束时自动记录', style: TextStyle(fontSize: 11.5)),
              value: Store.settings.autoNext,
              activeThumbColor: K.accent,
              onChanged: (v) => setState(() => Store.settings.setAutoNext(v)),
            ),

            // ---- 外观 ----
            K.sectionLabel('外观', cs.onSurface),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 0, label: Text('跟随系统'), icon: Icon(Icons.brightness_auto, size: 16)),
                  ButtonSegment(value: 1, label: Text('浅色'), icon: Icon(Icons.light_mode, size: 16)),
                  ButtonSegment(value: 2, label: Text('深色'), icon: Icon(Icons.dark_mode, size: 16)),
                ],
                selected: {Store.settings.themeMode},
                onSelectionChanged: (s) => Store.settings.setThemeMode(s.first),
              ),
            ),

            // ---- 数据 ----
            K.sectionLabel('本地数据', cs.onSurface),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                children: [
                  _dataRow('收藏', '${Store.favorites.map.length} 部'),
                  _dataRow('进度记录', '${Store.progress.map.length} 部'),
                  _dataRow('观看历史', '${Store.history.items.length} 条'),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        final ok = await showDialog<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: const Text('清除全部本地数据？'),
                            content: const Text('将删除本机的收藏、观看进度与历史记录。此操作不可撤销。'),
                            actions: [
                              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
                              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('确认清除')),
                            ],
                          ),
                        );
                        if (ok == true) {
                          await Store.clearAllUserData();
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已清除本地数据')));
                          }
                        }
                      },
                      icon: const Icon(Icons.delete_outline, size: 17),
                      label: const Text('清除全部本地数据'),
                    ),
                  ),
                ],
              ),
            ),

            // ---- 关于 ----
            K.sectionLabel('关于', cs.onSurface),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(color: K.accent, borderRadius: BorderRadius.circular(11)),
                        alignment: Alignment.center,
                        child: const Text('K', style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w700, height: 1.1)),
                      ),
                      const SizedBox(width: 12),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('K酱', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
                          Text('$kAppVersion · 追番客户端', style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 11.5)),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Text(
                    '数据来源：Bangumi 番组计划（bgm.tv）\n'
                    '播放来源：各第三方动漫站点的公开资源，仅供个人学习交流使用\n'
                    '本应用不提供、不存储任何视频内容，所有记录仅保存在本机',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(height: 1.75),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ═══════════════ 播放源（线路）分组管理 ═══════════════
  //
  // 【v1.9.3 完全重做】
  // 旧版把 86 条规则平铺成一个长列表，用户没法用；而且默认只开 2 条
  // （AGE + DM84），其中 AGE 实测是死的 → 实际只剩 1 条线路。
  //
  // 现在按「用起来是什么体验」分 4 个大类（直链/云播/接口/人机验证）
  // + 2 个地区类（国内/海外），每个类可一键开关；
  // 单条源仍可单独控制，并且**标出实测可用性与耗时**，
  // 让用户知道「哪些真的能播、哪条最快」。

  Widget _sourceGroupSection(ColorScheme cs) {
    final all = SourceRegistry.sources;
    // 按大类分组
    final byKind = <SourceKind, List<VideoSource>>{};
    for (final s in all) {
      final c = SourceClassifier.classify(s.rule);
      byKind.putIfAbsent(c.kind, () => []).add(s);
    }
    final enabledCount = all.where((s) => s.enabled).length;
    final activeCount = SourceRegistry.active.length;
    final suppressed = SourceRegistry.suppressedByGroup;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'K酱本身不存储任何视频，仅聚合各第三方站点的公开播放地址。\n'
            '规则库共 ${all.length} 条（来自 Kazumi 官方 KazumiRules）；'
            '当前勾选 $enabledCount 条，因「大类」被关闭而暂不参与聚合的有 $suppressed 条，'
            '实际参与聚合 $activeCount 条。',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(height: 1.6),
          ),
          const SizedBox(height: 6),
          // 快速操作
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              ActionChip(
                avatar: const Icon(Icons.bolt, size: 15),
                label: const Text('只留实测可用', style: TextStyle(fontSize: 11.5)),
                onPressed: () {
                  setState(() {
                    final verified =
                        SourceClassifier.verifiedStats.keys.toSet();
                    SourceRegistry.setManyEnabled(all.map((s) => s.name), false);
                    SourceRegistry.setManyEnabled(verified, true);
                    // 大类全部放开，否则刚开的又被过滤掉
                    for (final k in SourceKind.values) {
                      SourceRegistry.setKindEnabled(k, true);
                    }
                    for (final r in SourceRegion.values) {
                      SourceRegistry.setRegionEnabled(r, true);
                    }
                  });
                  _persistSourcePrefs();
                },
              ),
              ActionChip(
                avatar: const Icon(Icons.restart_alt, size: 15),
                label: const Text('恢复默认', style: TextStyle(fontSize: 11.5)),
                onPressed: () {
                  setState(() {
                    for (final s in all) {
                      SourceRegistry.setEnabled(s.name,
                          RuleRegistry.defaultEnabledNames.contains(s.name));
                    }
                    for (final k in SourceKind.values) {
                      SourceRegistry.setKindEnabled(k, true);
                    }
                    for (final r in SourceRegion.values) {
                      SourceRegistry.setRegionEnabled(r, true);
                    }
                  });
                  _persistSourcePrefs();
                },
              ),
              ActionChip(
                avatar: const Icon(Icons.check_box, size: 15),
                label: const Text('全开', style: TextStyle(fontSize: 11.5)),
                onPressed: () {
                  setState(() =>
                      SourceRegistry.setManyEnabled(all.map((s) => s.name), true));
                  _persistSourcePrefs();
                },
              ),
              ActionChip(
                avatar: const Icon(Icons.check_box_outline_blank, size: 15),
                label: const Text('全关', style: TextStyle(fontSize: 11.5)),
                onPressed: () {
                  setState(() =>
                      SourceRegistry.setManyEnabled(all.map((s) => s.name), false));
                  _persistSourcePrefs();
                },
              ),
            ],
          ),
          const SizedBox(height: 12),
          // ── 线路大类（每个类一个开关 + 可展开看详情）──
          Text('线路大类（按解析方式）',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  fontSize: 11, letterSpacing: .8, color: cs.onSurfaceVariant)),
          const SizedBox(height: 6),
          for (final kind in SourceKind.values)
            _kindGroupTile(kind, byKind[kind] ?? const [], cs),
          const SizedBox(height: 10),
          Text('地区（按网络可达性）',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  fontSize: 11, letterSpacing: .8, color: cs.onSurfaceVariant)),
          const SizedBox(height: 6),
          for (final region in SourceRegion.values)
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(region.label, style: const TextStyle(fontSize: 13.5)),
              subtitle: Text(
                '${all.where((s) => SourceClassifier.classify(s.rule).region == region).length} 条 · ${region.desc}',
                style: const TextStyle(fontSize: 11),
              ),
              value: SourceRegistry.groupPrefs.allowsRegion(region),
              activeThumbColor: K.accent,
              onChanged: (v) => setState(() =>
                  SourceRegistry.setRegionEnabled(region, v)),
            ),
        ],
      ),
    );
  }

  /// 一个大类的折叠卡片：开关 + 该类的实测可用数 + 展开看单条源
  Widget _kindGroupTile(SourceKind kind, List<VideoSource> list, ColorScheme cs) {
    final on = SourceRegistry.groupPrefs.allows(kind);
    final verified = list
        .where((s) => SourceClassifier.verifiedStats.containsKey(s.name))
        .length;
    final expanded = _expandedKinds.contains(kind);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        border: Border.all(
            color: on ? K.accent.withValues(alpha: .35) : cs.outlineVariant,
            width: .8),
        borderRadius: BorderRadius.circular(K.radiusSm),
        color: on ? K.accent.withValues(alpha: .03) : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(K.radiusSm),
            onTap: () => setState(() {
              if (expanded) {
                _expandedKinds.remove(kind);
              } else {
                _expandedKinds.add(kind);
              }
            }),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
              child: Row(
                children: [
                  Icon(
                    expanded
                        ? Icons.keyboard_arrow_down_rounded
                        : Icons.keyboard_arrow_right_rounded,
                    size: 18,
                    color: cs.onSurfaceVariant,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(kind.label,
                            style: const TextStyle(
                                fontSize: 13.5, fontWeight: FontWeight.w600)),
                        Text(
                          '${list.length} 条 · 实测可用 $verified 条',
                          style: TextStyle(
                              fontSize: 10.5, color: cs.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  Switch(
                    value: on,
                    activeThumbColor: K.accent,
                    onChanged: (v) {
                      setState(() => SourceRegistry.setKindEnabled(kind, v));
                      _persistSourcePrefs();
                    },
                  ),
                ],
              ),
            ),
          ),
          if (expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(kind.desc,
                        style: TextStyle(
                            fontSize: 11, color: cs.onSurfaceVariant, height: 1.5)),
                  ),
                  if (list.isEmpty)
                    Text('（该大类暂无规则）',
                        style: TextStyle(fontSize: 11.5, color: cs.outline))
                  else
                    for (final s in list) _sourceTile(s, cs),
                ],
              ),
            ),
        ],
      ),
    );
  }

  List<Widget> _latencyBadge(String base) {
    final r = _probeResult?.firstWhere(
      (e) => e.base == base,
      orElse: () => (base: base, latencyMs: -2),
    );
    final ms = r?.latencyMs ?? -2;
    final ok = ms >= 0;
    return [
      Text(ok ? '$ms ms' : '不可达',
          style: TextStyle(fontFamily: K.monoFamily, fontFamilyFallback: K.monoFallback, fontSize: 11, color: ok ? K.accent : Colors.grey)),
    ];
  }

  Widget _dataRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Text(label, style: const TextStyle(fontSize: 13.5)),
          const Spacer(),
          Text(value, style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 12.5)),
        ],
      ),
    );
  }

  /// 单条源：名称 + 域名 + 实测状态徽标 + 开关
  ///
  /// 【v1.9.3】新增「实测」信息（耗时 / 线路数 / 分集数），
  /// 并把实测失效的源显示为灰色 —— 用户一眼就知道哪些真的能播。
  Widget _sourceTile(VideoSource s, ColorScheme cs) {
    final c = SourceClassifier.classify(s.rule);
    final stat = SourceClassifier.verifiedStats[s.name];
    final dead = SourceClassifier.knownDead.contains(s.name);
    final usable = stat != null;
    final dim = !s.enabled || dead;

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
      decoration: BoxDecoration(
        border: Border.all(
            color: usable
                ? K.accent.withValues(alpha: .35)
                : (dead ? cs.outlineVariant : cs.outlineVariant),
            width: .8),
        borderRadius: BorderRadius.circular(K.radiusSm),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        s.name,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: dim ? cs.onSurface.withValues(alpha: .45) : null,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    // 实测徽标
                    if (usable)
                      _miniBadge(
                        '${stat.latencyMs}ms'
                        '${stat.roads > 1 ? " · ${stat.roads}线路" : ""}',
                        K.accent,
                      )
                    else if (dead)
                      _miniBadge('实测失效', cs.error.withValues(alpha: .8))
                    else
                      _miniBadge('未测', cs.onSurfaceVariant),
                  ],
                ),
                const SizedBox(height: 1),
                Text(
                  s.homepage,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontFamily: K.monoFamily,
                      fontFamilyFallback: K.monoFallback,
                      fontSize: 9.5,
                      color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
          Switch(
            value: s.enabled,
            activeThumbColor: K.accent,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            onChanged: (v) {
              setState(() => SourceRegistry.setEnabled(s.name, v));
              _persistSourcePrefs();
            },
          ),
        ],
      ),
    );
  }

  Widget _miniBadge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        border: Border.all(color: color.withValues(alpha: .5), width: .7),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(text, style: TextStyle(fontSize: 9, color: color, height: 1.3)),
    );
  }
}
