import 'package:datadisplay_app/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('app shell renders key workspace labels', (tester) async {
    tester.view.physicalSize = const Size(1440, 1024);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const DatadisplayApp());
    await tester.pumpAndSettle();

    expect(find.text('DATADISPLAY'), findsOneWidget);
    expect(find.text('Session'), findsWidgets);
    expect(find.text('Plots'), findsWidgets);
    expect(find.text('Plot window'), findsOneWidget);
    expect(find.text('Series deck'), findsOneWidget);
  });
}
