import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/source_provider.dart';

// What an add (Import from URL list, or a link another app sent) skips
// before fetching anything, for apps a link or JSON names by package. These
// were the link importer's own rules; they carried over when links moved to
// the URL list's flow.

const String _packageId = 'com.example.app';
const String _githubUrl = 'https://github.com/example/app';
const String _fdroidUrl = 'https://f-droid.org/packages/com.example.app/';

App _app({
  String id = _packageId,
  String? listingId,
  required String url,
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
  );
}

AppListings _listingsOf(List<App> apps) {
  final AppListings listings = AppListings();
  for (final App app in apps) {
    listings[app.listingKey] = AppInMemory(app, null, null, null);
  }
  return listings;
}

UrlImportPlan _plan(AppListings listings, List<App> linked) => planUrlImport(
  listings,
  [for (final App app in linked) UrlImportEntry(app.url, seed: app)],
  SourceProvider(),
);

void main() {
  test('an app that is already tracked is listed, not fetched', () {
    final App tracked = _app(url: _githubUrl, name: 'Renamed by the user');

    final UrlImportPlan plan = _plan(_listingsOf([tracked]), [
      _app(url: _githubUrl),
    ]);

    expect(plan.toFetch, isEmpty);
    expect(plan.alreadyTracked.single.listingKey, tracked.listingKey);
    expect(plan.alreadyTracked.single.app.name, 'Renamed by the user');
  });

  test('the same package from a second store is added', () {
    final UrlImportPlan plan = _plan(_listingsOf([_app(url: _githubUrl)]), [
      _app(url: _fdroidUrl),
    ]);

    expect(plan.alreadyTracked, isEmpty);
    expect(plan.toFetch.single.url, _fdroidUrl);
  });

  test('a store tracked under a listing ID is still found', () {
    // The package is tracked from F-Droid (bare key) and GitHub (listing ID).
    final App github = _app(
      listingId: appListingKey(_packageId, 'GitHub'),
      url: _githubUrl,
    );
    final UrlImportPlan plan = _plan(
      _listingsOf([_app(url: _fdroidUrl), github]),
      [_app(url: _githubUrl)],
    );

    expect(plan.toFetch, isEmpty);
    expect(plan.alreadyTracked.single.listingKey, github.listingKey);
  });

  test('a batch fetches only its new apps', () {
    final UrlImportPlan plan = _plan(_listingsOf([_app(url: _githubUrl)]), [
      _app(url: _githubUrl),
      _app(id: 'com.example.other', url: 'https://github.com/example/other'),
    ]);

    expect(plan.toFetch.map((UrlImportEntry entry) => entry.seed!.id), [
      'com.example.other',
    ]);
    expect(plan.alreadyTracked.single.listingKey, _packageId);
  });

  test('duplicate entries are fetched once', () {
    final UrlImportPlan plan = _plan(AppListings(), [
      _app(url: _githubUrl),
      _app(url: _githubUrl),
    ]);

    expect(plan.toFetch, hasLength(1));
    expect(plan.alreadyTracked, isEmpty);
  });

  test('two stores for one package are both fetched', () {
    final UrlImportPlan plan = _plan(AppListings(), [
      _app(url: _githubUrl),
      _app(url: _fdroidUrl),
    ]);

    expect(plan.toFetch.map((UrlImportEntry entry) => entry.url), [
      _githubUrl,
      _fdroidUrl,
    ]);
  });

  test('a listing duplicated twice is listed once', () {
    final UrlImportPlan plan = _plan(_listingsOf([_app(url: _githubUrl)]), [
      _app(url: _githubUrl),
      _app(url: _githubUrl),
    ]);

    expect(plan.toFetch, isEmpty);
    expect(plan.alreadyTracked, hasLength(1));
  });

  test('planning leaves the library untouched', () {
    final AppListings listings = _listingsOf([_app(url: _githubUrl)]);

    _plan(listings, [
      _app(url: _fdroidUrl),
      _app(id: 'com.example.other', url: 'https://github.com/example/other'),
    ]);

    expect(listings.keys, [_packageId]);
  });
}
