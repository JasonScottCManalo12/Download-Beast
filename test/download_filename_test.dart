import 'package:download_beast/download_filename.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('uses only the sanitized final URL path segment', () {
    expect(
      suggestDownloadFilename(Uri.parse('https://example.com/a/b/report.zip')),
      'report.zip',
    );
    expect(
      suggestDownloadFilename(Uri.parse('https://example.com/a/CON.txt')),
      '_CON.txt',
    );
    expect(
      suggestDownloadFilename(Uri.parse('https://example.com/a/name%3A.txt')),
      'name_.txt',
    );
  });

  test('falls back for empty and traversal-like final path segments', () {
    expect(
        suggestDownloadFilename(Uri.parse('https://example.com')), 'download');
    expect(suggestDownloadFilename(Uri.parse('https://example.com/%2E%2E')),
        'download');
  });

  test('removes Windows-invalid trailing spaces and dots', () {
    expect(
      suggestDownloadFilename(Uri.parse('https://example.com/name%20.%20')),
      'name',
    );
  });
}
