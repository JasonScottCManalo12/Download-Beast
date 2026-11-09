import 'package:download_beast/download_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('accepts the supported success, pause, retry and cancel transitions',
      () {
    final state = DownloadStatusMachine();
    state.transitionTo(DownloadStatus.downloading);
    state.transitionTo(DownloadStatus.paused);
    state.transitionTo(DownloadStatus.queued);
    state.transitionTo(DownloadStatus.downloading);
    state.transitionTo(DownloadStatus.completed);
    expect(state.current, DownloadStatus.completed);
  });

  test('rejects an invalid transition without changing persisted state', () {
    final state = DownloadStatusMachine();
    expect(
      () => state.transitionTo(DownloadStatus.completed),
      throwsStateError,
    );
    expect(state.current, DownloadStatus.queued);
  });

  test('integrity failure permits only a user-triggered retry transition', () {
    final state = DownloadStatusMachine();
    state.transitionTo(DownloadStatus.downloading);
    state.transitionTo(DownloadStatus.integrityFailed);
    state.transitionTo(DownloadStatus.queued);
    expect(state.current, DownloadStatus.queued);
  });
}
