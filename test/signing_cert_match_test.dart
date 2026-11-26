import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/providers/apps_provider_install.dart';

// Upstream #3490's cases (Wire 4.37.0 -> 4.37.1), run against ObtainX's rule
// (v1.7.5 sync D-04). ObtainX accepts an APK that shares any certificate with
// the installed app: a rotation lineage holding a certificate can only be made
// with that certificate's key. Upstream instead requires every APK certificate
// to be installed, or a lineage flag; both rules agree on every case below
// except the one marked.
void main() {
  group('signingCertificatesOverlap', () {
    test('matches identical certificates', () {
      expect(signingCertificatesOverlap({'current'}, {'current'}), isTrue);
    });

    test('matches when the installed history is a superset', () {
      expect(
        signingCertificatesOverlap({'current'}, {'old', 'current'}),
        isTrue,
      );
    });

    // Upstream accepts this only when the APK reports a lineage
    // (hasPastSigningCertificates) and warns otherwise. ObtainX never reads
    // that flag, and Android verifies the lineage at install either way.
    test('accepts a rotated APK that carries the installed certificate', () {
      expect(
        signingCertificatesOverlap({'old', 'current'}, {'current'}),
        isTrue,
      );
    });

    test('rejects an APK signed only with a past certificate', () {
      expect(signingCertificatesOverlap({'old'}, {'current'}), isFalse);
    });

    test('rejects unrelated certificates', () {
      expect(signingCertificatesOverlap({'attacker'}, {'current'}), isFalse);
    });

    test('rejects empty hash sets', () {
      expect(signingCertificatesOverlap(<String>{}, {'current'}), isFalse);
      expect(signingCertificatesOverlap({'current'}, <String>{}), isFalse);
    });
  });
}
