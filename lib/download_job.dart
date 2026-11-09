import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'download_integrity.dart';
import 'download_errors.dart';
import 'download_state.dart';
import 'segmented_download_engine.dart';
import 'segmented_download_plan.dart';
import 'segmented_download_probe.dart';
import 'windows_file_ops.dart';

typedef OverwriteConfirmation = Future<bool> Function(File destination);

class DestinationSnapshot {
  const DestinationSnapshot({
    required this.exists,
    this.length,
    this.modified,
    this.sha256,
    this.identity,
  });

  final bool exists;
  final int? length;
  final DateTime? modified;
  final String? sha256;
  final String? identity;

  @override
  bool operator ==(Object other) =>
      other is DestinationSnapshot &&
      exists == other.exists &&
      length == other.length &&
      modified == other.modified &&
      sha256 == other.sha256 &&
      identity == other.identity;

  @override
  int get hashCode => Object.hash(exists, length, modified, sha256, identity);
}

class DownloadJob {
  DownloadJob({
    required this.url,
    required this.destinationPath,
    required this.onChanged,
    this.expectedSha256,
    this.stagingPath,
    this.wasSegmented = false,
    DownloadStatus initialStatus = DownloadStatus.queued,
    this.confirmOverwrite,
    this.timeouts = const DownloadTimeouts(),
    this.timeoutPhaseHook,
    HttpClient Function()? clientFactory,
  })  : _clientFactory = clientFactory ?? HttpClient.new,
        _statusMachine = DownloadStatusMachine(initial: initialStatus);

  final Uri url;
  final String destinationPath;
  final VoidCallback onChanged;
  final String? expectedSha256;
  final OverwriteConfirmation? confirmOverwrite;
  final DownloadTimeouts timeouts;
  final FutureOr<void> Function(DownloadFailureKind phase)? timeoutPhaseHook;
  final HttpClient Function() _clientFactory;
  final DownloadStatusMachine _statusMachine;
  int? historyId;
  String? stagingPath;
  bool wasSegmented;
  bool managedByQueue = false;

  HttpClient? _client;
  Future<void>? _activeRun;
  bool _cancelRequested = false;
  bool _pauseRequested = false;
  bool _segmentedThisRun = false;
  String? entityTag;
  DownloadStatus get status => _statusMachine.current;
  void transitionTo(DownloadStatus next) => _statusMachine.transitionTo(next);
  int receivedBytes = 0;
  int totalBytes = -1;
  String? errorMessage;
  DownloadFailureKind? failureKind;
  String integrityStatus = IntegrityStatus.notChecked.name;
  String? actualSha256;
  DateTime? integrityCheckedAt;
  double? get progress => totalBytes > 0
      ? (receivedBytes / totalBytes).clamp(0.0, 1.0).toDouble()
      : null;
  String get currentStagingPath => _stage.path;
  Future<void> get settled => _activeRun ?? Future<void>.value();

  File get _stage => File(stagingPath ??= _defaultStagePath());

  String _defaultStagePath() =>
      '$destinationPath.download-beast-${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}.part';

  void cancel() {
    if (status != DownloadStatus.downloading &&
        status != DownloadStatus.paused &&
        status != DownloadStatus.queued) {
      return;
    }
    _cancelRequested = true;
    _client?.close(force: true);
    if (status == DownloadStatus.queued || status == DownloadStatus.paused) {
      transitionTo(DownloadStatus.cancelled);
      _activeRun = _discardAfterCancellation();
    }
  }

  Future<void> _discardAfterCancellation() async {
    final cleanupError = await _discardStage();
    if (cleanupError != null) errorMessage = cleanupError;
    onChanged();
    _activeRun = null;
  }

  Future<void> pause() async {
    if (status != DownloadStatus.downloading || _cancelRequested) return;
    _pauseRequested = true;
    _client?.close(force: true);
    final running = _activeRun;
    if (running != null) await running;
  }

