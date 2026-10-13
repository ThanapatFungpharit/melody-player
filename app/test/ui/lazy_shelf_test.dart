import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:melody/ui/shared/widgets.dart";

void main() {
  testWidgets("lazy shelf builds only the cards in or near view", (
    tester,
  ) async {
    final built = <int>{};
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            child: LazyShelf(
              itemCount: 500,
              prototype: const SizedBox(width: 100, height: 120),
              itemBuilder: (context, index) {
                built.add(index);
                return SizedBox(width: 100, child: Text("Card $index"));
              },
            ),
          ),
        ),
      ),
    );

    expect(tester.getSize(find.byType(LazyShelf)).height, 120);
    expect(built, contains(0));
    expect(built.length, lessThan(20));
    expect(find.text("Card 499"), findsNothing);

    await tester.dragUntilVisible(
      find.text("Card 60"),
      find.byType(ListView),
      const Offset(-300, 0),
    );
    expect(find.text("Card 60"), findsOneWidget);
  });
}
