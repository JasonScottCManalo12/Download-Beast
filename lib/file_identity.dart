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
  if (uri == null || !uri.hasAuthority) return rawUrl;
  final path = uri.path.isEmpty || uri.path == '/' ? '' : uri.path;
  final queryMarker = uri.hasQuery ? '?…' : '';
  return '${uri.host}$path$queryMarker';
}
