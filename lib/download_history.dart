import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'download_state.dart';
import 'download_errors.dart';

class DownloadHistoryRecord {
  const DownloadHistoryRecord({
    this.id,
    required this.url,
    required this.destinationPath,
    required this.status,
    required this.receivedBytes,
    required this.totalBytes,
    required this.createdAt,
    required this.updatedAt,
    this.errorMessage,
    this.failureKind,
    this.etag,
    this.expectedSha256,
    this.actualSha256,
    this.integrityStatus = 'notChecked',
    this.integrityCheckedAt,
    this.stagingPath,
    this.wasSegmented = false,
  });

  final int? id;
  final String url;
  final String destinationPath;
  final DownloadStatus status;
  final int receivedBytes;
  final int totalBytes;
  final String? errorMessage;
  final DownloadFailureKind? failureKind;
  final String? etag;
  final String? expectedSha256;
  final String? actualSha256;
  final String integrityStatus;
  final DateTime? integrityCheckedAt;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? stagingPath;
  final bool wasSegmented;

  DownloadHistoryRecord copyWith({
    int? id,
    String? url,
    String? destinationPath,
    DownloadStatus? status,
    int? receivedBytes,
    int? totalBytes,
    String? errorMessage,
    bool clearErrorMessage = false,
    DownloadFailureKind? failureKind,
    bool clearFailureKind = false,
    String? etag,
    bool clearEtag = false,
    String? expectedSha256,
    String? actualSha256,
    bool clearActualSha256 = false,
    String? integrityStatus,
    DateTime? integrityCheckedAt,
    bool clearIntegrityCheckedAt = false,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? stagingPath,
    bool clearStagingPath = false,
    bool? wasSegmented,
  }) {
    return DownloadHistoryRecord(
      id: id ?? this.id,
      url: url ?? this.url,
      destinationPath: destinationPath ?? this.destinationPath,
      status: status ?? this.status,
      receivedBytes: receivedBytes ?? this.receivedBytes,
      totalBytes: totalBytes ?? this.totalBytes,
      errorMessage:
          clearErrorMessage ? null : errorMessage ?? this.errorMessage,
      failureKind: clearFailureKind ? null : failureKind ?? this.failureKind,
      etag: clearEtag ? null : etag ?? this.etag,
      expectedSha256: expectedSha256 ?? this.expectedSha256,
      actualSha256:
          clearActualSha256 ? null : actualSha256 ?? this.actualSha256,
      integrityStatus: integrityStatus ?? this.integrityStatus,
      integrityCheckedAt: clearIntegrityCheckedAt
          ? null
          : integrityCheckedAt ?? this.integrityCheckedAt,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      stagingPath: clearStagingPath ? null : stagingPath ?? this.stagingPath,
      wasSegmented: wasSegmented ?? this.wasSegmented,
    );
  }

  Map<String, Object?> toMap() => {
        'url': url,
        'destination_path': destinationPath,
        'status': status.name,
        'received_bytes': receivedBytes,
        'total_bytes': totalBytes,
        'error_message': errorMessage,
        'failure_kind': failureKind?.name,
        'etag': etag,
        'expected_sha256': expectedSha256,
        'actual_sha256': actualSha256,
        'integrity_status': integrityStatus,
        'integrity_checked_at': integrityCheckedAt?.millisecondsSinceEpoch,
        'created_at': createdAt.millisecondsSinceEpoch,
        'updated_at': updatedAt.millisecondsSinceEpoch,
        'staging_path': stagingPath,
        'was_segmented': wasSegmented ? 1 : 0,
      };

  factory DownloadHistoryRecord.fromMap(Map<String, Object?> map) {
    return DownloadHistoryRecord(
      id: map['id'] as int,
      url: map['url'] as String,
      destinationPath: map['destination_path'] as String,
      status: _statusFromDatabase(map['status'] as String),
      receivedBytes: map['received_bytes'] as int,
      totalBytes: map['total_bytes'] as int,
      errorMessage: map['error_message'] as String?,
      failureKind: _failureKindFromDatabase(map['failure_kind'] as String?),
      etag: map['etag'] as String?,
      expectedSha256: map['expected_sha256'] as String?,
      actualSha256: map['actual_sha256'] as String?,
      integrityStatus: map['integrity_status'] as String? ?? 'notChecked',
      integrityCheckedAt: map['integrity_checked_at'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              map['integrity_checked_at'] as int),
      createdAt: DateTime.fromMillisecondsSinceEpoch(map['created_at'] as int),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(map['updated_at'] as int),
      stagingPath: map['staging_path'] as String?,
      wasSegmented: (map['was_segmented'] as int? ?? 0) != 0,
    );
  }

