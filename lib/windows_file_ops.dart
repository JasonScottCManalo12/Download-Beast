import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

abstract interface class FileOperationsAdapter {
  Future<String?> identity(File file);
  Future<void> replace({
    required File source,
    required File destination,
    required bool destinationExists,
    required File backup,
    String? expectedIdentity,
  });
  Future<void> open(File file);
  Future<void> reveal(File file);
}

/// Application facade for platform-specific file operations.
class WindowsFileOperations {
  static FileOperationsAdapter _adapter = _WindowsChannelFileOperations();

  static Future<String?> identity(File file) => _adapter.identity(file);

  static Future<void> replace({
    required File source,
    required File destination,
    required bool destinationExists,
    required File backup,
    String? expectedIdentity,
  }) =>
      _adapter.replace(
        source: source,
        destination: destination,
        destinationExists: destinationExists,
        backup: backup,
        expectedIdentity: expectedIdentity,
      );

  static Future<void> open(File file) => _adapter.open(file);
  static Future<void> reveal(File file) => _adapter.reveal(file);

  @visibleForTesting
  static void installForTesting(FileOperationsAdapter adapter) {
    _adapter = adapter;
  }

  @visibleForTesting
  static void resetAdapter() {
    _adapter = _WindowsChannelFileOperations();
  }
}

/// File-system implementation used outside Windows and in deterministic tests.
class FileSystemFileOperations implements FileOperationsAdapter {
  const FileSystemFileOperations();

  @override
  Future<String?> identity(File file) async => file.absolute.path.toLowerCase();

  @override
  Future<void> replace({
    required File source,
    required File destination,
    required bool destinationExists,
    required File backup,
    String? expectedIdentity,
  }) async {
    if (!destinationExists) {
      if (await destination.exists()) {
        throw FileSystemException(
            'Destination appeared before commit.', destination.path);
      }
      await source.rename(destination.path);
      return;
    }
    await destination.rename(backup.path);
    try {
      await source.rename(destination.path);
      await backup.delete();
    } on Object {
      if (!await destination.exists() && await backup.exists()) {
        try {
          await backup.rename(destination.path);
        } on Object {
          // Leave the backup at its recovery path if restoration fails.
        }
      }
      rethrow;
    }
  }

  @override
  Future<void> open(File file) =>
      throw UnsupportedError('Opening files is supported on Windows only.');

  @override
  Future<void> reveal(File file) =>
      throw UnsupportedError('Revealing files is supported on Windows only.');
}

class _WindowsChannelFileOperations implements FileOperationsAdapter {
  static const MethodChannel _channel = MethodChannel('download_beast/windows');

  @override
  Future<String?> identity(File file) =>
      _channel.invokeMethod<String>('fileIdentity', {'path': file.path});

  @override
  Future<void> replace({
    required File source,
    required File destination,
    required bool destinationExists,
    required File backup,
    String? expectedIdentity,
  }) async {
    await _channel.invokeMethod<bool>('replaceFile', {
      'source': source.path,
      'destination': destination.path,
      'backup': backup.path,
      'exists': destinationExists,
      'expectedIdentity': expectedIdentity,
    });
    if (destinationExists && await backup.exists()) {
      try {
        await backup.delete();
      } on FileSystemException {
        // Preserve the recovery copy if cleanup is blocked.
      }
    }
  }

  @override
  Future<void> open(File file) =>
      _channel.invokeMethod<void>('openFile', {'path': file.path});

  @override
  Future<void> reveal(File file) =>
      _channel.invokeMethod<void>('revealFile', {'path': file.path});
}
