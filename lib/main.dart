import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'download_history.dart';
import 'download_application.dart';
import 'download_filename.dart';
import 'download_integrity.dart';
import 'download_job.dart';
import 'download_scheduler.dart';
import 'download_state.dart';
import 'file_identity.dart';
import 'transfer_rate.dart';
import 'windows_file_ops.dart';
import 'youtube_metadata.dart';

typedef SaveLocationPicker = Future<String?> Function(String suggestedName);

void main() => runApp(const DownloadBeastApp());

class DownloadBeastApp extends StatelessWidget {
  const DownloadBeastApp(
      {super.key, this.historyStore, this.saveLocationPicker});
  final DownloadHistoryStore? historyStore;
  final SaveLocationPicker? saveLocationPicker;

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Download Beast',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF6750A4)),
          useMaterial3: true,
          scaffoldBackgroundColor: const Color(0xFFF7F6FA),
        ),
        home: DownloadHomePage(
            historyStore: historyStore, saveLocationPicker: saveLocationPicker),
      );
}

class DownloadHomePage extends StatefulWidget {
  const DownloadHomePage(
      {super.key, this.historyStore, this.saveLocationPicker});
  final DownloadHistoryStore? historyStore;
  final SaveLocationPicker? saveLocationPicker;
  @override
  State<DownloadHomePage> createState() => _DownloadHomePageState();
}

class _DownloadHomePageState extends State<DownloadHomePage> {
  final _url = TextEditingController();
  final _hash = TextEditingController();
  final _search = TextEditingController();
  final _jobs = <DownloadJob>[];
  final _rates = <DownloadJob, TransferRateEstimator>{};
  final _deletedIds = <int>{};
  final _history = <DownloadHistoryRecord>[];
  late final DownloadScheduler _scheduler;
  DownloadApplicationController? _application;
  Future<void> _initialization = Future<void>.value();
  Future<void> _persistence = Future<void>.value();
  String? _historyError;
  String _statusFilter = 'all';
  bool _newestFirst = true;
  bool _loading = false;
  bool _more = true;
  bool _choosing = false;
  int _historyOffset = 0;

  List<DownloadJob> get _queueJobs => _jobs
      .where((job) =>
          job.status == DownloadStatus.queued ||
          job.status == DownloadStatus.downloading ||
          job.status == DownloadStatus.paused)
      .toList();

  @override
  void initState() {
    super.initState();
    _scheduler = DownloadScheduler();
    _initialization = _initialize();
  }

  Future<void> _initialize() async {
    try {
      _application = await DownloadApplicationController.open(
        historyStore: widget.historyStore,
        scheduler: _scheduler,
      );
      await _loadHistory(reset: true);
    } catch (error) {
      if (mounted) {
        setState(() => _historyError =
            'History storage is unavailable. Downloads can continue for this session.');
      }
    }
  }

  Future<void> _loadHistory({bool reset = false}) async {
    final application = _application;
    if (application == null || _loading) return;
    if (reset) {
      _historyOffset = 0;
      _history.clear();
      _more = true;
    }
    if (!_more) return;
    _loading = true;
    try {
      final rows = await application.search(
        query: _search.text,
        status: _statusFilter,
        newestFirst: _newestFirst,
        offset: _historyOffset,
        limit: 50,
      );
      if (!mounted) return;
      application.rememberHistory(rows);
      setState(() {
        _history.addAll(rows);
        _historyOffset += rows.length;
        _more = rows.length == 50;
        _historyError = null;
      });
    } catch (_) {
      if (mounted) {
        setState(() => _historyError = 'Could not read download history.');
      }
    } finally {
      _loading = false;
    }
  }

  void _onJobChanged(DownloadJob job) {
    final estimator = _rates.putIfAbsent(job, TransferRateEstimator.new);
    estimator.record(job.receivedBytes, DateTime.now());
    if (mounted) setState(() {});
    _persistJob(job);
  }

