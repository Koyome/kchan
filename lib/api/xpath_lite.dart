/// 轻量 XPath 引擎（直接作用于 `package:html` 的 DOM）
///
/// ## 为什么不用 `package:xml` 的 XPath（本文件存在的唯一理由）
///
/// 旧实现（v1.9.0 及以前）是：
///   1. `html_parser.parse(html)`  → 拿到 DOM；
///   2. `_serialize()` 把整棵 DOM **手写拼成一个字符串**；
///   3. `XmlDocument.parse('<root>$s</root>')` → **再解析成 XML 树**；
///   4. 在 XML 树上跑 `package:xml` 的 XPath。
///
/// 第 2、3 步是纯粹的双重开销：一个 200KB 的搜索结果页要经历「DOM → 字符串 →
/// 又一棵树」，而 XPath 只用到其中几个节点。Kazumi 官方用的是
/// `xpath_selector_html_parser`，**直接在 HTML DOM 上求值**，没有这层往返。
///
/// 本文件对齐 Kazumi 的做法：直接在 `package:html` 的 DOM 上求值。
///
/// ## 支持的 XPath 子集
///
/// 覆盖 KazumiRules 全部 86 条规则实际用到的语法（见 `tool/xpath_census`）：
///   - 轴：`/`（子）、`//`（后代或自身）、`*`（通配）；
///   - 谓词：`[n]`（位置）、`[@attr]`、`[@attr='v']`、
///     `[contains(@a,'v')]`、`[starts-with(@a,'v')]`、`[text()='v']`；
///   - 终结：`/text()`、`/@attr`。
///
/// **不支持**（规则里没出现，遇到就返回空而不是抛错）：`last()`、
/// `following-sibling` 等其它轴、算术、`|` 并集、`normalize-space()`。
/// 返回空比抛错更符合解析器语义：某条规则某字段写歪了，只是这条规则取不到
/// 结果，不会让整个搜索崩掉。
library;

import 'package:html/dom.dart' as dom;

// ─────────────────────────── 结果节点 ───────────────────────────

/// XPath 求值结果：可能是元素，也可能是属性或文本节点。
///
/// 刻意做成一个包（而不是三态 union）：调用方 99% 的场景只是问
/// 「取文本」或「取属性」，让 `nodeText` / `resolveHref` 自己分派即可。
class XNode {
  final dom.Element? element;
  final String? _text;
  final String? _attrName;
  final String? _attrValue;

  const XNode._(this.element, this._text, this._attrName, this._attrValue);

  factory XNode.ofElement(dom.Element e) => XNode._(e, null, null, null);
  factory XNode.ofText(String t) => XNode._(null, t, null, null);
  factory XNode.ofAttr(String name, String value) =>
      XNode._(null, null, name, value);

  bool get isElement => element != null;
  bool get isText => _text != null;
  bool get isAttr => _attrName != null;

  /// 该节点的完整文本（元素 = 所有后代的文本拼接；属性 = 属性值）
  String? get text {
    if (_text != null) return _text;
    if (_attrValue != null) return _attrValue;
    return element?.text;
  }

  /// 取属性值。属性节点本身按名字返回。
  String? attr(String name) {
    if (_attrName != null && _attrName == name) return _attrValue;
    return element?.attributes[name];
  }
}

// ─────────────────────────── 词法/语法 ───────────────────────────

class _Step {
  /// 元素名，或 null 表示 `*`
  final String? tag;
  /// 谓词列表
  final List<_Pred> preds;
  /// 本步之前的轴：true = `//`（descendant-or-self），false = `/`（child）
  final bool descendant;

  const _Step(this.tag, this.preds, this.descendant);
}

sealed class _Pred {
  const _Pred();
}

/// `[n]` —— 位置（1 起）
class _IndexPred extends _Pred {
  final int index;
  const _IndexPred(this.index);
}

