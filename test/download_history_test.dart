import 'dart:io';

import 'package:download_beast/download_history.dart';
import 'package:download_beast/download_errors.dart';
import 'package:download_beast/download_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tempDirectory;
  late String databasePath;
  late DownloadHistoryStore store;

  setUp(() async {
    tempDirectory =
        await Directory.systemTemp.createTemp('download_history_test_');
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
    DownloadStatus status = DownloadStatus.downloading,
    int receivedBytes = 0,
    int totalBytes = -1,
    String? errorMessage,
    DownloadFailureKind? failureKind,
    String? etag,
    String? expectedSha256,
    String? actualSha256,
    String integrityStatus = 'notChecked',
    DateTime? integrityCheckedAt,
  }) {
    final now = DateTime.now();
    return DownloadHistoryRecord(
      url: 'https://example.com/archive.zip',
      destinationPath: p.join(tempDirectory.path, 'archive.zip'),
      status: status,
      receivedBytes: receivedBytes,
      totalBytes: totalBytes,
      errorMessage: errorMessage,
      failureKind: failureKind,
      etag: etag,
      expectedSha256: expectedSha256,
      actualSha256: actualSha256,
      integrityStatus: integrityStatus,
      integrityCheckedAt: integrityCheckedAt,
      createdAt: now,
      updatedAt: now,
    );
  }

  test('persists a record after the database is closed and reopened', () async {
    final original = record(
      status: DownloadStatus.completed,
      receivedBytes: 120,
      totalBytes: 120,
      etag: '"fixture-v1"',
      expectedSha256: List.filled(64, 'a').join(),
      actualSha256: List.filled(64, 'a').join(),
      integrityStatus: 'verified',
      integrityCheckedAt: DateTime.utc(2026, 10, 25),
    );
    final id = await store.insert(original);
    await store.close();

    store = await DownloadHistoryStore.open(databasePath: databasePath);
    final records = await store.listRecent();

    expect(records, hasLength(1));
    expect(records.single.id, id);
    expect(records.single.url, original.url);
    expect(records.single.destinationPath, original.destinationPath);
    expect(records.single.status, DownloadStatus.completed);
    expect(records.single.receivedBytes, 120);
    expect(records.single.totalBytes, 120);
    expect(records.single.etag, '"fixture-v1"');
    expect(records.single.expectedSha256, List.filled(64, 'a').join());
    expect(records.single.actualSha256, List.filled(64, 'a').join());
    expect(records.single.integrityStatus, 'verified');
    expect(records.single.integrityCheckedAt!.millisecondsSinceEpoch,
        DateTime.utc(2026, 10, 25).millisecondsSinceEpoch);
  });

  test('updates status, progress, error details, and updated timestamp',
      () async {
    final initial = record();
    final id = await store.insert(initial);
    final later = initial.copyWith(
      id: id,
      status: DownloadStatus.failed,
      failureKind: DownloadFailureKind.network,
      receivedBytes: 42,
      totalBytes: 200,
      errorMessage: 'Network error',
      updatedAt: initial.updatedAt.add(const Duration(seconds: 5)),
    );

    expect(await store.update(later), 1);
    final saved = (await store.listRecent()).single;

    expect(saved.status, DownloadStatus.failed);
    expect(saved.failureKind, DownloadFailureKind.network);
    expect(saved.receivedBytes, 42);
    expect(saved.totalBytes, 200);
    expect(saved.errorMessage, 'Network error');
    expect(saved.updatedAt.millisecondsSinceEpoch,
        later.updatedAt.millisecondsSinceEpoch);
    expect(saved.createdAt.millisecondsSinceEpoch,
        initial.createdAt.millisecondsSinceEpoch);
  });

  test('marks only active downloads interrupted after restart', () async {
    final activeId =
        await store.insert(record(receivedBytes: 32, totalBytes: 100));
    final completedId = await store.insert(record(
      status: DownloadStatus.completed,
      receivedBytes: 100,
      totalBytes: 100,
    ));

    expect(await store.markActiveDownloadsInterrupted(), 1);

    final records = await store.listRecent();
    final active = records.singleWhere((item) => item.id == activeId);
    final completed = records.singleWhere((item) => item.id == completedId);

    expect(active.status, DownloadStatus.interrupted);
    expect(active.receivedBytes, 0);
    expect(active.errorMessage,
        'App closed before the download finished; retry starts safely.');
    expect(completed.status, DownloadStatus.completed);
    expect(completed.receivedBytes, 100);
  });

  test('returns recent records newest first and honors the limit', () async {
    final first = record(status: DownloadStatus.completed).copyWith(
      updatedAt: DateTime.utc(2026, 1, 1),
      createdAt: DateTime.utc(2026, 1, 1),
    );
    final second = record(status: DownloadStatus.cancelled).copyWith(
      updatedAt: DateTime.utc(2026, 1, 2),
      createdAt: DateTime.utc(2026, 1, 2),
    );
    await store.insert(first);
    await store.insert(second);

    final records = await store.listRecent(limit: 1);

    expect(records, hasLength(1));
    expect(records.single.status, DownloadStatus.cancelled);
  });

  test('persists concurrency settings and enforces the 1 through 5 range',
      () async {
    expect(await store.getMaxConcurrentDownloads(), 3);
    await store.setMaxConcurrentDownloads(5);
    await store.close();
    store = await DownloadHistoryStore.open(databasePath: databasePath);
    expect(await store.getMaxConcurrentDownloads(), 5);
    await expectLater(store.setMaxConcurrentDownloads(0), throwsRangeError);
    await expectLater(store.setMaxConcurrentDownloads(6), throwsRangeError);
  });

  test('invalid persisted concurrency values fall back to three', () async {
    await store.setMaxConcurrentDownloads(5);
    await store.close();
    final database = await databaseFactory.openDatabase(databasePath);
    await database.update(
      'app_settings',
      {'setting_value': '9'},
      where: 'setting_key = ?',
      whereArgs: ['max_concurrent_downloads'],
    );
    await database.close();
    store = await DownloadHistoryStore.open(databasePath: databasePath);

    expect(await store.getMaxConcurrentDownloads(), 3);
  });

  test('deleting history removes its URL record but leaves the downloaded file',
      () async {
    final file = File(p.join(tempDirectory.path, 'kept.bin'));
    await file.writeAsString('keep downloaded bytes');
    final id = await store.insert(record(status: DownloadStatus.completed));

    expect(await store.deleteRecord(id), 1);
    expect(await store.listRecent(), isEmpty);
    expect(await file.readAsString(), 'keep downloaded bytes');
  });

  test('history beyond the first hundred remains searchable and deletable',
      () async {
    final base = DateTime.utc(2026, 1, 1);
    for (var index = 0; index < 105; index++) {
      final item = record(status: DownloadStatus.completed).copyWith(
        url: 'https://example.com/item-$index',
        destinationPath: p.join(tempDirectory.path, 'item-$index.bin'),
        createdAt: base.add(Duration(seconds: index)),
        updatedAt: base.add(Duration(seconds: index)),
      );
      await store.insert(item);
    }

    final firstPage = await store.search(limit: 100);
    expect(firstPage, hasLength(100));
    expect(firstPage.any((item) => item.url.endsWith('/item-0')), isFalse);
    final olderItem = await store.search(query: 'item-0');
    expect(olderItem, hasLength(1));
    expect(olderItem.single.url, 'https://example.com/item-0');
    expect(await store.deleteRecord(olderItem.single.id!), 1);
    expect(await store.search(query: 'item-0'), isEmpty);
  });

  test('migrates schema versions 1, 2 and 3 to v4 and converts legacy mismatch',
      () async {
    final createdAt = DateTime.utc(2025, 1, 2).millisecondsSinceEpoch;
    for (final version in [1, 2, 3]) {
      final legacyPath = p.join(tempDirectory.path, 'legacy-$version.sqlite');
      final legacy = await databaseFactory.openDatabase(
        legacyPath,
        options: OpenDatabaseOptions(
          version: version,
          onCreate: (db, _) async {
            final extraV2 = version >= 2 ? ', etag TEXT' : '';
            final extraV3 = version >= 3
                ? ', expected_sha256 TEXT, actual_sha256 TEXT, integrity_status TEXT NOT NULL DEFAULT \'notChecked\', integrity_checked_at INTEGER'
                : '';
            await db.execute('''CREATE TABLE download_history (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              url TEXT NOT NULL,
              destination_path TEXT NOT NULL,
              status TEXT NOT NULL,
              received_bytes INTEGER NOT NULL DEFAULT 0,
              total_bytes INTEGER NOT NULL DEFAULT -1,
              error_message TEXT,
              created_at INTEGER NOT NULL,
              updated_at INTEGER NOT NULL$extraV2$extraV3
            )''');
            await db.insert('download_history', {
              'url': 'https://example.com/private?token=fixture',
              'destination_path': p.join(tempDirectory.path, 'legacy.bin'),
              'status': 'completed',
              'received_bytes': 5,
              'total_bytes': 5,
              'error_message': version == 3 ? 'hash mismatch fixture' : null,
              'created_at': createdAt,
              'updated_at': createdAt,
              if (version >= 2) 'etag': '"fixture"',
              if (version >= 3) 'expected_sha256': List.filled(64, 'a').join(),
              if (version >= 3) 'actual_sha256': List.filled(64, 'b').join(),
              if (version >= 3) 'integrity_status': 'mismatch',
            });
          },
        ),
      );
      await legacy.close();
      await store.close();
      store = await DownloadHistoryStore.open(databasePath: legacyPath);
      final migrated = (await store.listRecent()).single;
      expect(
        migrated.status,
        version == 3
            ? DownloadStatus.integrityFailed
            : DownloadStatus.completed,
      );
      expect(migrated.createdAt.millisecondsSinceEpoch, createdAt);
      expect(migrated.updatedAt.millisecondsSinceEpoch, createdAt);
      expect(migrated.stagingPath, isNull);
      if (version == 3) {
        expect(migrated.integrityStatus, 'mismatch');
        expect(migrated.expectedSha256, List.filled(64, 'a').join());
        expect(migrated.actualSha256, List.filled(64, 'b').join());
        expect(migrated.errorMessage, 'hash mismatch fixture');
      }
    }
  });
}
