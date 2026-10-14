/// 公共组件：封面、条目卡片、评分徽标、状态条、跳转
library;

import 'dart:async';
import 'dart:io' show HttpClient, HttpHeaders;

import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../models.dart';
import '../api/bangumi_api.dart';
import '../api/diag_log.dart' show kLog;
import '../store/local_store.dart';
import '../theme.dart';

/// 封面图：**多候选自动降级** + 磁盘缓存 + 解码尺寸限制 + **并行预热**
///
/// 【v1.9.2 · 手机端图片专项重写】
///
/// 旧实现在手机上有两个真实问题：
///
///  1. **降级链要等前一个「失败」才算失败**。Flutter 的 `Image` 在网络不通时
///     不会很快报错（TCP 握手要等系统超时，实测 `lain.bgm.tv` 直连 **20s**），
///     于是用户看到的是「一直空白」，而不是切到下一个候选。
///     → 现在改为：**同时**对前若干候选发一个轻量 HEAD/GET 探测（2.5s 超时），
///     谁先返回 `image/*` 就用谁的 URL 去喂 `Image`。探测结果是进程级缓存，
///     同一张图/同一个候选不会重复探。
///
///  2. **候选可能包含「会返回 200 但不是图片」的地址**（API 镜像的 `/pic/`
///     在图不存在时返回 200 + JSON），旧代码把它当成功、解码失败后不再换 →
///     永远空白。→ 现在探测阶段直接校验 `Content-Type`，非 `image/*` 直接淘汰。
///
/// 与桌面端一致：`memCacheWidth/Height` 按显示尺寸 × DPR 限制解码分辨率，
/// 低端机滚动不掉帧。
class KCover extends StatefulWidget {
  final String url;
  final double? width;
  final double? height;
  final double radius;
  /// Bangumi 条目 id：用于走「镜像同域图片端点」这一最稳候选
  final int subjectId;
  const KCover({
    super.key,
    required this.url,
    this.width,
    this.height,
    this.radius = K.radiusSm,
    this.subjectId = 0,
  });

  @override
  State<KCover> createState() => _KCoverState();
}

/// 候选探测结果的进程级缓存：url → 是否可当图片用
///
/// 【v1.9.3 手机端修复】只缓存**成功**结果。
/// 旧版把失败也永久缓存，于是「首屏那几秒网络还没热起来」时的失败会被记死，
/// 后面就算网通了也不会再试 —— 这是手机端「封面一直空白、桌面却正常」的关键差异
/// （桌面网络稳，第一次探测就成功；手机首屏要跑一堆 API 请求，图片探测容易被挤超时）。
final Map<String, bool> _kProbeCache = {};

/// 失败计数：同一 URL 连续失败 3 次才认为它真的不可用（记入缓存）
final Map<String, int> _kProbeFailStreak = {};
const int _kProbeFailLimit = 3;

/// 探测超时（连接 + 响应头）。
///
/// 旧值 3s 在手机移动网络下太紧（还叠加 DNS 解析、TLS 握手），
/// 实测会导致「全部候选都探测失败」→ 退回直连 → 直连 20s 超时 → 一直空白。
/// 放宽到 6s，同时下面用「并发 + 谁先成功用谁」保证整体不会更慢。
const Duration _kProbeTimeout = Duration(seconds: 6);

/// 失败降级路径的探测超时：用户已经在等图了，宁可少换一个也不要再等 6s。
const Duration _kEscalateTimeout = Duration(milliseconds: 2500);

/// 正在探测中的 url（避免同一张图被几十个卡片重复探）
final Map<String, Future<bool>> _kProbeInflight = {};

/// 探测用的 HttpClient。
///
/// 只在这里创建一次：手机端 TLS 握手有额外开销，连接复用能明显减少探测耗时。
final HttpClient _kProbeClient = HttpClient()
  ..connectionTimeout = const Duration(seconds: 6)
  ..idleTimeout = const Duration(seconds: 15)
  ..maxConnectionsPerHost = 6;

