/// The ▶ badge must not bury a small thumbnail (M5 §C/§D).
///
/// The user's report — "挡住了看不清" — is the **list** size: a 40dp row thumbnail
/// (`kListIconDiameter`) under a **fixed 36dp** badge, i.e. the badge covered
/// most of the frame. The badge must stay on the big ones (a bubble's cover, the
/// media wall), which the user explicitly said not to touch.
///
/// Written **before** the fix, so the small-size case is a genuine red first.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/ui/widgets/file_thumbnail.dart';

import '../support/pump_app.dart';

Future<void> _pump(WidgetTester tester, double edge) => pumpApp(
      tester,
      Scaffold(
        body: Center(
          child: FileThumbnail(
            fileName: 'clip.mp4',
            mime: 'video/mp4',
            path: '/src/clip.mp4',
            edge: edge,
          ),
        ),
      ),
      settle: true,
    );

void main() {
  testWidgets('a small thumbnail carries no ▶ (it would bury the frame)',
      (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(600, 800));
    await _pump(tester, 40); // the list size, kListIconDiameter
    // ignore: avoid_print
    print('BADGE small(40): '
        '${find.byIcon(Icons.play_circle_fill).evaluate().length}');
    expect(
      find.byIcon(Icons.play_circle_fill),
      findsNothing,
      reason: 'at 40dp a 36dp badge covers the frame — the user says '
          '"挡住了看不清"',
    );
  });

  testWidgets('a large thumbnail keeps its ▶', (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(600, 800));
    await _pump(tester, 240); // a bubble cover / the media wall
    // ignore: avoid_print
    print('BADGE large(240): '
        '${find.byIcon(Icons.play_circle_fill).evaluate().length}');
    expect(
      find.byIcon(Icons.play_circle_fill),
      findsOneWidget,
      reason: 'the badge stays where there is room for it',
    );
  });
}