/// `[@attr]` / `[@attr='v']` / `[contains(@attr,'v')]` / `[starts-with(@attr,'v')]`
class _AttrPred extends _Pred {
  /// 1=存在, 2=相等, 3=contains, 4=starts-with
  final int kind;
  final String attr;
  final String value;
  const _AttrPred(this.kind, this.attr, this.value);
}

/// `[position() > 1]` / `[position() >= 1]` 之类的位置条件
///
/// 【为什么需要】官方规则 mengfan 的 `chapterResult` 是
/// `//div[2]/div[2]/div/div/div[2]/div/div[1]/div[2]//div[position() > 1]`
/// —— 站点的播放列表里第 1 个 div 是表头，要跳过。不支持这个函数就会让
/// 整条规则「编译失败 → 返回空 → 用户看到未收录」。
///
/// 只实现 `position()` 与常数的比较（`>` `>=` `<` `<=` `=` `!=`），
/// 这是规则库里唯一出现的形态。
class _PosPred extends _Pred {
  final String op;
  final int value;
  const _PosPred(this.op, this.value);
}

/// `[text()='v']`
class _TextPred extends _Pred {
  final String value;
  const _TextPred(this.value);
}

/// `[tag]` / `[tag='v']` —— 子元素存在性（规则里少见但语法上合法）
class _ChildPred extends _Pred {
  final String tag;
  const _ChildPred(this.tag);
}

/// 解析失败：调用方吞掉并返回空结果（一条坏规则不该毁掉整次搜索）
class XPathSyntaxError implements Exception {
  final String expression;
  final String reason;
  const XPathSyntaxError(this.expression, this.reason);
  @override
  String toString() => 'XPathSyntaxError($reason): $expression';
}

/// 把一个 XPath 表达式编译成步骤列表（可缓存复用）
class CompiledXPath {
  final String source;
  final List<_Step> steps;
  final bool wantsText;
  final String? wantsAttr;

  const CompiledXPath(this.source, this.steps, this.wantsText, this.wantsAttr);

  static final Map<String, CompiledXPath?> _cache = {};

  /// 编译并缓存。语法不支持时返回 null（缓存住不重复解析）。
  static CompiledXPath? of(String path) {
    final key = path;
    final hit = _cache[key];
    if (hit != null || _cache.containsKey(key)) return hit;
    CompiledXPath? c;
    try {
      c = _compile(path);
    } catch (_) {
      c = null;
    }
    _cache[key] = c;
    return c;
  }

