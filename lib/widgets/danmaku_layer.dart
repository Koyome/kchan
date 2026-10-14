/// 弹幕渲染层（基于 `canvas_danmaku`）
///
/// ## 为什么换掉原来的自绘实现
///
/// 原来这里是手写的 `Ticker` + `CustomPaint`。换成 `canvas_danmaku` 的收益：
///   - **轨道分配**：同轨道防重叠算法比自写的「前一条没完全进场就不发下一条」精确
///   - **分层重绘**：滚动层与静止层分开，静止层只在需要时重绘；
///     无弹幕时 Ticker 自动停止，不空转耗电
///   - **字形缓存**：每条弹幕的文字只渲染一次成 `ui.Image`，之后直接 drawImage
///   - 已内建 `IgnorePointer`，不会吞掉播放器的手势
///
/// ## 关键约束（决定了本文件的代码结构）
///
/// **`canvas_danmaku` 完全没有时间轴概念。**
/// `DanmakuContentItem` 没有时间字段，controller 也没有 `seek`/`setPosition`。
/// 它只知道「现在」。所以：
///
///   - 所有按时间调度的逻辑必须由**我们自己**从播放器 position 驱动；
///   - 正常播放时维护游标 `_cursor`，到点就 `addDanmaku`；
///   - 位置**大幅后退**（拖了进度条）时 `clear()` + 重注入最近一个时间窗。
///
/// ## 两个必须知道的库行为
///
/// 1. **重建 widget 改不了样式**：`DanmakuScreen` 只在 `initState` 读一次
///    `option`，没有 `didUpdateWidget`。所以修改字号/透明度**必须**走
///    `controller.updateOption(...)`，传新 option 重建是无效的。
/// 2. **`hideXxx` 从 false 改 true 会立即清空该类型在场弹幕**，改回 false
///    不会恢复。所以「关弹幕再开」会有一段空白 —— 这是库的行为，已在
///    `_applyStyle` 注释里标明。
///
/// ## 已知精度损失
///
/// 0.3.3 没有 offset API，seek 后重注入的弹幕**无法从半途续播**，
/// 会从屏幕右边缘重新滚入。属于「近似而非精确」，UI 上不做承诺。
library;

// canvas_danmaku 也导出了一个 `DanmakuItem`（它自己的渲染期条目类型），
// 与本项目 `danmaku_source.dart` 里的数据条目同名 —— 这里 hide 掉它，
// 避免歧义导入。两者语义不同：我们的是「从弹幕源拉到的原始数据」，
// 它的是「已进入渲染管线的在场条目」。
import 'package:canvas_danmaku/canvas_danmaku.dart' hide DanmakuItem;
import 'package:flutter/material.dart';

import '../api/danmaku_source.dart';
import '../api/diag_log.dart';

/// 弹幕显示设置（播放页可实时调整）
class DanmakuStyle {
  final bool enabled;
  final double opacity;
  final double fontSize;

  const DanmakuStyle({
    this.enabled = true,
    this.opacity = 1.0,
    this.fontSize = 16,
  });

  DanmakuStyle copyWith({bool? enabled, double? opacity, double? fontSize}) =>
      DanmakuStyle(
        enabled: enabled ?? this.enabled,
        opacity: opacity ?? this.opacity,
        fontSize: fontSize ?? this.fontSize,
      );
}

class DanmakuLayer extends StatefulWidget {
  const DanmakuLayer({
    super.key,
    required this.entries,
    required this.positionMs,
    required this.style,
    this.playing = true,
  });

  /// 全部弹幕（按 timeMs 升序）
  final List<DanmakuItem> entries;

  /// 当前播放位置（毫秒）—— 由播放页的 controller 监听器更新
  final int positionMs;

  final DanmakuStyle style;

  /// 播放器是否在播放（暂停时同步暂停弹幕动画）
  final bool playing;

  @override
  State<DanmakuLayer> createState() => DanmakuLayerState();
}

class DanmakuLayerState extends State<DanmakuLayer> {
  DanmakuController<void>? _c;

  /// 下一条待发射弹幕的下标（正常播放时只前进，不重置）
  int _cursor = 0;

  /// 上一帧位置，用于检测「后退 = seek」
  int _lastPos = 0;

  /// 已发射条数（诊断用）
  int _emitted = 0;

  /// 供外部读取的诊断信息
  String get debugInfo =>
      '已发射 $_emitted / 共 ${widget.entries.length} 条，游标 $_cursor';

  @override
  void didUpdateWidget(DanmakuLayer old) {
    super.didUpdateWidget(old);

    // 换集 / 换源 → 弹幕列表整体换了，重置时间轴
    if (!identical(old.entries, widget.entries)) {
      _cursor = 0;
      _lastPos = 0;
      _emitted = 0;
      _c?.clear();
      kLog('[弹幕] 列表已更换（${widget.entries.length} 条），时间轴重置');
      _pump();
      return;
    }

    // 样式变化 → 必须走 updateOption（重建 widget 无效，见文件头说明）
    if (old.style.opacity != widget.style.opacity ||
        old.style.fontSize != widget.style.fontSize ||
        old.style.enabled != widget.style.enabled) {
      _applyStyle();
    }

    // 暂停 / 继续：弹幕动画与播放器手动配对
    if (old.playing != widget.playing) {
      if (widget.playing) {
        _c?.resume();
      } else {
        _c?.pause();
      }
    }

    _pump();
  }

