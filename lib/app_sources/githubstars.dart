import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:http/http.dart';
import 'package:obtainium/app_sources/github.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/source_provider.dart';

/// A single starred repository returned by the GitHub stars API.
class GitHubStarredRepository {
  const GitHubStarredRepository({
    required this.url,
    required this.fullName,
    required this.description,
    this.starCount,
  });

  final String url;
  final String fullName;
  final String description;
  final int? starCount;
}

/// A GitHub Star List belonging to a user, with the canonical repository URLs
/// (lowercased) that belong to it.
class GitHubStarList {
  const GitHubStarList({
    required this.id,
    required this.name,
    required this.repositoryUrls,
  });

  final String id;
  final String name;
  final Set<String> repositoryUrls;

  bool containsUrl(String url) =>
      repositoryUrls.contains(url.trim().toLowerCase());
}

/// Combined result of fetching a GitHub user's starred repositories and
/// (when a GitHub PAT is configured) their GitHub Star Lists via GraphQL.
class GitHubStarredResult {
  const GitHubStarredResult({
    required this.repositories,
    this.lists = const <GitHubStarList>[],
  });

  final List<GitHubStarredRepository> repositories;
  final List<GitHubStarList> lists;
}

const String _starListsGraphQlQuery = r'''
query($login: String!, $listsCursor: String) {
  user(login: $login) {
    lists(first: 100, after: $listsCursor) {
      pageInfo {
        hasNextPage
        endCursor
      }
      nodes {
        id
        name
        items(first: 100) {
          pageInfo {
            hasNextPage
            endCursor
          }
          nodes {
            ... on Repository {
              url
            }
          }
        }
      }
    }
  }
}
''';

const String _starListItemsGraphQlQuery = r'''
query($listId: ID!, $itemsCursor: String) {
  node(id: $listId) {
    ... on UserList {
      items(first: 100, after: $itemsCursor) {
        pageInfo {
          hasNextPage
          endCursor
        }
        nodes {
          ... on Repository {
            url
          }
        }
      }
    }
  }
}
''';

/// Bulk import source: fetches all starred repos of a GitHub user.
///
/// Paginates through the GitHub REST API (100 repos per page) and returns each
/// repo's URL, full name, description, and star count. When a GitHub PAT is
/// configured, also queries the GitHub GraphQL API in parallel for the user's
/// Star Lists so the picker can filter by list.
class GitHubStars implements MassAppUrlSource {
  @override
  String get name => tr('githubStarredRepos');

  @override
  List<String> get requiredArgs => [tr('uname')];

  final GitHub _gh = GitHub();

  Future<List<GitHubStarredRepository>> getOnePageOfUserStarredRepositories(
    String username,
    int page,
    SettingsProvider sp,
  ) async {
    final String encodedUsername = Uri.encodeComponent(username);
    final resUrl =
        'https://api.github.com/users/$encodedUsername/starred?per_page=100&page=$page';
    final sourceConfigSettings = await _gh.getSourceConfigValues({}, sp);
    final Response res = await _gh.sourceRequest(resUrl, sourceConfigSettings);
    if (res.statusCode == 200) {
      final List<GitHubStarredRepository> repositories =
          <GitHubStarredRepository>[];
      for (final dynamic item in (jsonDecode(res.body) as List<dynamic>)) {
        String htmlUrl = item['html_url'] as String;
        if ((sourceConfigSettings['GHReqPrefix'] ?? '').isNotEmpty) {
          htmlUrl = _gh.undoGHProxyMod(htmlUrl, sourceConfigSettings);
        }
        final String fullName = item['full_name'] as String;
        final String description = (item['description'] as String? ?? '')
            .trim();
        final int? starCount = (item['stargazers_count'] as num?)?.toInt();
        repositories.add(
          GitHubStarredRepository(
            url: htmlUrl,
            fullName: fullName,
            description: description,
            starCount: starCount,
          ),
        );
      }
      return repositories;
    } else if (res.statusCode == 404) {
      throw ObtainiumError(tr('githubUserNotFound', args: [username]));
    } else {
      _gh.rateLimitErrorCheck(res);
      throw getObtainiumHttpError(res);
    }
  }

  Future<List<GitHubStarredRepository>> _fetchAllStarredRepositories(
    String username,
    SettingsProvider sp,
  ) async {
    final List<GitHubStarredRepository> repositories =
        <GitHubStarredRepository>[];
    var page = 1;
    while (true) {
      final List<GitHubStarredRepository> pageRepositories =
          await getOnePageOfUserStarredRepositories(username, page++, sp);
      repositories.addAll(pageRepositories);
      if (pageRepositories.length < 100) {
        break;
      }
    }
    return repositories;
  }