  static CompiledXPath _compile(String raw) {
    var s = raw.trim();
    if (s.isEmpty) throw XPathSyntaxError(raw, 'empty');

    bool wantsText = false;
    String? wantsAttr;

    // 终结符：/text() 或 /@attr
    if (s.endsWith('/text()')) {
      wantsText = true;
      s = s.substring(0, s.length - '/text()'.length).trim();
    } else {
      final at = s.lastIndexOf('/@');
      // 只认「最后一个 /@x」且 x 是合法属性名。
      // 注意这里必须显式匹配 `/@`：早期写成 `^/[A-Za-z_]...` 少了一个 `@`，
      // 结果是 `//a/@href` 被拆成两步（`a` 然后 `@href`）→ 永远取不到值。
      if (at >= 0 &&
          RegExp(r'^/@[A-Za-z_][\w:.-]*$').hasMatch(s.substring(at))) {
        wantsAttr = s.substring(at + 2);
        s = s.substring(0, at).trim();
      }
    }
    // 纯 @attr 表达式
    if (s.startsWith('@') && RegExp(r'^@[A-Za-z_][\w:.-]*$').hasMatch(s)) {
      return CompiledXPath(raw, const [], false, s.substring(1));
    }
    if (s.isEmpty) {
      // 形如 `/text()`：上下文节点自身取文本
      return CompiledXPath(raw, const [], wantsText, wantsAttr);
    }

    final steps = <_Step>[];
    // 前导：`//` = descendant from root；`/` = child of root
    var descendant = false;
    if (s.startsWith('//')) {
      descendant = true;
      s = s.substring(2);
    } else if (s.startsWith('/')) {
      s = s.substring(1);
    } else if (s.startsWith('./')) {
      // `.//x` / `./x` —— 相对当前节点；与绝对写法在本引擎里等价，
      // 因为 steps[0] 的 descendant 标志已经表达了语义。
      s = s.substring(1);
      if (s.startsWith('//')) {
        descendant = true;
        s = s.substring(2);
      } else if (s.startsWith('/')) {
        s = s.substring(1);
      }
    } else if (s.startsWith('.')) {
      s = s.substring(1);
      if (s.startsWith('//')) {
        descendant = true;
        s = s.substring(2);
      }
    }

    // 【边界】裸 `//` 或 `/`：规则库里 aafun 的 chapterRoads 就写着 `//`。
    // 语义 = 根下全部后代元素（等价 `//*`），退化成「一个匹配一切的 step」。
    if (s.isEmpty) {
      if (steps.isEmpty) steps.add(_Step(null, const [], descendant));
      return CompiledXPath(raw, steps, wantsText, wantsAttr);
    }

    while (s.isNotEmpty) {
      // 切出「名字 + 谓词」这一段
      var i = 0;
      final nameBuf = StringBuffer();
      while (i < s.length && s[i] != '/' && s[i] != '[') {
        nameBuf.write(s[i]);
        i++;
      }
      final name = nameBuf.toString().trim();

      final preds = <_Pred>[];
      while (i < s.length && s[i] == '[') {
        final end = _matchBracket(s, i);
        final body = s.substring(i + 1, end).trim();
        preds.add(_parsePred(body, raw));
        i = end + 1;
      }

      final tag = (name.isEmpty || name == '*') ? null : name;
      steps.add(_Step(tag, preds, descendant));

      if (i >= s.length) break;
      if (s[i] == '/') {
        if (i + 1 < s.length && s[i + 1] == '/') {
          descendant = true;
          i += 2;
        } else {
          descendant = false;
          i += 1;
        }
        s = s.substring(i);
      } else {
        s = s.substring(i);
      }
    }
    if (steps.isEmpty) throw XPathSyntaxError(raw, 'no steps');
    return CompiledXPath(raw, steps, wantsText, wantsAttr);
  }

  /// 找到与 `s[start]` 的 `[` 配对的 `]`（跳过引号内的括号）
  static int _matchBracket(String s, int start) {
    var depth = 0;
    String? quote;
    for (var i = start; i < s.length; i++) {
      final c = s[i];
      if (quote != null) {
        if (c == quote) quote = null;
        continue;
      }
      if (c == "'" || c == '"') {
        quote = c;
        continue;
      }
      if (c == '[') depth++;
      if (c == ']') {
        depth--;
        if (depth == 0) return i;
      }
    }
    throw XPathSyntaxError(s, 'unbalanced [');
  }

  static final _reContains =
      RegExp(r'''^contains\(\s*@([\w:.-]+)\s*,\s*(['"])(.*?)\2\s*\)$''',
          caseSensitive: false);
  static final _reStarts =
      RegExp(r'''^starts-with\(\s*@([\w:.-]+)\s*,\s*(['"])(.*?)\2\s*\)$''',
          caseSensitive: false);
  static final _reAttrEq =
      RegExp(r'''^@([\w:.-]+)\s*=\s*(['"])(.*?)\2$''', caseSensitive: false);
  static final _reAttrName = RegExp(r'^@([\w:.-]+)$');
  static final _reTextEq =
      RegExp(r'''^text\(\)\s*=\s*(['"])(.*?)\1$''', caseSensitive: false);
  static final _reInt = RegExp(r'^(\d+)$');
  static final _reTagName = RegExp(r'^[A-Za-z_][\w:.-]*$');
  static final _rePosition = RegExp(
      r'^position\(\)\s*(>=|<=|!=|>|<|=)\s*(\d+)$',
      caseSensitive: false);

