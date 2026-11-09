import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:download_beast/download_job.dart';
import 'package:download_beast/download_scheduler.dart';
import 'package:download_beast/download_state.dart';
import 'package:download_beast/windows_file_ops.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late HttpServer server;
  late Directory temp;
  final payload = utf8.encode('queued payload');
  final gates = <Completer<void>>[];
  final threeStarted = Completer<void>();
  final fiveStarted = Completer<void>();
  var active = 0;
  var maxActive = 0;

  setUpAll(() {
    WindowsFileOperations.installForTesting(const FileSystemFileOperations());
  });

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('download_scheduler_');
    gates.clear();
    active = 0;
    maxActive = 0;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response
        ..statusCode = HttpStatus.ok
        ..contentLength = payload.length;
      if (request.method == 'HEAD') {
        await request.response.close();
        return;
      }
      active++;
      if (active > maxActive) maxActive = active;
      final gate = Completer<void>();
      gates.add(gate);
      if (gates.length == 3 && !threeStarted.isCompleted) {
        threeStarted.complete();
      }
      if (gates.length == 5 && !fiveStarted.isCompleted) fiveStarted.complete();
      request.response.add(payload);
      await request.response.flush();
      await gate.future;
      await request.response.close();
      active--;
    });
  });

  tearDown(() async {
    for (final gate in gates) {
      if (!gate.isCompleted) gate.complete();
    }
    await server.close(force: true);
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  tearDownAll(WindowsFileOperations.resetAdapter);

  test('validates concurrency and never starts more than the configured cap',
      () async {
    final scheduler = DownloadScheduler();
    expect(scheduler.maxConcurrent, 3);
    expect(() => scheduler.setMaxConcurrent(0), throwsRangeError);
    expect(() => scheduler.setMaxConcurrent(6), throwsRangeError);

    final jobs = [
      for (var i = 0; i < 5; i++)
        DownloadJob(
          url:
              Uri.parse('http://${server.address.address}:${server.port}/file'),
          destinationPath: '${temp.path}/$i.bin',
          onChanged: () {},
        ),
    ];
    for (final job in jobs) {
      scheduler.enqueue(job);
    }

    await threeStarted.future.timeout(const Duration(seconds: 5));
    expect(scheduler.activeCount, 3);
    expect(maxActive, 3);
    scheduler.setMaxConcurrent(5);
    expect(scheduler.maxConcurrent, 5);
    await fiveStarted.future.timeout(const Duration(seconds: 5));
    expect(maxActive, 5);
    for (final gate in gates.take(3)) {
      gate.complete();
    }
    for (final gate in gates) {
      if (!gate.isCompleted) gate.complete();
    }
    await Future.wait(jobs.map((job) => job.settled))
        .timeout(const Duration(seconds: 10));
    expect(jobs.every((job) => job.status == DownloadStatus.completed), isTrue);
  });
}