  Future<void> resume() async {
    if (status != DownloadStatus.paused) return;
    _pauseRequested = false;
    if (wasSegmented) {
      await _discardStage();
      receivedBytes = 0;
      entityTag = null;
      _segmentedThisRun = false;
    }
    transitionTo(DownloadStatus.queued);
    onChanged();
    if (!managedByQueue) await start();
  }

  Future<void> retry() async {
    if (status != DownloadStatus.failed &&
        status != DownloadStatus.integrityFailed) {
      return;
    }
    _cancelRequested = false;
    _pauseRequested = false;
    final cleanupError = await _discardStage();
    if (cleanupError != null) {
      transitionTo(DownloadStatus.failed);
      failureKind = DownloadFailureKind.filesystem;
      errorMessage = cleanupError;
      onChanged();
      return;
    }
    receivedBytes = 0;
    totalBytes = -1;
    entityTag = null;
    actualSha256 = null;
    integrityCheckedAt = null;
    integrityStatus = IntegrityStatus.notChecked.name;
    errorMessage = null;
    failureKind = null;
    wasSegmented = false;
    transitionTo(DownloadStatus.queued);
    onChanged();
    if (!managedByQueue) await start();
  }

  Future<void> start() {
    final active = _activeRun;
    if (active != null) return active;
    if (_cancelRequested ||
        status == DownloadStatus.completed ||
        status == DownloadStatus.integrityFailed) {
      return Future<void>.value();
    }
    if (status != DownloadStatus.queued) return Future<void>.value();
    transitionTo(DownloadStatus.downloading);
    stagingPath ??= _defaultStagePath();
    onChanged();
    final running = _run();
    _activeRun = running;
    return running;
  }

