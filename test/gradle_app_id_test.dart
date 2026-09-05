import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/app_sources/gradle_app_id.dart';
import 'package:obtainium/providers/source_provider.dart';

void main() {
  test('groovy applicationId is extracted (upstream behaviour preserved)', () {
    expect(
      appIdFromGradleFileContents('''
android {
    defaultConfig {
        applicationId "nodomain.freeyourgadget.gadgetbridge"
    }
}
'''),
      'nodomain.freeyourgadget.gadgetbridge',
    );
  });

  test('single-quoted groovy applicationId is extracted', () {
    expect(
      appIdFromGradleFileContents("        applicationId 'com.example.app'"),
      'com.example.app',
    );
  });

  // The whole point of the change: Kotlin DSL uses `= "..."`, which upstream's
  // startsWith('applicationId "') test could never match. Both live GitLab
  // Android apps checked on 2026-08-18 look exactly like this.
  test('kotlin DSL applicationId with = is extracted', () {
    expect(
      appIdFromGradleFileContents('''
android {
    defaultConfig {
        applicationId = "com.aurora.store"
    }
}
'''),
      'com.aurora.store',
    );
    expect(
      appIdFromGradleFileContents('        applicationId = "org.fdroid"'),
      'org.fdroid',
    );
  });

  // Real noise from Gadgetbridge's build.gradle, which sits next to the real
  // declaration and must not be picked up.
  test('applicationIdSuffix and commented lines are ignored', () {
    expect(
      appIdFromGradleFileContents('''
        applicationId "nodomain.freeyourgadget.gadgetbridge"
        applicationIdSuffix ".debug"
        //applicationIdSuffix ""
        appAuthRedirectScheme: "\${applicationId}"
'''),
      'nodomain.freeyourgadget.gadgetbridge',
    );
    expect(
      appIdFromGradleFileContents('// applicationId "com.commented.out"'),
      isNull,
    );
  });

  // Unanchoring the pattern to allow `debug { applicationId = "x" }` means the
  // neighbouring Gradle properties have to be excluded by boundary, not by
  // position. testApplicationId names the *test* package, never the app's.
  test('testApplicationId is not mistaken for applicationId', () {
    expect(
      appIdFromGradleFileContents(
        '        testApplicationId "com.example.test"',
      ),
      isNull,
    );
    expect(
      appIdFromGradleFileContents('''
        testApplicationId = "com.example.test"
        applicationId = "com.example.app"
'''),
      'com.example.app',
    );
  });

  test('single-line flavour blocks are read', () {
    expect(
      appIdFromGradleFileContents(
        '    debug { applicationId = "com.example.app" }',
      ),
      'com.example.app',
    );
  });

  test('variable references resolve against def, val and const val', () {
    expect(
      appIdFromGradleFileContents('''
def appIdVar = "com.groovy.app"
        applicationId "\${appIdVar}"
'''),
      'com.groovy.app',
    );
    expect(
      appIdFromGradleFileContents('''
const val pkg = "com.kotlin.app"
        applicationId = "\$pkg"
'''),
      'com.kotlin.app',
    );
  });

  test(
    'unresolvable interpolation yields null, never a literal placeholder',
    () {
      expect(
        appIdFromGradleFileContents('        applicationId "\${missingVar}"'),
        isNull,
      );
      expect(
        appIdFromGradleFileContents(
          '        applicationId = "\${rootProject.ext.pkg}"',
        ),
        isNull,
      );
    },
  );

  // Upstream compared a non-deduplicated list length against 1, so a project
  // declaring the same id twice (debug + release blocks) was rejected.
  test('the same id declared twice still resolves', () {
    expect(
      appIdFromGradleFileContents('''
    debug { applicationId = "com.example.app" }
    release { applicationId = "com.example.app" }
'''),
      'com.example.app',
    );
  });

  test('genuinely different flavour ids stay ambiguous', () {
    expect(
      appIdFromGradleFileContents('''
    free { applicationId = "com.example.app.free" }
    paid { applicationId = "com.example.app.paid" }
'''),
      isNull,
    );
  });

  // The real shape of Gadgetbridge's app/build.gradle on Codeberg: two flavour
  // ids, plus a namespace that identifies which one is the default variant.
  test('namespace breaks a flavour tie when it matches one candidate', () {
    expect(
      appIdFromGradleFileContents('''
android {
    namespace = 'nodomain.freeyourgadget.gadgetbridge'
    defaultConfig {
        applicationId "nodomain.freeyourgadget.gadgetbridge"
        appAuthRedirectScheme: "\${applicationId}"
    }
    productFlavors {
        banglejs {
            applicationId "com.espruino.gadgetbridge"
        }
    }
    applicationVariants.all { variant ->
        variant.resValue "string", "applicationId", variant.applicationId
        outputFileName = "\${applicationId}_\${variant.versionName}.apk"
    }
}
'''),
      'nodomain.freeyourgadget.gadgetbridge',
    );
  });

  test('a namespace matching none of the flavour ids stays ambiguous', () {
    expect(
      appIdFromGradleFileContents('''
    namespace = "com.example.unrelated"
    free { applicationId = "com.example.app.free" }
    paid { applicationId = "com.example.app.paid" }
'''),
      isNull,
    );
  });

  test('namespace is used only when no applicationId exists', () {
    expect(
      appIdFromGradleFileContents('''
android {
    namespace = "com.example.fromnamespace"
}
'''),
      'com.example.fromnamespace',
    );
    // applicationId wins when both are present.
    expect(
      appIdFromGradleFileContents('''
    namespace = "com.example.namespace"
    applicationId = "com.example.real"
'''),
      'com.example.real',
    );
  });

  // A library module's namespace names its R class, not an installable
  // package. NextCloudTalkNext on Codefloe keeps `designsystem` next to the
  // real app, and reading its namespace would attach the app to
  // com.nextcloud.talk.redux.designsystem - a package that never exists.
  test("a library module's namespace is not an app id", () {
    expect(
      appIdFromGradleFileContents('''
plugins {
    alias(libs.plugins.kotlin.multiplatform)
    alias(libs.plugins.android.library)
}
android {
    namespace = "com.nextcloud.talk.redux.designsystem"
}
'''),
      isNull,
    );
    expect(
      appIdFromGradleFileContents('''
plugins {
    id("com.android.library")
}
android {
    namespace = "com.example.lib"
}
'''),
      isNull,
    );
  });

  test(
    'a root build file declaring plugins for subprojects is not a library',
    () {
      // `apply false` only makes the plugin available; the module itself is
      // still an application, so its namespace remains usable.
      expect(
        appIdFromGradleFileContents('''
plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.android.library) apply false
}
android {
    namespace = "com.example.app"
}
'''),
        'com.example.app',
      );
    },
  );

  group('finding build files anywhere in the repo', () {
    test('app-like modules rank above deeper and unrelated ones', () {
      expect(
        gradleBuildFilePathsByLikelihood(<String>[
          'README.md',
          'mobile_clients/Android/build.gradle.kts',
          'mobile_clients/Android/designsystem/build.gradle.kts',
          'mobile_clients/Android/composeApp/build.gradle.kts',
          'build/generated/build.gradle',
          'buildSrc/build.gradle.kts',
        ]),
        <String>[
          'mobile_clients/Android/composeApp/build.gradle.kts',
          'mobile_clients/Android/build.gradle.kts',
          'mobile_clients/Android/designsystem/build.gradle.kts',
        ],
      );
    });

    test('the tree payload yields blob paths only', () {
      expect(
        repoFilePathsFromTreeApiBody(
          jsonEncode({
            'tree': [
              {'path': 'app', 'type': 'tree'},
              {'path': 'app/build.gradle.kts', 'type': 'blob'},
              {'type': 'blob'},
            ],
          }),
        ),
        <String>['app/build.gradle.kts'],
      );
      expect(repoFilePathsFromTreeApiBody('{"message":"Not Found"}'), isNull);
    });

    test('a nested app module is found once the usual paths miss', () async {
      final List<String> attempted = <String>[];
      bool listed = false;
      final String? appId = await inferAppIdFromGradleFiles(
        (String path) async {
          attempted.add(path);
          if (path == 'mobile_clients/Android/composeApp/build.gradle.kts') {
            return 'applicationId = "com.nextcloud.talk.redux"';
          }
          return null;
        },
        listRepoFilePaths: () async {
          listed = true;
          return <String>[
            'mobile_clients/Android/build.gradle.kts',
            'mobile_clients/Android/composeApp/build.gradle.kts',
          ];
        },
      );

      expect(appId, 'com.nextcloud.talk.redux');
      expect(listed, isTrue);
      expect(attempted.take(gradleAppIdCandidatePaths.length), [
        ...gradleAppIdCandidatePaths,
      ]);
    });

    test('a conventional repo never pays for the file listing', () async {
      bool listed = false;
      final String? appId = await inferAppIdFromGradleFiles(
        (String path) async => 'applicationId = "com.example.app"',
        listRepoFilePaths: () async {
          listed = true;
          return <String>[];
        },
      );

      expect(appId, 'com.example.app');
      expect(listed, isFalse);
    });

    test('a failed listing is logged, not thrown', () async {
      final List<String> errors = <String>[];
      final String? appId = await inferAppIdFromGradleFiles(
        (String path) async => null,
        listRepoFilePaths: () async => throw Exception('boom'),
        onError: errors.add,
      );

      expect(appId, isNull);
      expect(errors.single, contains('Could not list repo files'));
    });
  });

  test('non-package-shaped values are rejected', () {
    expect(
      appIdFromGradleFileContents('applicationId = "notapackage"'),
      isNull,
    );
    expect(appIdFromGradleFileContents('applicationId = ""'), isNull);
  });

  test('contents API body decodes base64 payloads and tolerates junk', () {
    final String encoded = base64.encode(
      utf8.encode('        applicationId = "com.example.app"'),
    );
    expect(
      appIdFromGradleFileContents(
        decodeRepoContentsApiBody('{"content":"$encoded"}')!,
      ),
      'com.example.app',
    );
    // GitHub wraps long payloads at 60 chars; newlines must be stripped.
    final String wrapped = encoded.replaceAllMapped(
      RegExp('.{1,20}'),
      (m) => '${m.group(0)}\n',
    );
    expect(
      appIdFromGradleFileContents(
        decodeRepoContentsApiBody(jsonEncode({'content': wrapped}))!,
      ),
      'com.example.app',
    );
    expect(decodeRepoContentsApiBody('{"message":"Not Found"}'), isNull);
    expect(decodeRepoContentsApiBody('[]'), isNull);
  });

  test('kts paths are tried before their groovy siblings', () {
    expect(gradleAppIdCandidatePaths.first, 'app/build.gradle.kts');
    expect(
      gradleAppIdCandidatePaths.indexOf('app/build.gradle.kts') <
          gradleAppIdCandidatePaths.indexOf('app/build.gradle'),
      true,
    );
    for (final String location in <String>['app', 'android/app', 'src/app']) {
      expect(gradleAppIdCandidatePaths, contains('$location/build.gradle'));
      expect(gradleAppIdCandidatePaths, contains('$location/build.gradle.kts'));
    }
  });

  test('the walk skips missing files and stops at the first hit', () async {
    final List<String> attempted = <String>[];
    final String? appId = await inferAppIdFromGradleFiles((String path) async {
      attempted.add(path);
      if (path == 'app/build.gradle.kts') return null; // 404
      if (path == 'app/build.gradle') throw Exception('boom'); // network error
      return 'applicationId = "com.example.third"';
    });
    expect(appId, 'com.example.third');
    expect(attempted, <String>[
      'app/build.gradle.kts',
      'app/build.gradle',
      'android/app/build.gradle.kts',
    ]);
  });

  test('a file with no id does not stop the walk', () async {
    final String? appId = await inferAppIdFromGradleFiles((String path) async {
      if (path == 'app/build.gradle.kts') return 'android { }';
      return 'applicationId = "com.example.later"';
    });
    expect(appId, 'com.example.later');
  });

  // The Add-app page assigns the whole form value map to additionalSettings on
  // every change, and GeneratedFormTextField defaults to ''. An untouched
  // 'App ID - Custom' box must therefore read as "not supplied", or every app
  // added from a source that shows that box would get a blank id.
  group('explicit app id from additionalSettings', () {
    test('an empty or whitespace value is not treated as an id', () {
      expect(explicitAppIdFromSettings(const {'appId': ''}), isNull);
      expect(explicitAppIdFromSettings(const {'appId': '   '}), isNull);
      expect(explicitAppIdFromSettings(const {}), isNull);
      expect(explicitAppIdFromSettings(const {'appId': null}), isNull);
    });

    test('a real value is used, trimmed', () {
      expect(
        explicitAppIdFromSettings(const {'appId': 'com.example.app'}),
        'com.example.app',
      );
      expect(
        explicitAppIdFromSettings(const {'appId': '  com.example.app  '}),
        'com.example.app',
      );
    });
  });
}
