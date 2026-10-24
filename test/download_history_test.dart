import 'dart:io';

import 'package:download_beast/download_history.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tempDirectory;
  late String databasePath;
  late DownloadHistoryStore store;

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp('download_history_test_');
    databasePath = p.join(tempDirectory.path, 'history.sqlite');
    store = await DownloadHistoryStore.open(databasePath: databasePath);
  });

  tearDown(() async {
    await store.close();
    if (await tempDirectory.exists()) {
      await tempDirectory.delete(recursive: true);
    }
  });

  DownloadHistoryRecord record({
    String status = 'downloading',
    int receivedBytes = 0,
    int totalBytes = -1,
    String? errorMessage,
    String? etag,
  }) {
    final now = DateTime.now();
    return DownloadHistoryRecord(
      url: 'https://example.com/archive.zip',
      destinationPath: p.join(tempDirectory.path, 'archive.zip'),
      status: status,
      receivedBytes: receivedBytes,
      totalBytes: totalBytes,
      errorMessage: errorMessage,
      etag: etag,
      createdAt: now,
      updatedAt: now,
    );
  }

  test('persists a record after the database is closed and reopened', () async {
    final original = record(
      status: 'completed',
      receivedBytes: 120,
      totalBytes: 120,
      etag: '"fixture-v1"',
    );
    final id = await store.insert(original);
    await store.close();

    store = await DownloadHistoryStore.open(databasePath: databasePath);
    final records = await store.listRecent();

    expect(records, hasLength(1));
    expect(records.single.id, id);
    expect(records.single.url, original.url);
    expect(records.single.destinationPath, original.destinationPath);
    expect(records.single.status, 'completed');
    expect(records.single.receivedBytes, 120);
    expect(records.single.totalBytes, 120);
    expect(records.single.etag, '"fixture-v1"');
  });

  test('updates status, progress, error details, and updated timestamp', () async {
    final initial = record();
    final id = await store.insert(initial);
    final later = initial.copyWith(
      id: id,
      status: 'failed',
      receivedBytes: 42,
      totalBytes: 200,
      errorMessage: 'Network error',
      updatedAt: initial.updatedAt.add(const Duration(seconds: 5)),
    );

    expect(await store.update(later), 1);
    final saved = (await store.listRecent()).single;

    expect(saved.status, 'failed');
    expect(saved.receivedBytes, 42);
    expect(saved.totalBytes, 200);
    expect(saved.errorMessage, 'Network error');
    expect(saved.updatedAt.millisecondsSinceEpoch,
        later.updatedAt.millisecondsSinceEpoch);
    expect(saved.createdAt.millisecondsSinceEpoch,
        initial.createdAt.millisecondsSinceEpoch);
  });

  test('marks only active downloads interrupted after restart', () async {
    final activeId = await store.insert(record(receivedBytes: 32, totalBytes: 100));
    final completedId = await store.insert(record(
      status: 'completed',
      receivedBytes: 100,
      totalBytes: 100,
    ));

    expect(await store.markActiveDownloadsInterrupted(), 1);

    final records = await store.listRecent();
    final active = records.singleWhere((item) => item.id == activeId);
    final completed = records.singleWhere((item) => item.id == completedId);

    expect(active.status, 'interrupted');
    expect(active.receivedBytes, 32);
    expect(active.errorMessage, 'App closed before the download finished.');
    expect(completed.status, 'completed');
    expect(completed.receivedBytes, 100);
  });

  test('returns recent records newest first and honors the limit', () async {
    final first = record(status: 'completed').copyWith(
      updatedAt: DateTime.utc(2026, 1, 1),
      createdAt: DateTime.utc(2026, 1, 1),
    );
    final second = record(status: 'cancelled').copyWith(
      updatedAt: DateTime.utc(2026, 1, 2),
      createdAt: DateTime.utc(2026, 1, 2),
    );
    await store.insert(first);
    await store.insert(second);

    final records = await store.listRecent(limit: 1);

    expect(records, hasLength(1));
    expect(records.single.status, 'cancelled');
  });
}
