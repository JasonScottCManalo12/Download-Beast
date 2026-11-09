/// Pure planning and response-parsing helpers for segmented downloads.
///
/// This file does not perform network or filesystem operations. The download
/// engine must still validate each response body and representation validator
/// before accepting a segment.
const int defaultSegmentWorkerCount = 3;
const int defaultMaxConcurrentSegments = 3;
const int minimumSegmentedDownloadBytes = 16 * 1024 * 1024;

bool isEligibleSegmentedSize(int? totalBytes) =>
    totalBytes != null && totalBytes >= minimumSegmentedDownloadBytes;

/// An inclusive byte range within a known-length representation.
class SegmentRange {
  const SegmentRange({required this.start, required this.end})
      : assert(start >= 0),
        assert(end >= start);

  final int start;
  final int end;

  int get length => end - start + 1;

  @override
  bool operator ==(Object other) =>
      other is SegmentRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'bytes=$start-$end';
}

/// Creates contiguous, non-overlapping ranges covering [0, totalBytes - 1].
///
/// Invalid or unknown lengths must use the single-connection download path.
List<SegmentRange> planSegments({
  required int totalBytes,
}) {
  if (totalBytes <= 0) {
    throw ArgumentError.value(totalBytes, 'totalBytes', 'Must be positive.');
  }
  final workers =
      totalBytes >= defaultSegmentWorkerCount ? defaultSegmentWorkerCount : 1;
  final quotient = totalBytes ~/ workers;
  final remainder = totalBytes % workers;
  final ranges = <SegmentRange>[];
  var start = 0;
  for (var index = 0; index < workers; index++) {
    final length = quotient + (index < remainder ? 1 : 0);
    if (length == 0) continue;
    ranges.add(SegmentRange(start: start, end: start + length - 1));
    start += length;
  }
  return List<SegmentRange>.unmodifiable(ranges);
}

/// Parsed value of an HTTP Content-Range header for a byte-range response.
class ParsedContentRange {
  const ParsedContentRange({
    required this.start,
    required this.end,
    required this.total,
  });

  final int start;
  final int end;
  final int total;

  int get length => end - start + 1;
}

/// Parses a complete Content-Range value such as \`bytes 0-99/1000\`.
///
/// Returns null for unknown totals, malformed values, unsatisfiable ranges,
/// reversed ranges, or ranges that extend beyond the representation.
ParsedContentRange? parseContentRange(String? value) {
  if (value == null) return null;
  final match = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$').firstMatch(value.trim());
  if (match == null) return null;

  final start = int.tryParse(match.group(1)!);
  final end = int.tryParse(match.group(2)!);
  final total = int.tryParse(match.group(3)!);
  if (start == null || end == null || total == null) return null;
  if (total <= 0 || start < 0 || end < start || end >= total) return null;

  return ParsedContentRange(start: start, end: end, total: total);
}

/// Returns true only for a syntactically strong, quoted HTTP entity-tag.
///
/// Weak ETags (for example, W/"version-1") cannot safely pin parallel ranges.
bool isStrongEntityTag(String? value) {
  if (value == null) return false;
  final tag = value.trim();
  return RegExp(r'^"[^"\x00-\x20\x7F]*"$').hasMatch(tag);
}

/// Validates the headers and body length required for a one-byte range probe.
///
/// This is a pure validation helper; the HTTP layer must still consume the
/// response body, close the response, and decide whether to fall back.
bool isValidRangeProbe({
  required int statusCode,
  required String? contentRange,
  required int bodyLength,
  required String? entityTag,
}) {
  final parsed = parseContentRange(contentRange);
  return statusCode == 206 &&
      parsed != null &&
      parsed.start == 0 &&
      parsed.end == 0 &&
      parsed.total > 0 &&
      bodyLength == 1 &&
      isStrongEntityTag(entityTag);
}
