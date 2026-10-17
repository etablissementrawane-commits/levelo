import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habgame/main.dart';

void main() {
  testWidgets('glass surface renders its content', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Glass(child: Text('QuestLog'))),
    );
    expect(find.text('QuestLog'), findsOneWidget);
  });
}