  /// 把当前设置写到 controller
  void _applyStyle() {
    final c = _c;
    if (c == null) return;
    final on = widget.style.enabled;
    c.updateOption(c.option.copyWith(
      fontSize: widget.style.fontSize,
      opacity: widget.style.opacity,
      // 【注意】把 hideXxx 从 false 改 true 会**立即清空该类型已在场的弹幕**，
      // 改回 false 不会恢复。所以关闭再打开会有一段空白，这是库的行为。
      hideScroll: !on,
      hideTop: !on,
      hideBottom: !on,
      hideSpecial: !on,
    ));
    // 打一行日志，便于确认开关真的生效（排查「能开不能关」时靠它定位）。
    // 只在状态变化时打印，不会刷屏。
    if (_lastAppliedEnabled != on) {
      _lastAppliedEnabled = on;
      kLog('[弹幕] 显示开关 → ${on ? "开" : "关"}'
          '（hideScroll=${
          !on} fontSize=${widget.style.fontSize.toStringAsFixed(0)}'
          ' opacity=${widget.style.opacity.toStringAsFixed(2)}）');
    }
  }

  /// 上一次已应用的开关状态（用于日志去重）
  bool? _lastAppliedEnabled;

  /// 按当前播放位置发射到点的弹幕；检测到 seek 则重同步
  void _pump() {
    final c = _c;
    if (c == null || !widget.style.enabled) return;

    final pos = widget.positionMs;

    // 网络弹幕迟到、快进或后退时不能补发跨越区间的全部旧弹幕：
    // 那会一次性创建大量 ui.Image，造成明显卡顿和内存尖峰。
    if (pos < _lastPos - 1500 || pos > _lastPos + 2500) {
      _resync(pos);
      _lastPos = pos;
      return;
    }
    _lastPos = pos;

    // 正常播放：把到点的弹幕全部发出去
    while (_cursor < widget.entries.length &&
        widget.entries[_cursor].timeMs <= pos) {
      _add(widget.entries[_cursor]);
      _cursor++;
    }
  }

  void _add(DanmakuItem e) {
    final c = _c;
    if (c == null) return;
    c.addDanmaku(DanmakuContentItem<void>(
      e.text,
      color: Color(0xFF000000 | e.color),
      type: switch (e.mode) {
        DanmakuMode.top => DanmakuItemType.top,
        DanmakuMode.bottom => DanmakuItemType.bottom,
        DanmakuMode.scroll => DanmakuItemType.scroll,
      },
    ));
    _emitted++;
  }

  /// seek 重同步：清屏 + 重新注入「最近一个滚动周期」内的弹幕
  void _resync(int posMs) {
    final c = _c;
    if (c == null) return;
    c.clear();

    // 有序时间轴上二分定位，避免每次 seek 都扫描整集弹幕。
    final end = _firstAfter(posMs);
    _cursor = end;
    // 0.3.3 没有 offset，只能从右边缘重新滚入最近一段。
    // 最多 60 条，防止弹幕密集区一次生成数百张字形图片。
    final windowMs = (c.option.duration * 1000).round();
    final start = _firstAfter(posMs - windowMs);
    final first = start > end - 60 ? start : end - 60;
    for (var i = first; i < end; i++) {
      _add(widget.entries[i]);
    }
    kLog('[弹幕] seek 到 ${(posMs / 1000).toStringAsFixed(1)}s，'
        '重注入 ${end - first} 条，游标 → $_cursor');
  }

  int _firstAfter(int ms) {
    var lo = 0, hi = widget.entries.length;
    while (lo < hi) {
      final mid = lo + (hi - lo) ~/ 2;
      if (widget.entries[mid].timeMs <= ms) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  @override
  Widget build(BuildContext context) {
    return DanmakuScreen<void>(
      createdController: (c) {
        // 【注意】这里**不能** setState —— 它在 initState 阶段被调用
        _c = c;
        _applyStyle();
        // controller 就绪后补一次 pump，避免首帧前到点的弹幕被漏掉
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _pump();
        });
      },
      option: DanmakuOption(
        fontSize: widget.style.fontSize,
        opacity: widget.style.opacity,
        fontWeight: 4,
        // 滚动弹幕横穿屏幕的秒数
        duration: 10,
        // 顶部/底部静止弹幕停留秒数
        staticDuration: 5,
        strokeWidth: 1.5,
        lineHeight: 1.6,
        // 为底部控制栏预留空间，避免弹幕压住控件
        safeArea: true,
        hideScroll: !widget.style.enabled,
        hideTop: !widget.style.enabled,
        hideBottom: !widget.style.enabled,
      ),
    );
  }
}
