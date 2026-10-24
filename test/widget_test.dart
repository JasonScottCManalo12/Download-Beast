import 'package:download_beast/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows the Download Beast dashboard', (tester) async {
    await tester.pumpWidget(const DownloadBeastApp());

    expect(find.text('Download Beast'), findsOneWidget);
    expect(find.text('Add a download'), findsOneWidget);
    expect(find.text('No downloads yet'), findsOneWidget);
  });
}
