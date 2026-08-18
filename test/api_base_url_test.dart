import 'package:flutter_test/flutter_test.dart';
import 'package:manhuagui_flutter/app_setting.dart';
import 'package:manhuagui_flutter/config.dart';

void main() {
  test('effectiveApiBaseUrl falls back to the default developer proxy', () {
    expect(OtherSetting.defaultSetting.effectiveApiBaseUrl, BASE_API_URL);
    expect(OtherSetting.defaultSetting.copyWith(apiBaseUrl: '  ').effectiveApiBaseUrl, BASE_API_URL);
  });

  test('effectiveApiBaseUrl normalizes user input', () {
    OtherSetting setting(String url) => OtherSetting.defaultSetting.copyWith(apiBaseUrl: url);

    expect(setting('https://example.com').effectiveApiBaseUrl, 'https://example.com/v1/');
    expect(setting('https://example.com/').effectiveApiBaseUrl, 'https://example.com/v1/');
    expect(setting('https://example.com/v1').effectiveApiBaseUrl, 'https://example.com/v1/');
    expect(setting('https://example.com/v1/').effectiveApiBaseUrl, 'https://example.com/v1/');
    expect(setting('https://example.com/api/v1/').effectiveApiBaseUrl, 'https://example.com/api/v1/');
    expect(setting('http://10.0.0.2:10018/v1').effectiveApiBaseUrl, 'http://10.0.0.2:10018/v1/');
  });
}