  void _persistJob(DownloadJob job) {
    final id = job.historyId;
    final application = _application;
    if (id == null || application == null || _deletedIds.contains(id)) return;
    _persistence = _persistence.then((_) async {
      try {
        final updated = await application.persistJob(job);
        if (updated == null) return;
        final row = _history.indexWhere((item) => item.id == id);
        if (mounted && row >= 0) setState(() => _history[row] = updated);
      } catch (_) {
        if (mounted) {
          setState(() => _historyError =
              'A download changed, but history could not be updated.');
        }
      }
    });
  }

  Future<String?> _choosePath(String name) async {
    final picker = widget.saveLocationPicker;
    if (picker != null) return picker(name);
    return (await getSaveLocation(suggestedName: name))?.path;
  }

  Future<bool> _confirmOverwrite(File file) async {
    if (!mounted) return false;
    final exists = await file.exists();
    if (!mounted) return false;
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title:
                Text(exists ? 'Replace existing file?' : 'Destination changed'),
            content: Text(exists
                ? 'The destination already exists:\n${file.path}\n\nThe app checks its identity and SHA-256 before replacement. Fingerprinting can take time. The original is preserved if replacement fails.'
                : 'The destination state changed after you chose it:\n${file.path}\n\nConfirm using its current state. A no-overwrite operation will protect a file that appears before commit.'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Keep existing')),
              FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: Text(exists ? 'Replace after download' : 'Continue')),
            ],
          ),
        ) ??
        false;
  }

  DownloadJob _makeJob({
    required Uri uri,
    required String path,
    required String? expected,
    required int? historyId,
    String? stage,
    String? etag,
    bool segmented = false,
    DownloadStatus initialStatus = DownloadStatus.queued,
  }) {
    late final DownloadJob job;
    job = DownloadJob(
      url: uri,
      destinationPath: path,
      expectedSha256: expected,
      stagingPath: stage,
      wasSegmented: segmented,
      initialStatus: initialStatus,
      confirmOverwrite: _confirmOverwrite,
      onChanged: () => _onJobChanged(job),
    )..historyId = historyId;
    job.entityTag = etag;
    return job;
  }

  Future<void> _addDownload() async {
    final raw = _url.text.trim();
    final hash = _hash.text.trim();
    if (raw.isEmpty) {
      _message('Enter a download URL.');
      return;
    }
    final uri = Uri.tryParse(raw);
    if (uri == null ||
        !uri.hasAuthority ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      _message('Enter a valid HTTP or HTTPS URL.');
      return;
    }
    if (youtubeVideoId(uri.toString()) != null) {
      _message(
          'Direct YouTube media downloads are unsupported. You can request optional video metadata from a history item.');
      return;
    }
    if (hash.isNotEmpty && !isValidSha256(hash)) {
      _message(
          'Expected SHA-256 must contain exactly 64 hexadecimal characters.');
      return;
    }
    setState(() => _choosing = true);
    try {
      String? destination;
      try {
        destination = await _choosePath(suggestDownloadFilename(uri));
      } catch (_) {
        _message(
            'Could not choose a save location. Check that the destination is available and you have permission, then try again.');
        return;
      }
      if (!mounted || destination == null) return;
      if (_scheduler.hasDestination(destination)) {
        _message(
            'Another queued or active download already uses that destination.');
        return;
      }
      await _initialization;
      final now = DateTime.now();
      final record = DownloadHistoryRecord(
        url: uri.toString(),
        destinationPath: destination,
        status: DownloadStatus.queued,
        receivedBytes: 0,
        totalBytes: -1,
        expectedSha256: hash.isEmpty ? null : hash.toLowerCase(),
        createdAt: now,
        updatedAt: now,
      );
      int? id;
      final application = _application;
      if (application != null) {
        try {
          id = await application.insertHistory(record);
        } catch (_) {
          _message('Download will continue, but history could not be saved.');
        }
      }
      final job = _makeJob(
          uri: uri,
          path: destination,
          expected: record.expectedSha256,
          historyId: id);
      setState(() {
        _jobs.insert(0, job);
        if (id != null) {
          final storedRecord = record.copyWith(id: id);
          application?.rememberHistory([storedRecord]);
          _history.insert(0, storedRecord);
        }
        _url.clear();
        _hash.clear();
      });
      try {
        _scheduler.enqueue(job);
      } on ArgumentError catch (error) {
        _message(error.message.toString());
      }
    } catch (_) {
      if (mounted) {
        _message(
            'Could not create the download. Check the destination and try again.');
      }
    } finally {
      if (mounted) setState(() => _choosing = false);
    }
  }

  void _message(String value) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(value)));
    }
  }

  Future<void> _resumeRecord(DownloadHistoryRecord record) async {
    final uri = Uri.tryParse(record.url);
    if (uri == null) return;
    final job = _makeJob(
      uri: uri,
      path: record.destinationPath,
      expected: record.expectedSha256,
      historyId: record.id,
      stage: record.wasSegmented ? null : record.stagingPath,
      etag: record.wasSegmented ? null : record.etag,
      segmented: record.wasSegmented,
      initialStatus: record.status == DownloadStatus.paused
          ? DownloadStatus.paused
          : DownloadStatus.failed,
    );
    _application?.rememberHistory([record]);
    if (record.status == DownloadStatus.paused) {
      job.receivedBytes = record.wasSegmented ? 0 : record.receivedBytes;
      job.totalBytes = record.totalBytes;
      _scheduler.enqueue(job);
      _scheduler.resume(job);
    } else {
      _scheduler.enqueue(job);
      _scheduler.retry(job);
    }
    setState(() => _jobs.insert(0, job));
    await _loadHistory(reset: true);
  }

  Future<void> _setConcurrency(int value) async {
    _scheduler.setMaxConcurrent(value);
    try {
      await _application?.setMaxConcurrentDownloads(value);
    } catch (_) {
      _message('Could not save the concurrency setting.');
    }
    if (mounted) setState(() {});
  }

  Future<void> _deleteRecord(DownloadHistoryRecord record) async {
    bool deleteFile = false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
                title: const Text('Remove history record?'),
                content: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                          'This removes the record and its locally retained URL. The downloaded file stays on disk unless you select file deletion separately.'),
                      CheckboxListTile(
                          value: deleteFile,
                          onChanged: (value) =>
                              setDialogState(() => deleteFile = value ?? false),
                          title: const Text('Also delete downloaded file'),
                          contentPadding: EdgeInsets.zero),
                    ]),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Cancel')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('Remove'))
                ],
              )),
    );
    if (confirmed != true) return;
    if (deleteFile && record.status == DownloadStatus.completed) {
      try {
        final file = File(record.destinationPath);
        if (await file.exists()) await file.delete();
      } catch (_) {
        _message(
            'History was removed, but the downloaded file could not be deleted.');
      }
    }
    final id = record.id;
    if (id != null) {
      _deletedIds.add(id);
      _application?.forgetHistory(id);
      await _application?.deleteHistoryRecord(id);
    }
    if (mounted) setState(() => _history.removeWhere((item) => item.id == id));
  }

  Future<void> _clearHistory() async {
    bool deleteFiles = false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
                title: const Text('Clear all history?'),
                content: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Text(
                      'All retained history and URL data will be removed. Downloaded files remain unless separately selected.'),
                  CheckboxListTile(
                      value: deleteFiles,
                      onChanged: (value) =>
                          setDialogState(() => deleteFiles = value ?? false),
                      title:
                          const Text('Also delete completed downloaded files'),
                      contentPadding: EdgeInsets.zero),
                ]),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Cancel')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('Clear history'))
                ],
              )),
    );
    if (confirmed != true) return;
    if (deleteFiles) {
      final allRecords = await _application?.listAllHistory() ?? _history;
      for (final record in allRecords
          .where((row) => row.status == DownloadStatus.completed)) {
        try {
          final file = File(record.destinationPath);
          if (await file.exists()) await file.delete();
        } catch (_) {}
      }
    }
    await _application?.deleteAllHistory();
    _deletedIds.addAll(_history.map((row) => row.id).whereType<int>());
    _application?.forgetAllHistory();
    if (mounted) setState(_history.clear);
  }

  Future<void> _openFile(DownloadHistoryRecord record) async {
    final file = File(record.destinationPath);
    if (!await file.exists()) {
      _message('The completed file is no longer available.');
      return;
    }
    if (await needsExecutableWarning(file)) {
      if (!mounted) return;
      final proceed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
                title: const Text('Potentially executable file'),
                content: const Text(
                    'This file has an executable extension or PE header. This is a precaution, not malware detection or a security scan. Open it only if you trust its source.'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Cancel')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('Open anyway'))
                ],
              ));
      if (proceed != true) return;
    }
    try {
      await WindowsFileOperations.open(file);
    } catch (_) {
      _message('Windows could not open the file.');
    }
  }

  Future<void> _revealFile(DownloadHistoryRecord record) async {
    try {
      await WindowsFileOperations.reveal(File(record.destinationPath));
    } catch (_) {
      _message('Windows could not reveal the file.');
    }
  }

  Future<void> _youtubeMetadata(DownloadHistoryRecord record) async {
    final id = youtubeVideoId(record.url);
    if (id == null) return;
    final consent = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
              title: const Text('Look up YouTube title?'),
              content: const Text(
                  'This sends a canonical YouTube URL for the selected video to YouTube’s metadata endpoint. No other download URL or query parameters are sent.'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Cancel')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Send request'))
              ],
            ));
    if (consent != true) return;
    try {
      final title = await fetchYoutubeTitleForVideo(id);
      _message(title == null
          ? 'YouTube metadata was unavailable.'
          : 'YouTube · $title');
    } catch (_) {
      _message('YouTube metadata was unavailable.');
    }
  }

  Future<void> _copyFullUrl(DownloadHistoryRecord record) async {
    await Clipboard.setData(ClipboardData(text: record.url));
    _message('Full source URL copied after your explicit request.');
  }

  Future<void> _shutdown() async {
    for (final job in _jobs) {
      if (job.status == DownloadStatus.downloading ||
          job.status == DownloadStatus.queued) {
        job.cancel();
      }
    }
    await Future.wait(_jobs.map((job) => job.settled));
    await _persistence;
    await _application?.close();
  }

  @override
  void dispose() {
    _url.dispose();
    _hash.dispose();
    _search.dispose();
    unawaited(_shutdown());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Row(children: [
            NavigationRail(
              selectedIndex: 0,
              labelType: NavigationRailLabelType.all,
              leading: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Icon(Icons.downloading, size: 38)),
              destinations: const [
                NavigationRailDestination(
                    icon: Icon(Icons.download_outlined),
                    selectedIcon: Icon(Icons.download),
                    label: Text('Downloads'))
              ],
            ),
            const VerticalDivider(width: 1),
            Expanded(
                child: LayoutBuilder(
                    builder: (context, constraints) => SingleChildScrollView(
                          padding: const EdgeInsets.all(24),
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(minWidth: 700),
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(children: [
                                    Expanded(
                                        child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                          Text('Download Beast',
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .headlineMedium
                                                  ?.copyWith(
                                                      fontWeight:
                                                          FontWeight.w800)),
                                          const Text(
                                              'Manage downloads with clear progress and safe recovery.')
                                        ])),
                                    const Text('Parallel downloads'),
                                    const SizedBox(width: 8),
                                    Tooltip(
                                      message: 'Maximum simultaneous downloads',
                                      child: DropdownButton<int>(
                                          value: _scheduler.maxConcurrent,
                                          items: [
                                            for (var i = 1; i <= 5; i++)
                                              DropdownMenuItem(
                                                  value: i, child: Text('$i'))
                                          ],
                                          onChanged: (value) {
                                            if (value != null) {
                                              unawaited(_setConcurrency(value));
                                            }
                                          }),
                                    ),
                                  ]),
                                  const SizedBox(height: 22),
                                  Card(
                                      child: Padding(
                                          padding: const EdgeInsets.all(18),
                                          child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text('Add a download',
                                                    style: Theme.of(context)
                                                        .textTheme
                                                        .titleLarge),
                                                const SizedBox(height: 12),
                                                Row(children: [
                                                  Expanded(
                                                      child: TextField(
                                                          controller: _url,
                                                          keyboardType:
                                                              TextInputType.url,
                                                          textInputAction:
                                                              TextInputAction
                                                                  .go,
                                                          onSubmitted: (_) =>
                                                              _addDownload(),
                                                          decoration: const InputDecoration(
                                                              labelText:
                                                                  'Download URL',
                                                              hintText:
                                                                  'https://example.com/file.zip',
                                                              border:
                                                                  OutlineInputBorder()))),
                                                  const SizedBox(width: 10),
                                                  FilledButton.icon(
                                                      key: const ValueKey(
                                                          'download-action'),
                                                      onPressed: _choosing
                                                          ? null
                                                          : _addDownload,
                                                      icon: _choosing
                                                          ? const SizedBox(
                                                              width: 16,
                                                              height: 16,
                                                              child:
                                                                  CircularProgressIndicator(
                                                                      strokeWidth:
                                                                          2))
                                                          : const Icon(
                                                              Icons.add),
                                                      label: const Text(
                                                          'Download'))
                                                ]),
                                                const SizedBox(height: 10),
                                                TextField(
                                                    controller: _hash,
                                                    decoration: const InputDecoration(
                                                        labelText:
                                                            'Expected SHA-256 (optional)',
                                                        hintText:
                                                            '64 hexadecimal characters',
                                                        border:
                                                            OutlineInputBorder())),
                                                const SizedBox(height: 6),
                                                const Text(
                                                    'Without an expected hash, the file is not verified. A supplied hash proves equality to that value, not its authenticity.'),
                                              ]))),
                                  const SizedBox(height: 18),
                                  Row(children: [
                                    Text('Queue',
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleLarge),
                                    const SizedBox(width: 12),
                                    Chip(
                                        label: Text(
                                            '${_scheduler.activeCount} active / ${_scheduler.maxConcurrent} max'))
                                  ]),
                                  if (_queueJobs.isEmpty)
                                    const Card(
                                        child: Padding(
                                            padding: EdgeInsets.all(18),
                                            child: Text(
                                                'No queued or active downloads'))),
                                  for (final job in _queueJobs)
                                    _JobCard(
                                        job: job,
                                        rate: _rates[job]
                                            ?.bytesPerSecond(DateTime.now()),
                                        onPause: () => _scheduler.pause(job),
                                        onResume: () => _scheduler.resume(job),
                                        onCancel: () => _scheduler.cancel(job),
                                        onRetry: () => _scheduler.retry(job)),
                                  const SizedBox(height: 18),
                                  Row(children: [
                                    Text('Download history',
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleLarge),
                                    const Spacer(),
                                    TextButton.icon(
                                        onPressed: _clearHistory,
                                        icon: const Icon(
                                            Icons.delete_sweep_outlined),
                                        label: const Text('Clear all'))
                                  ]),
                                  Row(children: [
                                    Expanded(
                                        child: TextField(
                                            controller: _search,
                                            decoration: const InputDecoration(
                                                labelText:
                                                    'Search name, source or status',
                                                prefixIcon: Icon(Icons.search),
                                                border: OutlineInputBorder()),
                                            onSubmitted: (_) =>
                                                _loadHistory(reset: true))),
                                    const SizedBox(width: 8),
                                    DropdownButton<String>(
                                        value: _statusFilter,
                                        items: [
                                          const DropdownMenuItem(
                                              value: 'all',
                                              child: Text('All statuses')),
                                          ...[
                                            'queued',
                                            'downloading',
                                            'paused',
                                            'completed',
                                            'integrityFailed',
                                            'failed',
                                            'cancelled',
                                            'interrupted'
                                          ].map((s) => DropdownMenuItem(
                                              value: s, child: Text(s)))
                                        ],
                                        onChanged: (value) {
                                          if (value != null) {
                                            setState(
                                                () => _statusFilter = value);
                                          }
                                          unawaited(_loadHistory(reset: true));
                                        }),
                                    IconButton(
                                        tooltip: _newestFirst
                                            ? 'Newest first'
                                            : 'Oldest first',
                                        onPressed: () {
                                          setState(() =>
                                              _newestFirst = !_newestFirst);
                                          unawaited(_loadHistory(reset: true));
                                        },
                                        icon: const Icon(Icons.swap_vert)),
                                    IconButton(
                                        tooltip: 'Search history',
                                        onPressed: () =>
                                            _loadHistory(reset: true),
                                        icon: const Icon(Icons.search))
                                  ]),
                                  if (_historyError != null)
                                    Padding(
                                        padding: const EdgeInsets.all(8),
                                        child: Text(_historyError!,
                                            style: TextStyle(
                                                color: Theme.of(context)
                                                    .colorScheme
                                                    .error))),
                                  if (_history.isEmpty)
                                    const Card(
                                        child: Padding(
                                            padding: EdgeInsets.all(16),
                                            child: Text(
                                                'No matching history records.'))),
                                  for (final record in _history)
                                    _HistoryCard(
                                        record: record,
                                        onDelete: () => _deleteRecord(record),
                                        onRetry: () => _resumeRecord(record),
                                        onResume: () => _resumeRecord(record),
                                        onOpen: () => _openFile(record),
                                        onReveal: () => _revealFile(record),
                                        onMetadata: () =>
                                            _youtubeMetadata(record),
                                        onCopyUrl: () => _copyFullUrl(record)),
                                  if (_more)
                                    Center(
                                        child: TextButton(
                                            onPressed: _loading
                                                ? null
                                                : () => _loadHistory(),
                                            child: Text(_loading
                                                ? 'Loading…'
                                                : 'Load more history'))),
                                ]),
                          ),
                        ))),
          ]),
        ),
      );
}