  /// Best-effort fetch of [username]'s GitHub Star Lists via GraphQL.
  /// Returns an empty list when no GitHub PAT is configured or if the GraphQL
  /// endpoint rejects the request, so star import still works via REST alone.
  Future<List<GitHubStarList>> _fetchStarListsBestEffort(
    String username,
    SettingsProvider sp,
  ) async {
    try {
      final Map<String, dynamic> sourceConfigSettings = await _gh
          .getSourceConfigValues({}, sp);
      final String? token = await _gh.getTokenIfAny(sourceConfigSettings);
      if (token == null || token.isEmpty) {
        return const <GitHubStarList>[];
      }

      final List<GitHubStarList> lists = <GitHubStarList>[];
      String? listsCursor;
      while (true) {
        final Response res = await _gh.sourceRequest(
          'https://api.github.com/graphql',
          sourceConfigSettings,
          postBody: <String, dynamic>{
            'query': _starListsGraphQlQuery,
            'variables': <String, dynamic>{
              'login': username,
              'listsCursor': listsCursor,
            },
          },
        );
        if (res.statusCode != 200) {
          return lists;
        }
        final dynamic decoded = jsonDecode(res.body);
        if (decoded is! Map<String, dynamic>) return lists;
        final dynamic listsData = decoded['data']?['user']?['lists'];
        if (listsData is! Map<String, dynamic>) return lists;
        final dynamic nodes = listsData['nodes'];
        if (nodes is List<dynamic>) {
          for (final dynamic node in nodes) {
            if (node is! Map<String, dynamic>) continue;
            final String id = (node['id'] as String? ?? '').trim();
            final String name = (node['name'] as String? ?? '').trim();
            if (id.isEmpty || name.isEmpty) continue;
            final Set<String> repoUrls = <String>{};
            final dynamic itemsData = node['items'];
            if (itemsData is Map<String, dynamic>) {
              _collectRepositoryUrls(itemsData['nodes'], repoUrls);
              final dynamic itemsPageInfo = itemsData['pageInfo'];
              if (itemsPageInfo is Map<String, dynamic> &&
                  itemsPageInfo['hasNextPage'] == true) {
                final String? itemsCursor =
                    itemsPageInfo['endCursor'] as String?;
                if (itemsCursor != null && itemsCursor.isNotEmpty) {
                  await _fetchRemainingListItems(
                    listId: id,
                    initialCursor: itemsCursor,
                    sourceConfigSettings: sourceConfigSettings,
                    targetUrls: repoUrls,
                  );
                }
              }
            }
            lists.add(
              GitHubStarList(id: id, name: name, repositoryUrls: repoUrls),
            );
          }
        }
        final dynamic pageInfo = listsData['pageInfo'];
        if (pageInfo is Map<String, dynamic> &&
            pageInfo['hasNextPage'] == true) {
          final String? nextCursor = pageInfo['endCursor'] as String?;
          if (nextCursor == null || nextCursor.isEmpty) break;
          listsCursor = nextCursor;
        } else {
          break;
        }
      }
      return lists;
    } catch (_) {
      return const <GitHubStarList>[];
    }
  }

  Future<void> _fetchRemainingListItems({
    required String listId,
    required String initialCursor,
    required Map<String, dynamic> sourceConfigSettings,
    required Set<String> targetUrls,
  }) async {
    String? cursor = initialCursor;
    while (cursor != null && cursor.isNotEmpty) {
      final Response res = await _gh.sourceRequest(
        'https://api.github.com/graphql',
        sourceConfigSettings,
        postBody: <String, dynamic>{
          'query': _starListItemsGraphQlQuery,
          'variables': <String, dynamic>{
            'listId': listId,
            'itemsCursor': cursor,
          },
        },
      );
      if (res.statusCode != 200) return;
      final dynamic decoded = jsonDecode(res.body);
      if (decoded is! Map<String, dynamic>) return;
      final dynamic itemsData = decoded['data']?['node']?['items'];
      if (itemsData is! Map<String, dynamic>) return;
      _collectRepositoryUrls(itemsData['nodes'], targetUrls);
      final dynamic pageInfo = itemsData['pageInfo'];
      if (pageInfo is Map<String, dynamic> && pageInfo['hasNextPage'] == true) {
        cursor = pageInfo['endCursor'] as String?;
      } else {
        cursor = null;
      }
    }
  }

  void _collectRepositoryUrls(dynamic nodes, Set<String> targetUrls) {
    if (nodes is! List<dynamic>) return;
    for (final dynamic item in nodes) {
      if (item is! Map<String, dynamic>) continue;
      final String? url = item['url'] as String?;
      if (url != null && url.trim().isNotEmpty) {
        targetUrls.add(url.trim().toLowerCase());
      }
    }
  }

  Future<GitHubStarredResult> getStarredRepositoriesWithLists(
    String username,
  ) async {
    final sp = SettingsProvider();
    await sp.initializeSettings();
    final Future<List<GitHubStarredRepository>> reposFuture =
        _fetchAllStarredRepositories(username, sp);
    final Future<List<GitHubStarList>> listsFuture = _fetchStarListsBestEffort(
      username,
      sp,
    );
    final List<GitHubStarredRepository> repositories = await reposFuture;
    final List<GitHubStarList> lists = await listsFuture;
    return GitHubStarredResult(repositories: repositories, lists: lists);
  }

  Future<List<GitHubStarredRepository>> getStarredRepositories(
    String username,
  ) async {
    final sp = SettingsProvider();
    await sp.initializeSettings();
    return _fetchAllStarredRepositories(username, sp);
  }

  Future<Map<String, List<String>>> getOnePageOfUserStarredUrlsWithDescriptions(
    String username,
    int page,
    SettingsProvider sp,
  ) async {
    final List<GitHubStarredRepository> pageRepositories =
        await getOnePageOfUserStarredRepositories(username, page, sp);
    return <String, List<String>>{
      for (final GitHubStarredRepository repo in pageRepositories)
        repo.url: <String>[
          repo.fullName,
          repo.description.isNotEmpty ? repo.description : tr('noDescription'),
        ],
    };
  }

  @override
  Future<Map<String, List<String>>> getUrlsWithDescriptions(
    List<String> args,
  ) async {
    if (args.length != requiredArgs.length) {
      throw ObtainiumError(tr('wrongArgNum'));
    }
    final List<GitHubStarredRepository> repositories =
        await getStarredRepositories(args[0]);
    return <String, List<String>>{
      for (final GitHubStarredRepository repo in repositories)
        repo.url: <String>[
          repo.fullName,
          repo.description.isNotEmpty ? repo.description : tr('noDescription'),
        ],
    };
  }
}