/// 探测一个候选地址是否真的能拿到图片。
///
/// 只读响应头就关掉连接（`close()`），不下载 body —— 所以很便宜。
Future<bool> _probeImageCandidate(String url, {Duration? timeout}) async {
  final cached = _kProbeCache[url];
  if (cached != null) return cached;
  final inflight = _kProbeInflight[url];
  if (inflight != null) return inflight;

  final fut = () async {
    if (!url.startsWith('http')) return true;
    var ok = false;
    try {
      // ═══════════════════════════════════════════════════════════════════
      // 【v1.9.4 · 关键性能修复：探测改用 HEAD，不再下载图片本体】
      //
      // 旧代码用 `getUrl`（完整 GET）然后 `res.drain()` 掉 body ——
      // 也就是**为了看一眼 Content-Type，把整张封面图下载了一遍再扔掉**，
      // 随后 CachedNetworkImage 又去下载同一张图 → **每张图下两遍**。
      // 桌面宽带下感受不明显；手机上首屏 20+ 张封面 = 40+ 次请求、
      // 双倍流量，叠加 6s 超时，正是「手机端很卡」的主因之一。
      //
      // 现在只发 HEAD 只取响应头。个别图床不支持 HEAD 时，
      // 退化为 `Range: bytes=0-1` 的 GET —— 只取 1 字节，同样几乎零成本。
      // ═══════════════════════════════════════════════════════════════════
      final uri = Uri.parse(url);
      var req = await _kProbeClient.openUrl('HEAD', uri).timeout((timeout ?? _kProbeTimeout));
      req.headers.set('Accept', 'image/*,*/*');
      var res = await req.close().timeout((timeout ?? _kProbeTimeout));
      var code = res.statusCode;
      var ct = (res.headers.contentType?.mimeType ?? '').toLowerCase();
      // 不下载 body，直接放掉连接（必须 drain，否则连接不回收）
      unawaited(res.drain<void>().catchError((_) {}));

      if (code == 405 || code == 501 || code == 400 || code == 403) {
        // 该图床不支持/拒绝 HEAD → 用 1 字节 GET 再试一次
        req = await _kProbeClient.getUrl(uri).timeout((timeout ?? _kProbeTimeout));
        req.headers.set('Accept', 'image/*,*/*');
        req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1');
        res = await req.close().timeout((timeout ?? _kProbeTimeout));
        code = res.statusCode;
        ct = (res.headers.contentType?.mimeType ?? '').toLowerCase();
        unawaited(res.drain<void>().catchError((_) {}));
      }
      // 不下载 body，直接放掉连接（必须 drain，否则连接不回收）
      unawaited(res.drain<void>().catchError((_) {}));
      ok = (code == 200 || code == 206) && ct.startsWith('image/');
      // 【v1.9.4】把连通性反馈给 ImageProxy 熔断器：
      // 国外反代在国内网络是**稳定连不上**，连续失败后就不再列为候选，
      // 免得每张封面都白等一次 6s 超时（这是「手机端很卡」的主因之一）。
      if (ok) {
        ImageProxy.reportProxyReachable(url);
      }
      return ok;
    } catch (e) {
      // 网络类失败（超时/DNS/TLS）**不算「该地址不可用」**，不写缓存，
      // 让下一次刷新或滚动回来时还能再试。
      // 但要把「这个反代连不上」告诉熔断器（见 ImageProxy.reportProxyUnreachable）。
      ImageProxy.reportProxyUnreachable(url);
      // 只有「连上了但拿到的不是图片」才计入失败次数。
      return false;
    } finally {
      _kProbeInflight.remove(url);
      if (ok) {
        _kProbeCache[url] = true;
        _kProbeFailStreak.remove(url);
      } else {
        // 只有明确拿到响应但类型不对时才算「确定不可用」。
        // 这里用一个保守规则：连续失败 _kProbeFailLimit 次才记入缓存。
        final n = (_kProbeFailStreak[url] ?? 0) + 1;
        _kProbeFailStreak[url] = n;
        if (n >= _kProbeFailLimit) _kProbeCache[url] = false;
      }
    }
  }();

  _kProbeInflight[url] = fut;
  return fut;
}

/// 主动忘掉某张图的所有候选缓存（用户下拉刷新/点重试时调用）
void resetCoverProbeCache() {
  _kProbeCache.clear();
  _kProbeFailStreak.clear();
}

