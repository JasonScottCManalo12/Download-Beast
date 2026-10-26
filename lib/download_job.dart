import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'download_integrity.dart';
import 'segmented_download_engine.dart';
import 'segmented_download_plan.dart';

enum DownloadStatus { downloading, paused, completed, failed, cancelled }

class DownloadJob {
  DownloadJob({required this.url, required this.destinationPath, required this.onChanged, this.expectedSha256});
  final Uri url;
  final String destinationPath;
  final VoidCallback onChanged;
  final String? expectedSha256;
  int? historyId;
  HttpClient? _client;
  Future<void>? _activeRun;
  bool _cancelRequested = false;
  bool _pauseRequested = false;
  String? entityTag;
  DownloadStatus status = DownloadStatus.downloading;
  int receivedBytes = 0;
  int totalBytes = -1;
  String? errorMessage;
  String integrityStatus = IntegrityStatus.notChecked.name;
  String? actualSha256;
  DateTime? integrityCheckedAt;
  double? get progress => totalBytes > 0 ? (receivedBytes / totalBytes).clamp(0.0, 1.0).toDouble() : null;
  void cancel() {
    if ((status != DownloadStatus.downloading && status != DownloadStatus.paused) || _cancelRequested) return;
    final wasPaused = status == DownloadStatus.paused;
    _cancelRequested = true;
    _client?.close(force: true);
    if (wasPaused) {
      status = DownloadStatus.cancelled;
      unawaited(_deletePartialFile(File(destinationPath)).then((_) { receivedBytes = 0; onChanged(); }));
    }
    onChanged();
  }
  Future<void> pause() async {
    if (status != DownloadStatus.downloading || _cancelRequested) return;
    _pauseRequested = true;
    _client?.close(force: true);
    final running = _activeRun;
    if (running != null) await running;
  }
  Future<void> resume() async {
    if (status != DownloadStatus.paused || _cancelRequested) return;
    _pauseRequested = false;
    await start();
  }
  Future<void> retry() async {
    if (status != DownloadStatus.failed || _cancelRequested) return;
    status = DownloadStatus.downloading;
    receivedBytes = 0;
    totalBytes = -1;
    entityTag = null;
    errorMessage = null;
    onChanged();
    await start();
  }
  Future<void> start() {
    final active = _activeRun;
    if (active != null) return active;
    if (_cancelRequested || status == DownloadStatus.completed) return Future<void>.value();
    final running = _run();
    _activeRun = running;
    return running;
  }
  Future<void> _run() async {
    IOSink? sink;
    final output = File(destinationPath);
    try {
      if (_cancelRequested) throw const _DownloadCancelled();
      if (_pauseRequested) throw const _DownloadPaused();
      final existingBytes = await output.exists() ? await output.length() : 0;
      receivedBytes = existingBytes;
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 20)
        ..idleTimeout = const Duration(seconds: 30)
        ..userAgent = 'DownloadBeast/0.1';
      _client = client;
      if (existingBytes == 0) {
        final segmented = await _trySegmentedDownload(client, output);
        if (segmented) return;
      }
      final request = await client.getUrl(url);
      if (existingBytes > 0) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$existingBytes-');
        if (entityTag != null) request.headers.set(HttpHeaders.ifRangeHeader, entityTag!);
      }
      if (_cancelRequested) throw const _DownloadCancelled();
      if (_pauseRequested) throw const _DownloadPaused();
      final response = await request.close();
      if (_cancelRequested) throw const _DownloadCancelled();
      if (_pauseRequested) throw const _DownloadPaused();
      var append = false;
      if (response.statusCode == HttpStatus.partialContent) {
        final contentRange = response.headers.value(HttpHeaders.contentRangeHeader);
        final match = contentRange == null ? null : RegExp(r'^bytes (\d+)-(\d+)/(\d+)$').firstMatch(contentRange);
        if (existingBytes <= 0 || match == null) {
          await response.drain<void>();
          throw const HttpException('Server returned an invalid Content-Range.');
        }
        final start = int.parse(match.group(1)!);
        final end = int.parse(match.group(2)!);
        final total = int.parse(match.group(3)!);
        if (start != existingBytes || end < start || end >= total || (response.contentLength >= 0 && response.contentLength != end - start + 1)) {
          await response.drain<void>();
          throw const HttpException('Server returned a mismatched Content-Range.');
        }
        final responseEtag = response.headers.value(HttpHeaders.etagHeader);
        if (entityTag != null && responseEtag != entityTag) {
          await response.drain<void>();
          throw const HttpException('The remote file changed; resume was rejected.');
        }
        totalBytes = total;
        append = true;
      } else if (response.statusCode == HttpStatus.ok) {
        receivedBytes = 0;
        totalBytes = response.contentLength;
      } else {
        await response.drain<void>();
        throw HttpException('Server returned HTTP ${response.statusCode}.');
      }
      entityTag = response.headers.value(HttpHeaders.etagHeader) ?? entityTag;
      sink = output.openWrite(mode: append ? FileMode.append : FileMode.write);
      await for (final chunk in response) {
        if (_cancelRequested) throw const _DownloadCancelled();
        if (_pauseRequested) throw const _DownloadPaused();
        sink.add(chunk);
        receivedBytes += chunk.length;
        onChanged();
      }
      if (_cancelRequested) throw const _DownloadCancelled();
      if (_pauseRequested) throw const _DownloadPaused();
      await sink.flush();
      await sink.close();
      sink = null;
      if (totalBytes >= 0 && receivedBytes != totalBytes) throw HttpException('Downloaded file length mismatch: expected $totalBytes bytes, received $receivedBytes.');
      await _verifyCompletedDownload(output);
    } on _DownloadPaused {
      await _closeSinkQuietly(sink); sink = null;
      if (await output.exists()) receivedBytes = await output.length();
      status = DownloadStatus.paused;
    } on _DownloadCancelled {
      status = DownloadStatus.cancelled;
      await _closeSinkQuietly(sink); sink = null;
      await _deletePartialFile(output); receivedBytes = 0;
    } on SegmentedDownloadAborted {
      await _closeSinkQuietly(sink); sink = null;
      if (_cancelRequested) { status = DownloadStatus.cancelled; receivedBytes = 0; }
      else if (_pauseRequested) { status = DownloadStatus.paused; }
      else { status = DownloadStatus.failed; errorMessage = 'Segmented download was aborted.'; }
    } catch (error) {
      await _closeSinkQuietly(sink); sink = null;
      if (_cancelRequested) { status = DownloadStatus.cancelled; await _deletePartialFile(output); receivedBytes = 0; }
      else if (_pauseRequested) { if (await output.exists()) receivedBytes = await output.length(); status = DownloadStatus.paused; }
      else { status = DownloadStatus.failed; errorMessage = _describeError(error); await _deletePartialFile(output); receivedBytes = 0; }
    } finally {
      _client?.close(force: true); _client = null; _activeRun = null; onChanged();
    }
  }
  Future<bool> _trySegmentedDownload(HttpClient client, File output) async {
    final probeClient = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20)
      ..idleTimeout = const Duration(seconds: 30)
      ..userAgent = 'DownloadBeast/0.1';
    try {
      final request = await probeClient.getUrl(url);
      request.headers
        ..set(HttpHeaders.rangeHeader, 'bytes=0-0')
        ..set(HttpHeaders.acceptEncodingHeader, 'identity');
      final response = await request.close();
      final contentRange = response.headers.value(HttpHeaders.contentRangeHeader);
      final tag = response.headers.value(HttpHeaders.etagHeader);
      if (response.statusCode == HttpStatus.partialContent &&
          response.contentLength == 1 &&
          isValidRangeProbe(statusCode: response.statusCode, contentRange: contentRange, bodyLength: 1, entityTag: tag)) {
        await response.drain<void>();
        final parsed = parseContentRange(contentRange);
        if (parsed == null || parsed.total < minimumSegmentedDownloadBytes) return false;
        if (_cancelRequested) throw const _DownloadCancelled();
        if (_pauseRequested) throw const _DownloadPaused();
        totalBytes = parsed.total;
        entityTag = tag;
        await downloadSegmentedToFile(
          client: client,
          uri: url,
          destination: output,
          totalBytes: parsed.total,
          entityTag: tag!,
          shouldAbort: () => _cancelRequested || _pauseRequested,
          onProgress: (received, total) { receivedBytes = received; totalBytes = total; onChanged(); },
        );
        await _verifyCompletedDownload(output);
        return true;
      }
      // A 200 response means Range was ignored; a normal request must consume
      // the real body. Abort the probe instead of draining a possibly large
      // stream. Other HTTP errors are already definitive for this attempt and
      // should not trigger a second request or automatic retry.
      if (response.statusCode >= 400) {
        throw HttpException('Server returned HTTP ${response.statusCode}.');
      }
      return false;
    } finally {
      probeClient.close(force: true);
    }
  }
  Future<void> _verifyCompletedDownload(File output) async {
    final verification = await verifySha256(output, expectedSha256: expectedSha256);
    integrityStatus = verification.status.name;
    actualSha256 = verification.actualSha256;
    integrityCheckedAt = DateTime.now();
    if (verification.message != null && verification.status != IntegrityStatus.notChecked) errorMessage = verification.message;
    else errorMessage = null;
    status = DownloadStatus.completed;
  }
  String _describeError(Object error) {
    if (error is HttpException) return error.message;
    if (error is SocketException) return 'Network error: ${error.message}. Check your internet connection, server URL, firewall, or proxy.';
    if (error is HandshakeException) return 'Secure connection failed: ${error.message}. Check the site certificate and system date/time.';
    if (error is FileSystemException) return 'File error: ${error.message}. Check the save location and folder permissions.';
    if (error is TimeoutException) return 'Connection timed out. Check your internet connection or try again.';
    return 'Unexpected download error: $error';
  }
  Future<void> _closeSinkQuietly(IOSink? sink) async {
    if (sink == null) return;
    try { await sink.close(); } on FileSystemException { } on StateError { }
  }
  Future<void> _deletePartialFile(File file) async {
    try { if (await file.exists()) await file.delete(); } on FileSystemException { }
  }
}
class _DownloadCancelled implements Exception { const _DownloadCancelled(); }
class _DownloadPaused implements Exception { const _DownloadPaused(); }
