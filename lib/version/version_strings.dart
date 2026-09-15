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
    final numberRegex = RegExp(r'\$\d+');
    final numbers = numberRegex.allMatches(matchGroupString);
    if (numbers.isEmpty) {
      return null;
    }
    var outputString = matchGroupString;
    for (final numberMatch in numbers) {
      final number = numberMatch.group(0)!;
      final int matchGroupIndex = int.parse(number.substring(1));
      // Guard against a replacement referencing a capture group that doesn't
      // exist — return null (→ caller raises NoVersionError) instead of letting
      // match.group() throw a RangeError (parity with fork main).
      if (matchGroupIndex > match.groupCount) {
        return null;
      }
      final matchGroup = match.group(matchGroupIndex) ?? '';
      final isEscaped = outputString.contains('\\$number');
      if (!isEscaped) {
        outputString = outputString.replaceAll(number, matchGroup);
      } else {
        outputString = outputString.replaceAll('\\$number', number);
      }
    }
    return outputString;
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

/// Returns whether two plain dotted-numeric versions are equal after padding
/// missing trailing segments with zero. Returns null when either version uses a
/// different format.
bool? dottedNumericVersionsAreEqual(String firstVersion, String secondVersion) {
  final List<List<int>> parsedVersions = <List<int>>[];
  for (final String version in <String>[firstVersion, secondVersion]) {
    final List<String> segments = version.trim().split('.');
    if (segments.length < 2) {
      return null;
    }
    final List<int> numericSegments = <int>[];
    for (final String segment in segments) {
      if (segment.isEmpty ||
          segment.codeUnits.any((int codeUnit) => !_isDigit(codeUnit))) {
        return null;
      }
      final int? numericSegment = int.tryParse(segment);
      if (numericSegment == null) {
        return null;
      }
      numericSegments.add(numericSegment);
    }
    parsedVersions.add(numericSegments);
  }

  final List<int> firstSegments = parsedVersions[0];
  final List<int> secondSegments = parsedVersions[1];
  final int segmentCount = firstSegments.length > secondSegments.length
      ? firstSegments.length
      : secondSegments.length;
  for (int segmentIndex = 0; segmentIndex < segmentCount; segmentIndex++) {
    final int firstSegment = segmentIndex < firstSegments.length
        ? firstSegments[segmentIndex]
        : 0;
    final int secondSegment = segmentIndex < secondSegments.length
        ? secondSegments[segmentIndex]
        : 0;
    if (firstSegment != secondSegment) {
      return false;
    }
  }
  return true;
}

/// Result of [reconcileVersionDifferences]: whether two version strings denote
/// the same release, plus the string that should be stored for the app.
class VersionComparison {
  final bool areEqual;
  final String version;
  const VersionComparison({required this.areEqual, required this.version});

  @override
  String toString() => 'VersionComparison(areEqual: $areEqual, $version)';
}

