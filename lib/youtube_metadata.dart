import 'dart:convert';
import 'dart:io';

import 'file_identity.dart';

/// Fetches public YouTube metadata without treating the page as a media file.
/// Returns null when the source cannot be resolved quickly.
Future<String?> fetchYoutubeTitle(String rawUrl) async {
  final videoId = youtubeVideoId(rawUrl);
  if (videoId == null) return null;

  return fetchYoutubeTitleForVideo(videoId);
}

Uri canonicalYoutubeMetadataUrl(String videoId) {
  if (!RegExp(r'^[A-Za-z0-9_-]{6,}$').hasMatch(videoId)) {
    throw ArgumentError.value(videoId, 'videoId', 'Invalid YouTube video ID.');
  }
  return Uri.https('www.youtube.com', '/oembed', {
    'url': Uri.https('www.youtube.com', '/watch', {'v': videoId}).toString(),
    'format': 'json',
  });
}

Future<String?> fetchYoutubeTitleForVideo(String videoId) async {
  final source = canonicalYoutubeMetadataUrl(videoId);

  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final request =
        await client.getUrl(source).timeout(const Duration(seconds: 5));
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    final response = await request.close().timeout(const Duration(seconds: 5));
    if (response.statusCode != HttpStatus.ok) return null;
    final body = await response.transform(utf8.decoder).join();
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) return null;
    final title = decoded['title'];
    if (title is! String) return null;
    final normalized = title.trim();
    return normalized.isEmpty ? null : normalized;
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}
