/// 极小的「变更通知」工具（**不依赖 Flutter**）
///
/// ## 为什么不直接用 `ChangeNotifier` / `ValueNotifier`
///
/// `lib/api/bangumi_api.dart` 刻意保持**纯 Dart**：`tool/` 下的规则校验程序
/// 跑在纯 Dart VM 上（无法启动 Flutter engine），一旦这个文件 import 了
/// `package:flutter/foundation.dart`，验证程序就会因为
/// `dart:ui is not available on this platform` 而编译不出来。
///
/// 但「后台补齐中文名 → 通知界面刷新」确实需要一个可监听对象。所以这里
/// 手写一个 10 行的监听器容器：接口与 `Listenable` 一致（addListener /
/// removeListener），界面侧再包一层 `ListenableBuilder` 即可。
library;

typedef VoidCallback0 = void Function();

/// 一个可以被监听、并可以主动「敲一下」的对象。
class TickNotifier {
  final List<VoidCallback0> _listeners = <VoidCallback0>[];

  /// 当前计数（仅用于调试/日志）
  int value = 0;

  bool get hasListeners => _listeners.isNotEmpty;

  void addListener(VoidCallback0 fn) {
    if (!_listeners.contains(fn)) _listeners.add(fn);
  }

  void removeListener(VoidCallback0 fn) => _listeners.remove(fn);

  /// 通知所有监听者
  void notify() {
    value++;
    // 复制一份再遍历：监听者可能在自己的回调里移除自己
    for (final fn in List<VoidCallback0>.of(_listeners)) {
      try {
        fn();
      } catch (_) {
        // 单个监听者出错不该影响其它监听者
      }
    }
  }

  void dispose() => _listeners.clear();
}
