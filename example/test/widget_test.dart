import 'package:flutter_test/flutter_test.dart';
import 'package:live_photos_example/main.dart';

void main() {
  testWidgets('App renders correctly', (WidgetTester tester) async {
    await tester.pumpWidget(const LivePhotosTestApp());

    expect(find.text('Live Photos Test'), findsOneWidget);
    expect(find.text('Generate from URL → Save to Gallery'), findsOneWidget);
    expect(find.text('Generate from URL → Files Only'), findsOneWidget);
    expect(find.text('Clean Up Temp Files'), findsOneWidget);
    expect(find.text('Ready'), findsOneWidget);
  });
}
