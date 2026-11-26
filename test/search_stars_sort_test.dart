import 'dart:convert';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart';
import 'package:material_ui/material_ui.dart';
import 'package:obtainium/app_sources/codeberg.dart';
import 'package:obtainium/app_sources/fdroid.dart';
import 'package:obtainium/app_sources/github.dart';
import 'package:obtainium/app_sources/gitlab.dart';
import 'package:obtainium/pages/add_app.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/notifications_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:obtainium/theme.dart';
import 'package:obtainium/utils/format_utils.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _StubGitHub extends GitHub {
  _StubGitHub(this.response, {super.hostChanged});

  final Response response;
  final List<String> requestedUrls = [];

  @override
  String get sourceIdentifier => 'GitHub';

  @override
  Future<Response> sourceRequest(
    String url,
    Map<String, dynamic> additionalSettings, {
    bool followRedirects = true,
    Object? postBody,
  }) async {
    requestedUrls.add(url);
    return response;
  }
}

class _StubGitLab extends GitLab {
  _StubGitLab(this.response);

  final Response response;

  @override
  Future<Response> sourceRequest(
    String url,
    Map<String, dynamic> additionalSettings, {
    bool followRedirects = true,
    Object? postBody,
  }) async {
    return response;
  }
}

class _StubNonStarSource extends FDroid {
  _StubNonStarSource(this.searchResults);

  final Map<String, List<String>> searchResults;

  @override
  String get sourceIdentifier => 'FDroid';

  @override
  Future<Map<String, List<String>>> search(
    String query, {
    Map<String, dynamic> querySettings = const {},
  }) async {
    return searchResults;
  }
}

class _WidgetGitHubSource extends GitHub {
  _WidgetGitHubSource(this.searchDetails);

  final Map<String, SearchResultDetails> searchDetails;

  @override
  String get sourceIdentifier => 'GitHub';

  @override
  Future<Map<String, SearchResultDetails>> searchWithDetails(
    String query, {
    Map<String, dynamic> querySettings = const {},
  }) async {
    return searchDetails;
  }
}

class _FakeSourceProvider implements SourceProvider {
  _FakeSourceProvider(this._fakeSources);

  final List<AppSource> _fakeSources;
  final SourceProvider _real = SourceProvider();

  @override
  List<AppSource> get sources => _fakeSources;

  @override
  List<AppSource> get sourceTemplates => _fakeSources;

  @override
  AppSource getSource(String url, {String? overrideSource}) =>
      _real.getSource(url, overrideSource: overrideSource);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeAppsProvider extends ChangeNotifier implements AppsProvider {
  @override
  final AppListings apps = AppListings();

  @override
  dynamic noSuchMethod(Invocation invocation) {
    return super.noSuchMethod(invocation);
  }
}

class _FakeNotifications extends Fake implements NotificationsProvider {}

void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();
  late Directory storageDir;
  late SettingsProvider settings;
  late _FakeAppsProvider appsProvider;

