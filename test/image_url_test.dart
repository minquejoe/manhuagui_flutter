import 'package:flutter_test/flutter_test.dart';
import 'package:manhuagui_flutter/config.dart';
import 'package:manhuagui_flutter/service/image_url.dart';

void main() {
  const original = 'https://i.hamreus.com/ps2/d/x/1_2189.jpg.webp?e=1787564004&m=abcDEF';

  test('proxyImageUrl leaves non-CDN urls unchanged', () {
    expect(proxyImageUrl('https://example.com/x.jpg', apiBase: 'https://myapi/v1/'), 'https://example.com/x.jpg');
    expect(proxyImageUrl('https://www.manhuagui.com/comic/1.html', apiBase: 'https://myapi/v1/'), 'https://www.manhuagui.com/comic/1.html');
    expect(proxyImageUrl('', apiBase: 'https://myapi/v1/'), '');
  });

  test('proxyImageUrl does not proxy when pointed at the default developer server', () {
    expect(proxyImageUrl(original, apiBase: BASE_API_URL), original);
    expect(proxyImageUrl(original), original);
  });

  test('proxyImageUrl rewrites CDN urls when pointed at a custom server', () {
    final proxied = proxyImageUrl(original, apiBase: 'https://myapi.tailnet/v1/');
    expect(proxied, startsWith('https://myapi.tailnet/v1/image/proxy?url='));
    // 签名参数必须原样保留（整体编码，不能拆分重组）
    expect(proxied, contains('e%3D1787564004'));
    expect(proxied, contains('m%3DabcDEF'));
    // 解码回原始地址
    expect(proxyUrlToOriginal(proxied), original);
    expect(proxyUrlToOriginal(original), isNull);
  });

  test('originalImageUrl returns the original url', () {
    final proxied = proxyImageUrl(original, apiBase: 'https://myapi.tailnet/v1/');
    expect(originalImageUrl(proxied), original);
    expect(originalImageUrl(original), original);
  });
}
