class TransferRateEstimator {
  TransferRateEstimator({this.window = const Duration(seconds: 5)});
  final Duration window;
  final List<(DateTime time, int bytes)> _samples = [];
  int _lastBytes = 0;

  void record(int totalBytes, DateTime at) {
    if (totalBytes < _lastBytes) {
      _samples.clear();
      _lastBytes = totalBytes;
      return;
    }
    if (totalBytes <= _lastBytes) return;
    final delta = totalBytes - _lastBytes;
    _lastBytes = totalBytes;
    _samples.add((at, delta));
    _trim(at);
  }

  double? bytesPerSecond(DateTime now) {
    _trim(now);
    if (_samples.length < 3) return null;
    final bytes = _samples.fold<int>(0, (sum, item) => sum + item.$2);
    final elapsed = now.difference(_samples.first.$1).inMicroseconds /
        Duration.microsecondsPerSecond;
    if (elapsed <= 0) return null;
    return bytes / elapsed;
  }

  void _trim(DateTime now) {
    final cutoff = now.subtract(window);
    _samples.removeWhere((sample) => sample.$1.isBefore(cutoff));
  }
}