  Future<void> _run() async {
    final destination = File(destinationPath);
    final stage = _stage;
    IOSink? sink;
    try {
      if (_cancelRequested) throw const _DownloadCancelled();
      if (!await destination.parent.exists()) {
        throw FileSystemException(
            'Save directory does not exist.', destination.parent.path);
      }
      final initial = await _capture(destination);
      if (initial.exists && !await _askOverwrite(destination)) {
        throw const _DownloadCancelled();
      }

      final client = _clientFactory()
        ..connectionTimeout = timeouts.connection
        ..idleTimeout = timeouts.idleBody
        ..userAgent = 'DownloadBeast/1.0';
      _client = client;

      final existingStageBytes =
          await stage.exists() ? await stage.length() : 0;
      final canResume = existingStageBytes > 0 &&
          entityTag != null &&
          isStrongEntityTag(entityTag);
      if (existingStageBytes > 0 && !canResume) {
        await _discardStage();
        stagingPath = stage.path;
      }
      receivedBytes = canResume ? existingStageBytes : 0;

      final remote = await _headMetadata(client);
      totalBytes = remote.totalBytes ?? -1;
      if (!canResume &&
          !_segmentedThisRun &&
          isEligibleSegmentedSize(remote.totalBytes)) {
        final probe = await probeRangeSupport(
          client,
          url,
          connectionTimeout: timeouts.connection,
          responseHeaderTimeout: timeouts.responseHeader,
          idleBodyTimeout: timeouts.idleBody,
        );
        if (probe.supported &&
            probe.totalBytes == remote.totalBytes &&
            probe.entityTag == remote.entityTag) {
          wasSegmented = true;
          _segmentedThisRun = true;
          entityTag = probe.entityTag;
          await downloadSegmentedToFile(
            client: client,
            uri: url,
            destination: stage,
            totalBytes: probe.totalBytes!,
            entityTag: probe.entityTag!,
            shouldAbort: () => _cancelRequested || _pauseRequested,
            onProgress: (received, total) {
              receivedBytes = received;
              totalBytes = total;
              onChanged();
            },
          );
          if (_cancelRequested) throw const _DownloadCancelled();
          if (_pauseRequested) throw const _DownloadPaused();
          await _complete(destination, stage, probe.totalBytes!, initial);
          return;
        }
      }

      await _downloadSingle(client, stage, existingStageBytes, canResume);
      await _complete(destination, stage, totalBytes, initial);
    } on _DownloadPaused {
      await _closeSink(sink);
      sink = null;
      if (_segmentedThisRun || wasSegmented) {
        final cleanupError = await _discardStage();
        receivedBytes = 0;
        entityTag = null;
        errorMessage = cleanupError;
      }
      transitionTo(DownloadStatus.paused);
    } on _DownloadCancelled {
      await _closeSink(sink);
      sink = null;
      final cleanupError = await _discardStage();
      receivedBytes = 0;
      errorMessage = cleanupError;
      transitionTo(DownloadStatus.cancelled);
    } on _DestinationReplacementFailed catch (error) {
      await _closeSink(sink);
      sink = null;
      receivedBytes = 0;
      transitionTo(DownloadStatus.failed);
      failureKind = DownloadFailureKind.filesystem;
      errorMessage = error.message;
    } on DownloadTimeoutException catch (error) {
      await _closeSink(sink);
      sink = null;
      final cleanupError = await _discardStage();
      receivedBytes = 0;
      failureKind = error.kind;
      final timeoutMessage = switch (error.kind) {
        DownloadFailureKind.connectionTimeout =>
          'Connection timed out after 15 seconds.',
        DownloadFailureKind.responseHeaderTimeout =>
          'The server did not send response headers within 30 seconds.',
        DownloadFailureKind.idleBodyTimeout =>
          'The download stalled for 30 seconds without receiving data.',
        _ => 'Download timed out.',
      };
      errorMessage = cleanupError == null
          ? timeoutMessage
          : '$timeoutMessage $cleanupError';
      transitionTo(DownloadStatus.failed);
    } catch (error) {
      await _closeSink(sink);
      sink = null;
      if (_cancelRequested) {
        final cleanupError = await _discardStage();
        receivedBytes = 0;
        errorMessage = cleanupError;
        transitionTo(DownloadStatus.cancelled);
      } else if (_pauseRequested) {
        if (_segmentedThisRun || wasSegmented) {
          final cleanupError = await _discardStage();
          receivedBytes = 0;
          entityTag = null;
          errorMessage = cleanupError;
        }
        transitionTo(DownloadStatus.paused);
      } else {
        final cleanupError = await _discardStage();
        receivedBytes = 0;
        transitionTo(DownloadStatus.failed);
        errorMessage = [
          _describeError(error),
          if (cleanupError != null) cleanupError,
        ].join(' ');
        failureKind = _failureKind(error);
      }
    } finally {
      await _closeSink(sink);
      _client?.close(force: true);
      _client = null;
      _activeRun = null;
      onChanged();
    }
  }

