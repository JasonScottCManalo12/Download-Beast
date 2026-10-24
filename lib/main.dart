import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

void main() {
  runApp(const DownloadBeastApp());
}

class DownloadBeastApp extends StatelessWidget {
  const DownloadBeastApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF6750A4);
    return MaterialApp(
      title: 'Download Beast',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: seed),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF7F6FA),
        cardTheme: const CardThemeData(
          elevation: 0,
          margin: EdgeInsets.zero,
        ),
      ),
      home: const DownloadHomePage(),
    );
  }
}

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

  double? get progress =>
      totalBytes > 0 ? (receivedBytes / totalBytes).clamp(0.0, 1.0) : null;

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
        // Keep any partial file so the user can inspect or remove it.
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
      // Cancellation should still be reported even if cleanup is blocked.
    }
  }
}

class _DownloadCancelled implements Exception {
  const _DownloadCancelled();
}

class DownloadHomePage extends StatefulWidget {
  const DownloadHomePage({super.key});

  @override
  State<DownloadHomePage> createState() => _DownloadHomePageState();
}

class _DownloadHomePageState extends State<DownloadHomePage> {
  final _urlController = TextEditingController();
  final List<DownloadJob> _jobs = [];
  bool _choosingLocation = false;

  @override
  void dispose() {
    _urlController.dispose();
    for (final job in _jobs) {
      job.cancel();
    }
    super.dispose();
  }

  Future<void> _addDownload() async {
    final rawUrl = _urlController.text.trim();
    final uri = Uri.tryParse(rawUrl);
    if (uri == null ||
        !uri.hasAuthority ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      _showMessage('Enter a valid HTTP or HTTPS URL.');
      return;
    }

    setState(() => _choosingLocation = true);
    try {
      final suggestedName = _filenameFromUri(uri);
      final location = await getSaveLocation(suggestedName: suggestedName);
      if (!mounted || location == null) return;

      final job = DownloadJob(
        url: uri,
        destinationPath: location.path,
        onChanged: () {
          if (mounted) setState(() {});
        },
      );
      setState(() {
        _jobs.insert(0, job);
        _urlController.clear();
      });
      await job.start();
    } catch (_) {
      if (mounted) _showMessage('Could not start the download.');
    } finally {
      if (mounted) setState(() => _choosingLocation = false);
    }
  }

  String _filenameFromUri(Uri uri) {
    final segment = uri.pathSegments.isEmpty ? '' : uri.pathSegments.last;
    if (segment.isEmpty || segment == '.' || segment == '..') {
      return 'download.bin';
    }
    return segment.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  int get _activeCount =>
      _jobs.where((job) => job.status == DownloadStatus.downloading).length;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Row(
          children: [
            NavigationRail(
              selectedIndex: 0,
              labelType: NavigationRailLabelType.all,
              leading: Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primary,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(Icons.downloading, color: Colors.white),
                ),
              ),
              destinations: const [
                NavigationRailDestination(
                  icon: Icon(Icons.download_outlined),
                  selectedIcon: Icon(Icons.download),
                  label: Text('Downloads'),
                ),
              ],
            ),
            const VerticalDivider(width: 1),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(28),
                children: [
                  Text(
                    'Download Beast',
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'A faster, clearer place to manage your downloads.',
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                  const SizedBox(height: 28),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Add a download',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          const SizedBox(height: 14),
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _urlController,
                                  keyboardType: TextInputType.url,
                                  onSubmitted: (_) => _addDownload(),
                                  decoration: const InputDecoration(
                                    hintText: 'https://example.com/file.zip',
                                    labelText: 'Download URL',
                                    prefixIcon: Icon(Icons.link),
                                    border: OutlineInputBorder(),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              FilledButton.icon(
                                onPressed:
                                    _choosingLocation ? null : _addDownload,
                                icon: _choosingLocation
                                    ? const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Icon(Icons.add),
                                label: const Text('Download'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Text(
                            'Choose where to save the file. Downloads begin immediately after the server responds.',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      Text(
                        'Download queue',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                      const Spacer(),
                      Chip(label: Text('$_activeCount active')),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (_jobs.isEmpty)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: 38,
                          horizontal: 20,
                        ),
                        child: Column(
                          children: [
                            Icon(
                              Icons.cloud_download_outlined,
                              size: 44,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              'No downloads yet',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 4),
                            const Text(
                              'Paste a file URL above to start your first download.',
                            ),
                          ],
                        ),
                      ),
                    )
                  else
                    ..._jobs.map((job) => Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: _DownloadCard(
                            job: job,
                            onCancel: job.cancel,
                          ),
                        )),
                  const SizedBox(height: 20),
                  Text(
                    'Early build · Downloads are not yet saved across app restarts. Resume, segmented downloading, and persistent history are planned.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DownloadCard extends StatelessWidget {
  const _DownloadCard({required this.job, required this.onCancel});

  final DownloadJob job;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final statusText = switch (job.status) {
      DownloadStatus.downloading => 'Downloading',
      DownloadStatus.completed => 'Completed',
      DownloadStatus.failed => 'Failed',
      DownloadStatus.cancelled => 'Cancelled',
    };
    final color = switch (job.status) {
      DownloadStatus.completed => Colors.green,
      DownloadStatus.failed => Theme.of(context).colorScheme.error,
      DownloadStatus.cancelled => Theme.of(context).colorScheme.onSurfaceVariant,
      DownloadStatus.downloading => Theme.of(context).colorScheme.primary,
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(Icons.insert_drive_file_outlined, size: 30, color: color),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    job.destinationPath.split(Platform.pathSeparator).last,
                    style: Theme.of(context).textTheme.titleMedium,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '$statusText · ${_formatBytes(job.receivedBytes)}'
                    '${job.totalBytes > 0 ? ' / ${_formatBytes(job.totalBytes)}' : ''}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  if (job.status == DownloadStatus.downloading) ...[
                    const SizedBox(height: 10),
                    LinearProgressIndicator(value: job.progress),
                  ],
                  if (job.errorMessage != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      job.errorMessage!,
                      style: TextStyle(color: Theme.of(context).colorScheme.error),
                    ),
                  ],
                ],
              ),
            ),
            if (job.status == DownloadStatus.downloading)
              IconButton(
                tooltip: 'Cancel download',
                onPressed: onCancel,
                icon: const Icon(Icons.close),
              )
            else
              Icon(
                job.status == DownloadStatus.completed
                    ? Icons.check_circle_outline
                    : job.status == DownloadStatus.failed
                        ? Icons.error_outline
                        : Icons.cancel_outlined,
                color: color,
              ),
          ],
        ),
      ),
    );
  }
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}
