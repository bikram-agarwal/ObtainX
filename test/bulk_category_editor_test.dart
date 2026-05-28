import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/components/bulk_category_editor.dart';

void main() {
  test('builds all some and none category coverage', () {
    final coverage = buildBulkCategoryCoverage(
      availableCategoryColors: const {
        'Work': 0xFFE57373,
        'Personal': 0xFF64B5F6,
        'Shopping': 0xFF81C784,
      },
      selectedAppCategories: const [
        ['Work', 'Personal'],
        ['Work'],
      ],
    );
    final byCategory = {for (final item in coverage) item.category: item};

    expect(byCategory['Work']?.state, BulkCategoryCoverageState.all);
    expect(byCategory['Work']?.matchCount, 2);
    expect(byCategory['Work']?.totalCount, 2);
    expect(byCategory['Personal']?.state, BulkCategoryCoverageState.some);
    expect(byCategory['Personal']?.matchCount, 1);
    expect(byCategory['Shopping']?.state, BulkCategoryCoverageState.none);
    expect(byCategory['Shopping']?.matchCount, 0);
  });

  test('dedupes and matches categories case-insensitively', () {
    final coverage = buildBulkCategoryCoverage(
      availableCategoryColors: const {
        'MyTag': 0xFFE57373,
        'Errand': 0xFF64B5F6,
      },
      selectedAppCategories: const [
        ['mytag'],
        ['MYTAG'],
      ],
      extraCategories: const ['mytag'],
    );
    final byKey = {
      for (final item in coverage) bulkCategoryKey(item.category): item,
    };

    expect(
      coverage.where((item) => bulkCategoryKey(item.category) == 'mytag'),
      hasLength(1),
    );
    expect(byKey['mytag']?.category, 'MyTag');
    expect(byKey['mytag']?.state, BulkCategoryCoverageState.all);
    expect(byKey['errand']?.state, BulkCategoryCoverageState.none);
  });

  test(
    'sorts assigned categories before unassigned categories alphabetically',
    () {
      final coverage = buildBulkCategoryCoverage(
        availableCategoryColors: const {
          'Zulu': 0xFFE57373,
          'Alpha': 0xFF64B5F6,
          'Beta': 0xFF81C784,
        },
        selectedAppCategories: const [
          ['Zulu'],
          ['Beta'],
        ],
      );

      expect(coverage.map((item) => item.category).toList(), [
        'Beta',
        'Zulu',
        'Alpha',
      ]);
    },
  );

  test(
    'resolves staged actions with normalized keys and preserved display case',
    () {
      final key = bulkCategoryKey('mytag');
      final actions = resolveBulkCategoryIntentActions(
        coverage: const [
          BulkCategoryCoverage(
            category: 'MyTag',
            matchCount: 0,
            totalCount: 2,
            state: BulkCategoryCoverageState.none,
          ),
        ],
        extraAddedCategories: const ['mytag'],
        categoryIntents: {key: BulkCategoryIntent.add},
        newCategoryColorsByKey: {key: 0xFFABCDEF},
      );

      expect(actions.addCategories, {'MyTag'});
      expect(actions.removeCategories, isEmpty);
      expect(actions.newCategoryColors, {'MyTag': 0xFFABCDEF});
    },
  );

  test(
    'applies add and remove actions only to supplied selected category lists',
    () {
      const actions = BulkCategoryIntentActions(
        addCategories: {'Shared'},
        removeCategories: {'Old'},
        newCategoryColors: {},
      );

      final updated = applyBulkCategoryActionsToCategoryLists(const [
        ['Old', 'Keep'],
        ['keep', 'Other'],
      ], actions);

      expect(updated, [
        ['Keep', 'Shared'],
        ['keep', 'Other', 'Shared'],
      ]);
    },
  );
}
