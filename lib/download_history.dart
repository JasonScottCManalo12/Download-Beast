import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

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
  });

  final int? id;
  final String url;
  final String destinationPath;
  final String status;
  final int receivedBytes;
  final int totalBytes;
  final String? errorMessage;
  final DateTime createdAt;
  final DateTime updatedAt;

  DownloadHistoryRecord copyWith({
    int? id,
    String? url,
    String? destinationPath,
    String? status,
    int? receivedBytes,
    int? totalBytes,
    String? errorMessage,
    bool clearErrorMessage = false,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return DownloadHistoryRecord(
      id: id ?? this.id,
      url: url ?? this.url,
      destinationPath: destinationPath ?? this.destinationPath,
      status: status ?? this.status,
      receivedBytes: receivedBytes ?? this.receivedBytes,
      totalBytes: totalBytes ?? this.totalBytes,
      errorMessage: clearErrorMessage ? null : errorMessage ?? this.errorMessage,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, Object?> toMap() => {
        'url': url,
        'destination_path': destinationPath,
        'status': status,
        'received_bytes': receivedBytes,
        'total_bytes': totalBytes,
        'error_message': errorMessage,
        'created_at': createdAt.millisecondsSinceEpoch,
        'updated_at': updatedAt.millisecondsSinceEpoch,
      };

  factory DownloadHistoryRecord.fromMap(Map<String, Object?> map) {
    return DownloadHistoryRecord(
      id: map['id'] as int,
      url: map['url'] as String,
      destinationPath: map['destination_path'] as String,
      status: map['status'] as String,
      receivedBytes: map['received_bytes'] as int,
      totalBytes: map['total_bytes'] as int,
      errorMessage: map['error_message'] as String?,
      createdAt: DateTime.fromMillisecondsSinceEpoch(map['created_at'] as int),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(map['updated_at'] as int),
    );
  }
}

class DownloadHistoryStore {
  DownloadHistoryStore._(this._database);

  final Database _database;

  static Future<DownloadHistoryStore> open({String? databasePath}) async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

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
        version: 1,
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
              created_at INTEGER NOT NULL,
              updated_at INTEGER NOT NULL
            )
          ''');
          await db.execute(
            'CREATE INDEX idx_download_history_updated_at '
            'ON download_history(updated_at DESC)',
          );
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
  Future<int> markActiveDownloadsInterrupted() {
    final now = DateTime.now().millisecondsSinceEpoch;
    return _database.update(
      'download_history',
      {
        'status': 'interrupted',
        'error_message': 'App closed before the download finished.',
        'updated_at': now,
      },
      where: 'status = ?',
      whereArgs: ['downloading'],
    );
  }

  Future<List<DownloadHistoryRecord>> listRecent({int limit = 100}) async {
    final rows = await _database.query(
      'download_history',
      orderBy: 'updated_at DESC, id DESC',
      limit: limit,
    );
    return rows.map(DownloadHistoryRecord.fromMap).toList(growable: false);
  }

  Future<void> close() => _database.close();
}
