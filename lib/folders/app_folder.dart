import 'dart:math';
import 'package:obtainium/providers/source_provider.dart';

enum FolderRuleField { name, author, id, category, source }

enum FolderRuleMatchType { contains, equals, startsWith }

class FolderRule {
  final FolderRuleField field;
  final FolderRuleMatchType matchType;
  final String value;

  const FolderRule({
    required this.field,
    required this.matchType,
    required this.value,
  });

  /// Returns true if [app] satisfies this rule.
  /// [resolvedSource] is the source's runtimeType string (needed for [FolderRuleField.source]).
  bool matches(App app, {String resolvedSource = ''}) {
    if (value.isEmpty) return false;
    final lv = value.toLowerCase();

    bool applyMatch(String target) {
      final lt = target.toLowerCase();
      switch (matchType) {
        case FolderRuleMatchType.contains:
          return lt.contains(lv);
        case FolderRuleMatchType.equals:
          return lt == lv;
        case FolderRuleMatchType.startsWith:
          return lt.startsWith(lv);
      }
    }

    switch (field) {
      case FolderRuleField.name:
        return applyMatch(app.finalName);
      case FolderRuleField.author:
        return applyMatch(app.finalAuthor);
      case FolderRuleField.id:
        return applyMatch(app.id);
      case FolderRuleField.category:
        return app.categories.any((c) => applyMatch(c));
      case FolderRuleField.source:
        return applyMatch(resolvedSource);
    }
  }

  Map<String, dynamic> toJson() => {
    'field': field.name,
    'matchType': matchType.name,
    'value': value,
  };

  factory FolderRule.fromJson(Map<String, dynamic> json) => FolderRule(
    field: FolderRuleField.values.firstWhere(
      (e) => e.name == json['field'],
      orElse: () => FolderRuleField.name,
    ),
    matchType: FolderRuleMatchType.values.firstWhere(
      (e) => e.name == json['matchType'],
      orElse: () => FolderRuleMatchType.contains,
    ),
    value: json['value'] as String? ?? '',
  );
}

class AppFolder {
  final String id;
  final String name;
  final FolderRule? rule;

  const AppFolder({required this.id, required this.name, this.rule});

  AppFolder copyWith({
    String? name,
    FolderRule? rule,
    bool clearRule = false,
  }) => AppFolder(
    id: id,
    name: name ?? this.name,
    rule: clearRule ? null : (rule ?? this.rule),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    if (rule != null) 'rule': rule!.toJson(),
  };

  factory AppFolder.fromJson(Map<String, dynamic> json) => AppFolder(
    id: json['id'] as String,
    name: json['name'] as String,
    rule: json['rule'] != null
        ? FolderRule.fromJson(json['rule'] as Map<String, dynamic>)
        : null,
  );

  /// Generate a new unique ID for a folder.
  static String generateId() {
    final rand = Random();
    final ts = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
    final rnd = List.generate(
      6,
      (_) => rand.nextInt(36).toRadixString(36),
    ).join();
    return '$ts$rnd';
  }
}

// ── Per-app folder helpers ────────────────────────────────────────────────────

/// Returns the folder IDs this app explicitly belongs to.
List<String> folderIdsForApp(App app) {
  final raw = app.additionalSettings['folderIds'];
  if (raw == null) return [];
  return List<String>.from(raw as List);
}

/// Returns the folder IDs this app is explicitly excluded from.
List<String> excludedFolderIdsForApp(App app) {
  final raw = app.additionalSettings['excludedFolderIds'];
  if (raw == null) return [];
  return List<String>.from(raw as List);
}

/// Adds [folderId] to the app's folder membership and removes it from exclusions.
void addAppToFolder(App app, String folderId, String folderName) {
  final ids = folderIdsForApp(app).toSet()..add(folderId);
  final excluded = excludedFolderIdsForApp(app).toSet()..remove(folderId);
  app.additionalSettings['folderIds'] = ids.toList();
  app.additionalSettings['excludedFolderIds'] = excluded.toList();
  final Map<String, dynamic> folderNames = Map<String, dynamic>.from(
    app.additionalSettings['folderNames'] as Map? ?? {},
  );
  folderNames[folderId] = folderName;
  app.additionalSettings['folderNames'] = folderNames;
}

/// Removes [folderId] from the app's folder membership and adds it to exclusions.
void removeAppFromFolder(App app, String folderId) {
  final ids = folderIdsForApp(app).toSet()..remove(folderId);
  final excluded = excludedFolderIdsForApp(app).toSet()..add(folderId);
  app.additionalSettings['folderIds'] = ids.toList();
  app.additionalSettings['excludedFolderIds'] = excluded.toList();
  final Map<String, dynamic> folderNames = Map<String, dynamic>.from(
    app.additionalSettings['folderNames'] as Map? ?? {},
  );
  folderNames.remove(folderId);
  app.additionalSettings['folderNames'] = folderNames;
}

/// Removes all references to [folderId] from the app (membership + exclusions).
void clearFolderFromApp(App app, String folderId) {
  final ids = folderIdsForApp(app).toSet()..remove(folderId);
  final excluded = excludedFolderIdsForApp(app).toSet()..remove(folderId);
  app.additionalSettings['folderIds'] = ids.toList();
  app.additionalSettings['excludedFolderIds'] = excluded.toList();
  final Map<String, dynamic> folderNames = Map<String, dynamic>.from(
    app.additionalSettings['folderNames'] as Map? ?? {},
  );
  folderNames.remove(folderId);
  app.additionalSettings['folderNames'] = folderNames;
}
