import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import 'download_job.dart';
import 'download_history.dart';

void main() {
  runApp(const DownloadBeastApp());
}

class DownloadBeastApp extends StatelessWidget {
  const DownloadBeastApp({super.key, this.historyStore});

  final DownloadHistoryStore? historyStore;

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
      home: DownloadHomePage(historyStore: historyStore),
    );
  }
}

class DownloadHomePage extends StatefulWidget {
  const DownloadHomePage({super.key, this.historyStore});

  final DownloadHistoryStore? historyStore;

  @override
  State<DownloadHomePage> createState() => _DownloadHomePageState();
}

class _DownloadHomePageState extends State<DownloadHomePage> {
  final _urlController = TextEditingController();
  final List<DownloadJob> _jobs = [];
  final List<DownloadHistoryRecord> _historyRecords = [];
  DownloadHistoryStore? _historyStore;
  Future<void> _historyInitialization = Future<void>.value();
  Future<void> _persistenceChain = Future<void>.value();
  String? _historyError;
  bool _choosingLocation = false;

  @override
  void initState() {
    super.initState();
    _historyStore = widget.historyStore;
    _historyInitialization = _initializeHistory();
  }

  Future<void> _initializeHistory() async {
    try {
      _historyStore ??= await DownloadHistoryStore.open();
      await _historyStore!.markActiveDownloadsInterrupted();
      final records = await _historyStore!.listRecent();
      if (!mounted) return;
      setState(() {
        _historyRecords
          ..clear()
          ..addAll(records);
        _historyError = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _historyError = 'History storage unavailable: $error');
    }
  }

  List<DownloadHistoryRecord> get _visibleHistory => _historyRecords
      .where((record) => !_jobs.any((job) => job.historyId == record.id))
      .toList(growable: false);

  void _queuePersistJob(DownloadJob job) {
    final id = job.historyId;
    if (id == null) return;
    final index = _historyRecords.indexWhere((record) => record.id == id);
    if (index < 0) return;
    final current = _historyRecords[index];
    final updated = current.copyWith(
      status: job.status.name,
      receivedBytes: job.receivedBytes,
      totalBytes: job.totalBytes,
      errorMessage: job.errorMessage,
      clearErrorMessage: job.errorMessage == null,
      updatedAt: DateTime.now(),
    );
    _persistenceChain = _persistenceChain.then((_) async {
      try {
        await _historyStore?.update(updated);
        if (!mounted) return;
        setState(() {
          final row = _historyRecords.indexWhere((record) => record.id == id);
          if (row >= 0) _historyRecords[row] = updated;
        });
      } catch (error) {
        if (mounted) {
          setState(() => _historyError = 'Could not update download history: $error');
        }
      }
    });
  }

  @override
  void dispose() {
    _urlController.dispose();
    final store = _historyStore;
    if (store != null) {
      _persistenceChain = _persistenceChain.then((_) => store.close());
    }
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

    await _historyInitialization;
    setState(() => _choosingLocation = true);
    try {
      final suggestedName = _filenameFromUri(uri);
      final location = await getSaveLocation(suggestedName: suggestedName);
      if (!mounted || location == null) return;

      final now = DateTime.now();
      final record = DownloadHistoryRecord(
        url: uri.toString(),
        destinationPath: location.path,
        status: DownloadStatus.downloading.name,
        receivedBytes: 0,
        totalBytes: -1,
        createdAt: now,
        updatedAt: now,
      );
      int? historyId;
      if (_historyStore != null) {
        try {
          historyId = await _historyStore!.insert(record);
        } catch (error) {
          if (mounted) {
            _showMessage('Download will continue, but history could not be saved: $error');
          }
        }
      }

      late final DownloadJob job;
      job = DownloadJob(
        url: uri,
        destinationPath: location.path,
        onChanged: () {
          if (mounted) setState(() {});
          _queuePersistJob(job);
        },
      )..historyId = historyId;
      setState(() {
        _jobs.insert(0, job);
        if (historyId != null) {
          _historyRecords.insert(0, record.copyWith(id: historyId));
        }
        _urlController.clear();
        _choosingLocation = false;
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
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      Text(
                        'Recent history',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                      const Spacer(),
                      Text('${_visibleHistory.length} saved'),
                    ],
                  ),
                  if (_historyError != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _historyError!,
                      style: TextStyle(color: Theme.of(context).colorScheme.error),
                    ),
                  ],
                  const SizedBox(height: 10),
                  if (_visibleHistory.isEmpty)
                    const Card(
                      child: Padding(
                        padding: EdgeInsets.all(16),
                        child: Text('Completed and past downloads will appear here.'),
                      ),
                    )
                  else
                    ..._visibleHistory.map((record) => Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: _HistoryCard(record: record),
                        )),
                  const SizedBox(height: 20),
                  Text(
                    'History is stored locally on this device. Resume and segmented downloading are planned.',
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

class _HistoryCard extends StatelessWidget {
  const _HistoryCard({required this.record});

  final DownloadHistoryRecord record;

  @override
  Widget build(BuildContext context) {
    final filename = record.destinationPath.split(Platform.pathSeparator).last;
    final status = switch (record.status) {
      'completed' => 'Completed',
      'failed' => 'Failed',
      'cancelled' => 'Cancelled',
      'downloading' => 'Interrupted',
      _ => record.status,
    };
    final statusColor = switch (record.status) {
      'completed' => Colors.green,
      'failed' => Theme.of(context).colorScheme.error,
      _ => Theme.of(context).colorScheme.onSurfaceVariant,
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Icon(Icons.history, color: statusColor, size: 26),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(filename, style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 3),
                  Text(
                    '$status · ${_formatBytes(record.receivedBytes)}'
                    '${record.totalBytes > 0 ? ' / ${_formatBytes(record.totalBytes)}' : ''}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  Text(
                    record.url,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                  if (record.errorMessage != null)
                    Text(
                      record.errorMessage!,
                      style: TextStyle(color: Theme.of(context).colorScheme.error),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${record.updatedAt.toLocal()}'.split('.').first,
              style: Theme.of(context).textTheme.labelSmall,
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
