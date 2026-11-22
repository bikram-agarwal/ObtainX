import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/pages/home.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/source_provider.dart';

AppInMemory _makeListing({
  required String id,
  String? listingId,
  String? installedVersion,
  bool trackOnly = false,
}) {
  final App app = App(
    id: id,
    url: 'https://github.com/example/$id',
    author: 'example',
    name: 'Example $id',
    installedVersion: installedVersion,
    latestVersion: '1.0.0',
    apkUrls: const [],
    preferredApkIndex: 0,
    additionalSettings: {'trackOnly': trackOnly},
    lastUpdateCheck: null,
    pinned: false,
    listingId: listingId,
  );
  return AppInMemory(app, null, null, null);
}

void main() {
  group('openLinkTargets', () {
    test('is empty for null, empty, or unknown id', () {
      final AppListings apps = AppListings();
      expect(openLinkTargets(apps, null), isEmpty);
      expect(openLinkTargets(apps, '   '), isEmpty);
      expect(openLinkTargets(apps, 'com.example.missing'), isEmpty);
    });

    test('finds a single listing by package id or listing key', () {
      final AppListings apps = AppListings();
      final AppInMemory listing = _makeListing(
        id: 'com.example.app',
        listingId: 'com.example.app__fdroid',
      );
      apps[listing.listingKey] = listing;

      expect(openLinkTargets(apps, 'com.example.app'), [same(listing)]);
      expect(openLinkTargets(apps, ' com.example.app__fdroid '), [
        same(listing),
      ]);
    });

    test('a package tracked from several stores gives every listing', () {
      final AppListings apps = AppListings();
      // The first listing is keyed by the bare package ID, so a link naming
      // the package must not stop at it.
      final AppInMemory first = _makeListing(id: 'com.example.app');
      final AppInMemory fdroid = _makeListing(
        id: 'com.example.app',
        listingId: 'com.example.app__fdroid',
        installedVersion: '1.0.0',
      );
      final AppInMemory trackOnly = _makeListing(
        id: 'com.example.app',
        listingId: 'com.example.app__trackonly',
        trackOnly: true,
      );
      final AppInMemory other = _makeListing(id: 'com.example.other');
      for (final AppInMemory listing in [first, fdroid, trackOnly, other]) {
        apps[listing.listingKey] = listing;
      }

      expect(
        openLinkTargets(apps, 'com.example.app'),
        unorderedEquals([same(first), same(fdroid), same(trackOnly)]),
      );
      // A listing key still names just that listing.
      expect(openLinkTargets(apps, 'com.example.app__fdroid'), [same(fdroid)]);
    });
  });
}
