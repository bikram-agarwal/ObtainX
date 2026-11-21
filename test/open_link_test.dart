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
  group('resolveOpenLinkTarget', () {
    test('returns null for null, empty, or unknown id', () {
      final AppListings apps = AppListings();
      expect(resolveOpenLinkTarget(apps, null), isNull);
      expect(resolveOpenLinkTarget(apps, '   '), isNull);
      expect(resolveOpenLinkTarget(apps, 'com.example.missing'), isNull);
    });

    test('resolves a single listing by package id or listingKey', () {
      final AppListings apps = AppListings();
      final AppInMemory listing = _makeListing(
        id: 'com.example.app',
        listingId: 'com.example.app__fdroid',
      );
      apps[listing.listingKey] = listing;

      expect(resolveOpenLinkTarget(apps, 'com.example.app'), same(listing));
      expect(
        resolveOpenLinkTarget(apps, 'com.example.app__fdroid'),
        same(listing),
      );
    });

    test('prefers installed non-track-only listing among multiple stores', () {
      final AppListings apps = AppListings();
      final AppInMemory trackOnlyListing = _makeListing(
        id: 'com.example.app',
        listingId: 'com.example.app__trackonly',
        installedVersion: '1.0.0',
        trackOnly: true,
      );
      final AppInMemory uninstalledListing = _makeListing(
        id: 'com.example.app',
        listingId: 'com.example.app__github',
      );
      final AppInMemory installedListing = _makeListing(
        id: 'com.example.app',
        listingId: 'com.example.app__fdroid',
        installedVersion: '1.0.0',
      );
      apps[trackOnlyListing.listingKey] = trackOnlyListing;
      apps[uninstalledListing.listingKey] = uninstalledListing;
      apps[installedListing.listingKey] = installedListing;

      expect(
        resolveOpenLinkTarget(apps, 'com.example.app'),
        same(installedListing),
      );
    });
  });
}
