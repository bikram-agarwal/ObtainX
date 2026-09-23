import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/source_provider.dart';

const String _packageId = 'com.example.app';
const String _githubUrl = 'https://github.com/example/app';
const String _fdroidUrl = 'https://f-droid.org/packages/com.example.app/';

App _listing({String? listingId, required String url, String? overrideSource}) {
  return App(
    id: _packageId,
    listingId: listingId,
    url: url,
    author: 'Author',
    name: 'Example',
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
  test('a package\'s only listing is keyed by its package ID', () {
    final App github = _listing(url: _githubUrl);
    expect(github.listingKey, _packageId);
    expect(github.toJson().containsKey('listingId'), isFalse);
  });

  test('a second store gets its own stable listing key', () {
    final App fdroid = _listing(
      listingId: appListingKey(_packageId, 'FDroid'),
      url: _fdroidUrl,
    );
    expect(fdroid.listingKey, 'com.example.app@FDroid');
    expect(fdroid.listingKey, isNot(_listing(url: _githubUrl).listingKey));
    expect(App.fromJson(fdroid.toJson()).listingKey, fdroid.listingKey);
  });

  test('swapping the tracked source keeps the listing key', () {
    final App fdroid = _listing(
      listingId: appListingKey(_packageId, 'FDroid'),
      url: _fdroidUrl,
    );
    // What a GitHub -> F-Droid -> GitHub swap does: the URL (and so the
    // resolved store) changes, the record identity must not.
    final App swappedToGitHub = fdroid.copyWith(url: _githubUrl);
    expect(sourceIdentifierForApp(fdroid), 'FDroid');
    expect(sourceIdentifierForApp(swappedToGitHub), 'GitHub');
    expect(swappedToGitHub.listingKey, fdroid.listingKey);
  });

  test('AppListings holds both stores of one package', () {
    final App github = _listing(url: _githubUrl);
    final App fdroid = _listing(
      listingId: appListingKey(_packageId, 'FDroid'),
      url: _fdroidUrl,
    );
    final AppListings listings = AppListings();
    listings[github.listingKey] = AppInMemory(github, null, null, null);
    listings[fdroid.listingKey] = AppInMemory(fdroid, null, null, null);

    expect(listings.length, 2);
    expect(listings.containsListingKey(_packageId), isTrue);
    expect(listings.containsListingKey('com.example.app@FDroid'), isTrue);
    expect(listings.listingsForPackage(_packageId).length, 2);
    // The package ID is one of the two keys, so it still resolves exactly.
    expect(listings[_packageId]?.app.url, _githubUrl);
  });

  test('a swap into an already-tracked store is a same-store collision', () {
    final App github = _listing(url: _githubUrl);
    final App fdroid = _listing(
      listingId: appListingKey(_packageId, 'FDroid'),
      url: _fdroidUrl,
    );
    final AppListings listings = _listingsOf([github, fdroid]);

    // What swapTrackedSource checks: the GitHub listing rewritten to the
    // F-Droid URL collides with the existing F-Droid listing, while the
    // F-Droid listing keeping its own URL does not collide with itself.
    expect(
      sameStoreListingIn(
        listings,
        github.copyWith(url: _fdroidUrl),
        ignoreKey: github.listingKey,
      )?.listingKey,
      fdroid.listingKey,
    );
    expect(
      sameStoreListingIn(listings, fdroid, ignoreKey: fdroid.listingKey),
      isNull,
    );
  });

  test('re-adding the store a package is already tracked from collides', () {
    // The listing being added has no listing ID yet, so its key is the bare
    // package ID - the same key as the package's first listing. That must not
    // excuse the listing it duplicates, or the add creates a second record.
    final App github = _listing(url: _githubUrl);
    final AppListings listings = _listingsOf([github]);

    expect(
      sameStoreListingIn(listings, _listing(url: _githubUrl))?.listingKey,
      github.listingKey,
    );
  });

  test('re-adding a store whose record carries a listing ID collides', () {
    // A swap leaves the GitHub listing keyed '...@FDroid'. Re-adding GitHub has
    // to find it there.
    final App fdroidKeyedGithub = _listing(
      listingId: appListingKey(_packageId, 'FDroid'),
      url: _githubUrl,
    );
    final AppListings listings = _listingsOf([
      _listing(url: _fdroidUrl),
      fdroidKeyedGithub,
    ]);

    expect(
      sameStoreListingIn(listings, _listing(url: _githubUrl))?.listingKey,
      fdroidKeyedGithub.listingKey,
    );
  });

  test('a package may still be added from a second store', () {
    final AppListings listings = _listingsOf([_listing(url: _githubUrl)]);

    expect(sameStoreListingIn(listings, _listing(url: _fdroidUrl)), isNull);
  });

  test('third-party repos on different hosts are different stores', () {
    // Both listings resolve to the FDroidRepo source, so source type alone
    // would call them one store and refuse the second.
    final App firstRepo = _listing(
      url: 'https://repo.example.com/fdroid/repo',
      overrideSource: 'FDroidRepo',
    );
    final AppListings listings = _listingsOf([firstRepo]);

    expect(
      sameStoreListingIn(
        listings,
        _listing(
          url: 'https://other.example.org/fdroid/repo',
          overrideSource: 'FDroidRepo',
        ),
      ),
      isNull,
    );
    expect(
      sameStoreListingIn(
        listings,
        _listing(
          url: 'https://repo.example.com/fdroid/repo',
          overrideSource: 'FDroidRepo',
        ),
      )?.listingKey,
      firstRepo.listingKey,
    );
  });

  test('a www. host is the same store as its bare spelling', () {
    final App withWww = _listing(
      url: 'https://www.example.com/fdroid/repo',
      overrideSource: 'FDroidRepo',
    );
    final AppListings listings = _listingsOf([withWww]);

    expect(
      sameStoreListingIn(
        listings,
        _listing(
          url: 'https://example.com/fdroid/repo',
          overrideSource: 'FDroidRepo',
        ),
      )?.listingKey,
      withWww.listingKey,
    );
  });

  test('two repos on one host are one store', () {
    final App firstRepo = _listing(
      url: 'https://repo.example.com/fdroid/repo',
      overrideSource: 'FDroidRepo',
    );
    final AppListings listings = _listingsOf([firstRepo]);

    expect(
      sameStoreListingIn(
        listings,
        _listing(
          url: 'https://repo.example.com/other/fdroid/repo',
          overrideSource: 'FDroidRepo',
        ),
      )?.listingKey,
      firstRepo.listingKey,
    );
  });

  test('writing a listing under its package ID keeps its sibling', () {
    // What a library reload does: every record is written back in turn. A
    // record carrying a listing ID must not evict the listing whose key is the
    // bare package ID, or one of the two vanishes on every launch.
    final App github = _listing(url: _githubUrl);
    final App fdroid = _listing(
      listingId: appListingKey(_packageId, 'FDroid'),
      url: _fdroidUrl,
    );
    final AppListings listings = AppListings();
    listings[github.listingKey] = AppInMemory(github, null, null, null);
    listings[_packageId] = AppInMemory(fdroid, null, null, null);

    expect(listings.length, 2);
    expect(listings.containsListingKey(_packageId), isTrue);
    expect(listings.containsListingKey(fdroid.listingKey), isTrue);
  });

  test('renaming a package ID moves its listing instead of duplicating', () {
    final App github = _listing(url: _githubUrl);
    final AppListings listings = AppListings();
    listings[github.listingKey] = AppInMemory(github, null, null, null);

    final App renamed = github.copyWith(id: 'com.example.renamed');
    listings[github.listingKey] = AppInMemory(renamed, null, null, null);

    expect(listings.length, 1);
    expect(listings.containsListingKey('com.example.renamed'), isTrue);
    expect(listings.containsListingKey(_packageId), isFalse);
  });

  test('a stored listing survives its source being swapped', () {
    final App fdroid = _listing(
      listingId: appListingKey(_packageId, 'FDroid'),
      url: _fdroidUrl,
    );
    final AppListings listings = AppListings();
    listings[fdroid.listingKey] = AppInMemory(fdroid, null, null, null);
    final AppInMemory stored = listings[fdroid.listingKey]!;

    listings[stored.listingKey] = AppInMemory(
      stored.app.copyWith(url: _githubUrl),
      null,
      null,
      null,
      sourceType: 'GitHub',
    );

    expect(listings.length, 1);
    expect(listings[fdroid.listingKey]?.app.url, _githubUrl);
    expect(listings[fdroid.listingKey]?.sourceIdentifier, 'GitHub');
  });
}
