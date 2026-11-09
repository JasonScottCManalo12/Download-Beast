import 'dart:io';
import 'dart:typed_data';

import 'package:download_beast/file_identity.dart';
import 'package:download_beast/youtube_metadata.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('fileTypeLabel', () {
    test('recognizes common file formats case-insensitively', () {
      expect(fileTypeLabel('manual.PDF'), 'PDF document');
      expect(fileTypeLabel('installer.exe'), 'Windows executable');
      expect(fileTypeLabel('backup.zip'), 'ZIP archive');
      expect(fileTypeLabel('photo.webp'), 'WebP image');
    });

    test('does not pretend extensionless or unknown files are recognized', () {
      expect(fileTypeLabel('download'), 'Unknown file type');
      expect(fileTypeLabel('payload.unknownxyz'), 'UNKNOWNXYZ file');
    });

    test('uses only the final extension', () {
      expect(fileTypeLabel('archive.tar.gz'), 'Gzip archive');
      expect(fileTypeLabel('release.final.apk'), 'Android application package');
    });
  });

  group('YouTube source identification', () {
    test('recognizes watch, short, shorts, and embed links', () {
      expect(youtubeVideoId('https://www.youtube.com/watch?v=AbCdEf12345'),
          'AbCdEf12345');
      expect(
          youtubeVideoId('https://youtu.be/AbCdEf12345?t=30'), 'AbCdEf12345');
      expect(youtubeVideoId('https://youtube.com/shorts/AbCdEf12345'),
          'AbCdEf12345');
      expect(
          youtubeVideoId('https://www.youtube-nocookie.com/embed/AbCdEf12345'),
          'AbCdEf12345');
    });

    test('does not mistake unrelated or non-video YouTube URLs for a video',
        () {
      expect(youtubeVideoId('https://example.com/watch?v=AbCdEf12345'), isNull);
      expect(
          youtubeVideoId('https://www.youtube.com/feed/subscriptions'), isNull);
      expect(youtubeVideoId('not a URL'), isNull);
    });

    test('provides a recognizable YouTube label without claiming extraction',
        () {
      expect(
        downloadSourceLabel('https://youtu.be/AbCdEf12345'),
        'YouTube video · ID AbCdEf12345',
      );
    });
  });

  group('displayDownloadUri', () {
    test('redacts sensitive values and retains safe URL context', () {
      expect(
        displayDownloadUri(
            'https://example.com/files/archive.zip?token=secret'),
        'https://example.com/files/archive.zip?token=[REDACTED]',
      );
    });

    test('shows the host for a root URL and leaves invalid URLs readable', () {
      expect(displayDownloadUri('https://example.com'), 'https://example.com');
      expect(displayDownloadUri('not a URL'), '[invalid URL]');
    });
  });

  test('redacts user info, duplicate sensitive keys, and X-Amz query values',
      () {
    final result = redactDownloadUrl(
      'https://user:password@example.com/a?TOKEN=one&token=two&X-Amz-Signature=three&ok=yes',
    );
    expect(result, isNot(contains('user')));
    expect(result, isNot(contains('password')));
    expect(result, isNot(contains('one')));
    expect(result, isNot(contains('two')));
    expect(result, isNot(contains('three')));
    expect(result, contains('ok=yes'));
    expect('[REDACTED]'.allMatches(result).length, 3);
  });

  test('detects listed executable extensions', () async {
    final file =
        File('${Directory.systemTemp.path}/download-beast-warning-test.ps1');
    await file.writeAsString('Write-Output safe');
    addTearDown(() async {
      if (await file.exists()) await file.delete();
    });
    expect(await needsExecutableWarning(file), isTrue);
  });

  test('detects a PE header after a harmless filename extension', () async {
    final bytes = Uint8List(128);
    bytes[0] = 0x4d;
    bytes[1] = 0x5a;
    ByteData.sublistView(bytes).setUint32(0x3c, 64, Endian.little);
    bytes[64] = 0x50;
    bytes[65] = 0x45;
    final file = File('${Directory.systemTemp.path}/renamed-image.dat');
    await file.writeAsBytes(bytes);
    addTearDown(() async {
      if (await file.exists()) await file.delete();
    });
    expect(await needsExecutableWarning(file), isTrue);
  });

  test('rejects truncated and out-of-bounds PE headers', () async {
    final truncated = File('${Directory.systemTemp.path}/truncated.bin');
    await truncated.writeAsBytes([0x4d, 0x5a]);
    final invalid = Uint8List(64);
    invalid[0] = 0x4d;
    invalid[1] = 0x5a;
    ByteData.sublistView(invalid).setUint32(0x3c, 0xffff, Endian.little);
    final outOfBounds = File('${Directory.systemTemp.path}/invalid-pe.bin');
    await outOfBounds.writeAsBytes(invalid);
    addTearDown(() async {
      if (await truncated.exists()) await truncated.delete();
      if (await outOfBounds.exists()) await outOfBounds.delete();
    });
    expect(await hasPortableExecutableHeader(truncated), isFalse);
    expect(await hasPortableExecutableHeader(outOfBounds), isFalse);
  });

  test('metadata requests contain only a canonical selected-video URL', () {
    final metadata = canonicalYoutubeMetadataUrl('AbCdEf12345');
    expect(metadata.host, 'www.youtube.com');
    expect(metadata.path, '/oembed');
    expect(metadata.queryParameters['format'], 'json');
    expect(
      Uri.parse(metadata.queryParameters['url']!).queryParameters['v'],
      'AbCdEf12345',
    );
    expect(metadata.toString(), isNot(contains('token')));
    expect(() => canonicalYoutubeMetadataUrl('bad id'), throwsArgumentError);
  });
}
