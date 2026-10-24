import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:download_beast/download_job.dart';
import 'package:flutter_test/flutter_test.dart';

final _rangePayload = List<int>.generate(256 * 1024, (index) => index % 251);

void main() {
  late HttpServer server;
  late Directory tempDirectory;
  late Completer<void> slowResponseFlushed;
  final heldResponses = <Completer<void>>[];
  final rangeRequestHeaders = <String>[];
  var rangeRouteCount = 0;
  var flakyRouteCount = 0;
  var missingRouteCount = 0;

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp('download_beast_test_');
    slowResponseFlushed = Completer<void>();
    rangeRequestHeaders.clear();
    rangeRouteCount = 0;
    flakyRouteCount = 0;
    missingRouteCount = 0;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      if (request.uri.path == '/range-payload' ||
          request.uri.path == '/ignore-range' ||
          request.uri.path == '/bad-range' ||
          request.uri.path == '/changed-etag') {
        final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
        rangeRequestHeaders.add(rangeHeader ?? '');
        final honorRange = request.uri.path != '/ignore-range';
        var start = 0;
        if (honorRange && rangeHeader != null) {
          final match = RegExp(r'^bytes=(\d+)-$').firstMatch(rangeHeader);
          if (match != null) start = int.parse(match.group(1)!);
        }
        final routeNumber = ++rangeRouteCount;
        request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
        final responseEtag = request.uri.path == '/changed-etag' && routeNumber > 1
            ? '"fixture-v2"'
            : '"fixture-v1"';
        request.response.headers.set(HttpHeaders.etagHeader, responseEtag);
        if (start > 0) {
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes ${request.uri.path == '/bad-range' ? start + 1 : start}-${_rangePayload.length - 1}/${_rangePayload.length}',
          );
        }
        request.response.contentLength = _rangePayload.length - start;
        request.response.bufferOutput = false;
        for (var offset = start; offset < _rangePayload.length; offset += 8192) {
          final end = (offset + 8192 < _rangePayload.length)
              ? offset + 8192
              : _rangePayload.length;
          request.response.add(_rangePayload.sublist(offset, end));
          await request.response.flush();
          if (offset == start && routeNumber == 1) {
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

  test('pause preserves partial bytes and resume completes with HTTP Range', () async {
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
    expect(await File(destination).exists(), isTrue);
    final savedBytes = await File(destination).length();
    expect(savedBytes, greaterThan(0));
    expect(savedBytes, lessThan(job.totalBytes));

    for (final hold in heldResponses) {
      if (!hold.isCompleted) hold.complete();
    }
    await job.resume().timeout(const Duration(seconds: 10));

    expect(job.status, DownloadStatus.completed);
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

    expect(job.status, DownloadStatus.completed);
    expect(await File(destination).readAsBytes(), _rangePayload);
  });

  test('rejects a mismatched Content-Range without preserving corrupted output', () async {
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

    expect(job.status, DownloadStatus.completed);
    expect(await File(destination).readAsString(), 'Download Beast test payload');
    expect(job.receivedBytes, utf8.encode('Download Beast test payload').length);
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

  test('reports a useful network error when the server is unreachable', () async {
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

  test('does not retry a transient server failure until the user requests retry', () async {
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

    expect(job.status, DownloadStatus.completed);
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

  test('retry after repeated transient failures requires one explicit action per attempt', () async {
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

}