  static DownloadStatus _statusFromDatabase(String value) =>
      DownloadStatus.values.firstWhere(
        (status) => status.name == value,
        orElse: () => DownloadStatus.interrupted,
      );

  static DownloadFailureKind? _failureKindFromDatabase(String? value) {
    if (value == null) return null;
    for (final kind in DownloadFailureKind.values) {
      if (kind.name == value) return kind;
    }
    return DownloadFailureKind.protocol;
  }
}

class DownloadHistoryStore {
  DownloadHistoryStore._(this._database);

  static bool _ffiFactoryReady = false;

  final Database _database;

  static Future<DownloadHistoryStore> open({String? databasePath}) async {
    if (!_ffiFactoryReady) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      _ffiFactoryReady = true;
    }

    final path = databasePath ??
        p.join(
          (await getApplicationSupportDirectory()).path,
          'download_beast',
          'download_history.sqlite',
        );
    if (databasePath == null) {
      await Directory(p.dirname(path)).create(recursive: true);
    }

    final database = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 4,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE download_history (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              url TEXT NOT NULL,
              destination_path TEXT NOT NULL,
              status TEXT NOT NULL,
              received_bytes INTEGER NOT NULL DEFAULT 0,
              total_bytes INTEGER NOT NULL DEFAULT -1,
              error_message TEXT,
              failure_kind TEXT,
              etag TEXT,
              expected_sha256 TEXT,
              actual_sha256 TEXT,
              integrity_status TEXT NOT NULL DEFAULT 'notChecked',
              integrity_checked_at INTEGER,
              created_at INTEGER NOT NULL,
              updated_at INTEGER NOT NULL
              ,staging_path TEXT
              ,was_segmented INTEGER NOT NULL DEFAULT 0
            )
          ''');
          await db.execute(
            'CREATE INDEX idx_download_history_updated_at '
            'ON download_history(updated_at DESC)',
          );
          await db.execute('''CREATE TABLE app_settings (
            setting_key TEXT PRIMARY KEY,
            setting_value TEXT NOT NULL
          )''');
          await db.insert('app_settings', {
            'setting_key': 'max_concurrent_downloads',
            'setting_value': '3',
          });
        },
        onUpgrade: (db, oldVersion, newVersion) async {
          if (oldVersion < 2) {
            await db
                .execute('ALTER TABLE download_history ADD COLUMN etag TEXT');
          }
          if (oldVersion < 3) {
            await db.execute(
                'ALTER TABLE download_history ADD COLUMN expected_sha256 TEXT');
            await db.execute(
                'ALTER TABLE download_history ADD COLUMN actual_sha256 TEXT');
            await db.execute(
                "ALTER TABLE download_history ADD COLUMN integrity_status TEXT NOT NULL DEFAULT 'notChecked'");
            await db.execute(
                'ALTER TABLE download_history ADD COLUMN integrity_checked_at INTEGER');
          }
          if (oldVersion < 4) {
            await db.execute(
                'ALTER TABLE download_history ADD COLUMN failure_kind TEXT');
            await db.execute(
                'ALTER TABLE download_history ADD COLUMN staging_path TEXT');
            await db.execute(
                'ALTER TABLE download_history ADD COLUMN was_segmented INTEGER NOT NULL DEFAULT 0');
            await db.execute('''CREATE TABLE app_settings (
              setting_key TEXT PRIMARY KEY,
              setting_value TEXT NOT NULL
            )''');
            await db.insert('app_settings', {
              'setting_key': 'max_concurrent_downloads',
              'setting_value': '3',
            });
            await db.execute(
                "UPDATE download_history SET status = 'integrityFailed' WHERE status = 'completed' AND integrity_status = 'mismatch'");
          }
        },
      ),
    );
    return DownloadHistoryStore._(database);
  }

  Future<int> insert(DownloadHistoryRecord record) {
    return _database.insert('download_history', record.toMap());
  }

  Future<int> update(DownloadHistoryRecord record) async {
    final id = record.id;
    if (id == null) {
      throw ArgumentError.value(id, 'record.id', 'Must be set before update.');
    }
    return _database.update(
      'download_history',
      record.toMap(),
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Marks downloads left active by a previous process as interrupted.
  ///
  /// This records a truthful state after a crash or forced close; it does not
  /// claim that an incomplete file can be resumed.
  Future<int> markActiveDownloadsInterrupted() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final active = await _database.query(
      'download_history',
      where: 'status = ?',
      whereArgs: ['downloading'],
    );
    for (final row in active) {
      final id = row['id'] as int;
      final stagePath = row['staging_path'] as String?;
      String? cleanupError;
      if (stagePath != null) {
        try {
          final stage = File(stagePath);
          if (await stage.exists()) await stage.delete();
        } on FileSystemException catch (error) {
          cleanupError =
              'Temporary download data could not be removed at $stagePath: ${error.message}';
        }
      }
      await _database.update(
        'download_history',
        {
          'status': 'interrupted',
          'received_bytes': 0,
          'staging_path': cleanupError == null ? null : stagePath,
          'error_message': cleanupError ??
              'App closed before the download finished; retry starts safely.',
          'updated_at': now,
        },
        where: 'id = ?',
        whereArgs: [id],
      );
    }
    return active.length;
  }

  Future<List<DownloadHistoryRecord>> listRecent({int limit = 100}) async {
    final rows = await _database.query(
      'download_history',
      orderBy: 'updated_at DESC, id DESC',
      limit: limit,
    );
    return rows.map(DownloadHistoryRecord.fromMap).toList(growable: false);
  }

  Future<List<DownloadHistoryRecord>> search({
    String query = '',
    String? status,
    bool newestFirst = true,
    int offset = 0,
    int limit = 100,
  }) async {
    final needle = '%${query.trim().toLowerCase()}%';
    final clauses = <String>[];
    final args = <Object?>[];
    if (query.trim().isNotEmpty) {
      clauses.add(
          '(lower(destination_path) LIKE ? OR lower(url) LIKE ? OR lower(status) LIKE ?)');
      args.addAll([needle, needle, needle]);
    }
    if (status != null && status != 'all') {
      clauses.add('status = ?');
      args.add(status);
    }
    final rows = await _database.query(
      'download_history',
      where: clauses.isEmpty ? null : clauses.join(' AND '),
      whereArgs: clauses.isEmpty ? null : args,
      orderBy:
          'updated_at ${newestFirst ? 'DESC' : 'ASC'}, id ${newestFirst ? 'DESC' : 'ASC'}',
      limit: limit,
      offset: offset,
    );
    return rows.map(DownloadHistoryRecord.fromMap).toList(growable: false);
  }

  Future<int> deleteRecord(int id) => _database.delete(
        'download_history',
        where: 'id = ?',
        whereArgs: [id],
      );

  Future<int> deleteAll() => _database.delete('download_history');

  Future<List<DownloadHistoryRecord>> listAll() async {
    final rows = await _database.query('download_history');
    return rows.map(DownloadHistoryRecord.fromMap).toList(growable: false);
  }

  Future<int> getMaxConcurrentDownloads() async {
    final rows = await _database.query(
      'app_settings',
      columns: ['setting_value'],
      where: 'setting_key = ?',
      whereArgs: ['max_concurrent_downloads'],
      limit: 1,
    );
    final parsed = rows.isEmpty
        ? 3
        : int.tryParse(rows.single['setting_value'] as String? ?? '') ?? 3;
    if (parsed < 1 || parsed > 5) return 3;
    return parsed;
  }

  Future<void> setMaxConcurrentDownloads(int value) async {
    if (value < 1 || value > 5) {
      throw RangeError.range(value, 1, 5, 'value');
    }
    await _database.insert(
      'app_settings',
      {'setting_key': 'max_concurrent_downloads', 'setting_value': '$value'},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> close() => _database.close();
}