  Future<void> _downloadSingle(
    HttpClient client,
    File stage,
    int existingBytes,
    bool canResume,
  ) async {
    await _beforeTimeoutPhase(DownloadFailureKind.connectionTimeout);
    final request = await client.getUrl(url).timeout(
          timeouts.connection,
          onTimeout: () => throw const DownloadTimeoutException(
              DownloadFailureKind.connectionTimeout),
        );
    request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    if (canResume) {
      request.headers
        ..set(HttpHeaders.rangeHeader, 'bytes=$existingBytes-')
        ..set(HttpHeaders.ifRangeHeader, entityTag!);
    }
    await _beforeTimeoutPhase(DownloadFailureKind.responseHeaderTimeout);
    final response = await request.close().timeout(
          timeouts.responseHeader,
          onTimeout: () => throw const DownloadTimeoutException(
              DownloadFailureKind.responseHeaderTimeout),
        );
    if (_cancelRequested) throw const _DownloadCancelled();
    if (_pauseRequested) throw const _DownloadPaused();

    var append = false;
    final responseTag = response.headers.value(HttpHeaders.etagHeader);
    final length = response.contentLength;
    if (response.statusCode == HttpStatus.partialContent && canResume) {
      final range = parseContentRange(
          response.headers.value(HttpHeaders.contentRangeHeader));
      if (responseTag != entityTag) {
        await response.drain<void>();
        throw const HttpException(
            'The remote file changed; resume was rejected.');
      }
      if (range == null ||
          range.start != existingBytes ||
          !isStrongEntityTag(entityTag) ||
          (length >= 0 && length != range.length)) {
        await response.drain<void>();
        throw const HttpException(
            'Server returned an invalid or unvalidated Content-Range.');
      }
      totalBytes = range.total;
      append = true;
    } else if (response.statusCode == HttpStatus.ok) {
      receivedBytes = 0;
      totalBytes = length;
    } else {
      await response.drain<void>();
      throw HttpException('Server returned HTTP ${response.statusCode}.');
    }
    entityTag = isStrongEntityTag(responseTag) ? responseTag : null;
    final output =
        stage.openWrite(mode: append ? FileMode.append : FileMode.write);
    var receivedThisResponse = 0;
    try {
      await _beforeTimeoutPhase(DownloadFailureKind.idleBodyTimeout);
      await for (final chunk in response.timeout(
        timeouts.idleBody,
        onTimeout: (sink) => sink.addError(const DownloadTimeoutException(
            DownloadFailureKind.idleBodyTimeout)),
      )) {
        if (_cancelRequested) throw const _DownloadCancelled();
        if (_pauseRequested) throw const _DownloadPaused();
        output.add(chunk);
        receivedThisResponse += chunk.length;
        receivedBytes += chunk.length;
        onChanged();
      }
      await output.flush();
    } finally {
      await output.close();
    }
    if (totalBytes >= 0 && receivedBytes != totalBytes) {
      throw HttpException(
          'Downloaded file length mismatch: expected $totalBytes bytes, received $receivedBytes.');
    }
    if (canResume && length >= 0 && receivedThisResponse != length) {
      throw const HttpException(
          'Response body length did not match Content-Length.');
    }
  }

  Future<({int? totalBytes, String? entityTag})> _headMetadata(
      HttpClient client) async {
    try {
      await _beforeTimeoutPhase(DownloadFailureKind.connectionTimeout);
      final request = await client.openUrl('HEAD', url).timeout(
            timeouts.connection,
            onTimeout: () => throw const DownloadTimeoutException(
                DownloadFailureKind.connectionTimeout),
          );
      await _beforeTimeoutPhase(DownloadFailureKind.responseHeaderTimeout);
      final response = await request.close().timeout(
            timeouts.responseHeader,
            onTimeout: () => throw const DownloadTimeoutException(
                DownloadFailureKind.responseHeaderTimeout),
          );
      await response.drain<void>();
      if (response.statusCode < 200 || response.statusCode >= 400) {
        return (totalBytes: null, entityTag: null);
      }
      final length = response.contentLength;
      return (
        totalBytes: length >= 0 ? length : null,
        entityTag: response.headers.value(HttpHeaders.etagHeader)
      );
    } on DownloadTimeoutException {
      rethrow;
    } on Object {
      return (totalBytes: null, entityTag: null);
    }
  }

  Future<void> _beforeTimeoutPhase(DownloadFailureKind phase) async {
    await timeoutPhaseHook?.call(phase);
  }

