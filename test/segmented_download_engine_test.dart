import 'dart:io';

import 'package:download_beast/segmented_download_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late HttpServer server;
  late Directory tempDirectory;
  final payload = List<int>.generate(37, (index) => (index * 17) % 256);
  var malformedRange = false;
  var changedTag = false;
  var ignoreRange = false;
  var truncateFirstSegment = false;
  var activeRequests = 0;
  var maxActiveRequests = 0;

  setUp(() async {
    malformedRange = false;
    changedTag = false;
    ignoreRange = false;
    truncateFirstSegment = false;
    activeRequests = 0;
    maxActiveRequests = 0;
    tempDirectory = await Directory.systemTemp.createTemp('download_beast_segments_');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      activeRequests++;
      if (activeRequests > maxActiveRequests) maxActiveRequests = activeRequests;
      try {
        final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
        final match = rangeHeader == null
            ? null
            : RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(rangeHeader);
        if (match == null) {
          request.response.statusCode = HttpStatus.badRequest;
          await request.response.close();
          return;
        }
        final start = int.parse(match.group(1)!);
        final end = int.parse(match.group(2)!);
        if (ignoreRange) {
          request.response.statusCode = HttpStatus.ok;
          request.response.headers.set(HttpHeaders.etagHeader, '"stable-v1"');
          request.response.contentLength = payload.length;
          request.response.add(payload);
          await request.response.close();
          return;
        }
        final etag = changedTag ? '"changed-v2"' : '"stable-v1"';
        request.response.headers.set(HttpHeaders.etagHeader, etag);
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          malformedRange
              ? 'bytes ${start + 1}-$end/${payload.length}'
              : 'bytes $start-$end/${payload.length}',
        );
        var bytes = payload.sublist(start, end + 1);
        if (truncateFirstSegment && start == 0 && bytes.isNotEmpty) {
          // Return a shorter, otherwise well-formed HTTP body for the requested
          // range so the downloader's received-byte check detects truncation.
          bytes = bytes.sublist(0, bytes.length - 1);
        }
        request.response.contentLength = bytes.length;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        request.response.add(bytes);
        await request.response.close();
      } finally {
        activeRequests--;
      }
    });
  });

  tearDown(() async {
    await server.close(force: true);
    if (await tempDirectory.exists()) {
      await tempDirectory.delete(recursive: true);
    }
  });

  Uri buildUrl() => Uri.parse(
        'http://${InternetAddress.loopbackIPv4.address}:${server.port}/payload',
      );

  test('downloads, validates, and assembles ranges in exact byte order', () async {
    final destination = File('${tempDirectory.path}/payload.bin');
    final client = HttpClient();
    addTearDown(() => client.close(force: true));

    await downloadSegmentedToFile(
      client: client,
      uri: buildUrl(),
      destination: destination,
      totalBytes: payload.length,
      entityTag: '"stable-v1"',
      segmentSizeBytes: 5,
      maxConcurrentSegments: 3,
    );

    expect(await destination.readAsBytes(), payload);
    expect(maxActiveRequests, lessThanOrEqualTo(3));
    expect(maxActiveRequests, greaterThan(1));
  });

  test('rejects a mismatched Content-Range and preserves existing destination', () async {
    malformedRange = true;
    final destination = File('${tempDirectory.path}/existing.bin');
    await destination.writeAsString('keep me');
    final client = HttpClient();
    addTearDown(() => client.close(force: true));

    await expectLater(
      downloadSegmentedToFile(
        client: client,
        uri: buildUrl(),
        destination: destination,
        totalBytes: payload.length,
        entityTag: '"stable-v1"',
        segmentSizeBytes: 5,
      ),
      throwsA(isA<HttpException>()),
    );

    expect(await destination.readAsString(), 'keep me');
  });

  test('rejects a server that ignores Range and preserves existing destination', () async {
    ignoreRange = true;
    final destination = File('${tempDirectory.path}/existing-on-200.bin');
    await destination.writeAsString('keep this original');
    final client = HttpClient();
    addTearDown(() => client.close(force: true));

    await expectLater(
      downloadSegmentedToFile(
        client: client,
        uri: buildUrl(),
        destination: destination,
        totalBytes: payload.length,
        entityTag: '"stable-v1"',
        segmentSizeBytes: 5,
      ),
      throwsA(isA<HttpException>()),
    );

    expect(await destination.readAsString(), 'keep this original');
  });

  test('rejects a truncated segment and preserves existing destination', () async {
    truncateFirstSegment = true;
    final destination = File('${tempDirectory.path}/existing-on-truncation.bin');
    await destination.writeAsString('keep original bytes');
    final client = HttpClient();
    addTearDown(() => client.close(force: true));

    await expectLater(
      downloadSegmentedToFile(
        client: client,
        uri: buildUrl(),
        destination: destination,
        totalBytes: payload.length,
        entityTag: '"stable-v1"',
        segmentSizeBytes: 5,
        maxConcurrentSegments: 1,
      ),
      throwsA(anything),
    );

    expect(await destination.readAsString(), 'keep original bytes');
  });

  test('rejects a changed ETag before assembling output', () async {
    changedTag = true;
    final destination = File('${tempDirectory.path}/changed.bin');
    final client = HttpClient();
    addTearDown(() => client.close(force: true));

    await expectLater(
      downloadSegmentedToFile(
        client: client,
        uri: buildUrl(),
        destination: destination,
        totalBytes: payload.length,
        entityTag: '"stable-v1"',
        segmentSizeBytes: 5,
      ),
      throwsA(isA<HttpException>()),
    );

    expect(await destination.exists(), isFalse);
  });

  test('cancels a segmented transfer and cleans temporary segment state', () async {
    final destination = File('${tempDirectory.path}/cancelled.bin');
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    var abortChecks = 0;

    await expectLater(
      downloadSegmentedToFile(
        client: client,
        uri: buildUrl(),
        destination: destination,
        totalBytes: payload.length,
        entityTag: '"stable-v1"',
        segmentSizeBytes: 5,
        maxConcurrentSegments: 1,
        shouldAbort: () => ++abortChecks >= 3,
      ),
      throwsA(isA<SegmentedDownloadAborted>()),
    );

    expect(await destination.exists(), isFalse);
    final leftovers = tempDirectory
        .listSync()
        .where((entry) => entry.path.contains('.download-beast-segments-'));
    expect(leftovers, isEmpty);
  });

}
