import 'package:download_beast/file_identity.dart';
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
      expect(youtubeVideoId('https://www.youtube.com/watch?v=AbCdEf12345'), 'AbCdEf12345');
      expect(youtubeVideoId('https://youtu.be/AbCdEf12345?t=30'), 'AbCdEf12345');
      expect(youtubeVideoId('https://youtube.com/shorts/AbCdEf12345'), 'AbCdEf12345');
      expect(youtubeVideoId('https://www.youtube-nocookie.com/embed/AbCdEf12345'), 'AbCdEf12345');
    });

    test('does not mistake unrelated or non-video YouTube URLs for a video', () {
      expect(youtubeVideoId('https://example.com/watch?v=AbCdEf12345'), isNull);
      expect(youtubeVideoId('https://www.youtube.com/feed/subscriptions'), isNull);
      expect(youtubeVideoId('not a URL'), isNull);
    });

    test('provides a recognizable YouTube label without claiming extraction', () {
      expect(
        downloadSourceLabel('https://youtu.be/AbCdEf12345'),
        'YouTube video · ID AbCdEf12345',
      );
    });
  });

  group('displayDownloadUri', () {
    test('shows hostname and path while indicating a hidden query', () {
      expect(
        displayDownloadUri('https://example.com/files/archive.zip?token=secret'),
        'example.com/files/archive.zip?…',
      );
    });

    test('shows the host for a root URL and leaves invalid URLs readable', () {
      expect(displayDownloadUri('https://example.com'), 'example.com');
      expect(displayDownloadUri('not a URL'), 'not a URL');
    });
  });
}