class _JobCard extends StatelessWidget {
  const _JobCard(
      {required this.job,
      required this.rate,
      required this.onPause,
      required this.onResume,
      required this.onCancel,
      required this.onRetry});
  final DownloadJob job;
  final double? rate;
  final VoidCallback onPause, onResume, onCancel, onRetry;
  @override
  Widget build(BuildContext context) {
    final label = switch (job.status) {
      DownloadStatus.queued => 'Queued',
      DownloadStatus.downloading => 'Downloading',
      DownloadStatus.paused => 'Paused',
      DownloadStatus.completed => 'Completed',
      DownloadStatus.integrityFailed => 'Integrity failure',
      DownloadStatus.failed => 'Failed',
      DownloadStatus.cancelled => 'Cancelled',
      DownloadStatus.interrupted => 'Interrupted'
    };
    final filename = job.destinationPath.split(Platform.pathSeparator).last;
    return Card(
        child: Padding(
            padding: const EdgeInsets.all(14),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(
                    child: Text(filename,
                        style: Theme.of(context).textTheme.titleMedium)),
                Chip(label: Text(label))
              ]),
              LinearProgressIndicator(value: job.progress),
              Row(children: [
                Text(
                    '${_bytes(job.receivedBytes)}${job.totalBytes > 0 ? ' / ${_bytes(job.totalBytes)}' : ''}'),
                const SizedBox(width: 12),
                Text(rate == null
                    ? '5s avg · Calculating'
                    : '5s avg · ${_bytes(rate!.round())}/s'),
                const Spacer(),
                if (job.status == DownloadStatus.downloading) ...[
                  TextButton(onPressed: onPause, child: const Text('Pause')),
                  TextButton(onPressed: onCancel, child: const Text('Cancel'))
                ] else if (job.status == DownloadStatus.paused) ...[
                  TextButton(onPressed: onResume, child: const Text('Resume')),
                  TextButton(onPressed: onCancel, child: const Text('Cancel'))
                ] else if (job.status == DownloadStatus.failed ||
                    job.status == DownloadStatus.integrityFailed)
                  TextButton(onPressed: onRetry, child: const Text('Retry'))
              ]),
              Text('Integrity: ${job.integrityStatus}'),
              if (job.errorMessage != null)
                Text(job.errorMessage!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error)),
            ])));
  }
}

