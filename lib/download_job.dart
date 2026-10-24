import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

enum DownloadStatus { downloading, completed, failed, cancelled }

class DownloadJob {
  DownloadJob({
    required this.url,
    required this.destinationPath,
    required this.onChanged,
  }) {
    _client.connectionTimeout = const Duration(seconds: 20);
    _client.idleTimeout = const Duration(seconds: 30);
    _client.userAgent = 'DownloadBeast/0.1';
  }

  final Uri url;
  final String destinationPath;
  final VoidCallback onChanged;

  final HttpClient _client = HttpClient();
  DownloadStatus status = DownloadStatus.downloading;
  int receivedBytes = 0;
  int totalBytes = -1;
  String? errorMessage;
  bool _cancelRequested = false;

  double? get progress => totalBytes > 0
      ? (receivedBytes / totalBytes).clamp(0.0, 1.0).toDouble()
      : null;

  void cancel() {
    if (status != DownloadStatus.downloading || _cancelRequested) return;
    _cancelRequested = true;
    _client.close(force: true);
    onChanged();
  }

  Future<void> start() async {
    IOSink? sink;
    final output = File(destinationPath);
    try {
      if (_cancelRequested) throw const _DownloadCancelled();

      final request = await _client.getUrl(url);
      if (_cancelRequested) throw const _DownloadCancelled();

      final response = await request.close();
      if (_cancelRequested) throw const _DownloadCancelled();

      if (response.statusCode < 200 || response.statusCode >= 300) {
        // Drain the response so the connection can be released cleanly.
        await response.drain<void>();
        throw HttpException('Server returned HTTP ${response.statusCode}.');
      }

      totalBytes = response.contentLength;
      sink = output.openWrite(mode: FileMode.write);
      await for (final chunk in response) {
        if (_cancelRequested) throw const _DownloadCancelled();
        sink.add(chunk);
        receivedBytes += chunk.length;
        onChanged();
      }
      if (_cancelRequested) throw const _DownloadCancelled();

      await sink.flush();
      await sink.close();
      sink = null;

      if (_cancelRequested) {
        status = DownloadStatus.cancelled;
        await _deletePartialFile(output);
      } else {
        status = DownloadStatus.completed;
      }
    } on _DownloadCancelled {
      status = DownloadStatus.cancelled;
      await _closeSinkQuietly(sink);
      await _deletePartialFile(output);
    } catch (error) {
      await _closeSinkQuietly(sink);
      if (_cancelRequested) {
        status = DownloadStatus.cancelled;
        await _deletePartialFile(output);
      } else {
        status = DownloadStatus.failed;
        errorMessage = _describeError(error);
        await _deletePartialFile(output);
      }
    } finally {
      _client.close(force: true);
      onChanged();
    }
  }

  String _describeError(Object error) {
    if (error is HttpException) return error.message;
    if (error is SocketException) {
      return 'Network error: ${error.message}. Check your internet connection, server URL, firewall, or proxy.';
    }
    if (error is HandshakeException) {
      return 'Secure connection failed: ${error.message}. Check the site certificate and system date/time.';
    }
    if (error is FileSystemException) {
      return 'File error: ${error.message}. Check the save location and folder permissions.';
    }
    if (error is TimeoutException) {
      return 'Connection timed out. Check your internet connection or try again.';
    }
    return 'Unexpected download error: $error';
  }

  Future<void> _closeSinkQuietly(IOSink? sink) async {
    if (sink == null) return;
    try {
      await sink.close();
    } on FileSystemException {
      // Preserve the original download error or cancellation result.
    } on StateError {
      // The sink may already have been closed by the failing write.
    }
  }

  Future<void> _deletePartialFile(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // Keep the original error/status visible if cleanup is blocked.
    }
  }
}

class _DownloadCancelled implements Exception {
  const _DownloadCancelled();
}