  static _Pred _parsePred(String body, String whole) {
    if (body.isEmpty) throw XPathSyntaxError(whole, 'empty predicate');

    final mIdx = _reInt.firstMatch(body);
    if (mIdx != null) return _IndexPred(int.parse(mIdx.group(1)!));

    final mPos = _rePosition.firstMatch(body);
    if (mPos != null) {
      return _PosPred(mPos.group(1)!, int.parse(mPos.group(2)!));
    }

    final mC = _reContains.firstMatch(body);
    if (mC != null) return _AttrPred(3, mC.group(1)!, mC.group(3)!);

    final mS = _reStarts.firstMatch(body);
    if (mS != null) return _AttrPred(4, mS.group(1)!, mS.group(3)!);

    final mE = _reAttrEq.firstMatch(body);
    if (mE != null) return _AttrPred(2, mE.group(1)!, mE.group(3)!);

    final mN = _reAttrName.firstMatch(body);
    if (mN != null) return _AttrPred(1, mN.group(1)!, '');

    final mT = _reTextEq.firstMatch(body);
    if (mT != null) return _TextPred(mT.group(2)!);

    if (_reTagName.hasMatch(body)) return _ChildPred(body);

    throw XPathSyntaxError(whole, 'unsupported predicate [$body]');
  }

  // ─────────────────────── 求值 ───────────────────────

  /// 以 [context] 为当前节点求值。
  ///
  /// [context] 传 `dom.Document` 时按「文档根」处理（`//x` 会扫全文档）。
  List<XNode> eval(dom.Node context) {
    // 终结符为纯属性：`@href`
    if (steps.isEmpty) {
      if (wantsAttr != null) {
        final v = _attrOf(context, wantsAttr!);
        return v == null ? const [] : [XNode.ofAttr(wantsAttr!, v)];
      }
      final t = _textOf(context);
      return t == null ? const [] : [XNode.ofText(t)];
    }

    List<dom.Node> ctx = [context];
    for (var si = 0; si < steps.length; si++) {
      final step = steps[si];
      final out = <dom.Node>[];
      for (final n in ctx) {
        if (n is dom.Document) {
          // 文档根：把「根元素」当作上下文元素。
          // 【务必保留】html_parser.parse() 返回的是 Document，而 `//div` 这类
          // 表达式是从根元素往下找后代。若这里不展开成根元素，
          // `//div` 在整篇文档上会一个都匹配不到（实测踩过这个坑）。
          final root = n.documentElement;
          if (root == null) continue;
          if (step.descendant) {
            _collectDescendants(root, step.tag, out);
          } else {
            // `/div` = 根元素的直接子元素
            _collectChildren(root, step.tag, out);
          }
          continue;
        }
        if (n is! dom.Element) continue;
        if (step.descendant) {
          _collectDescendants(n, step.tag, out);
        } else {
          _collectChildren(n, step.tag, out);
        }
      }
      ctx = _applyPreds(out, step.preds);
      if (ctx.isEmpty) return const [];
    }

    if (wantsAttr != null) {
      final v = _attrOf(ctx.first, wantsAttr!);
      return v == null ? const [] : [XNode.ofAttr(wantsAttr!, v)];
    }
    if (wantsText) {
      final parts = <XNode>[];
      for (final n in ctx) {
        final t = _textOf(n);
        if (t != null) parts.add(XNode.ofText(t));
      }
      return parts;
    }
    return [
      for (final n in ctx)
        if (n is dom.Element) XNode.ofElement(n)
    ];
  }

