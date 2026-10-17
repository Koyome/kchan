/// K酱 视觉规范
/// 布局/交互：参考 Kazumi（Material 3、每日放送时间轴、横向卡片、聚合播放）
/// 配色/质感：参考 Koyome.me（浅纸底、衬线标题、等宽小标签、朱红 accent）
library;

import 'package:flutter/material.dart';

/// 应用版本号（**唯一来源**）
///
/// 【v1.9.6】之前「关于」页把版本号**写死**成 `v1.9.0`，改了 pubspec 也不会变 ——
/// 用户看到的版本永远停在 1.9.0，没法确认自己装的是哪一版。
/// 现在统一从这里取；发版时只需同步 pubspec.yaml 与本常量。
///
/// 之所以不用 `package_info_plus` 读真实包信息：那会引入新的原生插件，
/// 而本项目 Android 侧的插件注册是手工打补丁的，加插件成本高、风险大。
const String kAppVersion = 'v2.1.10';

/// 应用版本号（数字部分，用于对比/展示）
const String kAppVersionNumber = '2.1.10';

class K {
  // ---- 形态判定（v1.6.0 移动端适配）----
  static bool isPhoneOf(BuildContext context) =>
      MediaQuery.sizeOf(context).shortestSide < 600;
  /// 低端机判定：3x 屏多是低端机；用于降低解码/动效开销
  static bool isLowEndOf(BuildContext context) =>
      MediaQuery.of(context).devicePixelRatio >= 2.5 ||
      MediaQuery.sizeOf(context).shortestSide < 380;
  // ---- Koyome 纸墨朱红 ----
  static const paper = Color(0xFFF7F4EF); // 浅纸
  static const paperAlt = Color(0xFFEFEAE2);
  static const ink = Color(0xFF3B3A38); // 墨
  static const inkSoft = Color(0xFF6E6A63);
  static const line = Color(0xFFDED7CB);
  static const accent = Color(0xFF9E2B25); // 朱红（涨/强调）

  // 夜间
  static const night = Color(0xFF16151A);
  static const nightAlt = Color(0xFF201F26);
  static const nightLine = Color(0xFF34323C);
  static const nightInk = Color(0xFFEBE9E5);
  static const nightInkSoft = Color(0xFFA9A5A0);

  static const radius = 14.0;
  static const radiusSm = 9.0;

  // ---- 字体 ----
  /// 内置中文衬线（Noto Serif SC 静态子集）：标题、纸墨感
  static const serifFamily = 'KSerif';
  /// 内置中文无衬线（Noto Sans SC 静态子集）：正文、界面
  static const sansFamily = 'KSans';
  /// 等宽族：各平台系统等宽，用于 `[ 标签 ]`、时间码、评分
  static const monoFamily = 'KaiMono';
  /// 【v1.6.0 关键修复】内置字体是**静态子集**，只收录了常用字；
  /// 番剧名、简介、角色名等来自 API 的动态汉字必然有缺字。
  /// 所以 fallback 链必须落到**各平台真实存在的通用族名**：
  ///   - Android：Skia 认识 'sans-serif' / 'serif'（映射到 Noto Sans CJK，中文完整）
  ///   - Windows：'Microsoft YaHei' / 'serif'
  /// 旧版只写 'Noto Sans SC'/'PingFang SC'，Android 上这两个族名不存在，
  /// 缺字时没有任何兜底 —— 表现为「搜索结果/番剧名显示不出来（空白或豆腐块）」。
  static const serifFallback = <String>[
    'Noto Serif CJK SC', 'Source Han Serif SC', 'Songti SC', 'SimSun', 'serif'
  ];
  static const sansFallback = <String>[
    'Noto Sans CJK SC', 'Source Han Sans SC', 'Noto Sans SC',
    'PingFang SC', 'Microsoft YaHei', 'sans-serif'
  ];
  static const monoFallback = <String>['Consolas', 'SF Mono', 'Menlo', 'Roboto Mono', 'Droid Sans Mono', 'monospace'];

  static ThemeData light() => _build(
        bg: paper,
        surface: Colors.white,
        surfaceAlt: paperAlt,
        inkC: ink,
        inkSoftC: inkSoft,
        lineC: line,
        brightness: Brightness.light,
      );

  static ThemeData dark() => _build(
        bg: night,
        surface: nightAlt,
        surfaceAlt: nightAlt,
        inkC: nightInk,
        inkSoftC: nightInkSoft,
        lineC: nightLine,
        brightness: Brightness.dark,
      );

