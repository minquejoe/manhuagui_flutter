import 'package:manhuagui_flutter/config.dart';

/// 图床 URL 的统一改写：把 hamreus.com / mhgui.com 域名的图片地址改写为
/// 经由自建后端图片代理下载的地址，解决手机直连图床慢 / 间歇性超时的问题。
///
/// 仅当传入的 [apiBase] 指向自建服务器（非默认的开发者服务器）时才启用
/// 代理；未配置或指向默认服务器时原样返回，避免把图片请求打到没有代理
/// 端点的原开发者服务器上。
String proxyImageUrl(String url, {String? apiBase}) {
  if (url.isEmpty) {
    return url;
  }
  Uri uri;
  try {
    uri = Uri.parse(url);
  } catch (_) {
    return url;
  }
  var host = uri.host.toLowerCase();
  var isCdnHost = host == 'hamreus.com' ||
      host.endsWith('.hamreus.com') ||
      host == 'mhgui.com' ||
      host.endsWith('.mhgui.com');
  if (!isCdnHost) {
    return url; // 非图床域名（例如自建服务器自身）不动
  }
  var base = (apiBase ?? BASE_API_PURE_URL).replaceAll(RegExp(r'/+$'), '');
  if (base == BASE_API_PURE_URL.replaceAll(RegExp(r'/+$'), '') || base == BASE_API_URL.replaceAll(RegExp(r'/+$'), '')) {
    return url; // 未配置自建服务器 -> 直连图床
  }
  // base 形如 https://myapi/v1/，取其根路径再拼接代理端点
  if (base.toLowerCase().endsWith('/v1')) {
    base = base.substring(0, base.length - 3);
  }
  base = base.replaceAll(RegExp(r'/+$'), '');
  // url 必须整体 Uri.encodeComponent：图片 URL 自带 ?e=...&m=... 防过期签名，
  // 编码后作为单个 query 参数原样透传，绝不能拆开重组。
  return '$base/$IMAGE_PROXY_PATH?url=${Uri.encodeComponent(url)}';
}

/// 若 [url] 是经 [proxyImageUrl] 改写的代理地址，返回其原始图床 URL；
/// 否则返回 null。用于代理失败时回退直连。
String? proxyUrlToOriginal(String url) {
  if (url.isEmpty) {
    return null;
  }
  try {
    var uri = Uri.parse(url);
    if (!uri.path.endsWith('/$IMAGE_PROXY_PATH')) {
      return null;
    }
    var original = uri.queryParameters['url'];
    return (original == null || original.isEmpty) ? null : original;
  } catch (_) {
    return null;
  }
}

/// 返回 [url] 的原始图床地址（若为代理地址则解码出来），否则原样返回。
/// 用于需要从 URL 推导文件扩展名等场景（代理地址本身没有扩展名）。
String originalImageUrl(String url) => proxyUrlToOriginal(url) ?? url;