/// THE version reconciliation entry point — "do these two strings denote the
/// same release, and which one should be stored?".
///
/// Returns null when the two versions can't be related at all, a
/// [VersionComparison] with `areEqual: true` (and [comparisonVersion]) when they
/// denote the same release, or `areEqual: false` (and [templateVersion]) when
/// they are relatable but different.
///
/// DIRECTIONAL: [templateVersion] (the authoritative side — normally the real
/// device version) is matched strictly, while [comparisonVersion] may fall back
/// to loose matching. A shared-format substring match is not enough for
/// equality when one side continues with another dotted segment
/// (`('7.1', 'v7.1.1')`, `('26.06', '26.06.9df4c85')`). Suffixes after a
/// non-dot delimiter still count as the same release
/// (`('26.06', '26.06-9df4c85')`, `('2.19.1', '2.19.1 (git 50a6b17)')`).
/// Zero-only dotted padding (`('1.2', '1.2.0')`) remains equal. Argument order
/// still matters for relatability (`('v7.1.1', '7.1')` stays unrelatable
/// because the v-prefixed template has no strict format).
///
/// There used to be a second copy of this function as an extension member on
/// `AppsProvider` (in apps_provider_lifecycle.dart). Because an extension member
/// shadows a top-level function of the same name, every production caller
/// silently got that copy — which lacked the [reconcileVersionDifferencesByShape]
/// fallback, so versions like `1.0.915254043.release` were reported as
/// unreconcilable, install-status reconciliation flipped the app to pseudo
/// versioning and marked it as running a release it never installed. Keep this
/// as the ONLY implementation; do not reintroduce a same-named member anywhere.
VersionComparison? reconcileVersionDifferences(
  String templateVersion,
  String comparisonVersion,
) {
  // A stable release and its matching prerelease share the same dotted numeric
  // substring, but they are different releases. Without this guard, loose
  // matching treats 2.9.8 and v2.9.8-Preview-245 as equal, replaces the real
  // installed version with the preview tag, and makes the UI report a
  // pseudo-version even in explicit standard mode.
  if (_compareMatchingPrereleaseAndStableVersions(
        templateVersion,
        comparisonVersion,
      ) !=
      null) {
    return VersionComparison(areEqual: false, version: templateVersion);
  }
  final templateVersionFormats = findStandardFormatsForVersion(
    templateVersion,
    true,
  );
  var comparisonVersionFormats = findStandardFormatsForVersion(
    comparisonVersion,
    true,
  );
  if (comparisonVersionFormats.isEmpty) {
    comparisonVersionFormats = findStandardFormatsForVersion(
      comparisonVersion,
      false,
    );
  }
  final commonStandardFormats = templateVersionFormats.intersection(
    comparisonVersionFormats,
  );
  if (commonStandardFormats.isEmpty) {
    final VersionComparison? shapeComparison =
        reconcileVersionDifferencesByShape(templateVersion, comparisonVersion);
    if (shapeComparison != null) {
      return shapeComparison;
    }
    final bool? dottedNumericEquality = dottedNumericVersionsAreEqual(
      templateVersion,
      comparisonVersion,
    );
    if (dottedNumericEquality != null) {
      return VersionComparison(
        areEqual: dottedNumericEquality,
        version: dottedNumericEquality ? comparisonVersion : templateVersion,
      );
    }
    return null;
  }
  for (String pattern in commonStandardFormats) {
    final List<String>? matchedCores = VersionService()
        .matchedSubstringsUnderRegEx(
          pattern,
          comparisonVersion,
          templateVersion,
        );
    if (matchedCores == null || matchedCores[0] != matchedCores[1]) {
      continue;
    }
    // Same core under this pattern, but a short pattern can match a prefix of
    // a longer dotted version ('7.1' inside 'v7.1.1', '26.06' inside
    // '26.06.9df4c85'). Any further dotted segment is a different release;
    // suffixes after space/paren/hyphen/etc. are not.
    if (_matchedCoreHasAdditionalDottedSegment(
          comparisonVersion,
          matchedCores[0],
        ) ||
        _matchedCoreHasAdditionalDottedSegment(
          templateVersion,
          matchedCores[1],
        )) {
      continue;
    }
    return VersionComparison(areEqual: true, version: comparisonVersion);
  }
  return VersionComparison(areEqual: false, version: templateVersion);
}

/// True when [matchedCore] appears in [version] and is followed by another
/// dotted segment that is not zero-only numeric padding.
///
/// Dot-separated extensions are different releases (`7.1.1`, `26.06.9df4c85`).
/// Non-dot delimiters keep the same release (`26.06-9df4c85`,
/// `2.19.1 (git 50a6b17)`). Zero-only padding (`1.2.0` after core `1.2`) does
/// not count.
bool _matchedCoreHasAdditionalDottedSegment(
  String version,
  String matchedCore,
) {
  final String normalizedVersion = _normalizeVersionForComparison(version);
  final String normalizedCore = matchedCore.toLowerCase();
  if (normalizedCore.isEmpty) {
    return false;
  }
  final int coreAt = normalizedVersion.indexOf(normalizedCore);
  if (coreAt < 0) {
    return false;
  }
  final String remainder = normalizedVersion.substring(
    coreAt + normalizedCore.length,
  );
  if (!remainder.startsWith('.')) {
    return false;
  }
  final String dottedSuffix = remainder.substring(1);
  if (dottedSuffix.isEmpty) {
    return false;
  }
  return !_isOnlyZeroSegments(dottedSuffix);
}