  Future<void> _complete(
    File destination,
    File stage,
    int expectedLength,
    DestinationSnapshot initial,
  ) async {
    if (!await stage.exists()) {
      throw const FileSystemException('Staged download is missing.');
    }
    final actualLength = await stage.length();
    if (expectedLength >= 0 && actualLength != expectedLength) {
      throw HttpException(
          'Downloaded file length mismatch: expected $expectedLength bytes, received $actualLength.');
    }
    receivedBytes = actualLength;
    final verification =
        await verifySha256(stage, expectedSha256: expectedSha256);
    integrityStatus = verification.status.name;
    actualSha256 = verification.actualSha256;
    integrityCheckedAt = DateTime.now();
    if (verification.status == IntegrityStatus.mismatch) {
      final cleanupError = await _discardStage();
      transitionTo(DownloadStatus.integrityFailed);
      failureKind = DownloadFailureKind.integrity;
      errorMessage = cleanupError == null
          ? 'SHA-256 does not match. The staged download was discarded.'
          : 'SHA-256 does not match, and staged data could not be removed. $cleanupError';
      return;
    }

    var approved = initial;
    for (var attempt = 0; attempt < 5; attempt++) {
      final current = await _capture(destination);
      if (current != approved) {
        if (!await _askOverwrite(destination)) {
          throw const _DownloadCancelled();
        }
        approved = current;
        continue;
      }
      await _replaceStage(stage, destination, current);
      transitionTo(DownloadStatus.completed);
      return;
    }
    throw FileSystemException(
        'Destination changed repeatedly during overwrite confirmation.',
        destination.path);
  }

  Future<DestinationSnapshot> _capture(File file) async {
    if (!await file.exists()) return const DestinationSnapshot(exists: false);
    final stat = await file.stat();
    return DestinationSnapshot(
      exists: true,
      length: stat.size,
      modified: stat.modified,
      sha256: await sha256File(file),
      identity: await WindowsFileOperations.identity(file),
    );
  }

  Future<bool> _askOverwrite(File file) async =>
      await confirmOverwrite?.call(file) ?? false;

  Future<void> _replaceStage(
      File stage, File destination, DestinationSnapshot snapshot) async {
    final backup = File(
        '${destination.path}.download-beast-backup-${DateTime.now().microsecondsSinceEpoch}');
    try {
      await WindowsFileOperations.replace(
        source: stage,
        destination: destination,
        destinationExists: snapshot.exists,
        backup: backup,
        expectedIdentity: snapshot.identity,
      );
    } on Object catch (error) {
      final backupExists = await backup.exists();
      throw _DestinationReplacementFailed(
        'Could not safely replace the destination. The staged file remains at ${stage.path}.${backupExists ? ' The original is recoverable at ${backup.path}.' : ' The existing destination was preserved if it existed.'} Cause: $error',
      );
    }
  }

  Future<String?> _discardStage() async {
    try {
      if (await _stage.exists()) await _stage.delete();
      stagingPath = null;
      return null;
    } on FileSystemException catch (error) {
      return 'Could not clean temporary download data at ${_stage.path}: ${error.message}';
    }
  }

  Future<void> _closeSink(IOSink? sink) async {
    if (sink == null) return;
    try {
      await sink.close();
    } on Object {/* preserve primary transfer error */}
  }

  DownloadFailureKind _failureKind(Object error) {
    if (error is HttpException) return DownloadFailureKind.http;
    if (error is SocketException) return DownloadFailureKind.network;
    if (error is FileSystemException) return DownloadFailureKind.filesystem;
    return DownloadFailureKind.protocol;
  }

  String _describeError(Object error) {
    if (error is HttpException) return error.message;
    if (error is SocketException) return 'Network error: ${error.message}.';
    if (error is HandshakeException) {
      return 'Secure connection failed: ${error.message}.';
    }
    if (error is FileSystemException) return 'File error: ${error.message}.';
    if (error is DownloadTimeoutException) return 'Download timed out.';
    return 'Unexpected download error (${error.runtimeType}).';
  }
}

class _DestinationReplacementFailed implements Exception {
  const _DestinationReplacementFailed(this.message);
  final String message;
}

class _DownloadCancelled implements Exception {
  const _DownloadCancelled();
}

class _DownloadPaused implements Exception {
  const _DownloadPaused();
}
