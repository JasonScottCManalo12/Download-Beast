import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:download_beast/download_job.dart';
import 'package:download_beast/download_state.dart';
import 'package:download_beast/download_errors.dart';
import 'package:download_beast/windows_file_ops.dart';
import 'package:flutter_test/flutter_test.dart';

final _rangePayload = List<int>.generate(256 * 1024, (index) => index % 251);
final _segmentedPayload =
    List<int>.generate(16 * 1024 * 1024 + 123, (index) => index % 239);

void main() {
  setUpAll(() {
    WindowsFileOperations.installForTesting(const FileSystemFileOperations());
  });
  tearDownAll(() {
    WindowsFileOperations.resetAdapter();
  });

  late HttpServer server;
  late Directory tempDirectory;
  late Completer<void> slowResponseFlushed;
  final heldResponses = <Completer<void>>[];
  final rangeRequestHeaders = <String>[];
  final segmentedRangeHeaders = <String>[];
  late Completer<void> segmentedBodyStarted;
  late Completer<void> releaseSegmentedBody;
  var holdSegmentedBody = false;
  var flakyRouteCount = 0;
  var missingRouteCount = 0;

  setUp(() async {
    tempDirectory =
        await Directory.systemTemp.createTemp('download_beast_test_');
    slowResponseFlushed = Completer<void>();
    segmentedBodyStarted = Completer<void>();
    releaseSegmentedBody = Completer<void>();
    holdSegmentedBody = false;
    rangeRequestHeaders.clear();
    segmentedRangeHeaders.clear();
    flakyRouteCount = 0;
    missingRouteCount = 0;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      if (request.method == 'HEAD') {
        final path = request.uri.path;
        final length =
            path == '/segmented-payload' || path == '/segmented-pause'
                ? _segmentedPayload.length
                : (path == '/range-payload' ||
                        path == '/below-threshold' ||
                        path == '/ignore-range' ||
                        path == '/bad-range' ||
                        path == '/changed-etag')
                    ? _rangePayload.length
                    : utf8.encode('Download Beast test payload').length;
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.set(
              HttpHeaders.etagHeader,
              path == '/segmented-payload' || path == '/segmented-pause'
                  ? '"segmented-v1"'
                  : '"fixture-v1"')
          ..contentLength = length;
        await request.response.close();
        return;
      }
      if (request.uri.path == '/segmented-payload' ||
          request.uri.path == '/segmented-pause') {
        final isPauseFixture = request.uri.path == '/segmented-pause';
        if (request.method == 'HEAD') {
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.set(HttpHeaders.etagHeader, '"segmented-v1"')
            ..contentLength = _segmentedPayload.length;
          await request.response.close();
          return;
        }
        final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
        segmentedRangeHeaders.add(rangeHeader ?? '');
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
        if (start < 0 || end < start || end >= _segmentedPayload.length) {
          request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          await request.response.close();
          return;
        }
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers
          ..set(HttpHeaders.acceptRangesHeader, 'bytes')
          ..set(HttpHeaders.etagHeader, '"segmented-v1"')
          ..set(
            HttpHeaders.contentRangeHeader,
            'bytes $start-$end/${_segmentedPayload.length}',
          )
          ..contentLength = end - start + 1;
        request.response.add(_segmentedPayload.sublist(start, end + 1));
        await request.response.flush();
        if (isPauseFixture && holdSegmentedBody && rangeHeader != 'bytes=0-0') {
          if (!segmentedBodyStarted.isCompleted) {
            segmentedBodyStarted.complete();
          }
          await releaseSegmentedBody.future;
        }
        try {
          await request.response.close();
        } on HttpException {
          // Pausing closes the client's in-flight range request.
        } on SocketException {
          // Pausing closes the client's in-flight range request.
        }
        return;
      }

      if (request.uri.path == '/range-payload' ||
          request.uri.path == '/below-threshold' ||
          request.uri.path == '/ignore-range' ||
          request.uri.path == '/bad-range' ||
          request.uri.path == '/changed-etag') {
        final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
        rangeRequestHeaders.add(rangeHeader ?? '');
        final honorRange = request.uri.path != '/ignore-range';
        var start = 0;
        var endInclusive = _rangePayload.length - 1;
        var isRangeRequest = false;
        if (honorRange && rangeHeader != null) {
          final closedRange =
              RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(rangeHeader);
          final openRange = RegExp(r'^bytes=(\d+)-$').firstMatch(rangeHeader);
          if (closedRange != null) {
            start = int.parse(closedRange.group(1)!);
            endInclusive = int.parse(closedRange.group(2)!);
            isRangeRequest = true;
          } else if (openRange != null) {
            start = int.parse(openRange.group(1)!);
            isRangeRequest = true;
          }
        }
        if (start < 0 ||
            endInclusive < start ||
            start >= _rangePayload.length ||
            endInclusive >= _rangePayload.length) {
          request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          await request.response.close();
          return;
        }
        request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
        final isResumeRange = rangeHeader != null &&
            RegExp(r'^bytes=[1-9]\d*-$').hasMatch(rangeHeader);
        final responseEtag =
            request.uri.path == '/changed-etag' && isResumeRange
                ? '"fixture-v2"'
                : '"fixture-v1"';
        request.response.headers.set(HttpHeaders.etagHeader, responseEtag);
        if (isRangeRequest) {
          request.response.statusCode = HttpStatus.partialContent;
          final reportedStart =
              request.uri.path == '/bad-range' ? start + 1 : start;
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $reportedStart-$endInclusive/${_rangePayload.length}',
          );
        }
        final bytes = _rangePayload.sublist(start, endInclusive + 1);
        request.response.contentLength = bytes.length;
        request.response.bufferOutput = false;
        for (var offset = 0; offset < bytes.length; offset += 8192) {
          final chunkEnd =
              offset + 8192 < bytes.length ? offset + 8192 : bytes.length;
          request.response.add(bytes.sublist(offset, chunkEnd));
          await request.response.flush();
          // Hold only the first ordinary full download, never the 0-0 probe.
          if (request.uri.path == '/range-payload' &&
              rangeHeader == null &&
              offset == 0) {
            final hold = Completer<void>();
            heldResponses.add(hold);
            await hold.future;
          }
        }
        try {
          await request.response.close();
        } on HttpException {
          // A paused client may have closed this response.
        } on SocketException {
          // A paused client may have closed this response.
        }
        return;
      }
      if (request.uri.path == '/always-unavailable') {
        request.response.statusCode = HttpStatus.serviceUnavailable;
        request.response.write('Temporarily unavailable');
        await request.response.close();
        return;
      }
      if (request.uri.path == '/flaky') {
        flakyRouteCount++;
        if (flakyRouteCount == 1) {
          request.response.statusCode = HttpStatus.serviceUnavailable;
          request.response.write('Temporary server failure');
          await request.response.close();
          return;
        }
        final bytes = utf8.encode('Recovered after retry');
        request.response.headers.contentLength = bytes.length;
        request.response.add(bytes);
        await request.response.close();
        return;
      }
      if (request.uri.path == '/missing') {
        missingRouteCount++;
        request.response.statusCode = HttpStatus.notFound;
        request.response.write('Not found');
        await request.response.close();
        return;
      }

      if (request.uri.path == '/slow') {
        final hold = Completer<void>();
        heldResponses.add(hold);
        request.response.bufferOutput = false;
        request.response.headers.contentType = ContentType.text;
        request.response.add(List<int>.filled(64 * 1024, 65));
        await request.response.flush();
        if (!slowResponseFlushed.isCompleted) {
          slowResponseFlushed.complete();
        }
        await hold.future;
        try {
          await request.response.close();
        } on HttpException {
          // The client may already have cancelled the request.
        } on SocketException {
          // The client may already have cancelled the request.
        }
        return;
      }

      final bytes = utf8.encode('Download Beast test payload');
      if (request.uri.path == '/short-length') {
        request.response.headers.contentLength = bytes.length + 10;
        request.response.add(bytes);
        try {
          await request.response.close();
        } on HttpException {
          // The fixture deliberately advertises more bytes than it sends.
        } on SocketException {
          // The client may reject the incomplete response.
        }
        return;
      }
      request.response.headers.contentLength = bytes.length;
      request.response.add(bytes);
      await request.response.close();
    });
  });

  tearDown(() async {
    for (final hold in heldResponses) {
      if (!hold.isCompleted) hold.complete();
    }
    heldResponses.clear();
    await server.close(force: true);
    if (await tempDirectory.exists()) {
      await tempDirectory.delete(recursive: true);
    }
  });

  Uri url(String path) =>
      Uri.parse('http://${server.address.address}:${server.port}$path');

  test('uses segmented download for a large strong-ETag range-capable file',
      () async {
    final destination = '${tempDirectory.path}/segmented-payload.bin';
    final progressValues = <int>[];
    late final DownloadJob job;
    job = DownloadJob(
      url: url('/segmented-payload'),
      destinationPath: destination,
      onChanged: () => progressValues.add(job.receivedBytes),
    );

    await job.start().timeout(const Duration(seconds: 30));

    expect(job.status, DownloadStatus.completed, reason: job.errorMessage);
    expect(job.totalBytes, _segmentedPayload.length);
    expect(job.receivedBytes, _segmentedPayload.length);
    expect(job.progress, 1.0);
    expect(progressValues, isNotEmpty);
    expect(await File(destination).readAsBytes(), _segmentedPayload);
  });

  test('segmented pause discards progress and resumes from byte zero',
      () async {
    holdSegmentedBody = true;
    final destination = '${tempDirectory.path}/segmented-pause.bin';
    final progressReceived = Completer<void>();
    late final DownloadJob job;
    job = DownloadJob(
      url: url('/segmented-pause'),
      destinationPath: destination,
      onChanged: () {
        if (job.receivedBytes > 0 && !progressReceived.isCompleted) {
          progressReceived.complete();
        }
      },
    );

    final firstRun = job.start();
    await segmentedBodyStarted.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => throw StateError('No segmented body request arrived.'),
    );
    await progressReceived.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => throw StateError('No segmented progress arrived.'),
    );
    final pause = job.pause();
    holdSegmentedBody = false;
    if (!releaseSegmentedBody.isCompleted) releaseSegmentedBody.complete();
    await pause.timeout(
      const Duration(seconds: 10),
      onTimeout: () => throw StateError('Segmented pause did not settle.'),
    );
    await firstRun.timeout(
      const Duration(seconds: 10),
      onTimeout: () => throw StateError('Segmented transfer did not stop.'),
    );
    expect(job.status, DownloadStatus.paused);
    expect(job.receivedBytes, 0);
    expect(await File(job.currentStagingPath).exists(), isFalse);
    expect(
      tempDirectory
          .listSync()
          .where((entry) => entry.path.contains('.download-beast-segments-')),
      isEmpty,
    );

    await job.resume().timeout(const Duration(seconds: 30));
    expect(job.status, DownloadStatus.completed, reason: job.errorMessage);
    expect(job.receivedBytes, _segmentedPayload.length);
    expect(await File(destination).readAsBytes(), _segmentedPayload);
    expect(
        segmentedRangeHeaders.where((header) => header == 'bytes=0-0').length,
        2);
  });

  test('does not send a range probe below the 16 MiB threshold', () async {
    final destination = '${tempDirectory.path}/below-threshold.bin';
    final job = DownloadJob(
      url: url('/below-threshold'),
      destinationPath: destination,
      onChanged: () {},
    );
    await job.start();
    expect(job.status, DownloadStatus.completed);
    expect(rangeRequestHeaders, isNot(contains('bytes=0-0')));
  });

  test(
      'pause preserves staged single-stream bytes and resume validates HTTP Range',
      () async {
    final destination = '${tempDirectory.path}/range-payload.bin';
    final firstChunkReceived = Completer<void>();
    late final DownloadJob job;
    job = DownloadJob(
      url: url('/range-payload'),
      destinationPath: destination,
      onChanged: () {
        if (job.receivedBytes > 0 && !firstChunkReceived.isCompleted) {
          firstChunkReceived.complete();
        }
      },
    );

    final initialRun = job.start();
    await firstChunkReceived.future.timeout(const Duration(seconds: 10));
    await job.pause();
    await initialRun.timeout(const Duration(seconds: 10));

    expect(job.status, DownloadStatus.paused);
    expect(await File(destination).exists(), isFalse);
    expect(await File(job.currentStagingPath).exists(), isTrue);
    final savedBytes = await File(job.currentStagingPath).length();
    expect(savedBytes, greaterThan(0));
    expect(savedBytes, lessThan(job.totalBytes));

    for (final hold in heldResponses) {
      if (!hold.isCompleted) hold.complete();
    }
    await job.resume().timeout(const Duration(seconds: 10));

    expect(job.status, DownloadStatus.completed, reason: job.errorMessage);
    expect(await File(destination).readAsBytes(), _rangePayload);
    expect(rangeRequestHeaders, contains('bytes=$savedBytes-'));
  });

  test('resume restarts safely when server ignores Range', () async {
    final destination = '${tempDirectory.path}/ignore-range.bin';
    final firstChunkReceived = Completer<void>();
    late final DownloadJob job;
    job = DownloadJob(
      url: url('/ignore-range'),
      destinationPath: destination,
      onChanged: () {
        if (job.receivedBytes > 0 && !firstChunkReceived.isCompleted) {
          firstChunkReceived.complete();
        }
      },
    );

    final initialRun = job.start();
    await firstChunkReceived.future.timeout(const Duration(seconds: 10));
    await job.pause();
    await initialRun.timeout(const Duration(seconds: 10));

    expect(job.status, DownloadStatus.paused);
    for (final hold in heldResponses) {
      if (!hold.isCompleted) hold.complete();
    }
    await job.resume().timeout(const Duration(seconds: 10));

    expect(job.status, DownloadStatus.completed, reason: job.errorMessage);
    expect(await File(destination).readAsBytes(), _rangePayload);
  });

  test('rejects a mismatched Content-Range without preserving corrupted output',
      () async {
    final destination = '${tempDirectory.path}/bad-range.bin';
    final firstChunkReceived = Completer<void>();
    late final DownloadJob job;
    job = DownloadJob(
      url: url('/bad-range'),
      destinationPath: destination,
      onChanged: () {
        if (job.receivedBytes > 0 && !firstChunkReceived.isCompleted) {
          firstChunkReceived.complete();
        }
      },
    );
    final initialRun = job.start();
    await firstChunkReceived.future.timeout(const Duration(seconds: 10));
    await job.pause();
    await initialRun.timeout(const Duration(seconds: 10));
    for (final hold in heldResponses) {
      if (!hold.isCompleted) hold.complete();
    }
    await job.resume().timeout(const Duration(seconds: 10));
    expect(job.status, DownloadStatus.failed);
    expect(job.errorMessage, contains('Content-Range'));
    expect(await File(destination).exists(), isFalse);
  });

  test('rejects a changed ETag on resume', () async {
    final destination = '${tempDirectory.path}/changed-etag.bin';
    final firstChunkReceived = Completer<void>();
    late final DownloadJob job;
    job = DownloadJob(
      url: url('/changed-etag'),
      destinationPath: destination,
      onChanged: () {
        if (job.receivedBytes > 0 && !firstChunkReceived.isCompleted) {
          firstChunkReceived.complete();
        }
      },
    );
    final initialRun = job.start();
    await firstChunkReceived.future.timeout(const Duration(seconds: 10));
    await job.pause();
    await initialRun.timeout(const Duration(seconds: 10));
    expect(job.entityTag, '"fixture-v1"');
    for (final hold in heldResponses) {
      if (!hold.isCompleted) hold.complete();
    }
    await job.resume().timeout(const Duration(seconds: 10));
    expect(job.status, DownloadStatus.failed);
    expect(job.errorMessage, contains('remote file changed'));
    expect(await File(destination).exists(), isFalse);
  });

  test('downloads a file and reports completed progress', () async {
    final destination = '${tempDirectory.path}/payload.txt';
    var changeCount = 0;
    final job = DownloadJob(
      url: url('/payload'),
      destinationPath: destination,
      onChanged: () => changeCount++,
    );

    await job.start();

    expect(job.status, DownloadStatus.completed, reason: job.errorMessage);
    expect(
        await File(destination).readAsString(), 'Download Beast test payload');
    expect(
        job.receivedBytes, utf8.encode('Download Beast test payload').length);
    expect(job.totalBytes, job.receivedBytes);
    expect(job.progress, 1.0);
    expect(changeCount, greaterThan(0));
  });

  test('reports HTTP errors without creating a destination file', () async {
    final destination = '${tempDirectory.path}/missing.txt';
    final job = DownloadJob(
      url: url('/missing'),
      destinationPath: destination,
      onChanged: () {},
    );

    await job.start();

    expect(job.status, DownloadStatus.failed);
    expect(job.errorMessage, contains('404'));
    expect(await File(destination).exists(), isFalse);
  });

  test('reports a useful network error when the server is unreachable',
      () async {
    final unusedServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = unusedServer.port;
    await unusedServer.close(force: true);
    final destination = '${tempDirectory.path}/unreachable.txt';
    final job = DownloadJob(
      url: Uri.parse('http://127.0.0.1:$port/unreachable'),
      destinationPath: destination,
      onChanged: () {},
    );

    await job.start();

    expect(job.status, DownloadStatus.failed);
    expect(job.errorMessage, contains('Network error:'));
    expect(await File(destination).exists(), isFalse);
  });

  test('removes partial output when the save directory is invalid', () async {
    final destination = '${tempDirectory.path}/missing-folder/payload.txt';
    final job = DownloadJob(
      url: url('/payload'),
      destinationPath: destination,
      onChanged: () {},
    );

    await job.start();

    expect(job.status, DownloadStatus.failed);
    expect(job.errorMessage, contains('File error:'));
    expect(await File(destination).exists(), isFalse);
  });

  test('cancels an active download and removes the partial file', () async {
    final destination = '${tempDirectory.path}/partial.txt';
    final firstChunkReceived = Completer<void>();
    late final DownloadJob job;
    job = DownloadJob(
      url: url('/slow'),
      destinationPath: destination,
      onChanged: () {
        if (job.receivedBytes > 0 && !firstChunkReceived.isCompleted) {
          firstChunkReceived.complete();
        }
      },
    );

    final running = job.start();
    await slowResponseFlushed.future.timeout(const Duration(seconds: 10));
    await firstChunkReceived.future.timeout(const Duration(seconds: 10));
    job.cancel();
    await running.timeout(const Duration(seconds: 10));

    expect(job.status, DownloadStatus.cancelled);
    expect(await File(destination).exists(), isFalse);
  });

  test('cancels an active download only once and ignores later cancel calls',
      () async {
    final destination = '${tempDirectory.path}/partial-twice.txt';
    final firstChunkReceived = Completer<void>();
    late final DownloadJob job;
    job = DownloadJob(
      url: url('/slow'),
      destinationPath: destination,
      onChanged: () {
        if (job.receivedBytes > 0 && !firstChunkReceived.isCompleted) {
          firstChunkReceived.complete();
        }
      },
    );

    final running = job.start();
    await slowResponseFlushed.future.timeout(const Duration(seconds: 10));
    await firstChunkReceived.future.timeout(const Duration(seconds: 10));
    job.cancel();
    job.cancel();
    await running.timeout(const Duration(seconds: 10));

    expect(job.status, DownloadStatus.cancelled);
    expect(await File(destination).exists(), isFalse);
  });

  test(
      'does not retry a transient server failure until the user requests retry',
      () async {
    final destination = '${tempDirectory.path}/retry.txt';
    final job = DownloadJob(
      url: url('/flaky'),
      destinationPath: destination,
      onChanged: () {},
    );

    await job.start();

    expect(job.status, DownloadStatus.failed);
    expect(job.errorMessage, contains('503'));
    expect(flakyRouteCount, 1);
    expect(await File(destination).exists(), isFalse);

    await job.retry();

    expect(job.status, DownloadStatus.completed, reason: job.errorMessage);
    expect(flakyRouteCount, 2);
    expect(await File(destination).readAsString(), 'Recovered after retry');
  });

  test('failed HTTP 404 stays failed without automatic retry', () async {
    final destination = '${tempDirectory.path}/not-retryable.txt';
    final job = DownloadJob(
      url: url('/missing'),
      destinationPath: destination,
      onChanged: () {},
    );

    await job.start();

    expect(job.status, DownloadStatus.failed);
    expect(job.errorMessage, contains('404'));
    expect(missingRouteCount, 1);
    expect(await File(destination).exists(), isFalse);
  });

  test(
      'retry after repeated transient failures requires one explicit action per attempt',
      () async {
    final destination = '${tempDirectory.path}/retry-once.txt';
    final job = DownloadJob(
      url: url('/always-unavailable'),
      destinationPath: destination,
      onChanged: () {},
    );

    await job.start();
    expect(job.status, DownloadStatus.failed);
    expect(job.errorMessage, contains('503'));

    await job.retry();
    expect(job.status, DownloadStatus.failed);
    expect(job.errorMessage, contains('503'));
    expect(await File(destination).exists(), isFalse);
  });

  test('reports verified SHA-256 when expected hash matches downloaded bytes',
      () async {
    const payload = 'Download Beast test payload';
    final expected = sha256.convert(utf8.encode(payload)).toString();
    final destination = '${tempDirectory.path}/verified.txt';
    final job = DownloadJob(
      url: url('/payload'),
      destinationPath: destination,
      expectedSha256: expected,
      onChanged: () {},
    );

    await job.start();

    expect(job.status, DownloadStatus.completed, reason: job.errorMessage);
    expect(job.integrityStatus, 'verified');
    expect(job.actualSha256, expected);
    expect(job.integrityCheckedAt, isNotNull);
    expect(await File(destination).readAsString(), payload);
  });

  test('reports a terminal hash mismatch and discards staged data', () async {
    final destination = '${tempDirectory.path}/mismatch.txt';
    final job = DownloadJob(
      url: url('/payload'),
      destinationPath: destination,
      expectedSha256: List.filled(64, '0').join(),
      onChanged: () {},
    );

    await job.start();

    expect(job.status, DownloadStatus.integrityFailed);
    expect(job.integrityStatus, 'mismatch');
    expect(job.actualSha256, isNotNull);
    expect(job.errorMessage, contains('does not match'));
    expect(await File(destination).exists(), isFalse);
    expect(await File(job.currentStagingPath).exists(), isFalse);
  });

  test('does not claim hash verification when no expected hash is supplied',
      () async {
    final destination = '${tempDirectory.path}/unchecked.txt';
    final job = DownloadJob(
      url: url('/payload'),
      destinationPath: destination,
      onChanged: () {},
    );

    await job.start();

    expect(job.status, DownloadStatus.completed, reason: job.errorMessage);
    expect(job.integrityStatus, 'notChecked');
    expect(job.actualSha256, isNull);
  });

  test('rejects an incomplete response whose advertised length is not received',
      () async {
    final destination = '${tempDirectory.path}/incomplete.txt';
    final job = DownloadJob(
      url: url('/short-length'),
      destinationPath: destination,
      onChanged: () {},
    );

    await job.start().timeout(const Duration(seconds: 10));

    expect(job.status, DownloadStatus.failed);
    expect(await File(destination).exists(), isFalse);
  });

  test('each timeout fails safely and remains available for manual retry',
      () async {
    for (final phase in [
      DownloadFailureKind.connectionTimeout,
      DownloadFailureKind.responseHeaderTimeout,
      DownloadFailureKind.idleBodyTimeout,
    ]) {
      final destination = '${tempDirectory.path}/${phase.name}.txt';
      final original = File(destination);
      await original.writeAsString('original bytes');
      var injected = false;
      final job = DownloadJob(
        url: url('/payload'),
        destinationPath: destination,
        onChanged: () {},
        confirmOverwrite: (_) async => true,
        timeoutPhaseHook: (actual) {
          if (!injected && actual == phase) {
            injected = true;
            throw DownloadTimeoutException(phase);
          }
        },
      );
      await job.start();
      expect(job.status, DownloadStatus.failed, reason: phase.name);
      expect(job.failureKind, phase, reason: phase.name);
      final expectedMessage = switch (phase) {
        DownloadFailureKind.connectionTimeout =>
          'Connection timed out after 15 seconds.',
        DownloadFailureKind.responseHeaderTimeout =>
          'The server did not send response headers within 30 seconds.',
        DownloadFailureKind.idleBodyTimeout =>
          'The download stalled for 30 seconds without receiving data.',
        _ => fail('Unexpected timeout phase: ${phase.name}'),
      };
      expect(job.errorMessage, expectedMessage, reason: phase.name);
      expect(await original.readAsString(), 'original bytes',
          reason: phase.name);
      expect(await File(job.currentStagingPath).exists(), isFalse,
          reason: phase.name);

      await job.retry();
      expect(job.status, DownloadStatus.completed, reason: phase.name);
      expect(await File(destination).readAsString(),
          'Download Beast test payload');
    }
  });

  test('refuses to overwrite an existing destination without confirmation',
      () async {
    final destination = File('${tempDirectory.path}/keep.bin');
    await destination.writeAsString('original');
    final job = DownloadJob(
      url: url('/payload'),
      destinationPath: destination.path,
      onChanged: () {},
    );

    await job.start();

    expect(job.status, DownloadStatus.cancelled);
    expect(await destination.readAsString(), 'original');
  });

  test('replaces an existing destination only after confirmation', () async {
    final destination = File('${tempDirectory.path}/replace.bin');
    await destination.writeAsString('original');
    var confirmations = 0;
    final job = DownloadJob(
      url: url('/payload'),
      destinationPath: destination.path,
      onChanged: () {},
      confirmOverwrite: (_) async {
        confirmations++;
        return true;
      },
    );

    await job.start();

    expect(job.status, DownloadStatus.completed);
    expect(confirmations, 1);
    expect(await destination.readAsString(), 'Download Beast test payload');
    expect(
        tempDirectory
            .listSync()
            .where((entry) => entry.path.contains('backup')),
        isEmpty);
  });

  test('reconfirms when an existing destination changes after approval',
      () async {
    final destination = File('${tempDirectory.path}/changed-after-prompt.bin');
    await destination.writeAsString('original');
    final originalModified = (await destination.stat()).modified;
    var confirmations = 0;
    final job = DownloadJob(
      url: url('/payload'),
      destinationPath: destination.path,
      onChanged: () {},
      confirmOverwrite: (_) async {
        confirmations++;
        if (confirmations == 1) {
          await destination.writeAsString('modified');
          await destination.setLastModified(originalModified);
        }
        return true;
      },
    );

    await job.start();

    expect(job.status, DownloadStatus.completed, reason: job.errorMessage);
    expect(confirmations, 2);
    expect(await destination.readAsString(), 'Download Beast test payload');
  });

  test(
      'replacement failure preserves the original and leaves a recoverable stage',
      () async {
    addTearDown(() => WindowsFileOperations.installForTesting(
        const FileSystemFileOperations()));
    final destination = File('${tempDirectory.path}/locked-target.bin');
    await destination.writeAsString('original');
    WindowsFileOperations.installForTesting(const _FailingReplaceOperations());
    final job = DownloadJob(
      url: url('/payload'),
      destinationPath: destination.path,
      onChanged: () {},
      confirmOverwrite: (_) async => true,
    );

    await job.start();

    expect(job.status, DownloadStatus.failed);
    expect(await destination.readAsString(), 'original');
    expect(await File(job.currentStagingPath).exists(), isTrue);
    expect(job.errorMessage, contains(job.currentStagingPath));

    WindowsFileOperations.installForTesting(const FileSystemFileOperations());
    await job.retry();
    expect(job.status, DownloadStatus.completed, reason: job.errorMessage);
    expect(await destination.readAsString(), 'Download Beast test payload');
  });
}

class _FailingReplaceOperations implements FileOperationsAdapter {
  const _FailingReplaceOperations();

  final FileSystemFileOperations _fallback = const FileSystemFileOperations();

  @override
  Future<String?> identity(File file) => _fallback.identity(file);

  @override
  Future<void> replace({
    required File source,
    required File destination,
    required bool destinationExists,
    required File backup,
    String? expectedIdentity,
  }) async {
    throw FileSystemException('Destination is locked.', destination.path);
  }

  @override
  Future<void> open(File file) => _fallback.open(file);

  @override
  Future<void> reveal(File file) => _fallback.reveal(file);
}
