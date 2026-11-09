import 'package:download_beast/transfer_rate.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('rate requires three non-zero samples within the five-second window',
      () {
    final estimator = TransferRateEstimator();
    final start = DateTime.utc(2026, 1, 1);
    estimator.record(100, start);
    expect(estimator.bytesPerSecond(start.add(const Duration(seconds: 1))),
        isNull);
    estimator.record(300, start.add(const Duration(seconds: 1)));
    expect(estimator.bytesPerSecond(start.add(const Duration(seconds: 2))),
        isNull);
    estimator.record(600, start.add(const Duration(seconds: 2)));
    expect(estimator.bytesPerSecond(start.add(const Duration(seconds: 3))),
        isNotNull);
    expect(
      estimator.bytesPerSecond(start.add(const Duration(seconds: 8))),
      isNull,
    );
  });
}
