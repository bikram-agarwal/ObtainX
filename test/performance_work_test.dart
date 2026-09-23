import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart' as archive;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart';
import 'package:obtainium/app_sources/fdroidrepo.dart';
import 'package:obtainium/http/source_request_session.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/services/artifact_file_work.dart';
import 'package:obtainium/services/repository_index.dart';
import 'package:obtainium/services/store_lookup_queue.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'parallel repository checks share a request and refresh on the next operation',
    () async {
      int requests = 0;
      final gate = Completer<Response>();
      Future<Response> load() {
        requests++;
        return gate.future;
      }

      await SourceRequestSession.run(() async {
        final session = SourceRequestSession.current!;
        final first = session.repositoryResponse('repo', load);
        final second = session.repositoryResponse('repo', load);
        expect(requests, 1);
        gate.complete(Response('index', 200));
        expect(identical(await first, await second), isTrue);
        await SourceRequestSession.run(() async {
          await SourceRequestSession.current!.repositoryResponse('repo', load);
        });
        expect(requests, 1);
        await session.repositoryResponse('other-repo', load);
        expect(requests, 2);
      });
      expect(SourceRequestSession.current, isNull);
      await SourceRequestSession.run(() async {
        await SourceRequestSession.current!.repositoryResponse('repo', load);
      });
      expect(requests, 3);
    },
  );

  test(
    'failed repository responses can be retried within the operation',
    () async {
      await SourceRequestSession.run(() async {
        final session = SourceRequestSession.current!;
        await expectLater(
          session.repositoryResponse('repo', () async {
            throw const SocketException('disconnected');
          }),
          throwsA(isA<SocketException>()),
        );
        expect(
          (await session.repositoryResponse(
            'repo',
            () async => Response('', 503),
          )).statusCode,
          503,
        );
        expect(
          (await session.repositoryResponse(
            'repo',
            () async => Response('recovered', 200),
          )).body,
          'recovered',
        );
      });
    },
  );

  test(
    'one parsed index resolves independent apps and preserves name matching',
    () async {
      final response = Response(
        '''
<repo name="Repository">
<application id="org.example.first"><name>First App</name>
<package><version>1.0</version><versioncode>1</versioncode><apkname>first.apk</apkname></package>
</application>
<application id="org.example.second"><name>Second App</name>
<package><version>2.0</version><versioncode>2</versioncode><apkname>second.apk</apkname></package>
</application></repo>
''',
        200,
        request: Request('GET', Uri.parse('https://repo.example/index.xml')),
      );
      final indexes = await Future.wait([
        parseRepositoryIndex(response),
        parseRepositoryIndex(response),
      ]);
      expect(identical(indexes[0], indexes[1]), isTrue);
      expect(
        indexes.first.findApplication('SECOND APP')?.attributes['id'],
        'org.example.second',
      );
      expect(
        indexes.first.findApplication('First')?.attributes['id'],
        'org.example.first',
      );
      expect(indexes.first.findApplication('missing'), isNull);
      final details = await Future.wait([
        FDroidRepo.apkDetailsFromIndexXmlResponse(
          response,
          'org.example.first',
          {},
          'fallback',
        ),
        FDroidRepo.apkDetailsFromIndexXmlResponse(
          response,
          'org.example.second',
          {},
          'fallback',
        ),
      ]);
      expect(details[0].version, '1.0');
      expect(details[1].version, '2.0');
      expect(details[0].apkUrls.single.value, 'https://repo.example/first.apk');
      expect(
        details[1].apkUrls.single.value,
        'https://repo.example/second.apk',
      );
    },
  );

  test(
    'package lookup queries only the requested package and handles absence',
    () async {
      const channel = MethodChannel('dev.imranr.obtainium/device_apps');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.arguments['packageName'] == 'missing') return null;
        return {
          'packageName': call.arguments['packageName'],
          'versionName': '2.0',
          'versionCode': 2,
        };
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      expect((await getInstalledInfo('org.example.app'))?.versionName, '2.0');
      expect(await getInstalledInfo('missing'), isNull);
      expect(
        calls.map((call) => call.method),
        everyElement('getInstalledPackageInfo'),
      );
      expect(calls.first.arguments['includeSigningCertificates'], isFalse);
      await getInstalledInfo('org.example.app', light: false);
      expect(calls.last.arguments['includeSigningCertificates'], isTrue);
    },
  );

  test('repository worker preserves HTTP character decoding', () async {
    const xml =
        '<repo><application id="cafe"><name>Café</name></application></repo>';
    for (final charset in ['utf-8', 'iso-8859-1']) {
      final encoding = charset == 'utf-8' ? utf8 : latin1;
      final response = Response.bytes(
        encoding.encode(xml),
        200,
        headers: {'content-type': 'text/xml; charset=$charset'},
      );
      final index = await parseRepositoryIndex(response);
      expect(index.findApplication('Café')?.attributes['id'], 'cafe');
    }
  });

  test('SHA-256 worker preserves the artifact digest', () async {
    final directory = await Directory.systemTemp.createTemp(
      'obtainx-hash-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = await File('${directory.path}/artifact').writeAsString('abc');
    expect(
      await sha256FileOffIsolate(file.path),
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );
  });

  for (final compression in ['tar', 'gzip', 'bzip', 'xz']) {
    test('streaming extraction handles $compression and nested APKs', () async {
      final directory = await Directory.systemTemp.createTemp(
        'obtainx-tar-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final content = utf8.encode('test apk content');
      final bundle = archive.Archive()
        ..addFile(
          archive.ArchiveFile('nested/app.apk', content.length, content),
        );
      List<int> bytes = archive.TarEncoder().encodeBytes(bundle);
      if (compression == 'gzip') {
        bytes = const archive.GZipEncoder().encodeBytes(bytes);
      }
      if (compression == 'bzip') {
        bytes = archive.BZip2Encoder().encodeBytes(bytes);
      }
      if (compression == 'xz') bytes = archive.XZEncoder().encodeBytes(bytes);
      final file = await File('${directory.path}/download').writeAsBytes(bytes);
      await extractTarballOffIsolate(file.path, '${directory.path}/output');
      expect(
        await File('${directory.path}/output/nested/app.apk').readAsBytes(),
        content,
      );
    });
  }

  test(
    'store jobs share the limit and canceled queued jobs do not start',
    () async {
      final queue = StoreLookupQueue(1);
      final gate = Completer<void>();
      final started = <String>[];
      final first = queue.run(() async {
        started.add('first');
        await gate.future;
      });
      bool canceled = false;
      final second = queue.run(() async {
        started.add('second');
      }, shouldAbort: () => canceled);
      final third = queue.run(() async {
        started.add('third');
      });
      expect(started, ['first']);
      canceled = true;
      gate.complete();
      await Future.wait([first, second, third]);
      expect(started, ['first', 'third']);
      await expectLater(
        queue.run(() async {
          throw StateError('failed');
        }),
        throwsStateError,
      );
      await queue.run(() async {
        started.add('after-error');
      });
      expect(started.last, 'after-error');
    },
  );
}
