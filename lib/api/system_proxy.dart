/// 网络出口：系统代理 / 手动代理（**对齐 Kazumi**）
///
/// ## 为什么必须有这一层
///
/// Kazumi 在 Windows 上会跟随 WinINET 系统代理（`system_proxy_service.dart`），
/// 把 `HttpClient.findProxy` 装到它**所有**的 HTTP 客户端上（Dio、WebView、
/// 甚至 mpv）。
///
/// 在大陆网络下这不是锦上添花而是生死线：
///   - `api.bgm.tv` / `next.bgm.tv` / `agedm.io` 等域名**直连不可达**
///     （实测：握手超时 / 证书被重置）；
///   - 用户开着 Clash 之类的系统代理时，Kazumi 能用而 K酱不能，根子就在这。
///
/// 本文件用纯 `dart:ffi` 读注册表（不引第三方包、不引 win32 包，
/// 避免动 pubspec 与构建链），把代理规则装到全局 `HttpOverrides`，
/// 这样 `package:http`、规则搜索、解析链、图片加载**全部统一走代理**。
///
/// ## 优先级
///   手动代理（设置页填写）> 系统代理 > 直连
///   回环地址（127.0.0.1 / localhost）永远直连（本机 CDP、本机服务）。
library;

import 'dart:io' show HttpClient, HttpOverrides, Platform, SecurityContext;
import 'ip_pin.dart';
import 'dart:ffi' as ffi;
import 'package:ffi/ffi.dart' show calloc;

// ══════════════════════════════ 配置态 ══════════════════════════════

/// 代理设置（由 local_store 持久化、设置页修改）
class ProxySettings {
  /// 是否跟随系统代理（Windows 读注册表；Android 永远直连——
  /// 手机上的代理多为 VPN 模式，对 Dart 是透明的）
  bool followSystem = true;

  /// 手动代理开关
  bool manualEnabled = false;

  /// 手动代理地址，形如 `127.0.0.1:7890` 或 `http://127.0.0.1:7890`
  String manualUrl = '';

  ProxySettings();

  /// 手动代理解析成 (host, port)
  (String, int)? get manualProxy {
    if (!manualEnabled) return null;
    return _parseHostPort(manualUrl);
  }
}

/// 全局代理设置（main() 里从 Store 灌入）
ProxySettings proxySettings = ProxySettings();

// ══════════════════════════════ 系统代理（Windows） ══════════════════════════════

class _SystemProxyState {
  final (String, int)? httpProxy;
  final (String, int)? httpsProxy;
  final List<String> bypass;
  final bool bypassLocal;

  const _SystemProxyState({
    this.httpProxy,
    this.httpsProxy,
    required this.bypass,
    required this.bypassLocal,
  });

  static const _SystemProxyState none =
      _SystemProxyState(bypass: [], bypassLocal: false);

  bool get hasProxy => httpProxy != null || httpsProxy != null;
}

_SystemProxyState _sysState = _SystemProxyState.none;
bool _sysRefreshed = false;

/// 读取一次系统代理（Windows 才算，其他平台返回空）
void refreshSystemProxy() {
  if (_sysRefreshed) return;
  _sysRefreshed = true;
  if (!Platform.isWindows) return;
  try {
    _sysState = _readWindowsProxy();
  } catch (_) {
    _sysState = _SystemProxyState.none;
  }
}

bool get systemProxyActive => _sysState.hasProxy;

/// 当前生效的系统代理描述（给设置页显示）
String get systemProxyDescription {
  final p = _sysState.httpProxy ?? _sysState.httpsProxy;
  if (p == null) return '未检测到系统代理';
  return '系统代理 ${p.$1}:${p.$2}';
}

// —— Win32 FFI ——

const _regPath = r'Software\Microsoft\Windows\CurrentVersion\Internet Settings';

typedef _RegGetValueNative = ffi.Int32 Function(
  ffi.IntPtr hkey,
  ffi.Pointer<ffi.Uint16> lpSubKey,
  ffi.Pointer<ffi.Uint16> lpValue,
  ffi.Uint32 dwFlags,
  ffi.Pointer<ffi.Uint32> pdwType,
  ffi.Pointer<ffi.Void> pvData,
  ffi.Pointer<ffi.Uint32> pcbData,
);
typedef _RegGetValueDart = int Function(
  int hkey,
  ffi.Pointer<ffi.Uint16> lpSubKey,
  ffi.Pointer<ffi.Uint16> lpValue,
  int dwFlags,
  ffi.Pointer<ffi.Uint32> pdwType,
  ffi.Pointer<ffi.Void> pvData,
  ffi.Pointer<ffi.Uint32> pcbData,
);

