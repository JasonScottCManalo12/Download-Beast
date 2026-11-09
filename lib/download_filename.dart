/// Suggests a safe Windows filename from the final URL path segment.
///
/// Content-Disposition is deliberately not consulted; the URL path is the
/// only source used for the first release suggestion.
String suggestDownloadFilename(Uri uri) {
  var name = uri.pathSegments.isEmpty ? '' : uri.pathSegments.last;
  if (name.isEmpty || name == '.' || name == '..') name = 'download';
  name = name.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_').trim();
  name = name.replaceAll(RegExp(r'[ .]+$'), '');
  if (name.isEmpty || name == '.' || name == '..') name = 'download';

  final stem = name.split('.').first.trim().toUpperCase();
  const reservedWindowsNames = {
    'CON',
    'PRN',
    'AUX',
    'NUL',
    'COM1',
    'COM2',
    'COM3',
    'COM4',
    'COM5',
    'COM6',
    'COM7',
    'COM8',
    'COM9',
    'LPT1',
    'LPT2',
    'LPT3',
    'LPT4',
    'LPT5',
    'LPT6',
    'LPT7',
    'LPT8',
    'LPT9',
  };
  if (reservedWindowsNames.contains(stem)) name = '_$name';
  return name;
}
