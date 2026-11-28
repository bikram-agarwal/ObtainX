import 'package:easy_localization/easy_localization.dart';
// ignore: implementation_imports
import 'package:easy_localization/src/localization.dart';
// ignore: implementation_imports
import 'package:easy_localization/src/translations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:obtainium/app_sources/github.dart';
import 'package:obtainium/app_sources/githubstars.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/pages/import_github_stars.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:obtainium/widgets/help_hint_icon.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeGitHubStars extends GitHubStars {
  _FakeGitHubStars({
    Map<String, List<GitHubStarredRepository>>? responses,
    Map<String, List<GitHubStarList>>? listsByUser,
    Map<String, Object>? errors,
  }) : _responses = responses ?? <String, List<GitHubStarredRepository>>{},
       _listsByUser = listsByUser ?? <String, List<GitHubStarList>>{},
       _errors = errors ?? <String, Object>{};

  final Map<String, List<GitHubStarredRepository>> _responses;
  final Map<String, List<GitHubStarList>> _listsByUser;
  final Map<String, Object> _errors;
  final List<String> requestedUsernames = <String>[];

  @override
  Future<GitHubStarredResult> getStarredRepositoriesWithLists(
    String username,
  ) async {
    final List<GitHubStarredRepository> repos = await getStarredRepositories(
      username,
    );
    return GitHubStarredResult(
      repositories: repos,
      lists: _listsByUser[username] ?? const <GitHubStarList>[],
    );
  }

  @override
  Future<List<GitHubStarredRepository>> getStarredRepositories(
    String username,
  ) async {
    requestedUsernames.add(username);
    final Object? error = _errors[username];
    if (error != null) {
      throw error;
    }
    return _responses[username] ??
        <GitHubStarredRepository>[
          GitHubStarredRepository(
            url: 'https://github.com/$username/sample-app',
            fullName: '$username/sample-app',
            description: 'Sample app description',
            starCount: 25400,
          ),
        ];
  }
}

class _FakeAppsProvider extends ChangeNotifier implements AppsProvider {
  @override
  final AppListings apps = AppListings();

  final List<List<String>> addedUrlBatches = <List<String>>[];

