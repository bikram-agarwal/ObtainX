import 'dart:async';
import 'dart:ui' show Locale;

import 'package:easy_localization/easy_localization.dart';
// ignore: implementation_imports
import 'package:easy_localization/src/localization.dart';
// ignore: implementation_imports
import 'package:easy_localization/src/translations.dart';
import 'package:flutter_test/flutter_test.dart';

// Flutter applies this file to every suite under test/ automatically.
//
// Localization.instance is a lazily created singleton that holds no
// translations until Localization.load runs, which only happens in main() and
// bgUpdateCheck. Each test file runs in its own isolate, so without this hook
// every tr() call logs a "Localization key [...] not found" warning and returns
// the raw key instead of the English string.
//
// No fallback bundle is registered on purpose: English is the reference set, so
// a key that is genuinely absent from en.json should still warn.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Drop easy_localization's debug/info chatter (one "Load asset" line per
  // suite) while keeping warnings, so a key missing from en.json still shows up.
  // Filtered by name rather than against LevelMessages, which lives in the
  // transitive easy_logger package this project does not depend on directly.
  EasyLocalization.logger.enableLevels = EasyLocalization.logger.enableLevels
      .where((level) => level.name != 'debug' && level.name != 'info')
      .toList();
  final english = await const RootBundleAssetLoader().load(
    'assets/translations',
    const Locale('en'),
  );
  Localization.load(const Locale('en'), translations: Translations(english!));
  await testMain();
}
