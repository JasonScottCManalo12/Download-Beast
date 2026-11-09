import 'package:download_beast/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pumpAtMinimum(WidgetTester tester, Widget app) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 600);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(app);
  }

  testWidgets('shows the Download Beast dashboard', (tester) async {
    await pumpAtMinimum(tester, const DownloadBeastApp());

    expect(find.text('Download Beast'), findsOneWidget);
    expect(find.text('Add a download'), findsOneWidget);
    expect(find.text('No queued or active downloads'), findsOneWidget);
  });

  testWidgets(
      'prompts for a URL when Download is activated with an empty field',
      (tester) async {
    await pumpAtMinimum(tester, const DownloadBeastApp());

    await tester.tap(find.widgetWithText(FilledButton, 'Download'));
    await tester.pump();

    expect(find.text('Enter a download URL.'), findsOneWidget);
    expect(find.text('No queued or active downloads'), findsOneWidget);
  });

  testWidgets('exposes a semantic label for the URL input and Download action',
      (tester) async {
    await pumpAtMinimum(tester, const DownloadBeastApp());

    expect(find.bySemanticsLabel('Download URL'), findsWidgets);
    expect(find.bySemanticsLabel(RegExp(r'^Download$')), findsOneWidget);
  });

  testWidgets('shows actionable guidance when the save-location picker fails',
      (tester) async {
    var pickerCalls = 0;
    await pumpAtMinimum(tester, DownloadBeastApp(
      saveLocationPicker: (_) async {
        pickerCalls++;
        throw Exception('Access denied');
      },
    ));

    await tester.enterText(
      find.byType(TextField).first,
      'https://example.com/sample.zip',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Download'));
    await tester.pump();

    expect(pickerCalls, 1,
        reason: 'The save-location picker should be invoked after validation.');
    expect(
      find.text(
        'Could not choose a save location. Check that the destination is '
        'available and you have permission, then try again.',
      ),
      findsOneWidget,
    );
    expect(find.text('No queued or active downloads'), findsOneWidget);
  });

  testWidgets('rejects non-HTTP URLs without opening the save picker',
      (tester) async {
    await pumpAtMinimum(tester, const DownloadBeastApp());

    await tester.enterText(
      find.byType(TextField).first,
      'file:///private/file.txt',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Download'));
    await tester.pump();

    expect(find.text('Enter a valid HTTP or HTTPS URL.'), findsOneWidget);
    expect(find.text('No queued or active downloads'), findsOneWidget);
  });

  testWidgets('minimum logical window has no overflow at 100 and 150 percent',
      (tester) async {
    await pumpAtMinimum(tester, const DownloadBeastApp());
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    tester.view.devicePixelRatio = 1.5;
    tester.view.physicalSize = const Size(1350, 900);
    await tester.pumpWidget(const DownloadBeastApp());
    expect(tester.takeException(), isNull);
  });
}