  @override
  Future<List<List<String>>> addAppsByURL(
    List<String> urls, {
    AppSource? sourceOverride,
  }) async {
    addedUrlBatches.add(List<String>.from(urls));
    return <List<String>>[];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    return super.noSuchMethod(invocation);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late final Map<String, dynamic> translations;

  setUpAll(() async {
    translations = (await const RootBundleAssetLoader().load(
      'assets/translations',
      const Locale('en'),
    ))!;
  });

  Future<SettingsProvider> createSettings([
    Map<String, Object> initialPrefs = const <String, Object>{},
  ]) async {
    SharedPreferences.setMockInitialValues(initialPrefs);
    final SettingsProvider settings = SettingsProvider()
      ..prefs = await SharedPreferences.getInstance();
    addTearDown(settings.dispose);
    return settings;
  }

  Future<(_FakeGitHubStars, _FakeAppsProvider, SettingsProvider, List<String>)>
  pumpImportUi(
    WidgetTester tester, {
    List<String> savedUsernames = const <String>[],
    bool embedded = true,
    _FakeGitHubStars? source,
  }) async {
    final SettingsProvider settings = await createSettings(<String, Object>{
      if (savedUsernames.isNotEmpty)
        SettingsProvider.savedGitHubStarUsernamesKey: savedUsernames,
    });
    final _FakeAppsProvider apps = _FakeAppsProvider();
    addTearDown(apps.dispose);
    final _FakeGitHubStars fakeSource = source ?? _FakeGitHubStars();
    final List<String> openedUrls = <String>[];
    Localization.load(
      const Locale('en'),
      translations: Translations(translations),
    );
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppsProvider>.value(value: apps),
          ChangeNotifierProvider<SettingsProvider>.value(value: settings),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: embedded
                ? ImportGitHubStarsContent(
                    embedded: true,
                    source: fakeSource,
                    onOpenRepositoryUrl: (String url) async {
                      openedUrls.add(url);
                    },
                  )
                : Builder(
                    builder: (BuildContext context) => Center(
                      child: FilledButton(
                        onPressed: () => showImportGitHubStarsSheet(
                          context,
                          source: fakeSource,
                          onOpenRepositoryUrl: (String url) async {
                            openedUrls.add(url);
                          },
                        ),
                        child: const Text('Open Sheet'),
                      ),
                    ),
                  ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    if (!embedded) {
      await tester.tap(find.text('Open Sheet'));
      await tester.pumpAndSettle();
    }
    return (fakeSource, apps, settings, openedUrls);
  }

  group('SettingsProvider saved GitHub star usernames', () {
    test('saves up to 5 deduplicated MRU usernames and deletes cleanly', () async {
      final SettingsProvider settings = await createSettings();
      expect(settings.savedGitHubStarUsernames, isEmpty);

      settings.addSavedGitHubStarUsername('  alice  ');
      settings.addSavedGitHubStarUsername('bob');
      // Case-insensitive duplicate moves to front and updates casing without adding a slot.
      settings.addSavedGitHubStarUsername('Alice');
      expect(settings.savedGitHubStarUsernames, <String>['Alice', 'bob']);

      settings.addSavedGitHubStarUsername('charlie');
      settings.addSavedGitHubStarUsername('dave');
      settings.addSavedGitHubStarUsername('eve');
      expect(settings.savedGitHubStarUsernames, <String>[
        'eve',
        'dave',
        'charlie',
        'Alice',
        'bob',
      ]);

      // 6th distinct username evicts the oldest ('bob') and stays capped at 5.
      settings.addSavedGitHubStarUsername('frank');
      expect(settings.savedGitHubStarUsernames, <String>[
        'frank',
        'eve',
        'dave',
        'charlie',
        'Alice',
      ]);

      settings.removeSavedGitHubStarUsername('DAVE');
      expect(settings.savedGitHubStarUsernames, <String>[
        'frank',
        'eve',
        'charlie',
        'Alice',
      ]);
    });

    test('caps pre-populated or imported lists at 5', () async {
      final SettingsProvider settings = await createSettings(<String, Object>{
        SettingsProvider.savedGitHubStarUsernamesKey: <String>[
          'u1',
          'u2',
          'u3',
          'u4',
          'u5',
          'u6',
          'u7',
        ],
      });
      expect(settings.savedGitHubStarUsernames, <String>[
        'u1',
        'u2',
        'u3',
        'u4',
        'u5',
      ]);
    });
  });

  group('ImportGitHubStarsContent widget', () {
    testWidgets('remembers username by default on import without a checkbox', (
      WidgetTester tester,
    ) async {
      final (_FakeGitHubStars source, _, SettingsProvider settings, _) =
          await pumpImportUi(tester);

      expect(find.byType(CheckboxListTile), findsNothing);
      expect(find.byType(Checkbox), findsNothing);

      await tester.enterText(find.byType(TextField), 'octocat');
      await tester.tap(find.text(tr('import')));
      await tester.pumpAndSettle();

      expect(source.requestedUsernames, <String>['octocat']);
      expect(find.byType(GitHubStarsSelectionSheet), findsOneWidget);
      expect(settings.savedGitHubStarUsernames, <String>['octocat']);
    });

    testWidgets(
      'shows saved usernames below text box, deletes on trailing button, and '
      'starts star import flow with card results where tapping opens browser',
      (WidgetTester tester) async {
        final (
          _FakeGitHubStars source,
          _FakeAppsProvider apps,
          SettingsProvider settings,
          List<String> openedUrls,
        ) = await pumpImportUi(
          tester,
          embedded: false,
          savedUsernames: <String>['alice', 'bob'],
        );

        final double textFieldBottom = tester
            .getBottomLeft(find.byType(TextField))
            .dy;
        final double aliceTop = tester.getTopLeft(find.text('alice')).dy;
        expect(aliceTop, greaterThan(textFieldBottom));
        expect(find.text('bob'), findsOneWidget);

        // Delete button sits at the right end of each saved username row.
        final Finder aliceTile = find.ancestor(
          of: find.text('alice'),
          matching: find.byType(ListTile),
        );
        final Finder aliceDeleteButton = find.descendant(
          of: aliceTile,
          matching: find.byType(IconButton),
        );
        expect(
          tester.getCenter(aliceDeleteButton).dx,
          greaterThan(tester.getCenter(find.text('alice')).dx),
        );

        // Tapping delete removes 'alice' without starting import.
        await tester.tap(aliceDeleteButton);
        await tester.pumpAndSettle();

        expect(settings.savedGitHubStarUsernames, <String>['bob']);
        expect(find.text('alice'), findsNothing);
        expect(source.requestedUsernames, isEmpty);

        // Tapping saved username 'bob' immediately starts star import for 'bob'.
        await tester.tap(find.text('bob'));
        await tester.pumpAndSettle();

        expect(source.requestedUsernames, <String>['bob']);
        expect(find.byType(GitHubStarsSelectionSheet), findsOneWidget);
        expect(
          find.text('bob/sample-app · Sample app description'),
          findsOneWidget,
        );
        expect(find.text('https://github.com/bob/sample-app'), findsOneWidget);
        expect(find.text('25K'), findsOneWidget);

        // Tapping the result row opens the repository URL in the browser.
        await tester.tap(find.text('bob/sample-app · Sample app description'));
        await tester.pump();
        expect(openedUrls, <String>['https://github.com/bob/sample-app']);

        // Tapping the right-rail checkbox selects it and Save imports it.
        final Finder checkbox = find.descendant(
          of: find.byType(GitHubStarsSelectionSheet),
          matching: find.byType(Checkbox),
        );
        expect(tester.widget<Checkbox>(checkbox).value, isFalse);
        await tester.tap(checkbox);
        await tester.pump();
        expect(tester.widget<Checkbox>(checkbox).value, isTrue);

        await tester.tap(find.byTooltip(tr('save')));
        await tester.pumpAndSettle();
        expect(apps.addedUrlBatches, <List<String>>[
          <String>['https://github.com/bob/sample-app'],
        ]);
      },
    );

    testWidgets('keeps at most 5 saved usernames when importing a 6th', (
      WidgetTester tester,
    ) async {
      final (_, _, SettingsProvider settings, _) = await pumpImportUi(
        tester,
        savedUsernames: <String>['u1', 'u2', 'u3', 'u4', 'u5'],
      );

      await tester.enterText(find.byType(TextField), 'u6');
      await tester.tap(find.text(tr('import')));
      await tester.pumpAndSettle();

      expect(settings.savedGitHubStarUsernames, <String>[
        'u6',
        'u1',
        'u2',
        'u3',
        'u4',
      ]);
    });

    testWidgets(
      'shows inline error in sheet and does not save bogus username',
      (WidgetTester tester) async {
        final String notFoundMessage = tr(
          'githubUserNotFound',
          args: <String>['no-such-user'],
        );
        final (_, _, SettingsProvider settings, _) = await pumpImportUi(
          tester,
          embedded: false,
          source: _FakeGitHubStars(
            errors: <String, Object>{
              'no-such-user': ObtainiumError(notFoundMessage),
            },
          ),
        );

        await tester.enterText(find.byType(TextField), 'no-such-user');
        await tester.tap(find.text(tr('import')));
        await tester.pumpAndSettle();

        expect(find.text(notFoundMessage), findsOneWidget);
        expect(settings.savedGitHubStarUsernames, isEmpty);

        // Editing the field clears the inline error.
        await tester.enterText(find.byType(TextField), 'octocat');
        await tester.pump();
        expect(find.text(notFoundMessage), findsNothing);
      },
    );

    testWidgets(
      'shows star lists dropdown chip in filter bar and filters by selected list or All',
      (WidgetTester tester) async {
        final _FakeGitHubStars source = _FakeGitHubStars(
          responses: <String, List<GitHubStarredRepository>>{
            'octocat': const <GitHubStarredRepository>[
              GitHubStarredRepository(
                url: 'https://github.com/org/android-app',
                fullName: 'org/android-app',
                description: 'Android tool',
                starCount: 1200,
              ),
              GitHubStarredRepository(
                url: 'https://github.com/org/cli-tool',
                fullName: 'org/cli-tool',
                description: 'CLI utility',
                starCount: 800,
              ),
            ],
          },
          listsByUser: <String, List<GitHubStarList>>{
            'octocat': const <GitHubStarList>[
              GitHubStarList(
                id: 'list-android',
                name: 'Android',
                repositoryUrls: <String>{'https://github.com/org/android-app'},
              ),
              GitHubStarList(
                id: 'list-cli',
                name: 'CLI',
                repositoryUrls: <String>{'https://github.com/org/cli-tool'},
              ),
            ],
          },
        );

        await pumpImportUi(tester, source: source);
        await tester.enterText(find.byType(TextField), 'octocat');
        await tester.tap(find.text(tr('import')));
        await tester.pumpAndSettle();

        // Starts on "All" showing both repositories.
        expect(find.text(tr('all')), findsOneWidget);
        expect(find.text('org/android-app · Android tool'), findsOneWidget);
        expect(find.text('org/cli-tool · CLI utility'), findsOneWidget);

        // Select "Android" list from the dropdown chip.
        await tester.tap(find.text(tr('all')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Android').last);
        await tester.pumpAndSettle();

        expect(find.text('Android'), findsOneWidget);
        expect(find.text('org/android-app · Android tool'), findsOneWidget);
        expect(find.text('org/cli-tool · CLI utility'), findsNothing);

        // Switch back to "All".
        await tester.tap(find.text('Android'));
        await tester.pumpAndSettle();
        await tester.tap(find.text(tr('all')).last);
        await tester.pumpAndSettle();

        expect(find.text('org/android-app · Android tool'), findsOneWidget);
        expect(find.text('org/cli-tool · CLI utility'), findsOneWidget);
        expect(find.byType(HelpHintIcon), findsNothing);
      },
    );

    testWidgets(
      'shows PAT info HelpHintIcon in filter bar when no PAT is set and hides '
      'it when a PAT is configured',
      (WidgetTester tester) async {
        final (_, _, SettingsProvider settings, _) = await pumpImportUi(tester);

        await tester.enterText(find.byType(TextField), 'octocat');
        await tester.tap(find.text(tr('import')));
        await tester.pumpAndSettle();

        final Finder hintFinder = find.byType(HelpHintIcon);
        expect(hintFinder, findsOneWidget);
        expect(
          tester.widget<HelpHintIcon>(hintFinder).message,
          tr('githubStarListsPatHint'),
        );

        await tester.tap(hintFinder);
        await tester.pump();
        expect(find.text(tr('githubStarListsPatHint')), findsOneWidget);

        // Once a GitHub PAT is configured, the no-PAT hint disappears.
        settings.setSettingString(GitHub.githubCredsKey, 'ghp_testtoken');
        await tester.pumpAndSettle();
        expect(find.byType(HelpHintIcon), findsNothing);
      },
    );
  });
}