/// 【并行选路】从候选链里挑出第一个「确认可用」的地址。
///
/// 策略：**全部候选同时探测**，谁先成功用谁。
///
/// 为什么改成全部并发（而不是先探前 3 个）：
/// 候选链里排在后面的「API 镜像 /pic/ 路径」在手机上往往才是唯一能通的那个
/// （因为同一台主机已经在提供 API，手机网络必然能到它）。
/// 只探前 3 个会出现「唯一可用的候选没被探到」→ 退回直连 → 空白。
/// 候选总数很少（≤6），并发探测的额外开销可以忽略。
Future<String> resolveCoverUrl(List<String> candidates) async {
  if (candidates.isEmpty) return '';
  if (candidates.length == 1) return candidates.first;

  final completer = Completer<String>();
  var remaining = candidates.length;
  for (final url in candidates) {
    unawaited(() async {
      bool ok = false;
      try {
        ok = await _probeImageCandidate(url);
      } catch (_) {
        ok = false;
      }
      if (ok && !completer.isCompleted) completer.complete(url);
    }().whenComplete(() {
      remaining--;
      if (remaining == 0 && !completer.isCompleted) {
        // 一个都没探通：把候选列首交给 Image 自己试（至少不是死等）
        completer.complete(candidates.first);
      }
    }));
  }
  return completer.future;
}

class _KCoverState extends State<KCover> {
  late List<String> _candidates;
  /// 已确认可用的地址（探测出来之前为空 → 显示骨架色）
  String? _resolved;
  /// 还没有候选链（探测全失败后直接把 _candidates 交给 Image 逐级降级）
  int _fallbackIndex = 0;
  bool _probing = false;
  /// 是否正在执行失败降级探测（防重入）
  bool _escalating = false;
  /// 正在找可用候选（UI 上显示加载指示）
  bool _waitingProbe = false;

  /// 首选候选：**立刻**用来渲染（不等待探测）。
  ///
  /// 【v1.9.4】顺序已由 ImageProxy 按可达性重排，首选通常是能通的那个，
  /// 所以直接开下载 = 0 等待出图。
  String? get _preferred =>
      _candidates.isEmpty ? null : _candidates.first;

  @override
  void initState() {
    super.initState();
    _candidates = ImageProxy.candidates(widget.url, subjectId: widget.subjectId);
    // 【v1.9.5 · 性能修正】initState 里**什么都不探**。
    //
    // 上一版在这里无条件启动「竞速探测全部候选」。实测代价：
    //   - 即使首选 10ms 就显示出图，那张图仍会再发一轮请求；
    //   - 竞速会把国内连不上的候选（各 6s 超时）也一起跑满；
    //   - 首页 30 张封面 → 90 个额外请求，白白占 CPU 和带宽。
    // 用户直接反馈「Windows 版本加载反而变慢了」，就是这里造成的。
    //
    // 现在：首选候选直接渲染，**零额外请求**；
    // 只有 Image 层真的失败时才去探剩余候选（见 _nextFallback）。
  }

