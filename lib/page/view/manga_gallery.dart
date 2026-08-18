import 'dart:async';
import 'dart:io' show File;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_ahlib/flutter_ahlib.dart';
import 'package:manhuagui_flutter/app_setting.dart';
import 'package:manhuagui_flutter/config.dart';
import 'package:manhuagui_flutter/page/view/extended_gallery.dart';
import 'package:manhuagui_flutter/page/view/image_load.dart';
import 'package:manhuagui_flutter/service/dio/retry_interceptor.dart';
import 'package:manhuagui_flutter/service/storage/image_cache_manager.dart';
import 'package:photo_view/photo_view.dart';

/// 使用 [HorizontalGalleryView] 和 [VerticalGalleryView] 构建的漫画画廊，在 [MangaViewerPage] 使用
/// (实现部分页面交互逻辑，业务逻辑不在此处实现)
class MangaGalleryView extends StatefulWidget {
  const MangaGalleryView({
    Key? key,
    required this.imageCount,
    required this.imageUrlFutures,
    required this.imageFileFutures,
    required this.networkTimeout,
    required this.preloadPagesCount,
    required this.verticalScroll,
    required this.horizontalReverseScroll,
    required this.horizontalViewportFraction,
    required this.verticalViewportPageSpace,
    required this.slideWidthRatio,
    required this.slideHeightRatio,
    required this.onPageChanged, // exclude extra pages, start from 0
    this.initialImageIndex = 0, // exclude extra pages, start from 0
    required this.fileAndUrlNotFoundMessage,
    required this.onLongPressed, // exclude extra pages, start from 0
    required this.onCenterAreaTapped, // exclude extra pages, start from 0
    required this.firstPageBuilder,
    required this.lastPageBuilder,
  }) : super(key: key);

  final int imageCount;
  final List<Future<String?>> imageUrlFutures;
  final List<Future<File?>> imageFileFutures;
  final Duration? networkTimeout;
  final int preloadPagesCount;
  final bool verticalScroll;
  final bool horizontalReverseScroll;
  final double horizontalViewportFraction;
  final double verticalViewportPageSpace;
  final double slideWidthRatio;
  final double slideHeightRatio;
  final void Function(int imageIndex, bool inFirstExtraPage, bool inLastExtraPage) onPageChanged;
  final int initialImageIndex;
  final String fileAndUrlNotFoundMessage;
  final void Function(int imageIndex) onLongPressed;
  final void Function(int imageIndex) onCenterAreaTapped;
  final Widget Function(BuildContext) firstPageBuilder;
  final Widget Function(BuildContext) lastPageBuilder;

  @override
  State<MangaGalleryView> createState() => MangaGalleryViewState();
}

class MangaGalleryViewState extends State<MangaGalleryView> with WidgetsBindingObserver {
  final _cache = AppImageCacheManager();
  final _horizontalGalleryKey = GlobalKey<HorizontalGalleryViewState>();
  final _verticalGalleryKey = GlobalKey<VerticalGalleryViewState>();

