import 'dart:io';
import 'dart:typed_data';

/// Human-readable file type labels for common download extensions.
///
/// The label describes the filename extension only; it does not verify the
/// actual bytes or guarantee that the file is safe to open.
String fileTypeLabel(String filename) {
  final name = filename.toLowerCase();
  final dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return 'Unknown file type';
  final extension = name.substring(dot + 1);
  const labels = <String, String>{
    '7z': '7-Zip archive',
    'apk': 'Android application package',
    'avi': 'AVI video',
    'bat': 'Windows batch script',
    'bin': 'Binary file',
    'bmp': 'Bitmap image',
    'csv': 'CSV spreadsheet data',
    'doc': 'Word document',
    'docx': 'Word document',
    'dmg': 'macOS disk image',
    'exe': 'Windows executable',
    'flac': 'FLAC audio',
    'gif': 'GIF image',
    'gz': 'Gzip archive',
    'heic': 'HEIC image',
    'html': 'HTML webpage',
    'iso': 'ISO disk image',
    'jar': 'Java archive',
    'jpeg': 'JPEG image',
    'jpg': 'JPEG image',
    'js': 'JavaScript file',
    'json': 'JSON data',
    'm4a': 'M4A audio',
    'mkv': 'MKV video',
    'mov': 'QuickTime video',
    'mp3': 'MP3 audio',
    'mp4': 'MP4 video',
    'msi': 'Windows installer',
    'pdf': 'PDF document',
    'png': 'PNG image',
    'ppt': 'PowerPoint presentation',
    'pptx': 'PowerPoint presentation',
    'rar': 'RAR archive',
    'sh': 'Shell script',
    'svg': 'SVG image',
    'tar': 'TAR archive',
    'txt': 'Text file',
    'wav': 'WAV audio',
    'webm': 'WebM media',
    'webp': 'WebP image',
    'xls': 'Excel spreadsheet',
    'xlsx': 'Excel spreadsheet',
    'xml': 'XML data',
    'zip': 'ZIP archive',
  };
  return labels[extension] ?? '${extension.toUpperCase()} file';
}

/// Formats a URI for display without discarding the full URI stored in history.
String displayDownloadUri(String rawUrl) {
  final uri = Uri.tryParse(rawUrl);
  if (uri == null || !uri.hasAuthority) return '[invalid URL]';
  return redactDownloadUrl(rawUrl);
}

const Set<String> sensitiveQueryKeys = {
  'token',
  'access_token',
  'auth',
  'key',
  'password',
  'secret',
  'signature',
  'sig',
};

String redactDownloadUrl(String rawUrl) {
  final uri = Uri.tryParse(rawUrl);
  if (uri == null || !uri.hasAuthority) return '[invalid URL]';
  final redactedParts = <String>[];
  for (final part in uri.query.split('&')) {
    if (part.isEmpty) continue;
    final equals = part.indexOf('=');
    final rawKey = equals < 0 ? part : part.substring(0, equals);
    final key = Uri.decodeComponent(rawKey.replaceAll('+', ' ')).toLowerCase();
    final sensitive =
        sensitiveQueryKeys.contains(key) || key.startsWith('x-amz-');
    redactedParts.add(sensitive ? '$rawKey=[REDACTED]' : part);
  }
  return uri
      .replace(
        userInfo: '',
        query: uri.hasQuery ? redactedParts.join('&') : null,
      )
      .toString()
      .replaceAll('%5BREDACTED%5D', '[REDACTED]')
      .replaceAll('%5bredacted%5d', '[REDACTED]');
}

const Set<String> executableExtensions = {
  '.exe',
  '.com',
  '.bat',
  '.cmd',
  '.ps1',
  '.psm1',
  '.psd1',
  '.vbs',
  '.vbe',
  '.js',
  '.jse',
  '.wsf',
  '.wsh',
  '.hta',
  '.scr',
  '.msi',
  '.msp',
  '.mst',
  '.cpl',
  '.jar',
  '.lnk',
  '.pif',
  '.reg',
  '.scf',
  '.appx',
  '.msix',
};

Future<bool> hasPortableExecutableHeader(File file) async {
  RandomAccessFile? handle;
  try {
    final length = await file.length();
    if (length < 64) return false;
    handle = await file.open();
    final dos = await handle.read(64);
    if (dos.length != 64 || dos[0] != 0x4d || dos[1] != 0x5a) return false;
    final offset = ByteData.sublistView(Uint8List.fromList(dos))
        .getUint32(0x3c, Endian.little);
    if (offset < 64 || offset > length - 4) return false;
    await handle.setPosition(offset);
    final signature = await handle.read(4);
    return signature.length == 4 &&
        signature[0] == 0x50 &&
        signature[1] == 0x45 &&
        signature[2] == 0 &&
        signature[3] == 0;
  } on FileSystemException {
    return false;
  } finally {
    await handle?.close();
  }
}

Future<bool> needsExecutableWarning(File file) async {
  final name =
      file.uri.pathSegments.isEmpty ? file.path : file.uri.pathSegments.last;
  final extension = name.contains('.')
      ? name.substring(name.lastIndexOf('.')).toLowerCase()
      : '';
  return executableExtensions.contains(extension) ||
      await hasPortableExecutableHeader(file);
}

/// Returns the video ID for common YouTube watch, short, embed, and live URLs.
String? youtubeVideoId(String rawUrl) {
  final uri = Uri.tryParse(rawUrl);
  if (uri == null) return null;
  final host = uri.host.toLowerCase();
  if (host != 'youtube.com' &&
      host != 'www.youtube.com' &&
      host != 'm.youtube.com' &&
      host != 'music.youtube.com' &&
      host != 'youtu.be' &&
      host != 'www.youtu.be' &&
      host != 'youtube-nocookie.com' &&
      host != 'www.youtube-nocookie.com') {
    return null;
  }

  String? id;
  if (host == 'youtu.be' || host == 'www.youtu.be') {
    id = uri.pathSegments.isEmpty ? null : uri.pathSegments.first;
  } else if (uri.path == '/watch') {
    id = uri.queryParameters['v'];
  } else if (uri.pathSegments.length >= 2 &&
      const {'shorts', 'embed', 'live', 'v'}.contains(uri.pathSegments.first)) {
    id = uri.pathSegments[1];
  }
  if (id == null || !RegExp(r'^[A-Za-z0-9_-]{6,}$').hasMatch(id)) return null;
  return id;
}

/// Human-readable source identity. This does not imply that the source is
/// directly downloadable as a media file.
String downloadSourceLabel(String rawUrl) {
  final videoId = youtubeVideoId(rawUrl);
  if (videoId != null) return 'YouTube video · ID $videoId';
  return displayDownloadUri(rawUrl);
}
