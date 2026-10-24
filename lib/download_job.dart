import 'dart:io';

import 'package:flutter/foundation.dart';

enum DownloadStatus { downloading, completed, failed, cancelled }

class DownloadJob {
  DownloadJob({
    required this.url,
    required this.destinationPath,
    required this.onChanged,
  });

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
    if (status != DownloadStatus.downloading) return;
    _cancelRequested = true;
    _client.close(force: true);
    onChanged();
  }

  Future<void> start() async {
    IOSink? sink;
    final output = File(destinationPath);
    try {
      final request = await _client.getUrl(url);
      request.headers.set(HttpHeaders.userAgentHeader, 'DownloadBeast/0.1');
      final response = await request.close();

      if (response.statusCode < 200 || response.statusCode >= 300) {
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
      if (sink != null) await sink.close();
      await _deletePartialFile(output);
    } catch (error) {
      if (sink != null) await sink.close();
      if (_cancelRequested) {
        status = DownloadStatus.cancelled;
        await _deletePartialFile(output);
      } else {
        status = DownloadStatus.failed;
        errorMessage = error is HttpException
            ? error.message
            : 'The download could not be completed.';
      }
    } finally {
      _client.close(force: true);
      onChanged();
    }
  }

  Future<void> _deletePartialFile(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // Cancellation is still reported even if cleanup is blocked.
    }
  }
}

class _DownloadCancelled implements Exception {
  const _DownloadCancelled();
}
