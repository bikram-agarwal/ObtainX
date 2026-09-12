/// Version-string semantics: extraction, "standard format" matching,
/// reconciliation, and ordering.
///
/// Part of `lib/version/` — the single home for version semantics. Everything
/// here is pure and operates on strings only; nothing in this file knows about
/// `App`, providers, or storage. The `App`-level verdicts that build on it
/// (`appHasActionableUpdate` and friends) live in `apps_provider_updates.dart`.
///
/// This code was previously spread across `source_provider.dart` (the regex
/// machinery), `apps_provider.dart` (reconciliation) and
/// `apps_provider_updates.dart` (ordering), which is how two divergent copies of
/// `reconcileVersionDifferences` came to exist. Keep it in one place.
library;

import 'package:easy_localization/easy_localization.dart';
import 'package:obtainium/custom_errors.dart';
import 'version_comparison.dart';
export 'version_comparison.dart';

// ── Version-string extraction and "standard format" matching ────────────────

class VersionService {
  static const defaultMatchGroup = '0';

  static final List<String> standardVersionRegExStrings =
      _generateStandardVersionRegExStrings();

  static final List<MapEntry<String, RegExp>> strictStandardVersionRegExes =
      standardVersionRegExStrings
          .map((p) => MapEntry(p, RegExp('^$p\$', caseSensitive: false)))
          .toList();

  static final List<MapEntry<String, RegExp>> looseStandardVersionRegExes =
      standardVersionRegExStrings
          .map((p) => MapEntry(p, RegExp(p, caseSensitive: false)))
          .toList();

  static List<String> _generateStandardVersionRegExStrings() {
    final basics = [
      '[0-9]+',
      '[0-9]+\\.[0-9]+',
      '[0-9]+\\.[0-9]+\\.[0-9]+',
      '[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+',
    ];
    final preSuffixes = ['-', '\\+'];
    final suffixes = [
      'alpha',
      'beta',
      'rc',
      'pre',
      'preview',
      'dev',
      'snapshot',
      'nightly',
      'ose',
      '[0-9]+',
    ];
    final finals = ['\\+[0-9]+', '[0-9]+'];
    final List<String> results = [];
    for (var b in basics) {
      results.add(b);
      for (var p in preSuffixes) {
        for (var s in suffixes) {
          results.add('$b$s');
          results.add('$b$p$s');
          for (var f in finals) {
            results.add('$b$s$f');
            results.add('$b$p$s$f');
          }
        }
      }
    }
    return results.toSet().toList();
  }

  String? regExValidator(String? value) {
    if (value == null || value.isEmpty) {
      return null;
    }
    try {
      RegExp(value);
    } catch (e) {
      return tr('invalidRegEx');
    }
    return null;
  }

  /// Replaces `$N` references in a string with the corresponding regex match groups.
  String? replaceMatchGroupsInString(
    RegExpMatch match,
    String matchGroupString,
  ) {
    if (RegExp('^\\d+\$').hasMatch(matchGroupString)) {
      matchGroupString = '\$$matchGroupString';
    }
    final numberRegex = RegExp(r'(\\*)\$(\d+)');
    final numbers = numberRegex.allMatches(matchGroupString);
    if (numbers.isEmpty) {
      return null;
    }
    final output = StringBuffer();
    var previousEnd = 0;
    for (final numberMatch in numbers) {
      output.write(matchGroupString.substring(previousEnd, numberMatch.start));
      final slashes = numberMatch.group(1)!;
      output.write('\\' * (slashes.length ~/ 2));
      if (slashes.length.isOdd) {
        output.write('\$${numberMatch.group(2)}');
      } else {
        final matchGroupIndex = int.tryParse(numberMatch.group(2)!);
        if (matchGroupIndex == null || matchGroupIndex > match.groupCount) {
          return null;
        }
        output.write(match.group(matchGroupIndex) ?? '');
      }
      previousEnd = numberMatch.end;
    }
    output.write(matchGroupString.substring(previousEnd));
    return output.toString();
  }

  /// Applies a version extraction regex to a string and returns the captured match group.
  String? extractVersion(
    String? versionExtractionRegEx,
    String? matchGroupString,
    String stringToCheck,
  ) {
    if (versionExtractionRegEx?.isNotEmpty == true) {
      String? version = stringToCheck;
      final match = RegExp(versionExtractionRegEx!).allMatches(version);
      if (match.isEmpty) {
        throw NoVersionError();
      }
      matchGroupString = matchGroupString?.trim() ?? '';
      if (matchGroupString.isEmpty) {
        matchGroupString = defaultMatchGroup;
      }
      version = replaceMatchGroupsInString(match.last, matchGroupString);
      if (version?.isNotEmpty != true) {
        throw NoVersionError();
      }
      return version!;
    } else {
      return null;
    }
  }

