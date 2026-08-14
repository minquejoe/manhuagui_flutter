import 'package:dio/adapter.dart';
import 'package:dio/dio.dart';
import 'package:manhuagui_flutter/app_setting.dart';
import 'package:manhuagui_flutter/config.dart';
import 'package:manhuagui_flutter/service/dio/retry_interceptor.dart';

class DioManager {
  DioManager._();

  static DioManager? _instance;

  static DioManager get instance {
    _instance ??= DioManager._();
    return _instance!;
  }

  // global Dio instances
  Dio? _dio;
  Dio? _longDio;
  Dio? _longLongDio;
  Dio? _noTimeoutDio;

  Dio get dio {
    _dio ??= _createDio(connectTimeout: CONNECT_TIMEOUT, sendTimeout: SEND_TIMEOUT, receiveTimeout: RECEIVE_TIMEOUT);
    _longDio ??= _createDio(connectTimeout: CONNECT_LTIMEOUT, sendTimeout: SEND_LTIMEOUT, receiveTimeout: RECEIVE_LTIMEOUT);
    _longLongDio ??= _createDio(connectTimeout: CONNECT_LLTIMEOUT, sendTimeout: SEND_LLTIMEOUT, receiveTimeout: RECEIVE_LLTIMEOUT);
    _noTimeoutDio ??= _createDio(connectTimeout: 0, sendTimeout: 0, receiveTimeout: 0);
    return AppSetting.instance.other.timeoutBehavior.determineValue(
      normal: _dio!,
      long: _longDio!,
      longLong: _longLongDio!,
      disable: _noTimeoutDio!,
    )!;
  }

  Dio _createDio({required int connectTimeout, required int sendTimeout, required int receiveTimeout}) {
    var dio = Dio()
      ..options.connectTimeout = connectTimeout
      ..options.sendTimeout = sendTimeout
      ..options.receiveTimeout = receiveTimeout;
    _setupHttpClient(dio);
    dio.interceptors.add(LogInterceptor());
    dio.interceptors.add(RetryInterceptor(dio));
    return dio;
  }

  /// Hardens the underlying [HttpClient] against transient connection
  /// failures: keeps idle connections alive longer (fewer TLS handshakes,
  /// which is where the "Connection terminated during handshake" errors
  /// occur), so requests mostly reuse warm connections instead of re-negotiating.
  void _setupHttpClient(Dio dio) {
    dio.httpClientAdapter = DefaultHttpClientAdapter()
      ..onHttpClientCreate = (client) {
        client.idleTimeout = const Duration(seconds: 15);
        return client;
      };
  }
}

class LogInterceptor extends Interceptor {
  @override
  Future onRequest(RequestOptions options, RequestInterceptorHandler handler) async {
    print('┌─────────────────── Request ─────────────────────┐');
    print('date: ${DateTime.now().toIso8601String()}');
    print('uri: ${options.uri}');
    print('method: ${options.method}');
    if (options.extra.isNotEmpty) {
      print('extra: ${options.extra}');
    }
    print('headers:');
    options.headers.forEach((key, v) => print('    $key: $v'));
    print('└─────────────────── Request ─────────────────────┘');
    return super.onRequest(options, handler);
  }

  @override
  Future onError(DioError err, ErrorInterceptorHandler handler) async {
    print('┌─────────────────── DioError ────────────────────┐');
    print('date: ${DateTime.now().toIso8601String()}');
    print('uri: ${err.requestOptions.uri}');
    print('method: ${err.requestOptions.method}');
    print('error: $err');
    if (err.response != null) {
      _printResponse(err.response!);
    }
    print('└─────────────────── DioError ────────────────────┘');
    return super.onError(err, handler);
  }

  @override
  Future onResponse(Response response, ResponseInterceptorHandler handler) async {
    print('┌─────────────────── Response ────────────────────┐');
    print('date: ${DateTime.now().toIso8601String()}');
    _printResponse(response);
    print('└─────────────────── Response ────────────────────┘');
    return super.onResponse(response, handler);
  }

  void _printResponse(Response response) {
    print('uri: ${response.requestOptions.uri}');
    print('method: ${response.requestOptions.method}');
    print('statusCode: ${response.statusCode}');
    if (!response.headers.isEmpty) {
      print('headers:');
      response.headers.forEach((key, v) => print('    $key: ${v.join(',')}'));
    }
  }
}
