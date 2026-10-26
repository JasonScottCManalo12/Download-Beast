/// Pure planning and response-parsing helpers for segmented downloads.
///
/// This file does not perform network or filesystem operations. The download
/// engine must still validate each response body and representation validator
/// before accepting a segment.
const int defaultSegmentSizeBytes = 4 * 1024 * 1024;
const int defaultMaxConcurrentSegments = 3;
const int minimumSegmentedDownloadBytes = 8 * 1024 * 1024;

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
  int segmentSizeBytes = defaultSegmentSizeBytes,
}) {
  if (totalBytes <= 0) {
    throw ArgumentError.value(totalBytes, 'totalBytes', 'Must be positive.');
  }
  if (segmentSizeBytes <= 0) {
    throw ArgumentError.value(
      segmentSizeBytes,
      'segmentSizeBytes',
      'Must be positive.',
    );
  }

  final ranges = <SegmentRange>[];
  var start = 0;
  while (start < totalBytes) {
    final remaining = totalBytes - start;
    final length = remaining < segmentSizeBytes ? remaining : segmentSizeBytes;
    final end = start + length - 1;
    ranges.add(SegmentRange(start: start, end: end));
    start = end + 1;
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
  final match =
      RegExp(r'^bytes (\d+)-(\d+)/(\d+)$').firstMatch(value.trim());
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
