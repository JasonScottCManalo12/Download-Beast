enum DownloadFailureKind {
  connectionTimeout,
  responseHeaderTimeout,
  idleBodyTimeout,
  network,
  http,
  filesystem,
  protocol,
  integrity,
  cancelled,
}

class DownloadTimeouts {
  const DownloadTimeouts({
    this.connection = const Duration(seconds: 15),
    this.responseHeader = const Duration(seconds: 30),
    this.idleBody = const Duration(seconds: 30),
  });

  final Duration connection;
  final Duration responseHeader;
  final Duration idleBody;
}

class DownloadTimeoutException implements Exception {
  const DownloadTimeoutException(this.kind);
  final DownloadFailureKind kind;
}

class DownloadFailure implements Exception {
  const DownloadFailure(this.kind, this.message);
  final DownloadFailureKind kind;
  final String message;
  @override
  String toString() => message;
}