  @override
  void didUpdateWidget(covariant KCover old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url || old.subjectId != widget.subjectId) {
      _candidates =
          ImageProxy.candidates(widget.url, subjectId: widget.subjectId);
      _resolved = null;
      _fallbackIndex = 0;
      _waitingProbe = false;
      _escalating = false;
      // 【v1.9.5】这里同样不探测：直接让新的首选候选开始渲染。
    }
  }


  /// Image 层失败时的降级。
  ///
  /// 【v1.9.5】改成**失败驱动的顺序探测**：
  ///   1. 先看本地探测缓存里有没有已确认可用的候选；
  ///   2. 没有就只对「剩余候选」逐个探（每个 4s 上限），谁先通用谁；
  ///   3. 探测也没结果就按顺序换下一个候选。
  ///
  /// 关键是：这条路径**只在真的加载失败时才走**，正常情况零开销。
  Future<void> _nextFallback() async {
    if (!mounted || _escalating) return;
    if (_fallbackIndex + 1 >= _candidates.length) {
      // 没有更多候选了，把当前这个标记为最终失败
      if (mounted) setState(() => _waitingProbe = false);
      return;
    }
    _escalating = true;
    setState(() => _waitingProbe = true);
    try {
      final rest = _candidates.sublist(_fallbackIndex + 1);
      final hit = await _probeFirstWorking(rest);
      if (!mounted) return;
      if (hit != null) {
        // 探到能用的：直接换上（并记住它在链里的位置，之后仍可继续降级）
        final idx = _candidates.indexOf(hit);
        setState(() {
          _fallbackIndex = idx < 0 ? _fallbackIndex + 1 : idx;
          _waitingProbe = false;
        });
      } else {
        setState(() {
          _fallbackIndex++;
          _waitingProbe = false;
        });
      }
    } finally {
      _escalating = false;
    }
  }

  /// 顺序探测一批候选，返回第一个「确认能拿到图片」的地址；都不行返回 null。
  ///
  /// 顺序而不是并发：失败路径本来就不常见，顺序探测对站点更友好，
  /// 而且能保证拿到的是**链里最靠前**的可用地址（并发返回顺序不确定）。
  Future<String?> _probeFirstWorking(List<String> urls) async {
    for (final u in urls) {
      if (!mounted) return null;
      final cached = _kProbeCache[u];
      if (cached == true) return u;
      if (cached == false) continue;
      try {
        // 失败路径给短超时：用户已经在等了，宁可不换也不要再等 6s
        final ok = await _probeImageCandidate(u, timeout: _kEscalateTimeout);
        if (ok) return u;
      } catch (_) {}
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // 高分屏（Windows 125%/150%、手机 2x/3x）按设备像素比限制解码尺寸。
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final factor = dpr >= 2.5 ? 1.0 : 1.5;
    final cacheW =
        widget.width != null ? (widget.width! * dpr * factor).round() : null;
    final cacheH =
        widget.height != null ? (widget.height! * dpr * factor).round() : null;

    // 【v1.9.4】首选**同步可用** → 首屏立刻开始下载，不再等探测。
    // 探测出更优地址后 _resolved 会被换上。
    final url = _resolved ??
        (_candidates.isEmpty
            ? null
            : _candidates[_fallbackIndex.clamp(0, _candidates.length - 1)]);

    // 【v1.9.4 · 列表滚动优化】用 RepaintBoundary 把封面隔离成独立图层。
    //
    // 为什么需要：`CachedNetworkImage` 的 fadeIn 是一段 160ms 的透明度动画。
    // 首屏 20+ 张封面陆续到达 → 20 段动画**同时**在跑；没有 RepaintBoundary 时，
    // 每帧都要重绘整条列表，手机 GPU 直接跟不上（表现就是滑动卡顿、掉帧）。
    // 加上之后每张封面各自成层，只有它自己重绘，滚动时列表本层几乎不重绘。
    // 这是 Flutter 官方对「列表里的图片/动画」推荐的标准做法。
    return RepaintBoundary(
      child: ClipRRect(
      borderRadius: BorderRadius.circular(widget.radius),
      child: Container(
        width: widget.width,
        height: widget.height,
        color: cs.surfaceContainerHighest,
        child: url == null
            ? Icon(Icons.movie_outlined, color: cs.outline, size: 20)
            : CachedNetworkImage(
                key: ValueKey(url),
                imageUrl: url,
                fit: BoxFit.cover,
                filterQuality: FilterQuality.medium,
                memCacheWidth: cacheW,
                memCacheHeight: cacheH,
                maxWidthDiskCache: 600,
                fadeInDuration: const Duration(milliseconds: 160),
                // 探测阶段已确认 Content-Type 是图片，这里基本不会触发；
                // 真触发了就顺序换下一个候选（有上限，不会无限重试）。
                errorListener: (_) {
                  WidgetsBinding.instance
                      .addPostFrameCallback((_) => _nextFallback());
                },
                // 占位：首选在下载中（或正在等探测换更优地址）时显示
                // 一个很轻的进度指示，而不是纯色块 —— 让用户知道在加载
                placeholder: (_, __) => Container(
                  color: cs.surfaceContainerHighest,
                  alignment: Alignment.center,
                  child: SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.6,
                      color: cs.outline.withValues(alpha: .55),
                    ),
                  ),
                ),
                errorWidget: (_, __, ___) => _fallbackIndex + 1 < _candidates.length
                    ? Container(color: cs.surfaceContainerHighest)
                    : Icon(Icons.broken_image_outlined,
                        color: cs.outline, size: 18),
              ),
      ),
      ),
    );
  }
}

