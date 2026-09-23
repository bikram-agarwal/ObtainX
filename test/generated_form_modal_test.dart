import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/components/generated_form_renderer.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/theme/app_dialog_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Labels resolve to raw translation keys here (easy_localization is not
/// initialised in tests), which affects neither the measured width nor which
/// buttons are enabled.
void main() {
  const Size phone = Size(1080, 2400);
  const double dpr = 2.625;
  const double epsilon = 0.5;
  // [Dialog.insetPadding]'s default, 40 per side.
  const double dialogInsetPadding = 80;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  /// [AlertDialog] carries its own [Dialog] chrome (inset padding, centering,
  /// the 280dp floor), so pumping it directly lays out exactly as a showDialog
  /// route would - without leaving a route behind between cases.
  Future<void> pumpModal(
    WidgetTester tester, {
    required String title,
    required String initialUrl,
  }) async {
    tester.view.physicalSize = phone;
    tester.view.devicePixelRatio = dpr;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsProvider>(
        create: (_) => SettingsProvider(),
        child: MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: GeneratedFormModal(
            title: title,
            items: <List<GeneratedFormItem>>[
              <GeneratedFormItem>[
                GeneratedFormTextField('url', label: 'url', value: initialUrl),
              ],
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// [AlertDialog]'s own box spans the screen because it contains
  /// [Dialog.insetPadding]; the visible surface is the Material inside it.
  double dialogSurfaceWidth(WidgetTester tester) => tester
      .getSize(
        find
            .descendant(
              of: find.byType(Dialog),
              matching: find.byType(Material),
            )
            .first,
      )
      .width;

  testWidgets('width does not depend on title length', (
    WidgetTester tester,
  ) async {
    // AlertDialog measures itself with an IntrinsicWidth, so an unpinned
    // dialog is only as wide as its longest line of text: a short title
    // collapsed to Dialog's 280dp floor while "Search F-Droid third-party
    // repo" filled the screen, and identical fields read as pinched in the
    // narrow one.
    await pumpModal(tester, title: 'Search', initialUrl: '');
    final double shortTitleWidth = dialogSurfaceWidth(tester);
    await pumpModal(
      tester,
      title: 'Search F-Droid third-party repo',
      initialUrl: '',
    );
    final double longTitleWidth = dialogSurfaceWidth(tester);

    expect(shortTitleWidth, closeTo(longTitleWidth, epsilon));
    // Pinned, not merely equal: both must use the width the dialog can occupy
    // rather than collapsing to Dialog's 280dp minimum.
    expect(
      shortTitleWidth,
      closeTo(
        min(
          phone.width / dpr - dialogInsetPadding,
          appDialogContentWidth + appDialogContentPadding.horizontal,
        ),
        epsilon,
      ),
    );
  });

  testWidgets('a prefilled form can be confirmed without editing it', (
    WidgetTester tester,
  ) async {
    await pumpModal(
      tester,
      title: 'Search F-Droid third-party repo',
      initialUrl: 'https://apt.izzysoft.de/fdroid/repo',
    );

    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNotNull,
    );
  });

  testWidgets('an empty required field blocks confirming, silently', (
    WidgetTester tester,
  ) async {
    await pumpModal(tester, title: 'Search repo', initialUrl: '');

    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    // Validity is settled from the values, not by running the field
    // validators, so an untouched form doesn't open pre-marked with errors.
    expect(find.textContaining('requiredInBrackets'), findsNothing);
  });
}
