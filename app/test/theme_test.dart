import 'package:ant_colony_manager/app/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('chip labels are readable in both themes (explicit color per state)', (tester) async {
    for (final b in Brightness.values) {
      final theme = buildTheme(b);
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: Column(
              children: [
                FilterChip(label: const Text('aus'), selected: false, onSelected: (_) {}),
                FilterChip(label: const Text('an'), selected: true, onSelected: (_) {}),
                ChoiceChip(label: const Text('choice'), selected: false, onSelected: (_) {}),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle(); // theme change is animated
      Color? color(String t) =>
          tester.widget<RichText>(find.descendant(of: find.text(t), matching: find.byType(RichText))).text.style?.color;
      expect(color('aus'), theme.colorScheme.onSurface, reason: '$b unselected');
      expect(color('choice'), theme.colorScheme.onSurface, reason: '$b choice');
      expect(color('an'), theme.colorScheme.onSecondaryContainer, reason: '$b selected');
    }
  });
}
