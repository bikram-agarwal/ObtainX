import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart';
import 'package:obtainium/app_sources/tencent.dart';

// The fork reads everything from the one sj.qq.com page's `__NEXT_DATA__`.
// Card shapes are from upstream's tencent_test.dart (1c169b19), which tested
// a two-request design the fork doesn't use.

const _url = 'https://sj.qq.com/appdetail/com.example.app';
const _apkUrl = 'https://download.example.test/app.apk?fsname=example.apk';
const _record = {
  'pkg_name': 'com.example.app',
  'name': 'Example app',
  'developer': 'Example publisher',
  'version_name': '1.2.3',
  'download_url': _apkUrl,
  'icon': 'https://icon.example.test/app.png',
  'apk_size': '12345678',
  'update_time': '1791812310',
};

/// The same package as the app, with other values, as "you may also like"
/// cards and the client info carry it.
final _distraction = <String, String>{
  ..._record,
  'version_name': '0.9',
  'download_url': 'https://download.example.test/old.apk',
  'update_time': '1',
};

class _Tencent extends Tencent {
  _Tencent(this.page);

  final Map<String, dynamic> page;
  final List<String> requests = [];

  @override
  Future<Response> sourceRequest(
    String url,
    Map<String, dynamic> additionalSettings, {
    bool followRedirects = true,
    Object? postBody,
  }) async {
    requests.add(url);
    return Response(
      '<html><script id="__NEXT_DATA__" type="application/json">'
      '${jsonEncode(page)}</script></html>',
      200,
    );
  }
}

Map<String, dynamic> _component(
  List<dynamic> records, {
  String cardId = 'yybn_game_basic_info',
  String name = 'GameDetail',
}) => {
  'cardId': cardId,
  'data': {'name': name, 'cardid': cardId, 'itemData': records},
};

/// [otherProps] come first, so a plain depth-first search meets them first.
Map<String, dynamic> _page(
  List<dynamic> components, {
  Map<String, dynamic> otherProps = const {},
}) => {
  'props': {
    'pageProps': {
      ...otherProps,
      'dynamicCardResponse': {
        'data': {'components': components},
      },
    },
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('reads the main detail card, not other cards for the package', () async {
    final source = _Tencent(
      _page(
        [
          _component(
            [_distraction],
            cardId: 'yybn_game_related_game',
            name: 'YouMayAlsoLike',
          ),
          _component([], cardId: 'container', name: 'GameDetailContainer'),
          _component([
            _record,
            {'comments': []},
          ]),
        ],
        otherProps: {'YYBAppInfo': _distraction},
      ),
    );
    final details = await source.getLatestAPKDetails(_url, {});

    expect(details.version, '1.2.3');
    expect(details.names.name, 'Example app');
    expect(details.names.author, 'Example publisher');
    expect(details.apkUrls.single.key, 'example.apk');
    expect(details.apkUrls.single.value, _apkUrl);
    expect(details.iconUrl, 'https://icon.example.test/app.png');
    expect(details.apkSizeBytes, 12345678);
    expect(details.releaseDate?.millisecondsSinceEpoch, 1791812310000);
    // One request: version, APK, icon, size and date all come from it.
    expect(source.requests, [_url]);
  });

  test('pages without the main card still find the app record', () async {
    final source = _Tencent(
      _page([
        _component(
          [_record],
          cardId: 'yybn_game_other_layout',
          name: 'SomethingElse',
        ),
      ]),
    );
    final details = await source.getLatestAPKDetails(_url, {});

    expect(details.version, '1.2.3');
    expect(details.apkUrls.single.value, _apkUrl);
  });

  // D30 #11: an implausible update_time is no release date.
  test('ignores update times that aren\'t a plausible date', () async {
    for (final String raw in ['0', '1', '1791812310000', 'soon']) {
      final source = _Tencent(
        _page([
          _component([
            {..._record, 'update_time': raw},
          ]),
        ]),
      );
      final details = await source.getLatestAPKDetails(_url, {});
      expect(details.releaseDate, isNull, reason: raw);
    }
  });
}
