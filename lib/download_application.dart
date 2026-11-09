import 'download_history.dart';
import 'download_job.dart';
import 'download_scheduler.dart';
import 'download_state.dart';

/// Application-layer orchestration for task concurrency and durable history.
///
/// Widgets use this controller instead of opening SQLite or implementing
/// persistence policy. The store and scheduler remain injectable for tests.
class DownloadApplicationController {
  DownloadApplicationController._(this._history, this.scheduler);

  final DownloadHistoryStore _history;
  final Map<int, DownloadHistoryRecord> _jobRecords = {};
  final DownloadScheduler scheduler;

  static Future<DownloadApplicationController> open({
    DownloadHistoryStore? historyStore,
    DownloadScheduler? scheduler,
  }) async {
    final history = historyStore ?? await DownloadHistoryStore.open();
    final app = DownloadApplicationController._(
      history,
      scheduler ?? DownloadScheduler(),
    );
    await app.initialize();
    return app;
  }

  Future<void> initialize() async {
    await _history.markActiveDownloadsInterrupted();
    scheduler.setMaxConcurrent(await _history.getMaxConcurrentDownloads());
  }

  Future<List<DownloadHistoryRecord>> search({
    required String query,
    required String? status,
    required bool newestFirst,
    required int offset,
    required int limit,
  }) =>
      _history.search(
        query: query,
        status: status,
        newestFirst: newestFirst,
        offset: offset,
        limit: limit,
      );

  Future<int> insertHistory(DownloadHistoryRecord record) =>
      _history.insert(record);

  void rememberHistory(Iterable<DownloadHistoryRecord> records) {
    for (final record in records) {
      final id = record.id;
      if (id != null) _jobRecords[id] = record;
    }
  }

  Future<DownloadHistoryRecord?> persistJob(DownloadJob job) async {
    final id = job.historyId;
    if (id == null) return null;
    final old = _jobRecords[id];
    if (old == null) return null;
    final updated = old.copyWith(
      status: job.status,
      receivedBytes: job.receivedBytes,
      totalBytes: job.totalBytes,
      errorMessage: job.errorMessage,
      clearErrorMessage: job.errorMessage == null,
      failureKind: job.failureKind,
      clearFailureKind: job.failureKind == null,
      etag: job.entityTag,
      clearEtag: job.entityTag == null,
      expectedSha256: job.expectedSha256,
      actualSha256: job.actualSha256,
      clearActualSha256: job.actualSha256 == null,
      integrityStatus: job.integrityStatus,
      integrityCheckedAt: job.integrityCheckedAt,
      clearIntegrityCheckedAt: job.integrityCheckedAt == null,
      stagingPath: job.stagingPath,
      clearStagingPath: job.status == DownloadStatus.completed ||
          job.status == DownloadStatus.cancelled ||
          (job.status == DownloadStatus.integrityFailed &&
              job.stagingPath == null) ||
          (job.status == DownloadStatus.paused &&
              job.wasSegmented &&
              job.stagingPath == null),
      wasSegmented: job.wasSegmented,
      updatedAt: DateTime.now(),
    );
    await _history.update(updated);
    _jobRecords[id] = updated;
    return updated;
  }

  void forgetHistory(int id) => _jobRecords.remove(id);
  void forgetAllHistory() => _jobRecords.clear();

  Future<int> deleteHistoryRecord(int id) => _history.deleteRecord(id);
  Future<int> deleteAllHistory() => _history.deleteAll();
  Future<List<DownloadHistoryRecord>> listAllHistory() => _history.listAll();

  Future<void> setMaxConcurrentDownloads(int value) =>
      _history.setMaxConcurrentDownloads(value);

  Future<void> close() => _history.close();
}