  setUpAll(() {
    storageDir = Directory.systemTemp.createTempSync('obtainium-search-stars-');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => storageDir.path,
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/device_info'),
      (_) async => {
        'version': {
          'codename': 'REL',
          'incremental': '1',
          'release': '16',
          'sdkInt': 36,
        },
        for (final String key in [
          'board',
          'bootloader',
          'brand',
          'device',
          'display',
          'fingerprint',
          'hardware',
          'host',
          'id',
          'manufacturer',
          'model',
          'product',
          'tags',
          'type',
        ])
          key: 'test',
        for (final String key in [
          'time',
          'freeDiskSize',
          'totalDiskSize',
          'physicalRamSize',
          'availableRamSize',
        ])
          key: 0,
        'isPhysicalDevice': false,
        'isLowRamDevice': false,
        'systemFeatures': <String>[],
      },
    );
  });

  tearDownAll(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/device_info'),
      null,
    );
    storageDir.deleteSync(recursive: true);
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({'useGradientBackground': false});
    settings = SettingsProvider()
      ..prefs = await SharedPreferences.getInstance();
    appsProvider = _FakeAppsProvider();
    AddAppPageState.clearSearchCacheForTesting();
  });

  tearDown(() {
    AddAppPageState.clearSearchCacheForTesting();
    appsProvider.dispose();
    settings.dispose();
  });

  Future<AddAppPageState> openSearchFlow(
    WidgetTester tester, {
    required SourceProvider fakeSourceProvider,
    ValueNotifier<double>? textScaleNotifier,
    Size surfaceSize = const Size(480, 1200),
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = surfaceSize;
    addTearDown(tester.view.reset);
    final ValueNotifier<double> effectiveTextScale =
        textScaleNotifier ?? ValueNotifier<double>(1.0);
    if (textScaleNotifier == null) {
      addTearDown(effectiveTextScale.dispose);
    }
    await tester.runAsync(EasyLocalization.ensureInitialized);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppsProvider>.value(value: appsProvider),
          ChangeNotifierProvider<SettingsProvider>.value(value: settings),
          Provider<NotificationsProvider>.value(value: _FakeNotifications()),
        ],
        child: EasyLocalization(
          supportedLocales: const [Locale('en')],
          path: 'assets/translations',
          fallbackLocale: const Locale('en'),
          startLocale: const Locale('en'),
          useOnlyLangCode: true,
          child: ValueListenableBuilder<double>(
            valueListenable: effectiveTextScale,
            builder: (BuildContext context, double scale, _) => MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(scale)),
              child: MaterialApp(
                localizationsDelegates: context.localizationDelegates,
                supportedLocales: context.supportedLocales,
                locale: context.locale,
                theme: buildObtainiumTheme(const ColorScheme.light(), null),
                home: const AddAppPage(),
              ),
            ),
          ),
        ),
      ),
    );
    for (int frame = 0; frame < 5; frame++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();

    await tester.tap(find.text(tr('searchSourcesAddApp')));
    await tester.pumpAndSettle();

    final AddAppPageState searchPageState = tester.state<AddAppPageState>(
      find.byType(AddAppPage).last,
    );
    searchPageState.sourceProvider = fakeSourceProvider;
    return searchPageState;
  }

  group('formatCompactStarCount', () {
    test('formats star counts across compact magnitude boundaries', () {
      expect(formatCompactStarCount(-5), '0');
      expect(formatCompactStarCount(0), '0');
      expect(formatCompactStarCount(7), '7');
      expect(formatCompactStarCount(910), '910');
      expect(formatCompactStarCount(999), '999');
      expect(formatCompactStarCount(1000), '1K');
      expect(formatCompactStarCount(1049), '1K');
      expect(formatCompactStarCount(1050), '1.1K');
      expect(formatCompactStarCount(5781), '5.8K');
      expect(formatCompactStarCount(9949), '9.9K');
      expect(formatCompactStarCount(9950), '10K');
      expect(formatCompactStarCount(10000), '10K');
      expect(formatCompactStarCount(36093), '36K');
      expect(formatCompactStarCount(156489), '156K');
      expect(formatCompactStarCount(999499), '999K');
      expect(formatCompactStarCount(999500), '1M');
      expect(formatCompactStarCount(1240000), '1.2M');
      expect(formatCompactStarCount(9949999), '9.9M');
      expect(formatCompactStarCount(9950000), '10M');
    });
  });

  group('source searchWithDetails', () {
    test('GitHub.searchWithDetails parses stargazers_count, filters minStarCount, and keeps search() compatible', () async {
      final _StubGitHub github = _StubGitHub(
        Response(
          jsonEncode({
            'items': [
              {
                'html_url': 'https://github.com/tasks/tasks',
                'full_name': 'tasks/tasks',
                'description': 'Tasks app',
                'archived': false,
                'stargazers_count': 5781,
              },
              {
                'html_url': 'https://github.com/example/zero-stars',
                'full_name': 'example/zero-stars',
                'description': null,
                'archived': true,
                'stargazers_count': 0,
              },
            ],
          }),
          200,
        ),
      );

      final Map<String, SearchResultDetails> allResults = await github
          .searchWithDetails('tasks');
      expect(allResults['https://github.com/tasks/tasks']?.starCount, 5781);
      expect(allResults['https://github.com/tasks/tasks']?.subtitleLines, [
        'tasks/tasks',
        'Tasks app',
      ]);
      expect(allResults['https://github.com/example/zero-stars']?.starCount, 0);
      expect(
        allResults['https://github.com/example/zero-stars']?.subtitleLines,
        ['example/zero-stars', '[ARCHIVED] ${tr('noDescription')}'],
      );

      final Map<String, SearchResultDetails> filteredResults = await github
          .searchWithDetails('tasks', querySettings: {'minStarCount': 100});
      expect(filteredResults.keys, ['https://github.com/tasks/tasks']);

      final Map<String, List<String>> legacyResults = await github.search(
        'tasks',
      );
      expect(legacyResults, {
        'https://github.com/tasks/tasks': ['tasks/tasks', 'Tasks app'],
        'https://github.com/example/zero-stars': [
          'example/zero-stars',
          '[ARCHIVED] ${tr('noDescription')}',
        ],
      });
    });

    // Codeberg's own search, with only the HTTP answer stubbed: its API URL,
    // the 'data' root and its token lookup all run for real.
    test('Codeberg.searchWithDetails parses stars_count', () async {
      SharedPreferences.setMockInitialValues({});
      final _StubGitHub api = _StubGitHub(
        hostChanged: true,
        Response(
          jsonEncode({
            'data': [
              {
                'html_url': 'https://codeberg.org/example/notes',
                'full_name': 'example/notes',
                'description': 'Notes on Codeberg',
                'archived': false,
                'stars_count': 412,
              },
            ],
          }),
          200,
        ),
      );
      final Codeberg codeberg = Codeberg(apiHelper: api);

      final Map<String, SearchResultDetails> detailed = await codeberg
          .searchWithDetails('notes');
      expect(api.requestedUrls, [
        'https://codeberg.org/api/v1/repos/search?q=notes&limit=100',
      ]);
      expect(detailed['https://codeberg.org/example/notes']?.starCount, 412);
      expect(detailed['https://codeberg.org/example/notes']?.subtitleLines, [
        'example/notes',
        'Notes on Codeberg',
      ]);
    });

    test('GitLab.searchWithDetails parses star_count and keeps search() compatible', () async {
      final _StubGitLab gitlab = _StubGitLab(
        Response(
          jsonEncode([
            {
              'path_with_namespace': 'auroraoss/AuroraStore',
              'name_with_namespace': 'Aurora OSS / AuroraStore',
              'description': 'FOSS Google Play client',
              'star_count': 2100,
            },
          ]),
          200,
        ),
      );

      final Map<String, SearchResultDetails> detailed = await gitlab
          .searchWithDetails('aurora');
      expect(
        detailed['https://gitlab.com/auroraoss/AuroraStore']?.starCount,
        2100,
      );
      expect(
        detailed['https://gitlab.com/auroraoss/AuroraStore']?.subtitleLines,
        ['Aurora OSS / AuroraStore', 'FOSS Google Play client'],
      );

      final Map<String, List<String>> legacy = await gitlab.search('aurora');
      expect(legacy, {
        'https://gitlab.com/auroraoss/AuroraStore': [
          'Aurora OSS / AuroraStore',
          'FOSS Google Play client',
        ],
      });
    });

    test('default AppSource.searchWithDetails wraps non-star sources with null starCount', () async {
      final _StubNonStarSource fdroid = _StubNonStarSource({
        'https://f-droid.org/packages/org.tasks': [
          'Tasks.org',
          'Open source to-do list',
        ],
      });

      final Map<String, SearchResultDetails> detailed = await fdroid
          .searchWithDetails('tasks');
      expect(
        detailed['https://f-droid.org/packages/org.tasks']?.starCount,
        isNull,
      );
      expect(
        detailed['https://f-droid.org/packages/org.tasks']?.subtitleLines,
        ['Tasks.org', 'Open source to-do list'],
      );
    });
  });

  group('filterAndSortSearchResults', () {
    final Map<String, SearchResultDisplayEntry> sampleResults = {
      'GitHub|https://github.com/example/low': const SearchResultDisplayEntry(
        sourceIdentifier: 'GitHub',
        subtitleLines: ['example/low', 'First relevance task app'],
        starCount: 218,
      ),
      'FDroid|https://f-droid.org/packages/org.fdroid.first':
          const SearchResultDisplayEntry(
            sourceIdentifier: 'FDroid',
            subtitleLines: ['F-Droid First', 'Task app on F-Droid'],
          ),
      'GitHub|https://github.com/example/tie-a': const SearchResultDisplayEntry(
        sourceIdentifier: 'GitHub',
        subtitleLines: ['example/tie-a', 'Tied tasks repo A'],
        starCount: 5781,
      ),
      'GitHub|https://github.com/example/zero': const SearchResultDisplayEntry(
        sourceIdentifier: 'GitHub',
        subtitleLines: ['example/zero', 'Zero-star tasks repo'],
        starCount: 0,
      ),
      'FDroid|https://f-droid.org/packages/org.fdroid.second':
          const SearchResultDisplayEntry(
            sourceIdentifier: 'FDroid',
            subtitleLines: ['F-Droid Second', 'Another task app'],
          ),
      'GitHub|https://github.com/example/tie-b': const SearchResultDisplayEntry(
        sourceIdentifier: 'GitHub',
        subtitleLines: ['example/tie-b', 'Tied tasks repo B'],
        starCount: 5781,
      ),
      'GitHub|https://github.com/example/top': const SearchResultDisplayEntry(
        sourceIdentifier: 'GitHub',
        subtitleLines: ['example/top', 'Popular engine'],
        starCount: 36093,
      ),
    };

    test('preserves relevance order when sortByStars is false', () {
      final List<MapEntry<String, SearchResultDisplayEntry>> sorted =
          filterAndSortSearchResults(
            sampleResults,
            filterQuery: '',
            sortByStars: false,
          );
      expect(sorted.map((entry) => entry.key).toList(), sampleResults.keys);
    });

    test('sorts starred entries descending, keeps tie order, and puts null after zero', () {
      final List<MapEntry<String, SearchResultDisplayEntry>> sorted =
          filterAndSortSearchResults(
            sampleResults,
            filterQuery: '',
            sortByStars: true,
          );
      expect(sorted.map((entry) => entry.key).toList(), [
        'GitHub|https://github.com/example/top',
        'GitHub|https://github.com/example/tie-a',
        'GitHub|https://github.com/example/tie-b',
        'GitHub|https://github.com/example/low',
        'GitHub|https://github.com/example/zero',
        'FDroid|https://f-droid.org/packages/org.fdroid.first',
        'FDroid|https://f-droid.org/packages/org.fdroid.second',
      ]);
    });

    test('combines text filter with star sorting', () {
      final List<MapEntry<String, SearchResultDisplayEntry>> filtered =
          filterAndSortSearchResults(
            sampleResults,
            filterQuery: 'task',
            sortByStars: true,
          );
      expect(filtered.map((entry) => entry.key).toList(), [
        'GitHub|https://github.com/example/tie-a',
        'GitHub|https://github.com/example/tie-b',
        'GitHub|https://github.com/example/low',
        'GitHub|https://github.com/example/zero',
        'FDroid|https://f-droid.org/packages/org.fdroid.first',
        'FDroid|https://f-droid.org/packages/org.fdroid.second',
      ]);
    });
  });

  group('AddAppPage search stars UI', () {
    testWidgets(
      'renders star badges, toggles Most stars sort chip, and combines with filter',
      (WidgetTester tester) async {
        final _WidgetGitHubSource githubSource = _WidgetGitHubSource({
          'https://github.com/rolling-scopes-school/tasks':
              const SearchResultDetails(
                subtitleLines: ['rolling-scopes-school/tasks', 'Course tasks'],
                starCount: 910,
              ),
          'https://github.com/tasks/tasks': const SearchResultDetails(
            subtitleLines: ['tasks/tasks', 'Tasks app'],
            starCount: 5781,
          ),
          'https://github.com/esengine/DeepSeek-Reasonix':
              const SearchResultDetails(
                subtitleLines: [
                  'esengine/DeepSeek-Reasonix',
                  'Reasoning engine',
                ],
                starCount: 36093,
              ),
        });

        await openSearchFlow(
          tester,
          fakeSourceProvider: _FakeSourceProvider([githubSource]),
        );

        await tester.tap(find.widgetWithText(FilterChip, 'GitHub'));
        await tester.pump();
        await tester.enterText(
          find.byWidgetPredicate(
            (Widget widget) =>
                widget is TextField &&
                widget.decoration?.hintText == tr('search'),
          ),
          'tasks',
        );
        await tester.pump();
        await tester.tap(find.byIcon(Icons.search));
        await tester.pumpAndSettle();

        expect(find.text('910'), findsOneWidget);
        expect(find.text('5.8K'), findsOneWidget);
        expect(find.text('36K'), findsOneWidget);

        final Finder sortChipFinder = find.widgetWithText(
          FilterChip,
          tr('sortByMostStars'),
        );
        final Finder selectTitleFinder = find.text(
          tr('addAppSearchResultsTitle'),
        );
        expect(sortChipFinder, findsOneWidget);
        expect(tester.widget<FilterChip>(sortChipFinder).selected, isFalse);
        expect(
          tester.getTopRight(sortChipFinder).dx,
          greaterThan(tester.getTopRight(selectTitleFinder).dx),
        );

        final Finder rollingTasksTitle = find.text(
          'rolling-scopes-school/tasks · Course tasks',
        );
        final Finder tasksAppTitle = find.text('tasks/tasks · Tasks app');
        final Finder reasonixTitle = find.text(
          'esengine/DeepSeek-Reasonix · Reasoning engine',
        );

        final double relevanceFirstY = tester.getTopLeft(rollingTasksTitle).dy;
        final double relevanceSecondY = tester.getTopLeft(tasksAppTitle).dy;
        final double relevanceThirdY = tester.getTopLeft(reasonixTitle).dy;
        expect(relevanceFirstY, lessThan(relevanceSecondY));
        expect(relevanceSecondY, lessThan(relevanceThirdY));

        await tester.tap(sortChipFinder);
        await tester.pumpAndSettle();
        expect(tester.widget<FilterChip>(sortChipFinder).selected, isTrue);

        final double starsFirstY = tester.getTopLeft(reasonixTitle).dy;
        final double starsSecondY = tester.getTopLeft(tasksAppTitle).dy;
        final double starsThirdY = tester.getTopLeft(rollingTasksTitle).dy;
        expect(starsFirstY, lessThan(starsSecondY));
        expect(starsSecondY, lessThan(starsThirdY));

        final Finder filterFieldFinder = find.byWidgetPredicate(
          (Widget widget) =>
              widget is TextField &&
              widget.decoration?.hintText == tr('filter'),
        );
        await tester.enterText(filterFieldFinder, 'tasks');
        await tester.pumpAndSettle();
        expect(reasonixTitle, findsNothing);
        expect(
          tester.getTopLeft(tasksAppTitle).dy,
          lessThan(tester.getTopLeft(rollingTasksTitle).dy),
        );

        await tester.enterText(filterFieldFinder, '');
        await tester.pumpAndSettle();
        await tester.tap(sortChipFinder);
        await tester.pumpAndSettle();
        expect(tester.widget<FilterChip>(sortChipFinder).selected, isFalse);
        expect(
          tester.getTopLeft(rollingTasksTitle).dy,
          lessThan(tester.getTopLeft(tasksAppTitle).dy),
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      'hides Most stars sort chip and star badges for non-star sources',
      (WidgetTester tester) async {
        final _StubNonStarSource fdroidSource = _StubNonStarSource({
          'https://f-droid.org/packages/org.tasks': [
            'Tasks.org',
            'Open source to-do list',
          ],
        });

        await openSearchFlow(
          tester,
          fakeSourceProvider: _FakeSourceProvider([fdroidSource]),
        );

        await tester.tap(find.widgetWithText(FilterChip, fdroidSource.name));
        await tester.pump();
        await tester.enterText(
          find.byWidgetPredicate(
            (Widget widget) =>
                widget is TextField &&
                widget.decoration?.hintText == tr('search'),
          ),
          'tasks',
        );
        await tester.pump();
        await tester.tap(find.byIcon(Icons.search));
        await tester.pumpAndSettle();

        expect(find.textContaining('Tasks.org'), findsOneWidget);
        expect(
          find.widgetWithText(FilterChip, tr('sortByMostStars')),
          findsNothing,
        );
        expect(find.byIcon(Icons.star_rounded), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      'renders starred cards and Most stars chip cleanly at 200% text scale',
      (WidgetTester tester) async {
        final _WidgetGitHubSource githubSource = _WidgetGitHubSource({
          'https://github.com/anthropics/claude-code':
              const SearchResultDetails(
                subtitleLines: ['anthropics/claude-code', 'Coding tool'],
                starCount: 156489,
              ),
          'https://github.com/tasks/tasks': const SearchResultDetails(
            subtitleLines: ['tasks/tasks', 'Tasks app'],
            starCount: 5781,
          ),
        });
        final ValueNotifier<double> textScaleNotifier = ValueNotifier<double>(
          1.0,
        );
        addTearDown(textScaleNotifier.dispose);

        await openSearchFlow(
          tester,
          fakeSourceProvider: _FakeSourceProvider([githubSource]),
          textScaleNotifier: textScaleNotifier,
        );

        await tester.tap(find.widgetWithText(FilterChip, 'GitHub'));
        await tester.pump();
        await tester.enterText(
          find.byWidgetPredicate(
            (Widget widget) =>
                widget is TextField &&
                widget.decoration?.hintText == tr('search'),
          ),
          'tasks',
        );
        await tester.pump();
        await tester.tap(find.byIcon(Icons.search));
        await tester.pumpAndSettle();

        textScaleNotifier.value = 2.0;
        await tester.pumpAndSettle();

        final Finder sortChipFinder = find.widgetWithText(
          FilterChip,
          tr('sortByMostStars'),
        );
        expect(find.text('156K'), findsOneWidget);
        expect(find.text('5.8K'), findsOneWidget);
        expect(sortChipFinder, findsOneWidget);
        await tester.tap(sortChipFinder);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  });
}