const _HKEY_CURRENT_USER = 0x80000001;
const _RRF_RT_REG_DWORD = 0x00000010;
const _RRF_RT_REG_SZ = 0x00000002;

ffi.Pointer<ffi.Uint16> _toUtf16(String s) {
  final units = s.codeUnits;
  final p = calloc<ffi.Uint16>(units.length + 1);
  final view = p.asTypedList(units.length + 1);
  view.setRange(0, units.length, units);
  view[units.length] = 0;
  return p;
}

String? _fromUtf16(ffi.Pointer<ffi.Uint16> p, int chars) {
  if (chars <= 0) return null;
  final view = p.asTypedList(chars);
  return String.fromCharCodes(view);
}

int? _regReadDword(String name) {
  final lib = ffi.DynamicLibrary.open('advapi32.dll');
  final reg = lib.lookupFunction<_RegGetValueNative, _RegGetValueDart>(
      'RegGetValueW');
  final sub = _toUtf16(_regPath);
  final val = _toUtf16(name);
  final data = calloc<ffi.Uint32>(1);
  final cb = calloc<ffi.Uint32>(1);
  cb.value = 4;
  int status;
  try {
    status = reg(_HKEY_CURRENT_USER, sub, val, _RRF_RT_REG_DWORD,
        ffi.nullptr, data.cast(), cb);
  } finally {
    calloc.free(sub);
    calloc.free(val);
  }
  if (status != 0) {
    calloc.free(data);
    calloc.free(cb);
    return null;
  }
  final v = data.value;
  calloc.free(data);
  calloc.free(cb);
  return v;
}

String? _regReadString(String name) {
  final lib = ffi.DynamicLibrary.open('advapi32.dll');
  final reg = lib.lookupFunction<_RegGetValueNative, _RegGetValueDart>(
      'RegGetValueW');
  final sub = _toUtf16(_regPath);
  final val = _toUtf16(name);
  final cb = calloc<ffi.Uint32>(1);
  // 第一轮：取长度
  final status0 = reg(_HKEY_CURRENT_USER, sub, val, _RRF_RT_REG_SZ,
      ffi.nullptr, ffi.nullptr, cb);
  if (status0 != 0 || cb.value == 0) {
    calloc.free(sub);
    calloc.free(val);
    calloc.free(cb);
    return null;
  }
  final buf = calloc<ffi.Uint16>(cb.value);
  final status = reg(_HKEY_CURRENT_USER, sub, val, _RRF_RT_REG_SZ, ffi.nullptr,
      buf.cast(), cb);
  String? out;
  if (status == 0) {
    final chars = cb.value ~/ 2;
    out = _fromUtf16(buf, chars);
    // REG_SZ 可能带结尾 \0
    if (out != null && out.endsWith('\u0000')) {
      out = out.substring(0, out.length - 1);
    }
  }
  calloc.free(sub);
  calloc.free(val);
  calloc.free(buf);
  calloc.free(cb);
  return out;
}

_SystemProxyState _readWindowsProxy() {
  // ProxyEnable=0 时即使残留 ProxyServer 也视为无代理（与 Kazumi 一致）
  if ((_regReadDword('ProxyEnable') ?? 0) == 0) {
    return _SystemProxyState.none;
  }
  final server = _regReadString('ProxyServer') ?? '';
  final override = _regReadString('ProxyOverride') ?? '';
  final (http, https) = _parseProxyServer(server);
  final (patterns, bypassLocal) = _parseBypassList(override);
  return _SystemProxyState(
    httpProxy: http,
    httpsProxy: https,
    bypass: patterns,
    bypassLocal: bypassLocal,
  );
}

// ══════════════════════════════ 解析工具 ══════════════════════════════

(String, int)? _parseHostPort(String value) {
  var v = value.trim();
  if (v.isEmpty) return null;
  final schemeIdx = v.indexOf('://');
  if (schemeIdx >= 0) v = v.substring(schemeIdx + 3);
  v = v.replaceAll(RegExp(r'/.*$'), '');
  final colon = v.lastIndexOf(':');
  if (colon <= 0 || colon == v.length - 1) return null;
  var host = v.substring(0, colon);
  final port = int.tryParse(v.substring(colon + 1));
  if (port == null || port < 1 || port > 65535) return null;
  if (host.startsWith('[') && host.endsWith(']')) {
    host = host.substring(1, host.length - 1);
  }
  if (host.isEmpty) return null;
  return (host, port);
}

