import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:manhuagui_flutter/service/dio/retry_interceptor.dart';

class FakeHttpClientAdapter implements HttpClientAdapter {
  FakeHttpClientAdapter(this.failures, {this.onFail});

  final int failures;
  final DioError Function(RequestOptions options)? onFail;
  int calls = 0;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future? cancelFuture) async {
    calls++;
    if (calls <= failures) {
      throw onFail?.call(options) ??
          DioError(
            requestOptions: options,
            error: const SocketException('Connection terminated during handshake'),
            type: DioErrorType.other,
          );
    }
    return ResponseBody.fromString('ok', 200, headers: {Headers.contentTypeHeader: ['text/plain']});
  }

  @override
  void close({bool force = false}) {}
}

Dio _createDio(FakeHttpClientAdapter adapter, {int maxRetries = 2}) {
  final dio = Dio();
  dio.httpClientAdapter = adapter;
  dio.interceptors.add(RetryInterceptor(dio, maxRetries: maxRetries, retryInterval: Duration.zero));
  return dio;
}

void main() {
  test('retries GET requests that fail with connection errors', () async {
    final dio = _createDio(FakeHttpClientAdapter(2));

    final response = await dio.get<String>('https://example.com/v1/manga');

    expect(response.statusCode, 200);
    expect(response.data, 'ok');
    expect((dio.httpClientAdapter as FakeHttpClientAdapter).calls, 3);
  });

  test('gives up after exhausting max retries', () async {
    final adapter = FakeHttpClientAdapter(99);
    final dio = _createDio(adapter, maxRetries: 2);

    await expectLater(dio.get<String>('https://example.com/v1/manga'), throwsA(isA<DioError>()));
    expect(adapter.calls, 3);
  });

  test('does not retry non-idempotent requests', () async {
    final adapter = FakeHttpClientAdapter(99);
    final dio = _createDio(adapter);

    await expectLater(dio.post<dynamic>('https://example.com/v1/user/login'), throwsA(isA<DioError>()));
    expect(adapter.calls, 1);
  });

  test('does not retry when an HTTP response was received', () async {
    final adapter = FakeHttpClientAdapter(
      99,
      onFail: (options) => DioError(
        requestOptions: options,
        response: Response(requestOptions: options, statusCode: 502, statusMessage: 'Bad Gateway'),
        type: DioErrorType.response,
      ),
    );
    final dio = _createDio(adapter);

    await expectLater(dio.get<String>('https://example.com/v1/manga'), throwsA(isA<DioError>()));
    expect(adapter.calls, 1);
  });

  test('does not retry on receive timeout', () async {
    final adapter = FakeHttpClientAdapter(
      99,
      onFail: (options) => DioError(
        requestOptions: options,
        error: 'Receiving data timeout[10000ms]',
        type: DioErrorType.receiveTimeout,
      ),
    );
    final dio = _createDio(adapter);

    await expectLater(dio.get<String>('https://example.com/v1/manga'), throwsA(isA<DioError>()));
    expect(adapter.calls, 1);
  });

  test('does not retry cancelled requests', () async {
    final adapter = FakeHttpClientAdapter(
      99,
      onFail: (options) => DioError(
        requestOptions: options,
        error: 'cancelled',
        type: DioErrorType.cancel,
      ),
    );
    final dio = _createDio(adapter);

    await expectLater(dio.get<String>('https://example.com/v1/manga'), throwsA(isA<DioError>()));
    expect(adapter.calls, 1);
  });

  test('isConnectionError classifies transient connection errors', () {
    expect(isConnectionError(const SocketException('Connection terminated during handshake')), isTrue);
    expect(isConnectionError(const SocketException('Connection reset by peer')), isTrue);
    expect(isConnectionError(const SocketException('Connection refused')), isTrue);
    expect(isConnectionError(const SocketException('Software caused connection abort')), isTrue);
    expect(isConnectionError(const SocketException('Write failed (OS Error: Broken pipe)')), isTrue);
    expect(isConnectionError(const HandshakeException('Connection terminated during handshake')), isTrue);
    expect(isConnectionError(const HttpException('Connection closed before full header was received')), isTrue);
    expect(isConnectionError(const HttpException('Connection closed while received data')), isTrue);
    expect(isConnectionError(TimeoutException('after 10s')), isFalse);
    expect(isConnectionError(FormatException('bad json')), isFalse);
    expect(isConnectionError('Connection terminated during handshake'), isTrue); // wrapped text
    expect(isConnectionError('Normal string'), isFalse);
  });
}
