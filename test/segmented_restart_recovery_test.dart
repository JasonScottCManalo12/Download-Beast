import 'dart:io';

import 'package:download_beast/download_history.dart';
import 'package:download_beast/segmented_download_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tempDirectory;
  late HttpServer server;
  late String databasePath;
  final payload = List<int>.generate(64, (index) => (index * 29) % 256);
  var interrupted = false;

  setUp(() async {
    interrupted = false;
    tempDirectory = await Directory.systemTemp.createTemp(
      'download_beast_segmented_restart_',
    );
    databasePath = p.join(tempDirectory.path, 'history.sqlite');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
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
      request.response
        ..statusCode = HttpStatus.partialContent
        ..headers.set(HttpHeaders.etagHeader, '"restart-fixture-v1"')
        ..headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/${payload.length}',
        )
        ..contentLength = end - start + 1;
      await Future<void>.delayed(const Duration(milliseconds: 2));
      request.response.add(payload.sublist(start, end + 1));
      await request.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
    if (await tempDirectory.exists()) {
      await tempDirectory.delete(recursive: true);
    }
  });

  test(
    'segmented interruption cleans work files and restart persists interrupted history',
    () async {
      final destination = File(p.join(tempDirectory.path, 'payload.bin'));
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      var receivedBytes = 0;

      await expectLater(
        downloadSegmentedToFile(
          client: client,
          uri: Uri.parse(
            'http://${InternetAddress.loopbackIPv4.address}:${server.port}/payload',
          ),
          destination: destination,
          totalBytes: payload.length,
          entityTag: '"restart-fixture-v1"',
          segmentSizeBytes: 8,
          maxConcurrentSegments: 1,
          shouldAbort: () => interrupted,
          onProgress: (received, total) {
            receivedBytes = received;
            if (received >= 8) interrupted = true;
          },
        ),
        throwsA(isA<SegmentedDownloadAborted>()),
      );

      expect(receivedBytes, 8);
      expect(await destination.exists(), isFalse);
      expect(
        tempDirectory
            .listSync()
            .where((entry) => entry.path.contains('.download-beast-segments-')),
        isEmpty,
      );

      var store = await DownloadHistoryStore.open(databasePath: databasePath);
      final now = DateTime.now();
      final id = await store.insert(
        DownloadHistoryRecord(
          url: 'http://${InternetAddress.loopbackIPv4.address}:${server.port}/payload',
          destinationPath: destination.path,
          status: 'downloading',
          receivedBytes: receivedBytes,
          totalBytes: payload.length,
          etag: '"restart-fixture-v1"',
          createdAt: now,
          updatedAt: now,
        ),
      );
      await store.close();

      // Simulate a new app process opening the same database after interruption.
      store = await DownloadHistoryStore.open(databasePath: databasePath);
      addTearDown(store.close);
      expect(await store.markActiveDownloadsInterrupted(), 1);

      final recovered = (await store.listRecent())
          .singleWhere((record) => record.id == id);
      expect(recovered.status, 'interrupted');
      expect(recovered.receivedBytes, 8);
      expect(recovered.totalBytes, payload.length);
      expect(recovered.etag, '"restart-fixture-v1"');
      expect(
        recovered.errorMessage,
        'App closed before the download finished.',
      );
      expect(recovered.integrityStatus, 'notChecked');
    },
  );
}