/// `ProxyServer` 可能是 `host:port` 也可能是 `http=h:p;https=h:p`
((String, int)?, (String, int)?) _parseProxyServer(String raw) {
  final v = raw.trim();
  if (v.isEmpty) return (null, null);
  if (!v.contains('=')) {
    final p = _parseHostPort(v);
    return (p, p);
  }
  (String, int)? http;
  (String, int)? https;
  for (final entry in v.split(';')) {
    final idx = entry.indexOf('=');
    if (idx <= 0) continue;
    final scheme = entry.substring(0, idx).trim().toLowerCase();
    final parsed = _parseHostPort(entry.substring(idx + 1));
    if (parsed == null) continue;
    if (scheme == 'http') http = parsed;
    if (scheme == 'https') https = parsed;
  }
  return (http ?? https, https ?? http);
}

(List<String>, bool) _parseBypassList(String raw) {
  final patterns = <String>[];
  var bypassLocal = false;
  for (final part in raw.split(RegExp(r'[;,]'))) {
    var entry = part.trim().toLowerCase();
    if (entry.isEmpty) continue;
    if (entry == '<local>') {
      bypassLocal = true;
      continue;
    }
    final schemeIdx = entry.indexOf('://');
    if (schemeIdx > 0) entry = entry.substring(schemeIdx + 3);
    if (entry.isNotEmpty) patterns.add(entry);
  }
  return (patterns, bypassLocal);
}

bool _isLoopback(String host) {
  if (host == 'localhost' || host == '::1') return true;
  return host.startsWith('127.');
}

bool _shouldBypass(Uri url, _SystemProxyState state) {
  final host = url.host.toLowerCase();
  if (host.isEmpty) return true;
  if (_isLoopback(host)) return true;
  if (state.bypassLocal && !host.contains('.') && !host.contains(':')) {
    return true;
  }
  for (final pattern in state.bypass) {
    final target = pattern.contains(':') ? '$host:${url.port}' : host;
    final re = RegExp('^${RegExp.escape(pattern).replaceAll(r'\*', '.*')}\$');
    if (re.hasMatch(target)) return true;
  }
  return false;
}

// ══════════════════════════════ findProxy 回调 ══════════════════════════════

/// 给 `HttpClient.findProxy` 用的 PAC 风格回调（永不抛异常）
String kProxyFindProxy(Uri url) {
  try {
    final manual = proxySettings.manualProxy;
    if (manual != null) {
      if (_isLoopback(url.host.toLowerCase())) return 'DIRECT';
      return 'PROXY ${manual.$1}:${manual.$2}';
    }
    if (proxySettings.followSystem && _sysState.hasProxy) {
      if (_shouldBypass(url, _sysState)) return 'DIRECT';
      final p =
          url.scheme.toLowerCase() == 'https' ? _sysState.httpsProxy : _sysState.httpProxy;
      if (p != null) return 'PROXY ${p.$1}:${p.$2}';
    }
    return 'DIRECT';
  } catch (_) {
    return 'DIRECT';
  }
}

/// 全局 HttpOverrides：让**所有** `HttpClient()`（含 package:http 的 IOClient）
/// 自动带上代理规则。
class KProxyHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final c = super.createHttpClient(context);
    c.findProxy = kProxyFindProxy;
    // 【优选 IP】全 App 所有 HttpClient 的统一出口 —— 图片、弹幕、抓页都受益。
    //
    // 历史教训（别再犯）：
    //   ① 工厂里**必须**按 uri.scheme / uri.port 连接。写成「一律 443 + TLS」
    //      会让所有 http:// 请求失败 —— 播放源抓页大量是 http，表现为
    //      「解析不出来」。
    //   ② install() 里**不要**再加「有代理就跳过」的门禁。用户的 Windows
    //      系统代理若残留，会导致优选 IP 整体失效 → 数据源退回坏 IP → 不稳。
    IpPin.install(c);
    return c;
  }
}

/// 在 main() 里调用：读系统代理 + 安装全局 overrides。
void installProxyOverrides() {
  refreshSystemProxy();
  HttpOverrides.global = KProxyHttpOverrides();
}
