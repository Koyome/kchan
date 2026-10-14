/// 受限 JSONPath 引擎（对齐 Kazumi `RestrictedJsonPath`）
///
/// ## 背景
///
/// Kazumi 从 `api` level 8 起引入了**不解析 HTML、直接调站点 JSON 接口**的规则
/// （`searchMode: "api"` / `chapterMode: "api"`）。这类规则用 JSONPath 描述
/// 「从响应里取哪一段」。官方仓库里目前有 4 条：
/// `TvTFun` / `milimili` / `sorani` / `xfdmnext`。
///
/// 旧版 K酱 完全没有实现这部分 —— 这 4 条规则即使被启用也只会返回空结果，
/// 正是用户说的「很多视频源未适配」的一大类。本文件补齐该能力。
///
/// ## 为什么是「受限」JSONPath
///
/// 刻意只实现 Kazumi 支持的那一小撮语法（与其 `RestrictedJsonPath.validate`
/// 一一对应）。好处：
///   - 不需要引入 `json_path` 依赖（少一个第三方包 = 少一处 AOT/平台风险）；
///   - 语义与 Kazumi 完全一致，官方规则拿来即用。
///
/// 支持：`$.a.b`、`$.a[0]`、`$.a[*]`、`$['a b']`、`$[0]`、`$[*]`、`$`
/// 不支持：递归下降 `..`、过滤器 `[?(...)]`、切片 `[1:2]`、函数、`|`。
library;

/// JSONPath 语法错误（对齐 Kazumi 的 ApiRuleFormatException 语义）
class JsonPathFormatException implements Exception {
  final String message;
  const JsonPathFormatException(this.message);
  @override
  String toString() => 'JsonPathFormatException: $message';
}

/// 路径片段
sealed class _Seg {
  const _Seg();
}

/// `.name` 或 `['name']`
class _KeySeg extends _Seg {
  final String key;
  const _KeySeg(this.key);
}

/// `[n]`
class _IndexSeg extends _Seg {
  final int index;
  const _IndexSeg(this.index);
}

/// `[*]`
class _WildcardSeg extends _Seg {
  const _WildcardSeg();
}

class JsonPathLite {
  final String source;
  final List<_Seg> segs;

  const JsonPathLite(this.source, this.segs);

  static final Map<String, JsonPathLite?> _cache = {};

  /// 解析并缓存；表达式非法时抛 [JsonPathFormatException]。
  static JsonPathLite parse(String expression) {
    final expr = expression.trim();
    final hit = _cache[expr];
    if (hit != null) return hit;
    final p = _parse(expr);
    _cache[expr] = p;
    return p;
  }

  /// 与 Kazumi 的 validate 等价：只校验，不取值
  static void validate(String expression) => parse(expression);

  static JsonPathLite _parse(String expr) {
    if (expr.isEmpty || !expr.startsWith(r'$')) {
      throw JsonPathFormatException('JSONPath 必须以 \$ 开头: $expr');
    }
    final segs = <_Seg>[];
    var i = 1;
    while (i < expr.length) {
      final c = expr[i];
      if (c == '.') {
        i++;
        final start = i;
        while (i < expr.length && RegExp(r'[A-Za-z0-9_$-]').hasMatch(expr[i])) {
          i++;
        }
        if (i == start) {
          throw JsonPathFormatException('不支持的 JSONPath 片段: $expr');
        }
        segs.add(_KeySeg(expr.substring(start, i)));
        continue;
      }
      if (c == '[') {
        final end = _bracketEnd(expr, i);
        final content = expr.substring(i + 1, end).trim();
        if (content == '*') {
          segs.add(const _WildcardSeg());
        } else if (RegExp(r'^\d+$').hasMatch(content)) {
          segs.add(_IndexSeg(int.parse(content)));
        } else if (content.length >= 2 &&
            ((content.startsWith("'") && content.endsWith("'")) ||
                (content.startsWith('"') && content.endsWith('"')))) {
          segs.add(_KeySeg(content.substring(1, content.length - 1)));
        } else {
          throw JsonPathFormatException('不支持的 JSONPath 片段: [$content]');
        }
        i = end + 1;
        continue;
      }
      throw JsonPathFormatException('不支持的 JSONPath: $expr');
    }
    return JsonPathLite(expr, segs);
  }

  static int _bracketEnd(String s, int start) {
    String? quote;
    var escaped = false;
    for (var i = start + 1; i < s.length; i++) {
      final c = s[i];
      if (escaped) {
        escaped = false;
        continue;
      }
      if (c == r'\') {
        escaped = true;
        continue;
      }
      if (quote != null) {
        if (c == quote) quote = null;
        continue;
      }
      if (c == "'" || c == '"') {
        quote = c;
        continue;
      }
      if (c == ']') return i;
    }
    throw JsonPathFormatException('JSONPath 缺少 ]: $s');
  }

  /// 求值：返回全部匹配值（对齐 `readValues`）
  List<Object?> read(dynamic doc) {
    List<Object?> cur = [doc];
    for (final seg in segs) {
      final next = <Object?>[];
      switch (seg) {
        case _KeySeg(:final key):
          for (final n in cur) {
            if (n is Map && n.containsKey(key)) next.add(n[key]);
          }
        case _IndexSeg(:final index):
          for (final n in cur) {
            if (n is List && index >= 0 && index < n.length) next.add(n[index]);
            // 对齐 json_path：对 Map 用数字键也认（部分接口返回 {"0":…}）
            if (n is Map && n.containsKey('$index')) next.add(n['$index']);
          }
        case _WildcardSeg():
          for (final n in cur) {
            if (n is List) {
              next.addAll(n);
            } else if (n is Map) {
              next.addAll(n.values);
            }
          }
      }
      cur = next;
      if (cur.isEmpty) break;
    }
    return cur;
  }

  /// 首个匹配值（对齐 `readFirst`）
  Object? readFirst(dynamic doc) {
    final v = read(doc);
    return v.isEmpty ? null : v.first;
  }
}

/// 便捷：求值，出错返回空列表（解析器语义：坏规则只影响自己）
List<Object?> jsonPathRead(dynamic doc, String expression) {
  if (expression.trim().isEmpty) return const [];
  try {
    return JsonPathLite.parse(expression).read(doc);
  } on JsonPathFormatException {
    return const [];
  }
}

/// 便捷：取首个值，出错返回 null
Object? jsonPathFirst(dynamic doc, String expression) {
  final v = jsonPathRead(doc, expression);
  return v.isEmpty ? null : v.first;
}