  static ThemeData _build({
    required Color bg,
    required Color surface,
    required Color surfaceAlt,
    required Color inkC,
    required Color inkSoftC,
    required Color lineC,
    required Brightness brightness,
  }) {
    final scheme = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: brightness,
      primary: accent,
      surface: bg,
    ).copyWith(
      surface: bg,
      onSurface: inkC,
      surfaceContainerHighest: surfaceAlt,
      outlineVariant: lineC,
      outline: lineC,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: bg,
      // InkSparkle 需要 FragmentProgram 加载 shaders/ink_sparkle.frag，
      // 手工构建链（自定义 runner + AOT）下该资产加载失败会抛
      // 未捕获异常直接杀进程（2026-10-13 实测 341371 详情页崩溃）。
      // 桌面端 InkRipple 视觉更合适且零 shader 依赖。
      splashFactory: InkRipple.splashFactory,
      // 全站用内置中文无衬线打底；标题/标签再按需切成衬线、等宽
      fontFamily: sansFamily,
      fontFamilyFallback: sansFallback,
      textTheme: TextTheme(
        // 大标题：纸墨衬线，收一点字距，笔画更聚拢
        displaySmall: TextStyle(fontFamily: serifFamily, fontFamilyFallback: serifFallback, fontSize: 29, height: 1.28, fontWeight: FontWeight.w600, color: inkC, letterSpacing: .2),
        titleLarge: TextStyle(fontFamily: serifFamily, fontFamilyFallback: serifFallback, fontSize: 20.5, height: 1.32, fontWeight: FontWeight.w600, color: inkC, letterSpacing: .2),
        titleMedium: TextStyle(fontFamily: serifFamily, fontFamilyFallback: serifFallback, fontSize: 16.5, height: 1.34, fontWeight: FontWeight.w600, color: inkC, letterSpacing: .1),
        titleSmall: TextStyle(fontFamily: serifFamily, fontFamilyFallback: serifFallback, fontSize: 14.5, height: 1.35, fontWeight: FontWeight.w600, color: inkC),
        // 正文：无衬线，行高放宽，长文更透气
        bodyLarge: TextStyle(fontSize: 15, height: 1.72, color: inkC, letterSpacing: .1),
        bodyMedium: TextStyle(fontSize: 14, height: 1.68, color: inkC),
        bodySmall: TextStyle(fontSize: 12.5, height: 1.6, color: inkSoftC, letterSpacing: .05),
        // 标签：等宽，字距略收，避免中文被拉散
        labelLarge: TextStyle(fontSize: 13, letterSpacing: .3, height: 1.35, color: inkC),
        labelMedium: TextStyle(fontFamily: monoFamily, fontFamilyFallback: monoFallback, fontSize: 11, letterSpacing: .9, height: 1.3, color: inkSoftC),
        labelSmall: TextStyle(fontFamily: monoFamily, fontFamilyFallback: monoFallback, fontSize: 10.5, letterSpacing: 1.0, height: 1.3, color: inkSoftC),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: bg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(fontFamily: serifFamily, fontFamilyFallback: serifFallback, fontSize: 18.5, fontWeight: FontWeight.w600, color: inkC, letterSpacing: .4),
        iconTheme: IconThemeData(color: inkC, size: 21),
      ),
      cardTheme: CardThemeData(
        color: surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius), side: BorderSide(color: lineC, width: .8)),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: surfaceAlt,
        side: BorderSide(color: lineC, width: .8),
        labelStyle: TextStyle(fontSize: 11.5, color: inkC),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(K.radiusSm)),
      ),
      dividerTheme: DividerThemeData(color: lineC, thickness: .8, space: 1),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: accent.withValues(alpha: .12),
        elevation: 0,
        height: 62,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        labelTextStyle: WidgetStatePropertyAll(TextStyle(fontSize: 10.5, letterSpacing: .8, color: inkSoftC)),
        iconTheme: WidgetStatePropertyAll(IconThemeData(size: 21, color: inkSoftC)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surfaceAlt,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        hintStyle: TextStyle(fontSize: 13.5, color: inkSoftC),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(K.radiusSm), borderSide: BorderSide(color: lineC, width: .8)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(K.radiusSm), borderSide: BorderSide(color: lineC, width: .8)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(K.radiusSm), borderSide: const BorderSide(color: accent, width: 1.2)),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: inkC,
        contentTextStyle: TextStyle(color: bg, fontSize: 13.5),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(K.radiusSm)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: Colors.white,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(K.radiusSm)),
          textStyle: const TextStyle(fontSize: 13.5, letterSpacing: .4),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: inkC,
          side: BorderSide(color: lineC, width: .9),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(K.radiusSm)),
          textStyle: const TextStyle(fontSize: 13),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          textStyle: const WidgetStatePropertyAll(TextStyle(fontSize: 12.5)),
          side: WidgetStatePropertyAll(BorderSide(color: lineC, width: .8)),
          shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(K.radiusSm))),
        ),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(color: accent, linearMinHeight: 2.5),
    );
  }

  /// 等宽小节标题（Koyome 方言：`[ 每日放送 ]`）
  static Widget sectionLabel(String text, Color color) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 22, 16, 11),
        child: Row(
          children: [
            Text('[ ', style: TextStyle(fontFamily: monoFamily, fontFamilyFallback: monoFallback, fontSize: 12, color: color.withValues(alpha: .5))),
            Text(text,
                style: TextStyle(fontFamily: monoFamily, fontFamilyFallback: monoFallback, fontSize: 12, letterSpacing: 1.4, color: color.withValues(alpha: .78), fontWeight: FontWeight.w600)),
            Text(' ]', style: TextStyle(fontFamily: monoFamily, fontFamilyFallback: monoFallback, fontSize: 12, color: color.withValues(alpha: .5))),
            const SizedBox(width: 12),
            Expanded(child: Container(height: .8, color: color.withValues(alpha: .16))),
          ],
        ),
      );
}
