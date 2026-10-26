import 'dart:io';

import 'segmented_download_plan.dart';

/// Thrown when the owning DownloadJob asks a segmented transfer to stop.
class SegmentedDownloadAborted implements Exception {
  const SegmentedDownloadAborted();
}

/// Downloads a known-length representation in parallel to temporary segment
/// files, then assembles the verified byte ranges in order.
///
/// The caller supplies lifecycle callbacks so DownloadJob can expose progress
/// and cancellation without coupling this engine to Flutter UI state.
Future<void> downloadSegmentedToFile({
  required HttpClient client,
  required Uri uri,
  required File destination,
  required int totalBytes,
  required String entityTag,
  int segmentSizeBytes = defaultSegmentSizeBytes,
  int maxConcurrentSegments = defaultMaxConcurrentSegments,
  bool Function()? shouldAbort,
  void Function(int receivedBytes, int totalBytes)? onProgress,
}) async {
  if (totalBytes <= 0) {
    throw ArgumentError.value(totalBytes, 'totalBytes', 'Must be positive.');
  }
  if (!isStrongEntityTag(entityTag)) {
    throw ArgumentError.value(
      entityTag,
      'entityTag',
      'Segmented downloads require a strong ETag.',
    );
  }
  if (maxConcurrentSegments < 1 ||
      maxConcurrentSegments > defaultMaxConcurrentSegments) {
    throw ArgumentError.value(
      maxConcurrentSegments,
      'maxConcurrentSegments',
      'Must be between 1 and $defaultMaxConcurrentSegments.',
    );
  }

  final ranges = planSegments(
    totalBytes: totalBytes,
    segmentSizeBytes: segmentSizeBytes,
  );
  final parent = await destination.parent.create(recursive: true);
  final workDirectory = await parent.createTemp('.download-beast-segments-');
  final assembled = File(
    '${parent.path}${Platform.pathSeparator}.download-beast-${DateTime.now().microsecondsSinceEpoch}.tmp',
  );

  try {
    var nextRangeIndex = 0;
    var completedBytes = 0;

    void checkAborted() {
      if (shouldAbort?.call() ?? false) {
        throw const SegmentedDownloadAborted();
      }
    }

    Future<void> worker() async {
      while (true) {
        checkAborted();
        final index = nextRangeIndex++;
        if (index >= ranges.length) return;
        final range = ranges[index];
        final segmentFile = File(
          '${workDirectory.path}${Platform.pathSeparator}segment-$index.part',
        );
        final request = await client.getUrl(uri);
        request.headers
          ..set(HttpHeaders.rangeHeader, 'bytes=${range.start}-${range.end}')
          ..set(HttpHeaders.ifMatchHeader, entityTag)
          ..set(HttpHeaders.acceptEncodingHeader, 'identity');

        final response = await request.close();
        final parsed = parseContentRange(
          response.headers.value(HttpHeaders.contentRangeHeader),
        );
        final responseTag = response.headers.value(HttpHeaders.etagHeader);
        if (response.statusCode != HttpStatus.partialContent ||
            parsed == null ||
            parsed.start != range.start ||
            parsed.end != range.end ||
            parsed.total != totalBytes ||
            responseTag?.trim() != entityTag.trim() ||
            (response.contentLength >= 0 &&
                response.contentLength != range.length)) {
          await response.drain<void>();
          throw HttpException(
            'Server returned an invalid response for segment '
            '${range.start}-${range.end}.',
            uri: uri,
          );
        }

        IOSink? sink;
        var written = 0;
        try {
          sink = segmentFile.openWrite();
          await for (final chunk in response) {
            checkAborted();
            written += chunk.length;
            if (written > range.length) {
              throw const HttpException('Segment body exceeded its declared range.');
            }
            sink.add(chunk);
            onProgress?.call(completedBytes + written, totalBytes);
          }
          await sink.flush();
          await sink.close();
          sink = null;
        } finally {
          if (sink != null) {
            try {
              await sink.close();
            } on Object {
              // Preserve the original stream or validation error.
            }
          }
        }
        if (written != range.length) {
          throw HttpException(
            'Segment length mismatch: expected ${range.length}, received $written.',
            uri: uri,
          );
        }
        completedBytes += written;
        onProgress?.call(completedBytes, totalBytes);
      }
    }

    final workerCount = maxConcurrentSegments < ranges.length
        ? maxConcurrentSegments
        : ranges.length;
    await Future.wait(List<Future<void>>.generate(workerCount, (_) => worker()));
    checkAborted();

    final output = assembled.openWrite();
    try {
      for (var index = 0; index < ranges.length; index++) {
        checkAborted();
        await output.addStream(
          File(
            '${workDirectory.path}${Platform.pathSeparator}segment-$index.part',
          ).openRead(),
        );
      }
      await output.flush();
    } finally {
      await output.close();
    }

    if (await assembled.length() != totalBytes) {
      throw const HttpException('Assembled file length does not match the representation size.');
    }

    File? backup;
    if (await destination.exists()) {
      backup = File(
        '${destination.path}.download-beast-backup-${DateTime.now().microsecondsSinceEpoch}',
      );
      await destination.rename(backup.path);
    }

    try {
      await assembled.rename(destination.path);
    } on Object {
      if (backup != null && await backup.exists() && !await destination.exists()) {
        try {
          await backup.rename(destination.path);
          backup = null;
        } on Object {
          // Leave the backup at its recovery path for manual restoration.
        }
      }
      rethrow;
    }

    if (backup != null && await backup.exists()) {
      await backup.delete();
    }
    onProgress?.call(totalBytes, totalBytes);
  } finally {
    if (await assembled.exists()) await assembled.delete();
    if (await workDirectory.exists()) {
      await workDirectory.delete(recursive: true);
    }
  }
}
