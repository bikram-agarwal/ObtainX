import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart';
import 'package:obtainium/app_sources/github.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// v1.7.5 sync (plan §6 Q3): the add page's token field for an overridden
// GitHub source holds a per-app token. Validating it must ask that app's own
// API host. For a custom (Enterprise) host it must not touch the global
// token's validated fingerprint, which build verification for every
// github.com app depends on. A github.com token keeps the old behaviour and is
// recorded as validated, so build verification can use it (Phase C).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final originalGet = GitHub.patValidationGet;
  late List<Uri> requested;
  late int status;

  setUp(() {
    requested = <Uri>[];
    status = 200;
    GitHub.patValidationGet = (Uri url, {Map<String, String>? headers}) async {
      requested.add(url);
      return Response('{}', status);
    };
  });

  tearDown(() => GitHub.patValidationGet = originalGet);

  Future<SettingsProvider> settingsWithValidatedGlobalToken() async {
    SharedPreferences.setMockInitialValues({
      GitHub.githubCredsKey: 'global-token',
      GitHub.validatedPATFingerprintKey: GitHub.patFingerprint('global-token')!,
    });
    final SettingsProvider settings = SettingsProvider();
    settings.prefs = await SharedPreferences.getInstance();
    return settings;
  }

  GitHub enterprise() => GitHub(hostChanged: true)..hosts = ['git.example.com'];

  test('a per-app token is checked against the custom host', () async {
    final SettingsProvider settings = await settingsWithValidatedGlobalToken();
    final String? error = await enterprise().validatePATFromSourceConfig(
      'per-app-token',
      settings,
    );
    expect(error, isNull);
    expect(requested, [Uri.parse('https://git.example.com/api/v3/user')]);
  });

  test('a valid per-app token leaves the global validation alone', () async {
    final SettingsProvider settings = await settingsWithValidatedGlobalToken();
    await enterprise().validatePATFromSourceConfig('per-app-token', settings);
    expect(GitHub.hasValidatedPAT('global-token', settings), isTrue);
    expect(GitHub.hasValidatedPAT('per-app-token', settings), isFalse);
  });

  test('a rejected per-app token leaves the global validation alone', () async {
    status = 401;
    final SettingsProvider settings = await settingsWithValidatedGlobalToken();
    final String? error = await enterprise().validatePATFromSourceConfig(
      'per-app-token',
      settings,
    );
    expect(error, isNotNull);
    expect(GitHub.hasValidatedPAT('global-token', settings), isTrue);
  });

  test('a github.com override checks api.github.com and, as before, records '
      'the token so build verification can use it', () async {
    final SettingsProvider settings = await settingsWithValidatedGlobalToken();
    final GitHub source = GitHub(hostChanged: true)
      ..hosts = ['github.com']
      ..hostIdenticalDespiteAnyChange = true;
    await source.validatePATFromSourceConfig('per-app-token', settings);
    expect(requested, [Uri.parse('https://api.github.com/user')]);
    expect(GitHub.hasValidatedPAT('per-app-token', settings), isTrue);
  });

  test(
    'a GitHub Enterprise Cloud data-residency host uses api.<host>',
    () async {
      final SettingsProvider settings =
          await settingsWithValidatedGlobalToken();
      final GitHub source = GitHub(hostChanged: true)
        ..hosts = ['octocorp.ghe.com'];
      await source.validatePATFromSourceConfig('per-app-token', settings);
      expect(requested, [Uri.parse('https://api.octocorp.ghe.com/user')]);
      expect(GitHub.hasValidatedPAT('global-token', settings), isTrue);
      expect(
        await source.convertStandardUrlToAPIUrl(
          'https://octocorp.ghe.com/team/app',
          const {},
        ),
        'https://api.octocorp.ghe.com/repos/team/app',
      );
    },
  );

  test('the global token keeps being validated and stored', () async {
    final SettingsProvider settings = await settingsWithValidatedGlobalToken();
    await GitHub().validatePATFromSourceConfig('new-token', settings);
    expect(requested, [Uri.parse('https://api.github.com/user')]);
    expect(GitHub.hasValidatedPAT('new-token', settings), isTrue);

    status = 401;
    await GitHub().validatePATFromSourceConfig('new-token', settings);
    expect(GitHub.hasValidatedPAT('new-token', settings), isFalse);
  });

  test('Settings keeps validating against api.github.com', () async {
    expect(await GitHub.validatePAT('token'), isNull);
    expect(requested, [Uri.parse('https://api.github.com/user')]);
  });
}
