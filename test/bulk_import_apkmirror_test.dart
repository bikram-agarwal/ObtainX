// #339: bulk import's APKMirror availability check identifies as APKUpdater
// with ObtainX's name and version appended, so APKMirror can tell the calls
// are ObtainX's, and reads the answer back into app links.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:obtainium/app_sources/apkmirror.dart';
import 'package:obtainium/services/bulk_import_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('asks APKMirror as APKUpdater, naming ObtainX', () async {
    final List<http.Request> sent = [];
    final MockClient client = MockClient((http.Request request) async {
      sent.add(request);
      return http.Response(
        jsonEncode({
          'data': [
            {
              'pname': 'org.example.app',
              'exists': true,
              'app': {'link': '/apk/example/example-app/'},
            },
          ],
        }),
        200,
      );
    });

    final Map<String, String?> found = await http.runWithClient(
      () => BulkImportService.checkApkMirror(['org.example.app']),
      () => client,
    );

    final http.Request request = sent.single;
    expect(
      request.url.toString(),
      'https://www.apkmirror.com/wp-json/apkm/v1/app_exists/',
    );
    expect(
      request.headers['User-Agent'],
      startsWith('$apkMirrorAllowlistedUserAgentToken ObtainX/'),
    );
    expect(request.headers['Authorization'], startsWith('Basic '));
    expect(jsonDecode(request.body)['pnames'], ['org.example.app']);
    expect(found, {
      'org.example.app': 'https://www.apkmirror.com/apk/example/example-app/',
    });
  });
}
