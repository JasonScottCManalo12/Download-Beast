import 'dart:io';

import 'segmented_download_plan.dart';

/// Result of probing whether an origin safely supports byte-range downloads.
class RangeProbeResult {
  const RangeProbeResult._({
    required this.supported,
    this.totalBytes,
    this.entityTag,
  });

  const RangeProbeResult.unsupported()
      : this._(supported: false);

  const RangeProbeResult.supported({
    required int totalBytes,
    required String entityTag,
  }) : this._(
          supported: true,
          totalBytes: totalBytes,
          entityTag: entityTag,
        );

  final bool supported;
  final int? totalBytes;
  final String? entityTag;
}

/// Sends a bounded one-byte range request and validates the response.
///
/// A server is considered eligible only when it returns HTTP 206, the exact
/// \`bytes 0-0/total\` Content-Range, exactly one body byte, and a strong ETag.
/// Unsupported or malformed responses return [RangeProbeResult.unsupported]
/// so the caller can use the existing single-connection path.
///
/// The supplied [HttpClient] remains owned by the caller. The response body is
/// deliberately bounded to one byte to avoid buffering a full file if the
/// server ignores the Range header.
Future<RangeProbeResult> probeRangeSupport(
  HttpClient client,
  Uri uri, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  HttpClientRequest? request;
  try {
    request = await client.getUrl(uri).timeout(timeout);
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
    request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');

    final response = await request.close().timeout(timeout);
    final parsed = parseContentRange(
      response.headers.value(HttpHeaders.contentRangeHeader),
    );
    final entityTag = response.headers.value(HttpHeaders.etagHeader);

    if (response.statusCode != HttpStatus.partialContent ||
        parsed == null ||
        parsed.start != 0 ||
        parsed.end != 0 ||
        !isStrongEntityTag(entityTag)) {
      await response.listen((_) {}).cancel();
      return const RangeProbeResult.unsupported();
    }

    final body = <int>[];
    await for (final chunk in response.timeout(timeout)) {
      if (body.length + chunk.length > 1) {
        return const RangeProbeResult.unsupported();
      }
      body.addAll(chunk);
    }

    if (!isValidRangeProbe(
      statusCode: response.statusCode,
      contentRange: response.headers.value(HttpHeaders.contentRangeHeader),
      bodyLength: body.length,
      entityTag: entityTag,
    )) {
      return const RangeProbeResult.unsupported();
    }

    return RangeProbeResult.supported(
      totalBytes: parsed.total,
      entityTag: entityTag!.trim(),
    );
  } catch (_) {
    request?.abort();
    return const RangeProbeResult.unsupported();
  }
}
