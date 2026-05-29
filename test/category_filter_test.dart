import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/pages/apps.dart';

void main() {
  test('neutral category filter matches any category set', () {
    expect(appCategoriesMatchFilter(const []), true);
    expect(appCategoriesMatchFilter(const ['Social']), true);
  });

  test('included categories use any-match semantics', () {
    expect(
      appCategoriesMatchFilter(
        const ['Social'],
        includedCategories: const {'Google', 'Social'},
      ),
      true,
    );
    expect(
      appCategoriesMatchFilter(
        const ['Media'],
        includedCategories: const {'Google', 'Social'},
      ),
      false,
    );
  });

  test('included categories can use all-match semantics', () {
    expect(
      appCategoriesMatchFilter(
        const ['Google', 'Social', 'Open Source'],
        includedCategories: const {'Google', 'Social'},
        matchMode: CategoryFilterMatchMode.all,
      ),
      true,
    );
    expect(
      appCategoriesMatchFilter(
        const ['Social'],
        includedCategories: const {'Google', 'Social'},
        matchMode: CategoryFilterMatchMode.all,
      ),
      false,
    );
  });

  test('excluded categories reject any matching app category', () {
    expect(
      appCategoriesMatchFilter(
        const ['Social', 'Google'],
        excludedCategories: const {'Google'},
      ),
      false,
    );
    expect(
      appCategoriesMatchFilter(
        const ['Social'],
        excludedCategories: const {'Google'},
      ),
      true,
    );
  });

  test('included categories are filtered further by excluded categories', () {
    expect(
      appCategoriesMatchFilter(
        const ['Social', 'Google'],
        includedCategories: const {'Social'},
        excludedCategories: const {'Google'},
      ),
      false,
    );
    expect(
      appCategoriesMatchFilter(
        const ['Social', 'Open Source'],
        includedCategories: const {'Social'},
        excludedCategories: const {'Google'},
      ),
      true,
    );
  });

  test('category filter intent cycles through neutral include and exclude', () {
    expect(
      nextCategoryFilterIntent(CategoryFilterIntent.neutral),
      CategoryFilterIntent.include,
    );
    expect(
      nextCategoryFilterIntent(CategoryFilterIntent.include),
      CategoryFilterIntent.exclude,
    );
    expect(
      nextCategoryFilterIntent(CategoryFilterIntent.exclude),
      CategoryFilterIntent.neutral,
    );
  });
}
