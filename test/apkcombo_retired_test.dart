import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart';
import 'package:obtainium/app_sources/apkcombo.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/providers/source_provider.dart';

class _RecordingAPKCombo extends APKCombo {
  final List<String> requests = [];

  @override
  Future<Response> sourceRequest(
    String url,
    Map<String, dynamic> additionalSettings, {
    bool followRedirects = true,
    Object? postBody,
  }) async {
    requests.add(url);
    return Response('', 200);
  }
}

void main() {
  // v1.7.4 sync D19: upstream deleted APKCombo; the fork keeps a tombstone.
  test('APKCombo stays registered but never sends a request', () async {
    const url = 'https://apkcombo.com/example/com.example.app/';
    // Tracked apps, overridden ones included, still resolve to it.
    expect(SourceProvider().getSource(url), isA<APKCombo>());
    expect(
      SourceProvider().getSource(url, overrideSource: 'APKCombo'),
      isA<APKCombo>(),
    );

    final source = _RecordingAPKCombo();
    expect(source.name, 'APKCombo');
    expect(source.retired, isTrue);
    expect(source.allowOverride, isFalse);
    final standardUrl = source.standardizeUrl(url);
    expect(standardUrl, 'https://apkcombo.com/example/com.example.app');

    await expectLater(
      source.getLatestAPKDetails(standardUrl, {}),
      throwsA(isA<ObtainiumError>()),
    );
    await expectLater(
      source.assetUrlPrefetchModifier(
        'https://example.r2.dev/app.apk',
        standardUrl,
        {},
      ),
      throwsA(isA<ObtainiumError>()),
    );
    expect(source.requests, isEmpty);
  });
}