  static final Map<String, Set<String>> _strictFormatCache = {};
  static final Map<String, Set<String>> _looseFormatCache = {};
  static const int _maxFormatCacheSize = 4096;

  Set<String> findStandardFormatsForVersion(String version, bool strict) {
    final cache = strict ? _strictFormatCache : _looseFormatCache;
    final cached = cache[version];
    if (cached != null) return cached;

    final Set<String> results = {};
    final patterns = strict
        ? strictStandardVersionRegExes
        : looseStandardVersionRegExes;
    for (var entry in patterns) {
      if (entry.value.hasMatch(version)) {
        results.add(entry.key);
      }
    }
    if (cache.length >= _maxFormatCacheSize) cache.clear();
    cache[version] = results;
    return results;
  }

  bool doStringsMatchUnderRegEx(String pattern, String value1, String value2) {
    final List<String>? matchedCores = matchedSubstringsUnderRegEx(
      pattern,
      value1,
      value2,
    );
    return matchedCores != null && matchedCores[0] == matchedCores[1];
  }

  /// First regex captures from [value1] and [value2], lowercased. Null when
  /// either side has no match.
  List<String>? matchedSubstringsUnderRegEx(
    String pattern,
    String value1,
    String value2,
  ) {
    final regularExpression = RegExp(pattern, caseSensitive: false);
    final firstMatch = regularExpression.firstMatch(value1);
    final secondMatch = regularExpression.firstMatch(value2);
    if (firstMatch == null || secondMatch == null) {
      return null;
    }
    return <String>[
      value1.substring(firstMatch.start, firstMatch.end).toLowerCase(),
      value2.substring(secondMatch.start, secondMatch.end).toLowerCase(),
    ];
  }
}

/// Delegates to [VersionService.findStandardFormatsForVersion].
Set<String> findStandardFormatsForVersion(String version, bool strict) =>
    VersionService().findStandardFormatsForVersion(version, strict);

// ── Shared low-level string predicates ──────────────────────────────────────

bool _isDigit(int codeUnit) => codeUnit >= 0x30 && codeUnit <= 0x39; // '0'..'9'

final RegExp _digitsOnlySegmentPattern = RegExp(r'^\d+$');

String _trimAndRemoveLeadingVersionPrefix(String version) {
  final String trimmedVersion = version.trim();
  if (trimmedVersion.length > 1 &&
      trimmedVersion[0].toLowerCase() == 'v' &&
      _isDigit(trimmedVersion.codeUnitAt(1))) {
    return trimmedVersion.substring(1);
  }
  return trimmedVersion;
}

/// Trims, removes a conventional numeric `v` prefix, and normalizes case.
String _normalizeVersionForComparison(String version) {
  return _trimAndRemoveLeadingVersionPrefix(version).toLowerCase();
}

/// True for a bare integer version: an Android version code or build number
/// (`451`), as opposed to a version string with separators (`4.5.1`).
bool isBareIntegerVersion(String version) {
  return _digitsOnlySegmentPattern.hasMatch(
    _normalizeVersionForComparison(version),
  );
}

bool _containsDigit(String value) => value.codeUnits.any(_isDigit);

// ── Release-date-shaped version strings ─────────────────────────────────────

DateTime? _dateFromReleaseDateVersionString(String version) {
  final String trimmedVersion = _trimAndRemoveLeadingVersionPrefix(version);
  if (trimmedVersion.isEmpty) {
    return null;
  }
  if (RegExp(r'^\d{15,17}$').hasMatch(trimmedVersion)) {
    try {
      return DateTime.fromMicrosecondsSinceEpoch(int.parse(trimmedVersion));
    } catch (_) {
      return null;
    }
  }
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}(?:[T ].*)?$').hasMatch(trimmedVersion)) {
    return null;
  }
  return DateTime.tryParse(trimmedVersion);
}

int? compareReleaseDateVersionStrings(String installed, String latest) {
  final DateTime? installedDate = _dateFromReleaseDateVersionString(installed);
  final DateTime? latestDate = _dateFromReleaseDateVersionString(latest);
  if (installedDate == null || latestDate == null) {
    return null;
  }
  return installedDate.toUtc().compareTo(latestDate.toUtc()).sign;
}