/// Relates two versions that share a *shape* (digits replaced by `#`) but no
/// standard format — e.g. `1.0.896819557.release` and `1.0.915254043.release`.
VersionComparison? reconcileVersionDifferencesByShape(
  String templateVersion,
  String comparisonVersion,
) {
  final String templateShape = versionShapeForReconciliation(templateVersion);
  final String comparisonShape = versionShapeForReconciliation(
    comparisonVersion,
  );
  if (templateShape.isEmpty || templateShape != comparisonShape) {
    return null;
  }
  final templateTokens = numericVersionTokens(templateVersion);
  final comparisonTokens = numericVersionTokens(comparisonVersion);
  if (templateTokens.isEmpty ||
      templateTokens.length != comparisonTokens.length) {
    return null;
  }
  for (int index = 0; index < templateTokens.length; index++) {
    if (templateTokens[index] != comparisonTokens[index]) {
      return VersionComparison(areEqual: false, version: templateVersion);
    }
  }
  return VersionComparison(areEqual: true, version: comparisonVersion);
}

String versionShapeForReconciliation(String version) {
  return version.trim().toLowerCase().replaceAll(RegExp(r'\d+'), '#');
}

List<int> numericVersionTokens(String version) {
  return RegExp(
    r'\d+',
  ).allMatches(version).map((m) => int.tryParse(m.group(0)!) ?? 0).toList();
}

// ── Ordering: which of two version strings is newer? ────────────────────────

/// True when [needle] appears in [longer] as a contiguous substring with
/// boundaries so we do not treat [2.0] as inside [12.0] or [.0] as inside [8.0].
bool _boundedVersionSubstringInHaystack(
  String longer,
  String needle,
  int startIndex,
) {
  final int needleLen = needle.length;
  if (needleLen == 0 ||
      startIndex < 0 ||
      startIndex + needleLen > longer.length) {
    return false;
  }
  if (longer.substring(startIndex, startIndex + needleLen) != needle) {
    return false;
  }
  final int endIndex = startIndex + needleLen;
  final int firstUnit = needle.codeUnitAt(0);
  if (startIndex > 0) {
    final int prevUnit = longer.codeUnitAt(startIndex - 1);
    if (_isDigit(firstUnit) && _isDigit(prevUnit)) {
      return false;
    }
    if (firstUnit == 0x2E && _isDigit(prevUnit)) {
      // ".0" inside "8.0" must not match as a standalone version.
      return false;
    }
    if (_isDigit(firstUnit) &&
        prevUnit == 0x2E &&
        startIndex > 1 &&
        _isDigit(longer.codeUnitAt(startIndex - 2))) {
      // "0.2" inside "153.0.2" must not match as a standalone version.
      return false;
    }
  }
  if (endIndex < longer.length) {
    final int lastUnit = needle.codeUnitAt(needleLen - 1);
    final int nextUnit = longer.codeUnitAt(endIndex);
    if (_isDigit(lastUnit) && _isDigit(nextUnit)) {
      return false;
    }
    if (_isDigit(lastUnit) &&
        nextUnit == 0x2E &&
        endIndex + 1 < longer.length) {
      // A non-empty dot segment extends the version, whether it starts with a
      // digit ("153.0.2") or hash-like text ("26.03.a4d75424").
      return false;
    }
  }
  return true;
}

/// True when the shorter of [a]/[b] appears inside the longer as a bounded
/// substring (covers [1.6.5-rc0] in [v1.6.5-rc0], build ids embedded in carrier
/// strings, and titles like [1Password: ... 8.12.8-27.BETA]).
bool _oneVersionStringContainsOtherAsBoundedSubstring(String a, String b) {
  if (a.isEmpty || b.isEmpty || a == b) {
    return false;
  }
  final String shorter = a.length <= b.length ? a : b;
  final String longer = a.length <= b.length ? b : a;
  if (shorter.length == longer.length) {
    return false;
  }
  int searchFrom = 0;
  while (true) {
    final int foundAt = longer.indexOf(shorter, searchFrom);
    if (foundAt < 0) {
      return false;
    }
    if (_boundedVersionSubstringInHaystack(longer, shorter, foundAt)) {
      return true;
    }
    searchFrom = foundAt + 1;
  }
}

bool _isOnlyZeroSegments(String suffix) {
  final List<String> segments = suffix.split('.');
  for (final String segment in segments) {
    if (segment.isEmpty) return false;
    if (!_digitsOnlySegmentPattern.hasMatch(segment)) return false;
    if (int.tryParse(segment) != 0) return false;
  }
  return true;
}

final RegExp _recognizedPrereleasePattern = RegExp(
  r'^(.+)-(preview|alpha|beta|rc)(?:[.-]?\d+)?$',
  caseSensitive: false,
);

