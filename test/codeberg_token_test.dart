// Codeberg access token validation in Settings (v1.7.4 sync): the answer
// codeberg.org gives to GET /api/v1/user with the token.

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/app_sources/codeberg.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Codeberg.tokenValidationError', () {
    test('200 is valid', () {
      expect(Codeberg.tokenValidationError(200, '{}'), isNull);
    });

    test('401 is an invalid token', () {
      expect(
        Codeberg.tokenValidationError(401, '{"message":"token is invalid"}'),
        tr('codebergTokenInvalid'),
      );
    });

    test('403 for a missing read:user scope is still a valid token', () {
      expect(
        Codeberg.tokenValidationError(
          403,
          '{"message":"token does not have at least one of required scope(s): [read:user]"}',
        ),
        isNull,
      );
    });

    test('other 403s and 429 are reported as rate limits', () {
      expect(
        Codeberg.tokenValidationError(403, 'Forbidden'),
        tr('codebergTokenValidationRateLimited'),
      );
      expect(
        Codeberg.tokenValidationError(429, ''),
        tr('codebergTokenValidationRateLimited'),
      );
    });

    test('anything else is a failed validation', () {
      expect(
        Codeberg.tokenValidationError(500, ''),
        tr('codebergTokenValidationFailed'),
      );
    });
  });

  test('a validated token is remembered by fingerprint only', () async {
    SharedPreferences.setMockInitialValues({});
    final SettingsProvider sp = SettingsProvider()
      ..prefs = await SharedPreferences.getInstance();
    expect(Codeberg.hasValidatedToken('abc', sp), isFalse);
    Codeberg.storeTokenValidation('abc', sp);
    expect(Codeberg.hasValidatedToken('abc', sp), isTrue);
    expect(Codeberg.hasValidatedToken('abd', sp), isFalse);
    expect(
      sp.getSettingString(Codeberg.validatedTokenFingerprintKey),
      isNot(contains('abc')),
    );
    Codeberg.clearTokenValidation(sp);
    expect(Codeberg.hasValidatedToken('abc', sp), isFalse);
  });
}
