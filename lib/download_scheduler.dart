import 'dart:async';

import 'download_job.dart';
import 'download_state.dart';

/// Owns queue dispatch and enforces the application-wide simultaneous limit.
class DownloadScheduler {
  DownloadScheduler({int maxConcurrent = 3})
      : _maxConcurrent = _validate(maxConcurrent);

  final List<DownloadJob> _jobs = [];
  int _maxConcurrent;
  bool _dispatching = false;

  List<DownloadJob> get jobs => List.unmodifiable(_jobs);
  int get maxConcurrent => _maxConcurrent;
  int get activeCount =>
      _jobs.where((job) => job.status == DownloadStatus.downloading).length;
  bool hasDestination(String path) => _jobs.any((job) =>
      job.destinationPath.toLowerCase() == path.toLowerCase() &&
      {DownloadStatus.queued, DownloadStatus.downloading, DownloadStatus.paused}
          .contains(job.status));

  static int _validate(int value) {
    if (value < 1 || value > 5) {
      throw RangeError.range(value, 1, 5, 'maxConcurrent');
    }
    return value;
  }

  void setMaxConcurrent(int value) {
    _maxConcurrent = _validate(value);
    _pump();
  }

  void enqueue(DownloadJob job) {
    if (_jobs.contains(job)) return;
    final target = job.destinationPath.toLowerCase();
    if (_jobs.any((existing) =>
        existing.destinationPath.toLowerCase() == target &&
        {
          DownloadStatus.queued,
          DownloadStatus.downloading,
          DownloadStatus.paused
        }.contains(existing.status))) {
      throw ArgumentError(
          'Another queued or active download already uses this destination.');
    }
    _jobs.add(job);
    job.managedByQueue = true;
    if (job.status == DownloadStatus.downloading) {
      throw ArgumentError('A running download cannot be enqueued again.');
    }
    _pump();
  }

  void pause(DownloadJob job) => unawaited(job.pause().whenComplete(_pump));

  void resume(DownloadJob job) {
    if (job.status != DownloadStatus.paused) return;
    unawaited(job.resume().whenComplete(_pump));
    _pump();
  }

  void retry(DownloadJob job) {
    if (job.status != DownloadStatus.failed &&
        job.status != DownloadStatus.integrityFailed) {
      return;
    }
    unawaited(job.retry().whenComplete(_pump));
    _pump();
  }

  void cancel(DownloadJob job) {
    job.cancel();
    _pump();
  }

  void _pump() {
    if (_dispatching) return;
    _dispatching = true;
    scheduleMicrotask(() {
      try {
        while (activeCount < _maxConcurrent) {
          DownloadJob? next;
          for (final job in _jobs) {
            if (job.status == DownloadStatus.queued) {
              next = job;
              break;
            }
          }
          if (next == null) break;
          unawaited(next.start().whenComplete(() {
            _dispatching = false;
            _pump();
          }));
        }
      } finally {
        _dispatching = false;
      }
    });
  }
}