/// 竖版番剧卡片（网格/横滑用）
///
/// 【v1.9.2】宽度不再固定 118：横滑列表按屏宽推导，
/// 手机上 3 张刚好占满、桌面 6 张，两边观感一致（Kazumi 也是这个思路）。
///
/// 【v1.9.3】新增 [gridHeightFor]：把「系统字体放大」也算进去。
/// 手机上把系统字号调大（很常见）后，标题两行会变高，
/// 而网格格子高度是按 `childAspectRatio` 写死算出来的 → 文字被裁掉/溢出。
class SubjectCard extends StatelessWidget {
  final Subject subject;
  final VoidCallback? onTap;
  final double width;
  const SubjectCard({super.key, required this.subject, this.onTap, this.width = 118});

  /// 根据可用宽度算「一屏放几张」后的卡片宽度
  static double widthFor(BuildContext context, {int perScreen = 3, double gap = 11, double pad = 32}) {
    final w = MediaQuery.sizeOf(context).width;
    final usable = w - pad - gap * (perScreen - 1);
    return (usable / perScreen).clamp(96.0, 190.0);
  }

  /// 卡片在给定宽度下需要的**总高度**（封面 + 标题两行 + 日期），
  /// 已把系统字体缩放算进去。
  ///
  /// 网格用它当 `mainAxisExtent`（而不是 `childAspectRatio`），
  /// 这样大字体下格子会跟着变高，文字不会被裁。
  static double gridHeightFor(BuildContext context, double cardWidth) {
    final scaler = MediaQuery.textScalerOf(context);
    const baseTitle = 12.8;
    final titleLine = scaler.scale(baseTitle) * 1.32;
    final dateLine = scaler.scale(10.0) * 1.25 + 2;
    // 封面(宽×1.4) + 间距 7 + 标题两行 + （可选）日期行 + 底部余量 4
    return cardWidth * 1.4 + 7 + titleLine * 2 + dateLine + 4;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final fav = Store.favorites.statusOf(subject.id);
    // 卡片整体包一层重绘边界：网格滚动时不会连带重绘封面/评分徽标，
    // 低端机帧率明显更稳。
    return RepaintBoundary(
      child: GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: width,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              children: [
                KCover(url: subject.images.cover, width: width, height: width * 1.4, subjectId: subject.id),
                if (subject.score > 0)
                  Positioned(
                    left: 6,
                    top: 6,
                    child: ScoreBadge(score: subject.score),
                  ),
                if (fav != FavStatus.none)
                  Positioned(
                    right: 6,
                    top: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                      decoration: BoxDecoration(color: K.accent, borderRadius: BorderRadius.circular(4)),
                      child: Text(fav.label, style: const TextStyle(fontSize: 9, color: Colors.white, height: 1.2)),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 7),
            Text(
              subject.displayName,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: tt.bodyMedium?.copyWith(fontSize: 12.8, height: 1.32),
            ),
            if (subject.airDate.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(subject.airDate, style: tt.labelSmall?.copyWith(fontSize: 10, color: cs.onSurface.withValues(alpha: .45))),
              ),
          ],
        ),
      ),
      ),
    );
  }
}

class ScoreBadge extends StatelessWidget {
  final double score;
  final bool small;
  const ScoreBadge({super.key, required this.score, this.small = false});

  @override
  Widget build(BuildContext context) {
    if (score <= 0) return const SizedBox.shrink();
    return Container(
      padding: EdgeInsets.symmetric(horizontal: small ? 4 : 5.5, vertical: small ? 1 : 2),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: .58),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        score.toStringAsFixed(1),
        style: TextStyle(
          fontFamily: K.monoFamily, fontFamilyFallback: K.monoFallback,
          fontSize: small ? 9.5 : 11,
          fontWeight: FontWeight.w700,
          color: score >= 7.5 ? const Color(0xFFFFC24A) : Colors.white,
          height: 1.15,
        ),
      ),
    );
  }
}