final RegExp _recognizedNumericReleasePattern = RegExp(
  r'^\d+(?:\.\d+)+(?:-(?:preview|alpha|beta|rc)(?:[.-]?\d+)?)?$',
  caseSensitive: false,
);

/// True when both values are conventional dotted release versions, optionally
/// with a leading `v` and a recognized prerelease suffix. These versions remain
/// comparable even when only one side is a prerelease or their base versions
/// differ, such as `2.9.8-Preview-241` and `v2.9.7`.
bool recognizedNumericReleaseVersionsAreComparable(
  String installed,
  String latest,
) {
  return _recognizedNumericReleasePattern.hasMatch(
        _normalizeVersionForComparison(installed),
      ) &&
      _recognizedNumericReleasePattern.hasMatch(
        _normalizeVersionForComparison(latest),
      );
}

/// Orders a recognized prerelease immediately before the stable build with the
/// same base version.
int? _compareMatchingPrereleaseAndStableVersions(
  String installed,
  String latest,
) {
  final String normalizedInstalled = _normalizeVersionForComparison(installed);
  final String normalizedLatest = _normalizeVersionForComparison(latest);
  final RegExpMatch? installedPrerelease = _recognizedPrereleasePattern
      .firstMatch(normalizedInstalled);
  final RegExpMatch? latestPrerelease = _recognizedPrereleasePattern.firstMatch(
    normalizedLatest,
  );

  if (installedPrerelease?.group(1) == normalizedLatest) {
    return -1;
  }
  if (latestPrerelease?.group(1) == normalizedInstalled) {
    return 1;
  }
  return null;
}

/// True if both versions are equal or one is a prefix of the other with a
/// non-digit/non-dot suffix (e.g. 50.5.19 and 50.5.19-31), or zero-only dot
/// extension (e.g. 1.2 and 1.2.0), or both contain the same commit-hash-like
/// token (6+ hex chars). Avoids a false match of 1.0 in 10.0 by requiring a
/// boundary after the shorter.
bool versionsEffectivelyEqual(String installed, String latest) {
  final String normalizedInstalled = _normalizeVersionForComparison(installed);
  final String normalizedLatest = _normalizeVersionForComparison(latest);
  if (normalizedInstalled == normalizedLatest) return true;
  if (normalizedInstalled.isEmpty || normalizedLatest.isEmpty) return false;
  final int? releaseDateVersionComparison = compareReleaseDateVersionStrings(
    installed,
    latest,
  );
  if (releaseDateVersionComparison == 0) {
    return true;
  }
  if (_compareMatchingPrereleaseAndStableVersions(
        normalizedInstalled,
        normalizedLatest,
      ) !=
      null) {
    return false;
  }
  final installedLen = normalizedInstalled.length;
  final latestLen = normalizedLatest.length;
  if (normalizedLatest.startsWith(normalizedInstalled) &&
      latestLen > installedLen) {
    final nextChar = normalizedLatest.codeUnitAt(installedLen);
    if (!_isDigit(nextChar)) {
      if (nextChar == 0x2E) {
        if (_isOnlyZeroSegments(normalizedLatest.substring(installedLen + 1))) {
          return true;
        }
      } else {
        return true;
      }
    }
  }
  if (normalizedInstalled.startsWith(normalizedLatest) &&
      installedLen > latestLen) {
    final nextChar = normalizedInstalled.codeUnitAt(latestLen);
    if (!_isDigit(nextChar)) {
      if (nextChar == 0x2E) {
        if (_isOnlyZeroSegments(normalizedInstalled.substring(latestLen + 1))) {
          return true;
        }
      } else {
        return true;
      }
    }
  }
  if (_oneVersionStringContainsOtherAsBoundedSubstring(
    normalizedInstalled,
    normalizedLatest,
  )) {
    return true;
  }
  final installedHashes = commitHashLikeTokensFromVersion(normalizedInstalled);
  final latestHashes = commitHashLikeTokensFromVersion(normalizedLatest);
  if (installedHashes.intersection(latestHashes).isNotEmpty) {
    return true;
  }
  return false;
}

