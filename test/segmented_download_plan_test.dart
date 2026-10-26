import 'package:download_beast/segmented_download_plan.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('planSegments', () {
    test('covers the entire representation with contiguous ranges', () {
      final ranges = planSegments(totalBytes: 10, segmentSizeBytes: 4);

      expect(ranges, const [
        SegmentRange(start: 0, end: 3),
        SegmentRange(start: 4, end: 7),
        SegmentRange(start: 8, end: 9),
      ]);
      expect(ranges.map((range) => range.length), [4, 4, 2]);
      expect(ranges.first.start, 0);
      expect(ranges.last.end, 9);
    });

    test('creates one range when the file fits in one segment', () {
      expect(
        planSegments(totalBytes: 4, segmentSizeBytes: 4),
        const [SegmentRange(start: 0, end: 3)],
      );
    });

    test('uses the configured default segment size', () {
      final ranges = planSegments(
        totalBytes: defaultSegmentSizeBytes + 1,
      );

      expect(ranges, [
        const SegmentRange(start: 0, end: defaultSegmentSizeBytes - 1),
        const SegmentRange(
          start: defaultSegmentSizeBytes,
          end: defaultSegmentSizeBytes,
        ),
      ]);
    });

    test('returns an unmodifiable range list', () {
      final ranges = planSegments(totalBytes: 2);
      expect(() => ranges.add(const SegmentRange(start: 2, end: 2)),
          throwsUnsupportedError);
    });

    test('rejects unknown or non-positive lengths and segment sizes', () {
      expect(() => planSegments(totalBytes: 0), throwsArgumentError);
      expect(() => planSegments(totalBytes: -1), throwsArgumentError);
      expect(
        () => planSegments(totalBytes: 10, segmentSizeBytes: 0),
        throwsArgumentError,
      );
      expect(
        () => planSegments(totalBytes: 10, segmentSizeBytes: -1),
        throwsArgumentError,
      );
    });
  });

  group('parseContentRange', () {
    test('parses a valid inclusive byte range', () {
      final parsed = parseContentRange('bytes 10-19/100');

      expect(parsed, isNotNull);
      expect(parsed!.start, 10);
      expect(parsed.end, 19);
      expect(parsed.total, 100);
      expect(parsed.length, 10);
    });

    test('accepts a one-byte probe response', () {
      final parsed = parseContentRange('bytes 0-0/100');

      expect(parsed, isNotNull);
      expect(parsed!.length, 1);
      expect(parsed.total, 100);
    });

    test('rejects malformed, unknown-total, reversed, and out-of-bounds ranges',
        () {
      for (final value in <String?>[
        null,
        '',
        'bytes 0-1/*',
        'bytes 0-1/0',
        'bytes 2-1/10',
        'bytes 0-10/10',
        'items 0-1/10',
        'bytes 0-1/10 extra',
        'bytes -1-1/10',
        'bytes 0-1/ten',
      ]) {
        expect(
          parseContentRange(value),
          isNull,
          reason: 'Should reject Content-Range: $value',
        );
      }
    });
  });

  group('isStrongEntityTag', () {
    test('accepts quoted strong entity tags', () {
      expect(isStrongEntityTag('"v1"'), isTrue);
      expect(isStrongEntityTag('""'), isTrue);
    });

    test('rejects missing, weak, unquoted, and malformed tags', () {
      for (final value in <String?>[
        null,
        '',
        'v1',
        'W/"v1"',
        'w/"v1"',
        '"has a space"',
        '"unclosed',
        'unopened"',
        '"contains"quote"',
        '"contains\nnewline"',
      ]) {
        expect(
          isStrongEntityTag(value),
          isFalse,
          reason: 'Should reject ETag: $value',
        );
      }
    });
  });
}
