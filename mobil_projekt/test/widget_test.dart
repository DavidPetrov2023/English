// Basic Flutter widget test for English Learning app

import 'package:flutter_test/flutter_test.dart';

import 'package:english_learning/main.dart';

void main() {
  testWidgets('App starts and shows title', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const EnglishLearningApp());

    // Wait for async operations
    await tester.pumpAndSettle();

    // Verify that the app title is displayed
    expect(find.text('English Learning'), findsOneWidget);
  });
}
