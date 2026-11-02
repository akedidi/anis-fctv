import 'package:fctv33/shared/tv_focus.dart';
import 'package:fctv33/shared/tv_search_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Down from search enters the open letter pad', (tester) async {
    final controller = TextEditingController();
    final tableFocus = FocusNode();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              TvSearchField(controller: controller),
              TvFocusable(
                focusNode: tableFocus,
                onActivate: () {},
                child: const Text('Match table'),
              ),
            ],
          ),
        ),
      ),
    );

    final searchFocus = tester
        .widget<Focus>(
          find
              .descendant(
                of: find.byType(TvSearchField),
                matching: find.byType(Focus),
              )
              .first,
        )
        .focusNode!;
    searchFocus.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();

    // Return to the search chip with the pad still visible.
    searchFocus.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(controller.text, 'a');
    expect(tableFocus.hasFocus, isFalse);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(searchFocus.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(tableFocus.hasFocus, isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    tableFocus.dispose();
  });
}
