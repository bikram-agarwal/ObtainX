import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart';
import 'package:obtainium/app_sources/codeberg.dart';
import 'package:obtainium/app_sources/html.dart';
import 'package:obtainium/pages/add_app.dart';
import 'package:obtainium/pages/apps.dart';
import 'package:obtainium/providers/source_provider.dart';

class _RecordingCodeberg extends Codeberg {
  final List<String> requestedUrls = <String>[];

  @override
  Future<Response> sourceRequest(
    String url,
    Map<String, dynamic> additionalSettings, {
    bool followRedirects = true,
    Object? postBody,
  }) async {
    requestedUrls.add(url);
    return Response('{}', 404);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Codeberg and Forgejo are separate, independently filterable sources', () {
    final Codeberg codeberg = Codeberg();
    final Forgejo forgejo = Forgejo();
    expect(codeberg.name, 'Codeberg');
    expect(forgejo.name, 'Forgejo');
    // Distinct identifiers are what keep "source = Codeberg" from sweeping up
    // apps hosted on some other Forgejo instance.
    expect(codeberg.sourceIdentifier, 'Codeberg');
    expect(forgejo.sourceIdentifier, 'Forgejo');
    expect(codeberg.hosts, <String>['codeberg.org']);
    expect(forgejo.hosts, <String>['codefloe.com']);
    // Only Codeberg gets a search chip: no Forgejo instance can search another,
    // and prompting for one would disable result caching for every source in
    // the same search.
    expect(codeberg.canSearch, isTrue);
    expect(forgejo.canSearch, isFalse);
    expect(codeberg.includeAdditionalOptsInMainSearch, isFalse);
  });

  test('a URL resolves to whichever source owns its host', () {
    final SourceProvider provider = SourceProvider();
    expect(
      provider.getSource('https://codeberg.org/Freeyourgadget/Gadgetbridge'),
      isA<Codeberg>(),
    );
    const String releasesUrl =
        'https://codefloe.com/SnappTechnology/NextCloudTalkNext/releases';
    final AppSource source = provider.getSource(releasesUrl);
    expect(source, isA<Forgejo>());
    expect(source.sourceIdentifier, 'Forgejo');
    expect(
      source.standardizeUrl(releasesUrl),
      'https://codefloe.com/SnappTechnology/NextCloudTalkNext',
    );
    // The repo root as copied from the browser, trailing slash and all.
    expect(
      provider.getSource(
        'https://codefloe.com/SnappTechnology/NextCloudTalkNext/',
      ),
      isA<Forgejo>(),
    );
  });

  test('a self-hosted instance reaches either source by override', () {
    final SourceProvider provider = SourceProvider();
    expect(
      provider.getSource(
        'https://git.example.com/owner/repo',
        overrideSource: 'Forgejo',
      ),
      isA<Forgejo>(),
    );
    // Apps overridden onto Codeberg before the split keep resolving.
    expect(
      provider.getSource(
        'https://git.example.com/owner/repo',
        overrideSource: 'Codeberg',
      ),
      isA<Codeberg>(),
    );
  });

  test('an unknown forge host still falls through to HTML', () {
    expect(
      SourceProvider().getSource('https://git.example.com/owner/repo'),
      isA<HTML>(),
    );
  });

  test('app-id inference uses the app host, not hosts[0]', () async {
    final _RecordingCodeberg source = _RecordingCodeberg();
    await source.tryInferringAppId('http://git.example.com:3000/owner/repo');
    expect(source.requestedUrls, isNotEmpty);
    for (final String requestedUrl in source.requestedUrls) {
      expect(
        requestedUrl,
        startsWith('http://git.example.com:3000/api/v1/repos/owner/repo/'),
      );
      expect(requestedUrl.contains('codeberg.org'), isFalse);
    }
  });

  test('app-id inference widens to the repo file list', () async {
    final _RecordingCodeberg source = _RecordingCodeberg();
    await source.tryInferringAppId('https://codefloe.com/owner/repo');
    // Every conventional path 404s, so the walk must fall back to asking the
    // instance what the repo actually contains.
    expect(
      source.requestedUrls.last,
      'https://codefloe.com/api/v1/repos/owner/repo'
      '/git/trees/HEAD?recursive=true&per_page=1000',
    );
  });

  test('search prompt collapses a repo tracked by several apps to one', () {
    expect(
      searchPromptAutoCompleteOptions(
        trackedAppUrls: <String>[
          'https://apt.izzysoft.de/fdroid/repo?appid=com.example',
          'https://apt.izzysoft.de/fdroid/repo?appid=dev.other',
          'not a url at all',
        ],
      ),
      <String>['https://apt.izzysoft.de/fdroid/repo'],
    );
  });

  test('changelog images use the matched Forgejo origin', () {
    expect(
      resolveChangeLogImageSrc(
        src: './screenshots/a.png',
        appUrl: 'https://codefloe.com/owner/repo',
        appSource: Codeberg(),
      ),
      'https://codefloe.com/owner/repo/raw/branch/HEAD/screenshots/a.png',
    );
    expect(
      resolveChangeLogImageSrc(
        src: 'img.png',
        appUrl: 'https://codeberg.org/owner/repo',
        appSource: Codeberg(),
      ),
      'https://codeberg.org/owner/repo/raw/branch/HEAD/img.png',
    );
    expect(
      resolveChangeLogImageSrc(
        src: 'https://cdn.example/a.png',
        appUrl: 'https://codefloe.com/owner/repo',
        appSource: Codeberg(),
      ),
      'https://cdn.example/a.png',
    );
  });

  test('each source sits in its own alphabetical slot', () {
    // Source pickers and the supported-sources dialog list templates in this
    // order, so Codeberg listing next to the F-Droid entries (where "Forgejo"
    // sorts) reads as though it were named something else.
    final List<String> identifiers = SourceProvider().sourceTemplates
        .map((AppSource source) => source.sourceIdentifier)
        .toList();
    expect(identifiers.indexOf('Codeberg'), identifiers.indexOf('Aptoide') + 1);
    expect(identifiers.indexOf('CoolApk'), identifiers.indexOf('Codeberg') + 1);
    expect(
      identifiers.indexOf('Forgejo'),
      identifiers.indexOf('FDroidRepo') + 1,
    );
    expect(identifiers.indexOf('GitHub'), identifiers.indexOf('Forgejo') + 1);
  });
}
