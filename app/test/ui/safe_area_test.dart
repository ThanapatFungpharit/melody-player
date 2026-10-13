import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:melody/ui/shared/safe_area.dart";

/// An edge-to-edge Android phone: status bar, three-button navigation bar,
/// and a landscape-style cutout on the left, in physical pixels at 3x.
const _ratio = 3.0;
const _status = 24.0;
const _navigation = 48.0;
const _cutout = 30.0;
const _screen = Size(400, 800);

void main() {
  Future<void> pump(WidgetTester tester, Widget home) async {
    tester.view
      ..devicePixelRatio = _ratio
      ..physicalSize = _screen * _ratio
      ..padding = const FakeViewPadding(
        left: _cutout * _ratio,
        top: _status * _ratio,
        bottom: _navigation * _ratio,
      )
      ..viewPadding = const FakeViewPadding(
        left: _cutout * _ratio,
        top: _status * _ratio,
        bottom: _navigation * _ratio,
      );
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => SafeAreaGuard(child: child!),
        home: home,
      ),
    );
  }

  const safe = Rect.fromLTRB(_cutout, _status, 400, 800 - _navigation);

  void expectInside(WidgetTester tester, Finder finder) {
    final box = tester.getRect(finder);
    expect(
      box.left >= safe.left &&
          box.top >= safe.top &&
          box.right <= safe.right &&
          box.bottom <= safe.bottom,
      isTrue,
      reason: "$box should lie inside the safe area $safe",
    );
  }

  testWidgets("MediaQuery describes only the safe rectangle", (tester) async {
    late MediaQueryData inner;
    await pump(
      tester,
      Builder(
        builder: (context) {
          inner = MediaQuery.of(context);
          return const SizedBox.expand();
        },
      ),
    );
    expect(inner.size, safe.size);
    expect(inner.padding, EdgeInsets.zero);
    expect(inner.viewPadding, EdgeInsets.zero);
  });

  testWidgets("bottom sheets stay above the navigation bar", (tester) async {
    await pump(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () => showModalBottomSheet<void>(
            context: context,
            useSafeArea: true,
            isScrollControlled: true,
            builder: (_) => ListView(
              shrinkWrap: true,
              children: [
                for (var index = 0; index < 40; index++)
                  ListTile(title: Text("Action $index")),
              ],
            ),
          ),
          child: const Text("Open"),
        ),
      ),
    );
    await tester.tap(find.text("Open"));
    await tester.pumpAndSettle();
    expectInside(tester, find.byType(BottomSheet));
  });

  testWidgets("dialogs stay inside the safe area", (tester) async {
    await pump(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () => showDialog<void>(
            context: context,
            useSafeArea: false,
            builder: (_) => AlertDialog(
              insetPadding: EdgeInsets.zero,
              content: SingleChildScrollView(
                child: Column(
                  children: [
                    for (var index = 0; index < 40; index++)
                      Text("Line $index"),
                  ],
                ),
              ),
              actions: const [Text("Close")],
            ),
          ),
          child: const Text("Open"),
        ),
      ),
    );
    await tester.tap(find.text("Open"));
    await tester.pumpAndSettle();
    expectInside(tester, find.byType(Dialog));
    expectInside(tester, find.text("Close"));
  });

  testWidgets("the keyboard replaces the navigation bar inset", (tester) async {
    const keyboard = 300.0;
    const body = Key("body");
    await pump(tester, const Scaffold(body: SizedBox.expand(key: body)));
    tester.view
      ..padding = const FakeViewPadding(
        left: _cutout * _ratio,
        top: _status * _ratio,
      )
      ..viewInsets = const FakeViewPadding(bottom: keyboard * _ratio);
    await tester.pump();
    expect(tester.getRect(find.byKey(body)).bottom, 800 - keyboard);
  });
}
