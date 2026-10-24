import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:download_beast/download_job.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late HttpServer server;
  late Directory tempDirectory;
  late Completer<void> slowResponseFlushed;
  final heldResponses = <Completer<void>>[];

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp('download_beast_test_');
    slowResponseFlushed = Completer<void>();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      if (request.uri.path == '/missing') {
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
}
