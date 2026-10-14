/// 弹幕渲染层：轻量自绘实现（滚动 / 顶部 / 底部）
///
/// 设计要点：
///  - 用 `Ticker` 驱动，每帧读取播放器 position，按弹幕的 time 轴投放；
///  - 滚动弹幕走「泳道」：同一条泳道内前后弹幕不重叠（简化：前一条没
///    完全进场就不发下一条）；
///  - 顶部/底部弹幕居中静止显示 5 秒；
///  - 进度回退（拖进度条）时清空在场弹幕重新投放；
///  - 不做任何原生依赖，Android / Windows 行为一致。
library;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../api/danmaku_api.dart';
import '../api/player_backend.dart';

class DanmakuLayer extends StatefulWidget {
  final VideoHandle controller;
  final List<DanmakuEntry> entries;

  /// 是否显示（设置里可关）
  final bool visible;

  /// 不透明度 0..1
  final double opacity;

  const DanmakuLayer({
    super.key,
    required this.controller,
    required this.entries,
    this.visible = true,
    this.opacity = 0.85,
  });

  @override
  State<DanmakuLayer> createState() => _DanmakuLayerState();
}

class _ActiveItem {
  final DanmakuEntry e;
  final double start; // 投放时的播放位置（秒）
  final int lane;
  double textWidth;
  _ActiveItem(this.e, this.start, this.lane, {this.textWidth = 0});
}

class _DanmakuLayerState extends State<DanmakuLayer>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final List<_ActiveItem> _active = [];
  int _nextIndex = 0; // entries 已按 time 排序
  double _lastPos = 0;

  static const _scrollDuration = 9.0; // 滚动弹幕横越屏幕的秒数
  static const _fixedDuration = 5.0; // 顶部/底部停留秒数
  static const _laneCount = 8;
  static const _fontSize = 16.0;
  static const _laneHeight = _fontSize + 10;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _onTick(Duration _) {
    if (!mounted || !widget.visible) return;
    final c = widget.controller;
    if (!c.initialized) return;
    final pos = c.position.inMilliseconds / 1000.0;

    // 进度大幅回退：清场重投
    if (pos < _lastPos - 1.5 || pos > _lastPos + 30) {
      _active.clear();
      _nextIndex = 0;
      while (_nextIndex < widget.entries.length &&
          widget.entries[_nextIndex].time < pos - 0.2) {
        _nextIndex++;
      }
    }
    _lastPos = pos;

    // 投放新弹幕
    final es = widget.entries;
    while (_nextIndex < es.length && es[_nextIndex].time <= pos) {
      final e = es[_nextIndex];
      if (e.time >= pos - 0.6) _launch(e, pos);
      _nextIndex++;
    }

    // 回收离屏/超时的
    _active.removeWhere((a) {
      final elapsed = pos - a.start;
      if (a.e.type == 1) {
        // 完全滚出左缘
        final w = _lastWidth;
        final total = w + a.textWidth;
        return elapsed * (total / _scrollDuration) > total + 40;
      }
      return elapsed > _fixedDuration;
    });

    setState(() {});
  }

  double _lastWidth = 400;

  void _launch(DanmakuEntry e, double pos) {
    // 选泳道：顶部/底部与滚动分开算
    final lanesUsed = <int>{};
    for (final a in _active) {
      final sameKind = (a.e.type == 1) == (e.type == 1);
      if (sameKind) lanesUsed.add(a.lane);
    }
    var lane = 0;
    final maxLane = e.type == 1 ? _laneCount : 2;
    while (lane < maxLane && lanesUsed.contains(lane)) {
      lane++;
    }
    if (lane >= maxLane) return; // 满了就丢（避免糊屏）
    _active.add(_ActiveItem(e, pos, lane));
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.visible) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, c) {
        _lastWidth = c.maxWidth;
        return Opacity(
          opacity: widget.opacity,
          child: CustomPaint(
            size: Size(c.maxWidth, c.maxHeight),
            painter: _DanmakuPainter(
              active: _active,
              pos: _lastPos,
              scrollDuration: _scrollDuration,
              fixedDuration: _fixedDuration,
              laneHeight: _laneHeight,
              fontSize: _fontSize,
            ),
          ),
        );
      },
    );
  }
}

class _DanmakuPainter extends CustomPainter {
  final List<_ActiveItem> active;
  final double pos;
  final double scrollDuration;
  final double fixedDuration;
  final double laneHeight;
  final double fontSize;

  _DanmakuPainter({
    required this.active,
    required this.pos,
    required this.scrollDuration,
    required this.fixedDuration,
    required this.laneHeight,
    required this.fontSize,
  });

  @override
  void paint(Canvas canvas, Size size) {
    for (final a in active) {
      final tp = TextPainter(
        text: TextSpan(
          text: a.e.message,
          style: TextStyle(
            color: Color(0xFF000000 | a.e.color),
            fontSize: fontSize,
            fontWeight: FontWeight.w600,
            shadows: const [
              Shadow(color: Colors.black87, blurRadius: 2.5),
              Shadow(color: Colors.black54, blurRadius: 5),
            ],
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout(maxWidth: size.width);
      a.textWidth = tp.width;

      final elapsed = pos - a.start;
      double x, y;
      if (a.e.type == 1) {
        // 滚动：右缘进场 → 左缘出场
        final total = size.width + tp.width;
        x = size.width - (elapsed / scrollDuration) * total;
        y = 6 + a.lane * laneHeight;
      } else if (a.e.type == 5) {
        // 顶部
        x = (size.width - tp.width) / 2;
        y = 6 + a.lane * laneHeight;
      } else {
        // 底部
        x = (size.width - tp.width) / 2;
        y = size.height - 14 - (a.lane + 1) * laneHeight;
      }
      if (y + tp.height > size.height - 4 || y < 0) continue;
      tp.paint(canvas, Offset(x, y));
    }
  }

  @override
  bool shouldRepaint(covariant _DanmakuPainter oldDelegate) => true;
}