// ── Build-hash tokens ───────────────────────────────────────────────────────

/// True for 8-digit all-decimal tokens that look like YYYYMMDD (excludes them
/// from commit-hash intersection so shared build dates do not imply same build).
bool isPlausibleVersionDateTokenYYYYMMDD(String token) {
  if (token.length != 8) return false;
  if (!RegExp(r'^\d{8}$').hasMatch(token)) return false;
  final year = int.tryParse(token.substring(0, 4));
  final month = int.tryParse(token.substring(4, 6));
  final day = int.tryParse(token.substring(6, 8));
  if (year == null || month == null || day == null) return false;
  if (year < 1990 || year > 2100) return false;
  if (month < 1 || month > 12) return false;
  if (day < 1 || day > 31) return false;
  return true;
}

/// True when [token] is a date-shaped build stamp rather than a build hash: a
/// YYYYMMDD run, optionally followed by a short revision suffix (`20260412a`).
/// Two releases built on the same day do not share a build identity.
bool _isDateBuildStampToken(String token) {
  if (token.length < 8 || token.length > 10) return false;
  return isPlausibleVersionDateTokenYYYYMMDD(token.substring(0, 8));
}

final RegExp _hexTokenPattern = RegExp(r'[0-9a-fA-F]{6,}');

Set<String> commitHashLikeTokensFromVersion(String version) {
  final result = <String>{};
  for (final Match match in _hexTokenPattern.allMatches(version)) {
    final String token = match.group(0)!.toLowerCase();
    // Decimal-only runs are Android versionCode / build numbers, not git hex.
    if (_digitsOnlySegmentPattern.hasMatch(token)) continue;
    if (_isDateBuildStampToken(token)) continue;
    // A build hash mixes digits with hex letters. Requiring at least one digit
    // keeps ordinary words that happen to spell hex ('facade', 'decade',
    // 'beaded', 'defaced') from being read as a shared build identity — which
    // makes two unrelated releases compare equal and pins the app to "up to
    // date" forever. An all-letter digest is possible but vanishingly rare, and
    // missing one only costs an equality shortcut, while a false match hides
    // updates indefinitely.
    if (!_containsDigit(token)) continue;
    result.add(token);
  }
  return result;
}

// ── Reconciliation: do two strings denote the same release? ─────────────────

/// Compatibility entry points all delegate to the same typed comparison.
bool? dottedNumericVersionsAreEqual(String firstVersion, String secondVersion) {
  if (!RegExp(r'^\d+(?:\.\d+)+$').hasMatch(firstVersion.trim()) ||
      !RegExp(r'^\d+(?:\.\d+)+$').hasMatch(secondVersion.trim())) {
    return null;
  }
  return compareVersionStrings(firstVersion, secondVersion).relation ==
      VersionRelation.same;
}

class VersionComparison {
  final bool areEqual;
  final String version;
  const VersionComparison({required this.areEqual, required this.version});
}

/// Relates two labels without discarding the authoritative template value.
VersionComparison? reconcileVersionDifferences(
  String templateVersion,
  String comparisonVersion,
) {
  final decision = compareVersionStrings(templateVersion, comparisonVersion);
  if (decision.relation == VersionRelation.unknown) return null;
  return VersionComparison(
    areEqual: decision.relation == VersionRelation.same,
    version: templateVersion,
  );
}

VersionComparison? reconcileVersionDifferencesByShape(
  String templateVersion,
  String comparisonVersion,
) {
  return reconcileVersionDifferences(templateVersion, comparisonVersion);
}

String versionShapeForReconciliation(String version) {
  return version.trim().toLowerCase().replaceAll(RegExp(r'\d+'), '#');
}

List<BigInt> numericVersionTokens(String version) {
  return RegExp(
    r'\d+',
  ).allMatches(version).map((match) => BigInt.parse(match.group(0)!)).toList();
}

bool recognizedNumericReleaseVersionsAreComparable(
  String installed,
  String latest,
) {
  return compareVersionStrings(installed, latest).relation !=
      VersionRelation.unknown;
}

bool versionsEffectivelyEqual(String installed, String latest) {
  return compareVersionStrings(installed, latest).relation ==
      VersionRelation.same;
}

int? compareVersionsByNumericSegments(String installed, String latest) {
  return compareVersionStrings(installed, latest).comparison;
}

bool versionOrderIsUnclear(String installed, String latest) {
  if (installed.trim().isEmpty || latest.trim().isEmpty) return false;
  return compareVersionStrings(installed, latest).relation ==
      VersionRelation.unknown;
}