/// 横滑分组
///
/// 【v1.9.2 修排版】高度不再写死 236：
/// 卡片高度 = 封面(width×1.4) + 间距7 + 两行标题 + 日期行。
/// 写死高度在手机大字体/小屏下会**溢出**（黄色黑条），也是用户反馈的
/// 「排版不正常」来源之一。现在按实际卡片宽度算。
class SubjectRow extends StatelessWidget {
  final String title;
  final List<Subject> items;
  final void Function(Subject)? onTap;
  const SubjectRow({super.key, required this.title, required this.items, this.onTap});

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    final cardW = SubjectCard.widthFor(context);
    final rowH = SubjectCard.gridHeightFor(context, cardW);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        K.sectionLabel(title, Theme.of(context).colorScheme.onSurface),
        SizedBox(
          height: rowH,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(width: 11),
            itemBuilder: (_, i) => SubjectCard(
              // 稳定 key：条目 id 不变 → Element 复用，图片不重解码
              key: ValueKey('sub-${items[i].id}'),
              subject: items[i],
              width: cardW,
              onTap: () => onTap?.call(items[i]),
            ),
          ),
        ),
      ],
    );
  }
}

/// 收藏状态操作条
class FavStatusBar extends StatelessWidget {
  final Subject subject;
  const FavStatusBar({super.key, required this.subject});

  static const _order = [FavStatus.doing, FavStatus.wish, FavStatus.collect, FavStatus.onHold, FavStatus.dropped];

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Store.favorites,
      builder: (context, _) {
        final cur = Store.favorites.statusOf(subject.id);
        // 【v1.6.0 触控】手机上把可点区域撑到 ≥40px 高（原来 30px 出头，容易点空）
        final touchPad = K.isPhoneOf(context) ? 10.0 : 7.0;
        return Wrap(
          spacing: 7,
          runSpacing: 7,
          children: [
            for (final s in _order)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  Store.favorites.setStatus(subject, cur == s ? FavStatus.none : s);
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  padding: EdgeInsets.symmetric(horizontal: 14, vertical: touchPad),
                  decoration: BoxDecoration(
                    color: cur == s ? K.accent : Colors.transparent,
                    border: Border.all(color: cur == s ? K.accent : Theme.of(context).colorScheme.outlineVariant, width: .9),
                    borderRadius: BorderRadius.circular(K.radiusSm),
                  ),
                  child: Text(
                    s.label,
                    style: TextStyle(fontSize: 12.5, color: cur == s ? Colors.white : Theme.of(context).colorScheme.onSurface, height: 1.2),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// 空状态
class EmptyHint extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? sub;
  final Widget? action;
  const EmptyHint({super.key, required this.icon, required this.title, this.sub, this.action});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(36),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 38, color: cs.outline),
            const SizedBox(height: 14),
            Text(title, style: Theme.of(context).textTheme.bodyLarge?.copyWith(fontSize: 14.5, color: cs.onSurface.withValues(alpha: .75))),
            if (sub != null) ...[
              const SizedBox(height: 6),
              Text(sub!, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
            ],
            if (action != null) ...[const SizedBox(height: 18), action!],
          ],
        ),
      ),
    );
  }
}

/// 错误条（带重试）
class ErrorBar extends StatelessWidget {
  final String message;
  final VoidCallback? onRetry;
  const ErrorBar({super.key, required this.message, this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: K.accent.withValues(alpha: .07),
        border: Border.all(color: K.accent.withValues(alpha: .28), width: .8),
        borderRadius: BorderRadius.circular(K.radiusSm),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, size: 17, color: K.accent.withValues(alpha: .8)),
          const SizedBox(width: 9),
          Expanded(child: Text(message, style: const TextStyle(fontSize: 12.5, height: 1.45))),
          if (onRetry != null)
            TextButton(
              onPressed: onRetry,
              style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8), minimumSize: Size.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
              child: const Text('重试', style: TextStyle(fontSize: 12.5)),
            ),
        ],
      ),
    );
  }
}
