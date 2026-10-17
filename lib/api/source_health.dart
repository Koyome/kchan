/// 线路（播放源）健康度 —— **被动记录版**
///
/// ## 为什么从「启动探测」改成「被动记录」
///
/// 第一版是启动时并发探测 86 个源的 baseURL。数据本身有用
/// （实测 52 可用 / 34 连不上），但它带来一个更严重的副作用：
/// **启动瞬间 86 个请求抢带宽**，把数据源请求拖成不稳定，
/// 用户直接反馈「所有数据源都不可达」。典型的拆东墙补西墙。
///
/// 现在改为被动：
///
/// · **零额外请求** —— 只在用户真实搜索某部番时，记录该源成功/失败；
/// · 连续失败 2 次才降权（单次网络抖动不误伤）；
/// · 30 分钟后自动遗忘（源站恢复即自动回到前面）；
/// · 永远**不删除**任何源，只调整顺序。
///
/// 效果：用得越久，排序越贴近这台机器此刻的真实网络，而且完全免费。
///
/// ## 边界
///
/// 这里只管「顺序」，不参与任何网络决策。即使整张表都错，最坏也只是
/// 排序不理想，**不会导致连不上**。
library;

class _Stat {
  int lastOkMs = 0;
  int okCount = 0;
  int failCount = 0; // 连续失败次数
  int updatedAt = 0;
}

class SourceHealth {
  SourceHealth._();

  static final Map<String, _Stat> _stats = {};

  /// 记录有效期：30 分钟
  static const int _ttlMs = 30 * 60 * 1000;

  /// 连续失败几次判为「暂时不可用」
  static const int _failThreshold = 2;

  static bool _fresh(_Stat s) =>
      DateTime.now().millisecondsSinceEpoch - s.updatedAt < _ttlMs;

  static _Stat? _get(String name) {
    final s = _stats[name];
    if (s == null) return null;
    if (!_fresh(s)) {
      _stats.remove(name);
      return null;
    }
    return s;
  }

  /// 搜索成功：记录耗时
  static void reportSuccess(String name, int elapsedMs) {
    final s = _stats.putIfAbsent(name, _Stat.new);
    s.lastOkMs = elapsedMs;
    s.okCount++;
    s.failCount = 0;
    s.updatedAt = DateTime.now().millisecondsSinceEpoch;
  }

  /// 搜索失败：累计连续失败
  static void reportFailure(String name) {
    final s = _stats.putIfAbsent(name, _Stat.new);
    s.failCount++;
    s.updatedAt = DateTime.now().millisecondsSinceEpoch;
  }

  /// 是否已被降权
  static bool isDegraded(String name) {
    final s = _get(name);
    return s != null && s.failCount >= _failThreshold;
  }

  /// 已知成功耗时
  static int? latencyOf(String name) {
    final s = _get(name);
    if (s == null || s.okCount == 0) return null;
    return s.lastOkMs > 0 ? s.lastOkMs : null;
  }

  /// 排序分数：越小越优先
  ///
  /// 1. 近期成功过 → 按实测耗时
  /// 2. 没见过 → 用离线分类的静态值（不惩罚）
  /// 3. 连续失败 → 排最后（但仍会尝试）
  static int sortScore(String name, {int staticFallback = 0}) {
    if (isDegraded(name)) return 1 << 30;

    final live = latencyOf(name);
    if (live != null) return live;

    final s = _get(name);
    if (s != null && s.failCount > 0) {
      return staticFallback > 0 ? staticFallback + 2000 : 8000;
    }

    if (staticFallback > 0) return staticFallback;
    return 5000;
  }

  /// 摘要（日志用）
  static String describe() {
    var ok = 0;
    var bad = 0;
    for (final e in _stats.entries) {
      if (!_fresh(e.value)) continue;
      if (e.value.failCount >= _failThreshold) {
        bad++;
      } else if (e.value.okCount > 0) {
        ok++;
      }
    }
    return '成功 $ok · 降权 $bad · 记录 ${_stats.length}';
  }

  /// 清空（测试用）
  static void reset() => _stats.clear();
}