/// Compare version strings by numeric segments (e.g. 2.0.0 vs 1.9.9).
/// Returns -1 if [installed] < [latest], 0 if equal, 1 if [installed] > [latest],
/// null if not comparable.
int? compareVersionsByNumericSegments(String installed, String latest) {
  final String normalizedInstalled = _normalizeVersionForComparison(installed);
  final String normalizedLatest = _normalizeVersionForComparison(latest);
  final int? releaseDateVersionComparison = compareReleaseDateVersionStrings(
    installed,
    latest,
  );
  if (releaseDateVersionComparison != null) {
    return releaseDateVersionComparison;
  }
  final int? prereleaseVersionComparison =
      _compareMatchingPrereleaseAndStableVersions(
        normalizedInstalled,
        normalizedLatest,
      );
  if (prereleaseVersionComparison != null) {
    return prereleaseVersionComparison;
  }
  final installedSegments = numericVersionTokens(normalizedInstalled);
  final latestSegments = numericVersionTokens(normalizedLatest);
  if (installedSegments.isEmpty || latestSegments.isEmpty) return null;
  final maxLen = installedSegments.length > latestSegments.length
      ? installedSegments.length
      : latestSegments.length;
  for (int i = 0; i < maxLen; i++) {
    final inst = i < installedSegments.length ? installedSegments[i] : 0;
    final lat = i < latestSegments.length ? latestSegments[i] : 0;
    if (inst < lat) return -1;
    if (inst > lat) return 1;
  }
  return 0;
}

/// True when dot-separated segments match numerically through the shared prefix,
/// and the first differing part involves commit-hash-like material on at least
/// one side (e.g. [26.03.a4d75424] vs [26.03.0264c0ba]).
bool _dotSeparatedNumericPrefixThenIncomparableHashRemainder(
  String installed,
  String latest,
) {
  final installedParts = installed.split('.');
  final latestParts = latest.split('.');
  final int pairCount = installedParts.length <= latestParts.length
      ? installedParts.length
      : latestParts.length;
  for (int index = 0; index < pairCount; index++) {
    final String installedSegment = installedParts[index];
    final String latestSegment = latestParts[index];
    if (installedSegment == latestSegment) continue;
    final bool installedNumeric = _digitsOnlySegmentPattern.hasMatch(
      installedSegment,
    );
    final bool latestNumeric = _digitsOnlySegmentPattern.hasMatch(
      latestSegment,
    );
    if (installedNumeric && latestNumeric) {
      if (int.parse(installedSegment) != int.parse(latestSegment)) {
        return false;
      }
      continue;
    }
    final bool hashInstalled = commitHashLikeTokensFromVersion(
      installedSegment,
    ).isNotEmpty;
    final bool hashLatest = commitHashLikeTokensFromVersion(
      latestSegment,
    ).isNotEmpty;
    return hashInstalled || hashLatest;
  }
  if (installedParts.length == latestParts.length) return false;
  final List<String> longerParts = installedParts.length > latestParts.length
      ? installedParts
      : latestParts;
  final int shorterLen = installedParts.length <= latestParts.length
      ? installedParts.length
      : latestParts.length;
  for (int index = shorterLen; index < longerParts.length; index++) {
    final String tailSegment = longerParts[index];
    if (tailSegment.isEmpty) continue;
    if (_digitsOnlySegmentPattern.hasMatch(tailSegment) &&
        int.parse(tailSegment) == 0) {
      continue;
    }
    if (commitHashLikeTokensFromVersion(tailSegment).isNotEmpty) return true;
  }
  return false;
}

/// True when ordering is ambiguous: [compareVersionsByNumericSegments] ties on
/// digit groups, or dot segments disagree in a hash-like way that overrides that
/// compare. Not [versionsEffectivelyEqual].
bool versionOrderIsUnclear(String installed, String latest) {
  final String normalizedInstalled = _normalizeVersionForComparison(installed);
  final String normalizedLatest = _normalizeVersionForComparison(latest);
  if (normalizedInstalled.isEmpty || normalizedLatest.isEmpty) return false;
  if (normalizedInstalled == normalizedLatest) return false;
  if (versionsEffectivelyEqual(installed, latest)) {
    return false;
  }
  if (compareReleaseDateVersionStrings(installed, latest) != null) {
    return false;
  }
  if (compareVersionsByNumericSegments(normalizedInstalled, normalizedLatest) ==
      0) {
    return true;
  }
  return _dotSeparatedNumericPrefixThenIncomparableHashRemainder(
    normalizedInstalled,
    normalizedLatest,
  );
}
