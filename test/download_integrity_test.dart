import 'dart:io';
import 'dart:convert';

import 'package:download_beast/download_integrity.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart';

void main() {
  late Directory directory;
  late File file;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('download_integrity_test_');
    file = File('${directory.path}/payload.bin');
    await file.writeAsString('Download Beast integrity fixture');
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test('validates SHA-256 input format', () {
    expect(isValidSha256(List.filled(64, 'a').join()), isTrue);
    expect(isValidSha256(List.filled(64, 'g').join()), isFalse);
    expect(isValidSha256(List.filled(63, 'a').join()), isFalse);
    expect(isValidSha256(''), isFalse);
  });

  test('reports verified when the supplied expected hash matches', () async {
    final expected = sha256.convert(utf8.encode('Download Beast integrity fixture')).toString();
    final result = await verifySha256(file, expectedSha256: expected);
    expect(result.status, IntegrityStatus.verified);
    expect(result.actualSha256, expected);
  });

  test('reports mismatch when the supplied expected hash differs', () async {
    final result = await verifySha256(file, expectedSha256: List.filled(64, '0').join());
    expect(result.status, IntegrityStatus.mismatch);
    expect(result.actualSha256, isNotNull);
  });

  test('missing expected hash is not marked verified', () async {
    final result = await verifySha256(file);
    expect(result.status, IntegrityStatus.notChecked);
    expect(result.actualSha256, isNull);
  });

  test('malformed expected hash is unavailable rather than verified', () async {
    final result = await verifySha256(file, expectedSha256: 'not-a-hash');
    expect(result.status, IntegrityStatus.unavailable);
  });
}