class _HistoryCard extends StatelessWidget {
  const _HistoryCard(
      {required this.record,
      required this.onDelete,
      required this.onRetry,
      required this.onResume,
      required this.onOpen,
      required this.onReveal,
      required this.onMetadata,
      required this.onCopyUrl});
  final DownloadHistoryRecord record;
  final VoidCallback onDelete, onRetry, onResume, onOpen, onReveal, onMetadata;
  final VoidCallback onCopyUrl;
  @override
  Widget build(BuildContext context) {
    final id = youtubeVideoId(record.url);
    final completed = record.status == DownloadStatus.completed;
    return Card(
        child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.history),
              const SizedBox(width: 12),
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(
                        record.destinationPath
                            .split(Platform.pathSeparator)
                            .last,
                        style: Theme.of(context).textTheme.titleSmall),
                    Tooltip(
                        message: redactDownloadUrl(record.url),
                        child: Text(displayDownloadUri(record.url),
                            maxLines: 1, overflow: TextOverflow.ellipsis)),
                    Text(
                        '${record.status.name}${record.failureKind == null ? '' : ' · ${record.failureKind!.name}'} · ${_bytes(record.receivedBytes)}${record.totalBytes > 0 ? ' / ${_bytes(record.totalBytes)}' : ''} · ${record.integrityStatus}'),
                    if (record.errorMessage != null)
                      Text(record.errorMessage!,
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.error)),
                  ])),
              if (completed) ...[
                IconButton(
                    tooltip: 'Open completed file',
                    onPressed: onOpen,
                    icon: const Icon(Icons.open_in_new)),
                IconButton(
                    tooltip: 'Reveal in Explorer',
                    onPressed: onReveal,
                    icon: const Icon(Icons.folder_open))
              ],
              if (record.status == DownloadStatus.failed ||
                  record.status == DownloadStatus.integrityFailed ||
                  record.status == DownloadStatus.interrupted)
                IconButton(
                    tooltip: 'Retry download',
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh)),
              if (record.status == DownloadStatus.paused)
                IconButton(
                    tooltip: 'Resume download',
                    onPressed: onResume,
                    icon: const Icon(Icons.play_arrow)),
              if (id != null)
                IconButton(
                    tooltip: 'Look up YouTube metadata (sends canonical URL)',
                    onPressed: onMetadata,
                    icon: const Icon(Icons.info_outline)),
              IconButton(
                  tooltip: 'Copy full source URL',
                  onPressed: onCopyUrl,
                  icon: const Icon(Icons.copy)),
              IconButton(
                  tooltip: 'Remove history record',
                  onPressed: onDelete,
                  icon: const Icon(Icons.delete_outline)),
            ])));
  }
}

String _bytes(int value) {
  if (value < 1024) return '$value B';
  if (value < 1024 * 1024) return '${(value / 1024).toStringAsFixed(1)} KB';
  if (value < 1024 * 1024 * 1024) {
    return '${(value / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(value / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}
