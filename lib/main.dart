import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'file_identity.dart';

class DownloadJob {
  DownloadJob({required this.url, required this.destinationPath});
  final Uri url;
  final String destinationPath;
}

class _SourceLink extends StatefulWidget {
  const _SourceLink({required this.url});
  final String url;
  @override
  State<_SourceLink> createState() => _SourceLinkState();
}

class _SourceLinkState extends State<_SourceLink> {
  late Future<String?> _titleFuture;

  @override
  void initState() {
    super.initState();
    _titleFuture = fetchYoutubeTitle(widget.url);
  }

  @override
  void didUpdateWidget(covariant _SourceLink oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) _titleFuture = fetchYoutubeTitle(widget.url);
  }

  @override
  Widget build(BuildContext context) {
    final uri = Uri.tryParse(widget.url);
    final validHttpUrl = uri != null && uri.hasAuthority && (uri.scheme == 'http' || uri.scheme == 'https');
    final fallback = downloadSourceLabel(widget.url);

    return Row(
      children: [
        const Icon(Icons.link, size: 16),
        const SizedBox(width: 4),
        Expanded(
          child: Tooltip(
            message: widget.url,
            child: FutureBuilder<String?>(
              future: _titleFuture,
              builder: (context, snapshot) {
                final label = snapshot.data == null || snapshot.data!.isEmpty
                    ? fallback
                    : 'YouTube · ${snapshot.data!}';
                return Text(
                  label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.primary),
                );
              },
            ),
          ),
        ),
        IconButton(
          tooltip: 'Copy full source URL',
          visualDensity: VisualDensity.compact,
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: widget.url));
            if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Full source URL copied.')));
          },
          icon: const Icon(Icons.copy, size: 18),
        ),
        IconButton(
          tooltip: 'Open source link in browser',
          visualDensity: VisualDensity.compact,
          onPressed: !validHttpUrl
              ? null
              : () async {
                  final opened = await launchUrl(uri!, mode: LaunchMode.externalApplication);
                  if (!opened && context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not open source URL.')));
                },
          icon: const Icon(Icons.open_in_new, size: 18),
        ),
      ],
    );
  }
}

Future<String?> fetchYoutubeTitle(String rawUrl) async {
  final id = youtubeVideoId(rawUrl);
  if (id == null) return null;
  final endpoint = Uri.parse('https://www.youtube.com/oembed?url=https://www.youtube.com/watch?v=$id&format=json');
  try {
    final client = HttpClient();
    final request = await client.getUrl(endpoint);
    final response = await request.close();
    final body = await response.transform(const SystemEncoding().decoder).join();
    client.close();
    if (response.statusCode != 200) return null;
    final match = RegExp(r'\"title\"\s*:\s*\"((?:\\.|[^\"\\])*)\"').firstMatch(body);
    return match == null ? null : match.group(1);
  } catch (_) {
    return null;
  }
}
