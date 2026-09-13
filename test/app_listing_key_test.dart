import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/source_provider.dart';

const String _packageId = 'com.example.app';
const String _githubUrl = 'https://github.com/example/app';
const String _fdroidUrl = 'https://f-droid.org/packages/com.example.app/';

App _listing({String? listingId, required String url}) {
  return App(
    id: _packageId,
    listingId: listingId,
    url: url,
    author: 'Author',
    name: 'Example',
    latestVersion: '1.0',
    preferredApkIndex: 0,
    additionalSettings: {},
  );
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
    final AppListings listings = AppListings();
    listings[github.listingKey] = AppInMemory(github, null, null, null);
    listings[fdroid.listingKey] = AppInMemory(fdroid, null, null, null);

    // What swapTrackedSource checks: the GitHub listing rewritten to the
    // F-Droid URL collides with the existing F-Droid listing, while the
    // F-Droid listing keeping its own URL does not collide with itself.
    final App githubSwappedToFdroid = github.copyWith(url: _fdroidUrl);
    expect(
      listings
          .listingsForPackage(_packageId)
          .where(
            (listing) =>
                listing.listingKey != github.listingKey &&
                listing.sourceIdentifier ==
                    sourceIdentifierForApp(githubSwappedToFdroid),
          )
          .map((listing) => listing.listingKey),
      [fdroid.listingKey],
    );
    expect(
      listings
          .listingsForPackage(_packageId)
          .where(
            (listing) =>
                listing.listingKey != fdroid.listingKey &&
                listing.sourceIdentifier == sourceIdentifierForApp(fdroid),
          ),
      isEmpty,
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
