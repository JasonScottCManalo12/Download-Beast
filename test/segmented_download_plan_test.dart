import 'package:download_beast/segmented_download_plan.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('segmentation threshold is inclusive at exactly 16 MiB', () {
    expect(isEligibleSegmentedSize(minimumSegmentedDownloadBytes - 1), isFalse);
    expect(isEligibleSegmentedSize(minimumSegmentedDownloadBytes), isTrue);
    expect(isEligibleSegmentedSize(minimumSegmentedDownloadBytes + 1), isTrue);
    expect(isEligibleSegmentedSize(null), isFalse);
  });

  group('planSegments', () {
    test('covers the entire representation with contiguous ranges', () {
      final ranges = planSegments(totalBytes: 10);

      expect(ranges, const [
        SegmentRange(start: 0, end: 3),
        SegmentRange(start: 4, end: 6),
        SegmentRange(start: 7, end: 9),
      ]);
      expect(ranges.map((range) => range.length), [4, 3, 3]);
      expect(ranges.first.start, 0);
      expect(ranges.last.end, 9);
    });

    test('uses one range only when three non-empty ranges cannot be formed',
        () {
      expect(
        planSegments(totalBytes: 2),
        const [SegmentRange(start: 0, end: 1)],
      );
    });

    test('distributes remainder bytes to the earliest ranges deterministically',
        () {
      expect(planSegments(totalBytes: 11), const [
        SegmentRange(start: 0, end: 3),
        SegmentRange(start: 4, end: 7),
        SegmentRange(start: 8, end: 10),
      ]);
    });

    test('returns an unmodifiable range list', () {
      final ranges = planSegments(totalBytes: 3);
      expect(() => ranges.add(const SegmentRange(start: 2, end: 2)),
          throwsUnsupportedError);
    });

    test('rejects unknown or non-positive lengths', () {
      expect(() => planSegments(totalBytes: 0), throwsArgumentError);
      expect(() => planSegments(totalBytes: -1), throwsArgumentError);
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

  group('isValidRangeProbe', () {
    test('accepts only a valid one-byte partial response with a strong ETag',
        () {
      expect(
        isValidRangeProbe(
          statusCode: 206,
          contentRange: 'bytes 0-0/100',
          bodyLength: 1,
          entityTag: '"stable-v1"',
        ),
        isTrue,
      );
    });

    test('rejects HTTP 200 even if it supplies a strong ETag', () {
      expect(
        isValidRangeProbe(
          statusCode: 200,
          contentRange: 'bytes 0-0/100',
          bodyLength: 1,
          entityTag: '"stable-v1"',
        ),
        isFalse,
      );
    });

    test('rejects wrong range, total, body length, or weak ETag', () {
      final invalidProbes = <({
        int statusCode,
        String? contentRange,
        int bodyLength,
        String? entityTag,
      })>[
        (
          statusCode: 206,
          contentRange: 'bytes 1-1/100',
          bodyLength: 1,
          entityTag: '"v1"'
        ),
        (
          statusCode: 206,
          contentRange: 'bytes 0-1/100',
          bodyLength: 1,
          entityTag: '"v1"'
        ),
        (
          statusCode: 206,
          contentRange: 'bytes 0-0/*',
          bodyLength: 1,
          entityTag: '"v1"'
        ),
        (
          statusCode: 206,
          contentRange: 'bytes 0-0/100',
          bodyLength: 0,
          entityTag: '"v1"'
        ),
        (
          statusCode: 206,
          contentRange: 'bytes 0-0/100',
          bodyLength: 2,
          entityTag: '"v1"'
        ),
        (
          statusCode: 206,
          contentRange: 'bytes 0-0/100',
          bodyLength: 1,
          entityTag: 'W/"v1"'
        ),
        (
          statusCode: 206,
          contentRange: 'invalid',
          bodyLength: 1,
          entityTag: '"v1"'
        ),
      ];

      for (final probe in invalidProbes) {
        expect(
          isValidRangeProbe(
            statusCode: probe.statusCode,
            contentRange: probe.contentRange,
            bodyLength: probe.bodyLength,
            entityTag: probe.entityTag,
          ),
          isFalse,
          reason: 'Should reject $probe',
        );
      }
    });
  });
}
