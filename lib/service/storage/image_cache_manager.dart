import 'dart:async';
import 'dart:io';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:manhuagui_flutter/config.dart';
import 'package:manhuagui_flutter/service/dio/retry_interceptor.dart';
import 'package:manhuagui_flutter/service/image_url.dart';

/// The shared [CacheManager] used by every network image in the app
/// (reader pages, covers, image viewer, saving images, ...).
///
/// Why not [DefaultCacheManager]?
///
/// Its built-in [HttpFileService] wraps a bare `package:http` client that:
///
/// 1. has **no connect timeout** — when the image CDN (i.hamreus.com)
///    throttles a session it sometimes *tarpits* connections (accepts the
///    TCP/TLS connection and then never answers). A stuck request never
///    finishes, and since flutter_cache_manager only releases a download
///    queue slot when a request completes, a few stuck requests permanently
///    deadlock the whole cache manager: every later page keeps spinning or
///    fails (the typical symptom is "network terminated" after roughly
///    16-17 pages);
///
/// 2. closes idle connections after 15s — so almost every page turn after a
///    short pause requires a brand-new TLS handshake, and the image CDN
///    throttles/drops handshakes from one IP once a burst threshold is hit
///    (measured: bandwidth throttling kicks in after ~14-17 fresh requests);
///
/// 3. never retries transient connection errors — the Dio-level
///    [RetryInterceptor] does not apply here, because gallery images are
///    fetched through the cache manager, not through Dio.
///
/// [AppImageCacheManager] keeps the same on-disk cache key as
/// [DefaultCacheManager] (`libCachedImageData`) so already cached images are
/// reused, but downloads through [HardenedHttpFileService].
class AppImageCacheManager extends CacheManager {
  static final AppImageCacheManager _instance = AppImageCacheManager._();

  factory AppImageCacheManager() => _instance;

  AppImageCacheManager._()
      : super(Config(
          DefaultCacheManager.key,
          fileService: HardenedHttpFileService(),
        ));
}

/// A [FileService] for [AppImageCacheManager] that downloads images through a
/// hardened dart:io [HttpClient]:
///
/// - a longer keep-alive ([IMAGE_DOWNLOAD_IDLE_TIMEOUT]) so connections
///   survive the pauses between page turns and get reused instead of
///   re-negotiating a TLS handshake every time;
/// - a connect deadline ([IMAGE_DOWNLOAD_CONNECT_TIMEOUT]) and a per-attempt
///   deadline ([IMAGE_DOWNLOAD_REQUEST_TIMEOUT]) that **abort** the request,
///   so tarpit connections release their socket and their download queue slot
///   instead of deadlocking every later download;
/// - a body-read deadline ([IMAGE_DOWNLOAD_BODY_TIMEOUT]) that also releases
///   the queue slot when the server stalls mid-download;
/// - automatic retry (GET is idempotent) of transient connection failures
///   with a short backoff, mirroring [RetryInterceptor] which only covers the
///   Dio/API path.
class HardenedHttpFileService extends FileService {
  HardenedHttpFileService({
    this.maxRetries = IMAGE_DOWNLOAD_MAX_RETRIES,
    this.retryInterval = const Duration(milliseconds: IMAGE_DOWNLOAD_RETRY_INTERVAL_MS),
  }) {
    // Reduces the download burst (flutter_cache_manager's default is 10):
    // fewer simultaneous connections means the CDN's per-IP handshake /
    // connection throttle is tripped much later.
    concurrentFetches = IMAGE_DOWNLOAD_CONCURRENT_FETCHES;
  }

  final int maxRetries;
  final Duration retryInterval;

  late final HttpClient _client = _createClient();

  HttpClient _createClient() {
    var client = HttpClient();
    client.idleTimeout = IMAGE_DOWNLOAD_IDLE_TIMEOUT;
    client.connectionTimeout = IMAGE_DOWNLOAD_CONNECT_TIMEOUT;
    client.maxConnectionsPerHost = IMAGE_DOWNLOAD_MAX_CONNECTIONS_PER_HOST;
    return client;
  }

  @override
  Future<FileServiceResponse> get(String url, {Map<String, String>? headers}) async {
    var attempt = 0;
    while (true) {
      try {
        var response = await _getOnce(url, headers);
        // 代理端点返回 502（其后端到图床抓取失败）时，回退直连原始图床 URL
        if (response.statusCode == 502) {
          var original = proxyUrlToOriginal(url);
          if (original != null) {
            return await _getOnce(original, headers);
          }
        }
        return response;
      } catch (e) {
        attempt++;
        if (attempt > maxRetries || !(isConnectionError(e) || e is TimeoutException)) {
          // 代理地址请求彻底失败时，同样回退直连原始图床 URL（仅一次）
          var original = proxyUrlToOriginal(url);
          if (original != null) {
            return await _getOnce(original, headers);
          }
          rethrow;
        }
        await Future<void>.delayed(retryInterval * attempt);
      }
    }
  }

  Future<FileServiceResponse> _getOnce(String url, Map<String, String>? headers) async {
    var request = await _client.getUrl(Uri.parse(url));
    headers?.forEach((key, value) => request.headers.set(key, value));
    // Bounds connect + TLS handshake + response headers. `abort()` closes the
    // socket, so the connection pool slot is released instead of leaking.
    var response = await request.close().timeout(IMAGE_DOWNLOAD_REQUEST_TIMEOUT, onTimeout: () {
      request.abort();
      throw TimeoutException('Image request timed out: $url', IMAGE_DOWNLOAD_REQUEST_TIMEOUT);
    });
    return _HardenedFileServiceResponse(response);
  }
}

class _HardenedFileServiceResponse implements FileServiceResponse {
  _HardenedFileServiceResponse(this._response);

  final HttpClientResponse _response;

  static const _mimeTypes = <String, String>{
    'image/bmp': '.bmp',
    'image/gif': '.gif',
    'image/jpeg': '.jpg',
    'image/png': '.png',
    'image/svg+xml': '.svg',
    'image/tiff': '.tiff',
    'image/vnd.microsoft.icon': '.ico',
    'image/webp': '.webp',
  };

  /// Bounds the body read: on stall, the subscription is cancelled, which
  /// closes the connection and (through the error propagated into
  /// flutter_cache_manager's download loop) releases the queue slot.
  @override
  Stream<List<int>> get content => _response.timeout(IMAGE_DOWNLOAD_BODY_TIMEOUT);

  @override
  int? get contentLength => _response.contentLength < 0 ? null : _response.contentLength;

  @override
  int get statusCode => _response.statusCode;

  @override
  DateTime get validTill {
    // Same semantics as flutter_cache_manager's HttpGetResponse:
    // without a cache-control header the file is kept for a week.
    var ageDuration = const Duration(days: 7);
    final controlHeader = _response.headers.value(HttpHeaders.cacheControlHeader);
    if (controlHeader != null) {
      for (final setting in controlHeader.split(',')) {
        final s = setting.trim().toLowerCase();
        if (s == 'no-cache') {
          ageDuration = Duration.zero;
        } else if (s.startsWith('max-age=')) {
          var seconds = int.tryParse(s.substring('max-age='.length)) ?? 0;
          if (seconds > 0) {
            ageDuration = Duration(seconds: seconds);
          }
        }
      }
    }
    return DateTime.now().add(ageDuration);
  }

  @override
  String? get eTag => _response.headers.value(HttpHeaders.etagHeader);

  @override
  String get fileExtension {
    var contentType = _response.headers.contentType;
    return _mimeTypes[contentType?.mimeType] ?? '.${contentType?.subType ?? ''}';
  }
}
