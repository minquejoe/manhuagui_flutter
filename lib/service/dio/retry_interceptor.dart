import 'dart:io';
import 'dart:math' as math;

import 'package:dio/dio.dart';

/// Automatically retries requests that failed due to transient connection
/// errors (e.g. `HandshakeException: Connection terminated during handshake`,
/// connection reset/refused), which occur sporadically on unstable networks.
///
/// Only idempotent requests (GET/HEAD) are retried, and requests that already
/// got an HTTP response are never retried.
class RetryInterceptor extends Interceptor {
  RetryInterceptor(
    this.dio, {
    this.maxRetries = 2,
    this.retryInterval = const Duration(milliseconds: 500),
    this.retryBackoffFactor = 2.0,
    this.retryMaxInterval = const Duration(seconds: 3),
  });

  final Dio dio;

  /// Maximum number of retries after the first failed attempt.
  final int maxRetries;

  /// Delay before the first retry, multiplied by [retryBackoffFactor] per retry.
  final Duration retryInterval;

  final double retryBackoffFactor;

  /// Upper bound of the retry delay.
  final Duration retryMaxInterval;

  // Uses identity comparison (RequestOptions does not override ==).
  final Map<RequestOptions, int> _retryCounts = {};

  @override
  void onError(DioError err, ErrorInterceptorHandler handler) {
    if (!_shouldRetry(err)) {
      handler.next(err);
      return;
    }
    var options = err.requestOptions;
    var count = (_retryCounts[options] ?? 0) + 1;
    if (count > maxRetries) {
      _retryCounts.remove(options);
      handler.next(err);
      return;
    }
    _retryCounts[options] = count;
    var interval = Duration(
      milliseconds: math.min(
        (retryInterval.inMilliseconds * math.pow(retryBackoffFactor, count - 1)).toInt(),
        retryMaxInterval.inMilliseconds,
      ),
    );
    Future.delayed(interval, () {
      dio.fetch(options).then((response) {
        _retryCounts.remove(options);
        handler.resolve(response);
      }).catchError((Object e) {
        _retryCounts.remove(options);
        handler.next(e is DioError ? e : err);
      });
    });
  }

  bool _shouldRetry(DioError err) {
    if (err.response != null) {
      return false; // got an HTTP response, not a connection failure
    }
    if (err.type == DioErrorType.cancel) {
      return false;
    }
    var method = err.requestOptions.method.toUpperCase();
    if (method != 'GET' && method != 'HEAD') {
      return false; // never retry non-idempotent requests
    }
    if (err.type == DioErrorType.connectTimeout) {
      return true;
    }
    if (err.type != DioErrorType.other) {
      return false;
    }
    return _isConnectionError(err.error);
  }

  bool _isConnectionError(dynamic e) {
    if (e is SocketException || e is TlsException /* includes HandshakeException */ || e is HttpException) {
      return true;
    }
    if (e.runtimeType.toString() == 'ClientException' || e.runtimeType.toString() == '_ClientSocketException') {
      return true;
    }
    var msg = e.toString().toLowerCase();
    return msg.contains('connection terminated') ||
        msg.contains('connection reset') ||
        msg.contains('connection refused') ||
        msg.contains('connection abort') ||
        msg.contains('connection failed') ||
        msg.contains('connection closed');
  }
}