  /// 取「元素上下文」
  static String? _attrOf(dom.Node n, String name) {
    if (n is dom.Element) {
      final v = n.attributes[name];
      if (v != null) return v;
      // 名字大小写不敏感兜底（HTML 属性通常已小写化）
      final lower = name.toLowerCase();
      for (final e in n.attributes.entries) {
        if (e.key.toString().toLowerCase() == lower) return e.value;
      }
    }
    return null;
  }

  static String? _textOf(dom.Node n) {
    if (n is dom.Element) return n.text;
    if (n is dom.Text) return n.text;
    if (n is dom.Document) return n.documentElement?.text;
    return null;
  }

  /// 后代或自身里收集匹配 [tag] 的元素。
  ///
  /// 性能要点：`//div` 这类「按标签名找后代」用 DOM 自带的
  /// `getElementsByTagName`（底层是索引/快速遍历），比手写递归快得多；
  /// 只有 `//*` 与带谓词的场合才回落到自写遍历。
  static void _collectDescendants(
      dom.Element? root, String? tag, List<dom.Node> out) {
    if (root == null) return;
    if (tag != null) {
      // getElementsByTagName 返回**后代**（不含自身），语义正好是 `//tag`
      out.addAll(root.getElementsByTagName(tag));
      return;
    }
    // `//*`：自身 + 全部后代元素
    out.add(root);
    _walkAll(root, out);
  }

  static void _walkAll(dom.Element e, List<dom.Node> out) {
    for (final c in e.children) {
      out.add(c);
      _walkAll(c, out);
    }
  }

  static void _collectChildren(
      dom.Element parent, String? tag, List<dom.Node> out) {
    if (tag == null) {
      out.addAll(parent.children);
      return;
    }
    for (final c in parent.children) {
      if (c.localName == tag) out.add(c);
    }
  }

  static List<dom.Node> _applyPreds(List<dom.Node> nodes, List<_Pred> preds) {
    if (preds.isEmpty) return nodes;
    var cur = nodes;
    for (final p in preds) {
      switch (p) {
        case _IndexPred(:final index):
          if (index < 1 || index > cur.length) return const [];
          cur = [cur[index - 1]];
        case _PosPred():
          final filtered = <dom.Node>[];
          for (var i = 0; i < cur.length; i++) {
            if (_posMatch(i + 1, p)) filtered.add(cur[i]);
          }
          cur = filtered;
        case _AttrPred():
          cur = [
            for (final n in cur)
              if (_attrMatch(n, p)) n
          ];
        case _TextPred(:final value):
          cur = [
            for (final n in cur)
              if ((_textOf(n) ?? '').trim() == value) n
          ];
        case _ChildPred(:final tag):
          cur = [
            for (final n in cur)
              if (n is dom.Element && n.children.any((c) => c.localName == tag))
                n
          ];
      }
      if (cur.isEmpty) return const [];
    }
    return cur;
  }

  /// `position()` 比较（位置是 1 起的）
  static bool _posMatch(int pos, _PosPred p) {
    switch (p.op) {
      case '>':
        return pos > p.value;
      case '>=':
        return pos >= p.value;
      case '<':
        return pos < p.value;
      case '<=':
        return pos <= p.value;
      case '!=':
        return pos != p.value;
      case '=':
        return pos == p.value;
    }
    return false;
  }

  static bool _attrMatch(dom.Node n, _AttrPred p) {
    final v = _attrOf(n, p.attr);
    if (v == null) return false;
    switch (p.kind) {
      case 1:
        return true;
      case 2:
        return v == p.value;
      case 3:
        return v.contains(p.value);
      case 4:
        return v.startsWith(p.value);
    }
    return false;
  }
}

/// 便捷入口：在 [context] 上求 [path]。语法不支持 / 无匹配 → 空列表。
List<XNode> xpathSelect(dom.Node context, String path) {
  if (path.trim().isEmpty) return const [];
  final c = CompiledXPath.of(path);
  if (c == null) return const [];
  try {
    return c.eval(context);
  } catch (_) {
    return const [];
  }
}