  // auto retry failed pages (transient network errors only), with backoff
  static const _kMaxAutoRetryCount = 3;
  final _autoRetryCounts = <int, int>{};
  final _autoRetryTimers = <int, Timer>{};
  final _failedPages = <int>{}; // pages currently waiting for auto retry
  StreamSubscription<ConnectivityResult>? _connectivitySubscription;
  Timer? _connectivityPollTimer;
  var _connectivityWatcherStarted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance?.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _reloadFailedPages(); // 解锁 / 回到前台时自动重载失败页
    }
  }

  // current page index, include extra pages, start from 0.
  late var _currentPageIndex = widget.initialImageIndex + 1;

  // current image index, exclude extra pages, start from 0.
  int get _currentImageIndex => (_currentPageIndex - 1).clamp(0, widget.imageCount - 1);

  Offset? _pointerDownPosition;

  void _onPointerDown(Offset pos) {
    _pointerDownPosition = pos;
  }

  void _onPointerUp(Offset pos) {
    if (_pointerDownPosition != null && _pointerDownPosition == pos) {
      if (!widget.verticalScroll) {
        var width = MediaQuery.of(context).size.width;
        if (pos.dx < width * widget.slideWidthRatio) {
          jumpToPage(!widget.horizontalReverseScroll ? _currentPageIndex - 1 : _currentPageIndex + 1); // 上一页 / 下一页(反)
        } else if (pos.dx > width * (1 - widget.slideWidthRatio)) {
          jumpToPage(!widget.horizontalReverseScroll ? _currentPageIndex + 1 : _currentPageIndex - 1); // 下一页 / 上一页(反)
        } else {
          widget.onCenterAreaTapped.call(_currentImageIndex);
        }
      } else {
        var height = MediaQuery.of(context).size.height;
        if (pos.dy < height * widget.slideHeightRatio) {
          jumpToPage(_currentPageIndex - 1); // 上一页
        } else if (pos.dy > height * (1 - widget.slideHeightRatio)) {
          jumpToPage(_currentPageIndex + 1); // 下一页
        } else {
          widget.onCenterAreaTapped.call(_currentImageIndex);
        }
      }
    }
    _pointerDownPosition = null;
  }

  /// jumpToPage, include extra pages, start from 0
  void jumpToPage(int pageIndex, {bool animated = false}) {
    if (pageIndex >= 0 && pageIndex <= widget.imageCount + 1) {
      if (!widget.verticalScroll) {
        _horizontalGalleryKey.currentState?.jumpToPage(pageIndex, animated: animated);
      } else {
        _verticalGalleryKey.currentState?.jumpToPage(pageIndex, masked: !animated);
      }
    }
  }

  /// jumpToImage, exclude extra pages, start from 0.
  void jumpToImage(int imageIndex, {bool animated = false}) {
    if (imageIndex >= 0 && imageIndex < widget.imageCount) {
      var pageIndex = imageIndex + 1; // include extra pages, start from 0
      if (!widget.verticalScroll) {
        _horizontalGalleryKey.currentState?.jumpToPage(pageIndex, animated: animated);
      } else {
        _verticalGalleryKey.currentState?.jumpToPage(pageIndex, masked: !animated);
      }
    }
  }

  /// reloadImage, exclude extra pages, start from 0.
  void reloadImage(int imageIndex) async {
    if (imageIndex >= 0 && imageIndex < widget.imageCount) {
      await (await widget.imageUrlFutures[imageIndex])?.let((url) async {
        await _cache.removeFile(url);
      });
      if (!widget.verticalScroll) {
        _horizontalGalleryKey.currentState?.reload(imageIndex, alsoEvict: true);
      } else {
        _verticalGalleryKey.currentState?.reload(imageIndex, alsoEvict: true);
      }
    }
  }

  /// Auto-retries a failed image after a backoff delay, so a CDN throttle
  /// window or a signal loss (subway tunnels) is usually ridden out without
  /// user interaction. Only transient connection failures and timeouts are
  /// retried; other errors keep the manual long-press -> reload behavior.
  void _scheduleAutoRetry(int imageIndex, Object? err) {
    if (err == null) {
      _autoRetryCounts.remove(imageIndex);
      _failedPages.remove(imageIndex);
      return;
    }
    if (!(isConnectionError(err) || err is TimeoutException)) {
      return; // not a transient network failure, no auto retry
    }
    var count = (_autoRetryCounts[imageIndex] ?? 0) + 1;
    if (count > _kMaxAutoRetryCount) {
      _autoRetryCounts.remove(imageIndex);
      _failedPages.remove(imageIndex);
      return;
    }
    _autoRetryCounts[imageIndex] = count;
    _failedPages.add(imageIndex);
    _startConnectivityWatcher();
    _autoRetryTimers[imageIndex]?.cancel();
    // Backoff: 5s, 15s, 30s. Longer spacing than before so that longer
    // outages (e.g. a whole subway tunnel) can be ridden out as well.
    _autoRetryTimers[imageIndex] = Timer(Duration(seconds: 5 * count * (count + 1) ~/ 2), () {
      if (mounted) {
        reloadImage(imageIndex);
      }
    });
  }

  /// Watches for the network coming back (subway tunnels, airplane mode) so
  /// that failed pages reload immediately instead of waiting for the backoff
  /// timers to finish. Falls back to polling [Connectivity.checkConnectivity]
  /// every 10s because some platforms do not emit change events on regain.
  void _startConnectivityWatcher() {
    if (!_connectivityWatcherStarted) {
      _connectivityWatcherStarted = true;
      try {
        _connectivitySubscription = Connectivity().onConnectivityChanged.listen((result) {
          if (result != ConnectivityResult.none) {
            _reloadFailedPages();
          }
        }, onError: (Object _) {});
      } catch (_) {
        // plugin unavailable (e.g. in unit tests)
      }
    }
    _connectivityPollTimer?.cancel();
    _connectivityPollTimer = Timer.periodic(const Duration(seconds: 10), (_) async {
      if (_failedPages.isEmpty) {
        _connectivityPollTimer?.cancel();
        _connectivityPollTimer = null;
        return;
      }
      try {
        var result = await Connectivity().checkConnectivity();
        if (result != ConnectivityResult.none) {
          _reloadFailedPages();
        }
      } catch (_) {
        // ignore
      }
    });
  }

  void _reloadFailedPages() {
    if (_failedPages.isEmpty) {
      return;
    }
    final pages = _failedPages.toList();
    _failedPages.clear();
    for (final imageIndex in pages) {
      _autoRetryTimers[imageIndex]?.cancel();
      if (mounted) {
        reloadImage(imageIndex);
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance?.removeObserver(this);
    _connectivitySubscription?.cancel();
    _connectivityPollTimer?.cancel();
    _autoRetryTimers.values.forEach((timer) => timer.cancel());
    super.dispose();
  }

  // for ImageErrorView
  String? _imageErrorFormatter(dynamic error) {
    // Image file "/storage/emulated/0/Manhuagui/manhuagui_download/39793/620266/0005.webp" is not found while given url is null.
    if (error is LoadImageException && error.type == LoadImageExceptionType.notExistedFileNullUrl) {
      return widget.fileAndUrlNotFoundMessage; // 该页尚未下载，且未获取到该页的链接
    }
    return null;
  }

  Widget _buildPageWithPageNumber(BuildContext context, Widget photoView, int imageIndex) {
    var pos = AppSetting.instance.view.pageNoPosition; // only for VerticalGalleryView
    double? left, right, top, bottom;
    switch (pos) {
      case PageNoPosition.hide:
        return photoView;
      case PageNoPosition.topLeft:
        left = 0.0;
        top = 0.0;
        break;
      case PageNoPosition.topCenter:
        left = 0.0;
        right = 0.0;
        top = 0.0;
        break;
      case PageNoPosition.topRight:
        right = 0.0;
        top = 0.0;
        break;
      case PageNoPosition.bottomLeft:
        left = 0.0;
        bottom = 0.0;
        break;
      case PageNoPosition.bottomCenter:
        left = 0.0;
        right = 0.0;
        bottom = 0.0;
        break;
      case PageNoPosition.bottomRight:
        right = 0.0;
        bottom = 0.0;
        break;
    }
    return Stack(
      children: [
        Center(child: photoView),
        Positioned(
          left: left,
          right: right,
          top: top,
          bottom: bottom,
          child: Center(
            child: Container(
              color: Colors.black.withOpacity(0.5),
              padding: EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              child: Text(
                '${imageIndex + 1}',
                style: TextStyle(color: Colors.white),
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.verticalScroll) {
      return HorizontalGalleryView(
        key: _horizontalGalleryKey,
        imageCount: widget.imageCount,
        preloadPagesCount: widget.preloadPagesCount,
        initialPage: widget.initialImageIndex + 1 /* include extra pages, start from 0 */,
        viewportFraction: widget.horizontalViewportFraction,
        reverse: widget.horizontalReverseScroll,
        onPageChanged: (pageIndex) {
          _currentPageIndex = pageIndex; // include extra pages, start from 0
          widget.onPageChanged.call(
            _currentImageIndex, // exclude extra pages, start from 0
            pageIndex == 0,
            pageIndex == widget.imageCount + 1,
          );
        },
        // ****************************************************************
        // 漫画页
        // ****************************************************************
        imagePageBuilder: (c, imageIndex) => ExtendedPhotoGalleryPageOptions(
          initialScale: PhotoViewComputedScale.contained,
          minScale: PhotoViewComputedScale.contained / 2,
          maxScale: 1.5,
          backgroundDecoration: BoxDecoration(color: Colors.black),
          filterQuality: FilterQuality.high,
          onTapDown: (c, d, v) => _onPointerDown(d.globalPosition),
          onTapUp: (c, d, v) => _onPointerUp(d.globalPosition),
          imageProviderBuilder: (key) => LocalOrCachedNetworkImageProvider.fromFutures(
            key: key,
            urlFuture: widget.imageUrlFutures[imageIndex],
            headers: {'User-Agent': USER_AGENT, 'Referer': REFERER},
            cacheManager: _cache,
            networkTimeout: widget.networkTimeout,
            fileFuture: widget.imageFileFutures[imageIndex],
            fileMustExist: false, // <<<
            onUrlLoaded: (err) => _scheduleAutoRetry(imageIndex, err),
          ),
          loadingBuilder: (_, ev) => GestureDetector(
            onTapDown: (d) => _onPointerDown(d.globalPosition),
            onTapUp: (d) => _onPointerUp(d.globalPosition),
            onLongPress: () => widget.onLongPressed.call(imageIndex),
            child: ImageLoadingView(
              title: (imageIndex + 1).toString(),
              event: ev,
            ),
          ),
          errorBuilder: (_, err, __) => GestureDetector(
            onTapDown: (d) => _onPointerDown(d.globalPosition),
            onTapUp: (d) => _onPointerUp(d.globalPosition),
            onLongPress: () => widget.onLongPressed.call(imageIndex),
            child: ImageLoadFailedView(
              title: (imageIndex + 1).toString(),
              error: err,
              errorFormatter: _imageErrorFormatter,
            ),
          ),
        ),
        onImageLongPressed: (imageIndex) => widget.onLongPressed.call(imageIndex),
        // ****************************************************************
        // 额外页
        // ****************************************************************
        firstPageBuilder: (c) => Container(
          color: Theme.of(context).scaffoldBackgroundColor,
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height - MediaQuery.of(context).padding.vertical,
            maxWidth: MediaQuery.of(context).size.width - MediaQuery.of(context).padding.horizontal,
          ),
          child: widget.firstPageBuilder.call(c), // 额外页-开头
        ),
        lastPageBuilder: (c) => Container(
          color: Theme.of(context).scaffoldBackgroundColor,
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height - MediaQuery.of(context).padding.vertical,
            maxWidth: MediaQuery.of(context).size.width - MediaQuery.of(context).padding.horizontal,
          ),
          child: widget.lastPageBuilder.call(c), // 额外页-末尾
        ),
      );
    }

    return VerticalGalleryView(
      key: _verticalGalleryKey,
      imageCount: widget.imageCount,
      preloadPagesCount: widget.preloadPagesCount,
      initialPage: widget.initialImageIndex + 1 /* include extra pages, start from 0 */,
      viewportPageSpace: widget.verticalViewportPageSpace,
      onPageChanged: (pageIndex) {
        _currentPageIndex = pageIndex; // include extra pages, start from 0
        widget.onPageChanged.call(
          _currentImageIndex, // exclude extra pages, start from 0
          pageIndex == 0,
          pageIndex == widget.imageCount + 1,
        );
      },
      // ****************************************************************
      // 漫画页
      // ****************************************************************
      imagePageBuilder: (c, imageIndex) => ExtendedPhotoGalleryPageOptions(
        initialScale: PhotoViewComputedScale.contained,
        minScale: PhotoViewComputedScale.contained / 2,
        maxScale: 1.5,
        backgroundDecoration: BoxDecoration(color: Colors.black),
        filterQuality: FilterQuality.high,
        onTapDown: null /* >>> */,
        onTapUp: null /* >>> */,
        imageProviderBuilder: (key) => LocalOrCachedNetworkImageProvider.fromFutures(
          key: key,
          urlFuture: widget.imageUrlFutures[imageIndex],
          headers: {'User-Agent': USER_AGENT, 'Referer': REFERER},
          cacheManager: _cache,
          networkTimeout: widget.networkTimeout,
          fileFuture: widget.imageFileFutures[imageIndex],
          fileMustExist: false,
          onUrlLoaded: (err) => _scheduleAutoRetry(imageIndex, err),
        ),
        loadingBuilder: (_, ev) => GestureDetector(
          onTapDown: (d) => _onPointerDown(d.globalPosition),
          onTapUp: (d) => _onPointerUp(d.globalPosition),
          onLongPress: () => widget.onLongPressed.call(imageIndex),
          child: ImageLoadingView(
            title: (imageIndex + 1).toString(),
            event: ev,
          ),
        ),
        errorBuilder: (_, err, ___) => GestureDetector(
          onTapDown: (d) => _onPointerDown(d.globalPosition),
          onTapUp: (d) => _onPointerUp(d.globalPosition),
          onLongPress: () => widget.onLongPressed.call(imageIndex),
          child: ImageLoadFailedView(
            title: (imageIndex + 1).toString(),
            error: err,
            errorFormatter: _imageErrorFormatter,
          ),
        ),
      ),
      onImageTapDown: (d) => _onPointerDown(d.globalPosition) /* <<< */,
      onImageTapUp: (d) => _onPointerUp(d.globalPosition) /* <<< */,
      onImageLongPressed: (imageIndex) => widget.onLongPressed.call(imageIndex),
      customPageBuilder: _buildPageWithPageNumber,
      // ****************************************************************
      // 额外页
      // ****************************************************************
      firstPageBuilder: (c) => Container(
        color: Theme.of(context).scaffoldBackgroundColor,
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width - MediaQuery.of(context).padding.horizontal,
        ),
        child: widget.firstPageBuilder.call(c), // 额外页-开头
      ),
      lastPageBuilder: (c) => Container(
        color: Theme.of(context).scaffoldBackgroundColor,
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width - MediaQuery.of(context).padding.horizontal,
        ),
        child: widget.lastPageBuilder.call(c), // 额外页-末尾
      ),
    );
  }
}
