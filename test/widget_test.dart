import 'package:download_beast/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows the Download Beast dashboard', (tester) async {
    await tester.pumpWidget(const DownloadBeastApp());

    expect(find.text('Download Beast'), findsOneWidget);
    expect(find.text('Add a download'), findsOneWidget);
    expect(find.text('No downloads yet'), findsOneWidget);
  });

  testWidgets('prompts for a URL when Download is activated with an empty field',
      (tester) async {
    await tester.pumpWidget(const DownloadBeastApp());

    await tester.tap(find.widgetWithText(FilledButton, 'Download'));
    await tester.pump();

    expect(find.text('Enter a download URL.'), findsOneWidget);
    expect(find.text('No downloads yet'), findsOneWidget);
  });

  testWidgets('exposes a semantic label for the URL input and Download action',
      (tester) async {
    await tester.pumpWidget(const DownloadBeastApp());

    expect(find.bySemanticsLabel('Download URL'), findsOneWidget);
    expect(find.bySemanticsLabel('Download'), findsOneWidget);
  });

  testWidgets('rejects non-HTTP URLs without opening the save picker',
      (tester) async {
    await tester.pumpWidget(const DownloadBeastApp());

    await tester.enterText(find.byType(TextField), 'file:///private/file.txt');
    await tester.tap(find.widgetWithText(FilledButton, 'Download'));
    await tester.pump();

    expect(find.text('Enter a valid HTTP or HTTPS URL.'), findsOneWidget);
    expect(find.text('No downloads yet'), findsOneWidget);
  });
}
