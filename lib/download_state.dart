/// User-visible lifecycle states stored by both the task and history layers.
enum DownloadStatus {
  queued,
  downloading,
  paused,
  completed,
  integrityFailed,
  failed,
  cancelled,
  interrupted,
}

/// Validates transitions so UI or persistence code cannot invent task states.
class DownloadStatusMachine {
  DownloadStatusMachine({DownloadStatus initial = DownloadStatus.queued})
      : _current = initial;

  DownloadStatus _current;
  DownloadStatus get current => _current;

  static const Map<DownloadStatus, Set<DownloadStatus>> _allowed = {
    DownloadStatus.queued: {
      DownloadStatus.downloading,
      DownloadStatus.cancelled,
      DownloadStatus.failed,
    },
    DownloadStatus.downloading: {
      DownloadStatus.paused,
      DownloadStatus.completed,
      DownloadStatus.integrityFailed,
      DownloadStatus.failed,
      DownloadStatus.cancelled,
    },
    DownloadStatus.paused: {
      DownloadStatus.queued,
      DownloadStatus.downloading,
      DownloadStatus.cancelled,
      DownloadStatus.failed,
    },
    DownloadStatus.failed: {DownloadStatus.queued},
    DownloadStatus.integrityFailed: {DownloadStatus.queued},
    DownloadStatus.interrupted: {DownloadStatus.queued, DownloadStatus.failed},
    DownloadStatus.completed: {},
    DownloadStatus.cancelled: {},
  };

  void transitionTo(DownloadStatus next) {
    if (next == _current) return;
    if (!_allowed[_current]!.contains(next)) {
      throw StateError('Invalid download transition: $_current -> $next.');
    }
    _current = next;
  }
}
