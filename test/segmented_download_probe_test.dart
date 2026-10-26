import 'dart:io';

import 'package:download_beast/segmented_download_probe.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late HttpServer server;
  late HttpClient client;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    client = HttpClient();

    server.listen((request) async {
      final response = request.response;
      switch (request.uri.path) {
        case '/valid':
          response.statusCode = HttpStatus.partialContent;
          response.headers.set(HttpHeaders.contentRangeHeader, 'bytes 0-0/4');
          response.headers.set(HttpHeaders.etagHeader, '"stable-v1"');
          response.add([0x41]);
          break;
        case '/ignored':
          response.statusCode = HttpStatus.ok;
          response.headers.set(HttpHeaders.etagHeader, '"stable-v1"');
          response.write('server ignored range');
          break;
        case '/malformed':
          response.statusCode = HttpStatus.partialContent;
          response.headers.set(HttpHeaders.contentRangeHeader, 'bytes 0-1/4');
          response.headers.set(HttpHeaders.etagHeader, '"stable-v1"');
          response.add([0x41]);
          break;
        case '/weak-etag':
          response.statusCode = HttpStatus.partialContent;
          response.headers.set(HttpHeaders.contentRangeHeader, 'bytes 0-0/4');
          response.headers.set(HttpHeaders.etagHeader, 'W/"weak-v1"');
          response.add([0x41]);
          break;
        case '/long-body':
          response.statusCode = HttpStatus.partialContent;
          response.headers.set(HttpHeaders.contentRangeHeader, 'bytes 0-0/4');
          response.headers.set(HttpHeaders.etagHeader, '"stable-v1"');
          response.add([0x41, 0x42]);
          break;
        default:
          response.statusCode = HttpStatus.notFound;
      }
      await response.close();
    });
  });

  tearDown(() async {
    client.close(force: true);
    await server.close(force: true);
  });

  Uri url(String path) => Uri.parse(
        'http://' +
            InternetAddress.loopbackIPv4.address +
            ':' +
            server.port.toString() +
            path,
      );

  test('accepts an exact one-byte 206 response with a strong ETag', () async {
    final result = await probeRangeSupport(client, url('/valid'));

    expect(result.supported, isTrue);
    expect(result.totalBytes, 4);
    expect(result.entityTag, '"stable-v1"');
  });

  test('rejects a server that ignores Range and returns HTTP 200', () async {
    final result = await probeRangeSupport(client, url('/ignored'));

    expect(result.supported, isFalse);
    expect(result.totalBytes, isNull);
  });

  test('rejects incorrect Content-Range boundaries', () async {
    final result = await probeRangeSupport(client, url('/malformed'));

    expect(result.supported, isFalse);
  });

  test('rejects weak ETags', () async {
    final result = await probeRangeSupport(client, url('/weak-etag'));

    expect(result.supported, isFalse);
  });

  test('rejects a response body longer than one byte', () async {
    final result = await probeRangeSupport(client, url('/long-body'));

    expect(result.supported, isFalse);
  });
}
