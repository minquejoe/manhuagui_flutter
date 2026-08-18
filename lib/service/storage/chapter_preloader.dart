import 'dart:async';

import 'package:manhuagui_flutter/service/storage/image_cache_manager.dart';

/// Background-prefetches a whole chapter's images into [AppImageCacheManager]
/// (the hardened disk cache), so pages are already on disk when the network
/// drops (subway tunnels, weak signal, ...).
///
/// Downloads go through the hardened client (long keep-alive, retry,
/// timeouts), so prefetching does not trip the image CDN's per-connection
/// throttle the way the gallery's per-page handshakes did.
class ChapterImagePreloader {
  ChapterImagePreloader({this.concurrency = 2});

  final int concurrency;
  final _cache = AppImageCacheManager();

  final _queue = <String>[];
  var _active = 0;
  var _stopped = false;

  bool get isIdle => _queue.isEmpty && _active == 0;

  /// Enqueues [urls] for prefetching. Pages that are already cached complete
  /// instantly (flutter_cache_manager serves them from disk without network).
  /// Safe to call again while the previous run is still going.
  void enqueue(List<String> urls, {Map<String, String>? headers}) {
    _stopped = false;
    for (final url in urls) {
      if (url.isNotEmpty && !_queue.contains(url)) {
        _queue.add(url);
      }
    }
    _pump(headers);
  }

  /// Pauses enqueueing new downloads (e.g. when the app goes to background);
  /// in-flight ones finish (they still cache). Call [resume] to continue.
  void pause() {
    _stopped = true;
  }

  void resume() {
    if (_stopped) {
      _stopped = false;
      _pump(null);
    }
  }

  /// Stops enqueueing new downloads; in-flight ones finish (they still cache).
  void stop() {
    _stopped = true;
  }

  void _pump(Map<String, String>? headers) {
    while (!_stopped && _active < concurrency && _queue.isNotEmpty) {
      final url = _queue.removeAt(0);
      _active++;
      _prefetch(url, headers).whenComplete(() {
        _active--;
        if (!_stopped && _queue.isNotEmpty) {
          _pump(headers);
        }
      });
    }
  }

  Future<void> _prefetch(String url, Map<String, String>? headers) async {
    try {
      // Returns instantly for valid cached files; otherwise downloads through
      // the hardened FileService. Consuming the whole stream ensures the file
      // is in the cache when it completes.
      await for (final _ in _cache.getFileStream(url, headers: headers, withProgress: false)) {}
    } catch (_) {
      // Ignore prefetch errors: if the user actually reaches that page, the
      // gallery's own loading + auto-retry will handle it.
    }
  }
}
