import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:manhuagui_flutter/service/storage/image_cache_manager.dart';

/// Reads the HTTP request headers from [socket] and returns when the header
/// terminator (`\r\n\r\n`) has been received.
Future<void> _drainRequestHeaders(Socket socket) async {
  final data = <int>[];
  await for (final chunk in socket) {
    data.addAll(chunk);
    if (String.fromCharCodes(data).contains('\r\n\r\n')) {
      return;
    }
  }
}

void main() {
  test('HardenedHttpFileService retries transient connection errors', () async {
    var requests = 0;
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((socket) async {
      requests++;
      await _drainRequestHeaders(socket);
      if (requests == 1) {
        // Simulate a connection that dies before responding (like the CDN
        // tarpit / "Connection terminated" case): the client should retry.
        socket.destroy();
      } else {
        final body = utf8.encode('fake-image-bytes');
        socket.write('HTTP/1.1 200 OK\r\n'
            'Content-Type: image/webp\r\n'
            'Content-Length: ${body.length}\r\n'
            'Cache-Control: max-age=3600\r\n'
            'Connection: close\r\n'
            '\r\n');
        socket.add(body);
        await socket.flush();
        socket.close();
      }
    }, onError: (_) {});

    try {
      final service = HardenedHttpFileService(maxRetries: 2, retryInterval: Duration.zero);
      final response = await service.get(
        'http://${server.address.host}:${server.port}/page.webp',
        headers: {'User-Agent': 'test'},
      );

      expect(response.statusCode, 200);
      expect(response.fileExtension, '.webp');
      expect(response.eTag, isNull);
      expect(response.contentLength, 'fake-image-bytes'.length);
      expect(response.validTill.isAfter(DateTime.now().add(const Duration(minutes: 59))), isTrue); // max-age=3600
      var bytes = 0;
      await for (final chunk in response.content) {
        bytes += chunk.length;
      }
      expect(bytes, 'fake-image-bytes'.length);
      expect(requests, 2);
    } finally {
      await subscription.cancel();
      await server.close();
    }
  });

  test('HardenedHttpFileService gives up after exhausting max retries', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((socket) async {
      await _drainRequestHeaders(socket);
      socket.destroy();
    }, onError: (_) {});

    try {
      final service = HardenedHttpFileService(maxRetries: 1, retryInterval: Duration.zero);
      await expectLater(
        service.get('http://${server.address.host}:${server.port}/page.webp'),
        throwsA(anyOf(isA<SocketException>(), isA<HttpException>(), isA<HandshakeException>())),
      );
    } finally {
      await subscription.cancel();
      await server.close();
    }
  });
}
