import 'dart:io';

import 'package:crypto/crypto.dart';

/// Results of checking a downloaded file against information supplied by the
/// server or by the user.
enum IntegrityStatus { verified, mismatch, unavailable, notChecked }

class DownloadIntegrityResult {
  const DownloadIntegrityResult({
    required this.status,
    this.actualSha256,
    this.message,
  });

  final IntegrityStatus status;
  final String? actualSha256;
  final String? message;
}

bool isValidSha256(String value) => RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(value.trim());

Future<String> sha256File(File file) async {
  final digest = await sha256.bind(file.openRead()).first;
  return digest.toString();
}

/// Checks a local file against a user-supplied expected hash.
///
/// A missing expected hash is never reported as verified.
Future<DownloadIntegrityResult> verifySha256(
  File file, {
  String? expectedSha256,
}) async {
  final expected = expectedSha256?.trim();
  if (expected == null || expected.isEmpty) {
    return const DownloadIntegrityResult(
      status: IntegrityStatus.notChecked,
      message: 'No expected SHA-256 hash was supplied.',
    );
  }
  if (!isValidSha256(expected)) {
    return const DownloadIntegrityResult(
      status: IntegrityStatus.unavailable,
      message: 'Expected SHA-256 must contain exactly 64 hexadecimal characters.',
    );
  }
  if (!await file.exists()) {
    return const DownloadIntegrityResult(
      status: IntegrityStatus.unavailable,
      message: 'The downloaded file is unavailable for verification.',
    );
  }

  final actual = await sha256File(file);
  final matches = actual.toLowerCase() == expected.toLowerCase();
  return DownloadIntegrityResult(
    status: matches ? IntegrityStatus.verified : IntegrityStatus.mismatch,
    actualSha256: actual,
    message: matches
        ? 'SHA-256 matches the expected hash.'
        : 'SHA-256 does not match the expected hash.',
  );
}
