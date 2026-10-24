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
