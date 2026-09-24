import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/source_provider.dart';

const String _packageId = 'com.example.app';
const String _githubUrl = 'https://github.com/example/app';
const String _fdroidUrl = 'https://f-droid.org/packages/com.example.app/';

App _app({
  String id = _packageId,
  String? listingId,
  required String url,
  String? overrideSource,
  String name = 'Example',
}) {
  return App(
    id: id,
    listingId: listingId,
    url: url,
    author: 'Author',
    name: name,
    latestVersion: '1.0',
    preferredApkIndex: 0,
    additionalSettings: {},
    overrideSource: overrideSource,
  );
}

AppListings _listingsOf(List<App> apps) {
  final AppListings listings = AppListings();
  for (final App app in apps) {
    listings[app.listingKey] = AppInMemory(app, null, null, null);
  }
  return listings;
}

void main() {
  test('a link for a listing that is already tracked adds nothing', () {
    final App tracked = _app(url: _githubUrl, name: 'Renamed by the user');
    final AppListings listings = _listingsOf([tracked]);

    final LinkImportPlan plan = planLinkImport(listings, [
      _app(url: _githubUrl),
    ]);

    expect(plan.toAdd, isEmpty);
    expect(plan.alreadyTracked.single.listingKey, tracked.listingKey);
    expect(plan.alreadyTracked.single.app.name, 'Renamed by the user');
  });

  test('a link from a second store becomes a further listing', () {
    final AppListings listings = _listingsOf([_app(url: _githubUrl)]);

    final LinkImportPlan plan = planLinkImport(listings, [
      _app(url: _fdroidUrl),
    ]);

    expect(plan.alreadyTracked, isEmpty);
    expect(plan.toAdd.single.listingKey, 'com.example.app@FDroid');
    expect(plan.toAdd.single.url, _fdroidUrl);
  });

  test('a new package keeps its package ID as its key', () {
    final AppListings listings = _listingsOf([_app(url: _githubUrl)]);

    final LinkImportPlan plan = planLinkImport(listings, [
      _app(id: 'com.example.other', url: 'https://github.com/example/other'),
    ]);

    expect(plan.toAdd.single.listingKey, 'com.example.other');
    expect(plan.toAdd.single.listingId, isNull);
  });

  test('a store tracked under a listing ID is still found', () {
    // The package is tracked from F-Droid (bare key) and GitHub (listing ID).
    // A GitHub link must find the second one, not overwrite the first.
    final App fdroid = _app(url: _fdroidUrl);
    final App github = _app(
      listingId: appListingKey(_packageId, 'GitHub'),
      url: _githubUrl,
    );
    final AppListings listings = _listingsOf([fdroid, github]);

    final LinkImportPlan plan = planLinkImport(listings, [
      _app(url: _githubUrl),
    ]);

    expect(plan.toAdd, isEmpty);
    expect(plan.alreadyTracked.single.listingKey, github.listingKey);
  });

  test('a listing ID carried by the link is ignored', () {
    // Kept as-is, this ID would save the repo listing over the F-Droid one.
    final App fdroid = _app(
      listingId: appListingKey(_packageId, 'FDroid'),
      url: _fdroidUrl,
    );
    final AppListings listings = _listingsOf([_app(url: _githubUrl), fdroid]);

    final LinkImportPlan plan = planLinkImport(listings, [
      _app(
        listingId: fdroid.listingKey,
        url: 'https://repo.example.com/fdroid/repo',
        overrideSource: 'FDroidRepo',
      ),
    ]);

    final App added = plan.toAdd.single;
    expect(added.listingKey, isNot(fdroid.listingKey));
    expect(added.listingKey, isNot(_packageId));
    expect(listings.containsListingKey(added.listingKey), isFalse);
  });

  test('a batch adds only its new apps', () {
    final AppListings listings = _listingsOf([_app(url: _githubUrl)]);

    final LinkImportPlan plan = planLinkImport(listings, [
      _app(url: _githubUrl),
      _app(id: 'com.example.other', url: 'https://github.com/example/other'),
    ]);

    expect(plan.toAdd.map((app) => app.listingKey), ['com.example.other']);
    expect(plan.alreadyTracked.single.listingKey, _packageId);
  });

  test('duplicate entries in one payload add one listing', () {
    final LinkImportPlan plan = planLinkImport(AppListings(), [
      _app(url: _githubUrl),
      _app(url: _githubUrl),
    ]);

    expect(plan.toAdd.single.listingKey, _packageId);
    // The second entry matched the first, not anything in the library.
    expect(plan.alreadyTracked, isEmpty);
  });

  test('two stores for one package in one payload get distinct keys', () {
    final LinkImportPlan plan = planLinkImport(AppListings(), [
      _app(url: _githubUrl),
      _app(url: _fdroidUrl),
    ]);

    expect(plan.toAdd.map((app) => app.listingKey), [
      _packageId,
      'com.example.app@FDroid',
    ]);
  });

  test('a listing duplicated twice is reported once', () {
    final AppListings listings = _listingsOf([_app(url: _githubUrl)]);

    final LinkImportPlan plan = planLinkImport(listings, [
      _app(url: _githubUrl),
      _app(url: _githubUrl),
    ]);

    expect(plan.toAdd, isEmpty);
    expect(plan.alreadyTracked.length, 1);
  });

  test('planning leaves the library untouched', () {
    final AppListings listings = _listingsOf([_app(url: _githubUrl)]);

    planLinkImport(listings, [
      _app(url: _fdroidUrl),
      _app(id: 'com.example.other', url: 'https://github.com/example/other'),
    ]);

    expect(listings.keys, [_packageId]);
  });
}
