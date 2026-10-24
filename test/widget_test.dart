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

  testWidgets('shows actionable guidance when the save-location picker fails',
      (tester) async {
    await tester.pumpWidget(DownloadBeastApp(
      saveLocationPicker: (_) async => throw Exception('Access denied'),
    ));

    await tester.enterText(
      find.byType(TextField),
      'https://example.com/sample.zip',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Download'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));

    expect(
      find.text(
        'Could not choose a save location. Check that the destination is '
        'available and you have permission, then try again.',
      ),
      findsOneWidget,
    );
    expect(find.text('No downloads yet'), findsOneWidget);
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
