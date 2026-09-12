/// A comparison result is separate from either original version string.
enum VersionRelation { same, older, newer, unknown }

class VersionDecision {
  final VersionRelation relation;
  final String reason;

  const VersionDecision(this.relation, this.reason);

  int? get comparison => switch (relation) {
    VersionRelation.same => 0,
    VersionRelation.older => -1,
    VersionRelation.newer => 1,
    VersionRelation.unknown => null,
  };
}

final _decimal = RegExp(r'^\d+$');
final _numericCore = RegExp(r'^(\d+(?:\.\d+)*)(.*)$');

/// Candidate labels retain qualifiers and revisions for the shared parser.
final releaseVersionPattern = RegExp(
  r'v?\d+(?:\.\d+)+[a-z0-9.+_-]*(?:[ \t]+(?:dev|snapshot|nightly|alpha|beta|preview|pre|rc)(?:[.-][a-z0-9-]+(?:\.[a-z0-9-]+)*|\d+(?:\.[a-z0-9-]+)*)?\b)?(?:\s*\([^)]*\))?',
  caseSensitive: false,
);
final _hashToken = RegExp(r'(?<![a-z0-9])[a-f0-9]{6,}(?![a-z0-9])');
final _prerelease = RegExp(
  r'^[.-]?(dev|snapshot|nightly|alpha|beta|preview|pre|rc)(?:[.-]([a-z0-9-]+(?:\.[a-z0-9-]+)*)|(\d+(?:\.[a-z0-9-]+)*))?$',
);
const _prereleaseRank = {
  'dev': 0,
  'snapshot': 1,
  'nightly': 2,
  'alpha': 3,
  'beta': 4,
  'pre': 5,
  'preview': 6,
  'rc': 7,
};

String normalizeVersionLabel(String value) {
  final normalized = value.trim().toLowerCase();
  if (RegExp(r'^v\d').hasMatch(normalized)) return normalized.substring(1);
  return normalized;
}

VersionDecision _ordered(int comparison, String reason) {
  return VersionDecision(
    comparison == 0
        ? VersionRelation.same
        : comparison < 0
        ? VersionRelation.older
        : VersionRelation.newer,
    reason,
  );
}

/// Decimal identifiers are compared without a machine integer limit.
int compareDecimalIdentifiers(String first, String second) {
  final firstDigits = first.replaceFirst(RegExp(r'^0+'), '');
  final secondDigits = second.replaceFirst(RegExp(r'^0+'), '');
  final lengthComparison = firstDigits.length.compareTo(secondDigits.length);
  if (lengthComparison != 0) return lengthComparison.sign;
  return firstDigits.compareTo(secondDigits).sign;
}

int _compareComponents(
  List<String> first,
  List<String> second, {
  bool pad = true,
}) {
  final length = first.length > second.length ? first.length : second.length;
  for (var index = 0; index < length; index++) {
    if (!pad && (index >= first.length || index >= second.length)) {
      return first.length.compareTo(second.length).sign;
    }
    final firstPart = index < first.length ? first[index] : '0';
    final secondPart = index < second.length ? second[index] : '0';
    final firstNumeric = _decimal.hasMatch(firstPart);
    final secondNumeric = _decimal.hasMatch(secondPart);
    final comparison = firstNumeric && secondNumeric
        ? compareDecimalIdentifiers(firstPart, secondPart)
        : firstNumeric != secondNumeric
        ? (firstNumeric ? -1 : 1)
        : firstPart.compareTo(secondPart).sign;
    if (comparison != 0) return comparison;
  }
  return 0;
}

class _ParsedRelease {
  final List<String> core;
  final String? qualifier;
  final List<String> qualifierParts;
  final List<String>? revision;
  final String variant;
  final String? hash;

  const _ParsedRelease(
    this.core,
    this.qualifier,
    this.qualifierParts,
    this.revision,
    this.variant,
    this.hash,
  );
}

_ParsedRelease? _parseRelease(String input) {
  var text = normalizeVersionLabel(input);
  // A title's digits are not version segments. Extract only one unambiguous
  // dotted version, preserving its suffix; multiple candidates require a rule.
  if (!RegExp(r'^\d+(?:[.\-+ (]|$)').hasMatch(text)) {
    final candidates = releaseVersionPattern.allMatches(text).toList();
    if (candidates.length != 1) return null;
    text = normalizeVersionLabel(candidates.single.group(0)!);
  }
  final metadata = text.indexOf('+');
  if (metadata >= 0) {
    if (!RegExp(
      r'^[a-z0-9-]+(?:\.[a-z0-9-]+)*$',
    ).hasMatch(text.substring(metadata + 1))) {
      return null;
    }
    text = text.substring(0, metadata);
  }
  String? hash;
  final hashMatches = _hashToken.allMatches(text).where((match) {
    final token = match.group(0)!;
    return RegExp(r'[a-f]').hasMatch(token) && RegExp(r'\d').hasMatch(token);
  }).toList();
  if (hashMatches.length > 1) return null;
  if (hashMatches.isNotEmpty) {
    hash = hashMatches.single.group(0);
    text = text.replaceRange(
      hashMatches.single.start,
      hashMatches.single.end,
      '',
    );
    text = text.replaceAll(RegExp(r'\s*\((?:git\s*)?\)\s*'), '');
    text = text.replaceFirst(RegExp(r'[.-]$'), '');
  }
  List<String>? revision;
  final parenthesizedBuild = RegExp(r'\s*\((\d+)\)$').firstMatch(text);
  if (parenthesizedBuild != null) {
    revision = [parenthesizedBuild.group(1)!];
    text = text.substring(0, parenthesizedBuild.start);
  }
  final coreMatch = _numericCore.firstMatch(text);
  if (coreMatch == null) return null;
  final core = coreMatch.group(1)!.split('.');
  final suffix = coreMatch.group(2)!.trim();
  if (suffix.isEmpty) {
    return _ParsedRelease(core, null, const [], revision, '', hash);
  }
  final qualifier = _prerelease.firstMatch(suffix);
  if (qualifier != null) {
    return _ParsedRelease(
      core,
      qualifier.group(1),
      (qualifier.group(2) ?? qualifier.group(3))?.split('.') ?? const [],
      revision,
      '',
      hash,
    );
  }
  // Android release revisions (e.g. 8.12.9-28.BETA) are not discarded as fluff.
  final build = RegExp(
    r'^-(\d+(?:\.\d+)*)([.-][a-z][a-z0-9.-]*)?$',
  ).firstMatch(suffix);
  if (build != null) {
    return _ParsedRelease(
      core,
      null,
      const [],
      build.group(1)!.split('.'),
      build.group(2) ?? '',
      hash,
    );
  }
  if (RegExp(r'^[.-][a-z][a-z0-9.-]*$').hasMatch(suffix)) {
    return _ParsedRelease(core, null, const [], revision, suffix, hash);
  }
  return null;
}

// Lists and source sorting ask about the same labels repeatedly. Bound this
// cache so long-running background checks cannot retain every past release.
final _parsedReleaseCache = <String, _ParsedRelease?>{};
_ParsedRelease? _cachedRelease(String label) {
  if (_parsedReleaseCache.containsKey(label)) return _parsedReleaseCache[label];
  final parsed = _parseRelease(label);
  if (_parsedReleaseCache.length >= 256) {
    _parsedReleaseCache.remove(_parsedReleaseCache.keys.first);
  }
  _parsedReleaseCache[label] = parsed;
  return parsed;
}

/// Choose a single ordering policy for a source list. Mixing version order and
/// date/name fallbacks pair by pair can create cycles and arbitrary results.
bool versionsHaveConsistentOrder(Iterable<String> labels) {
  final unique = labels.toSet().toList();
  for (var firstIndex = 0; firstIndex < unique.length; firstIndex++) {
    for (
      var secondIndex = firstIndex + 1;
      secondIndex < unique.length;
      secondIndex++
    ) {
      if (compareVersionStrings(
            unique[firstIndex],
            unique[secondIndex],
          ).relation ==
          VersionRelation.unknown) {
        return false;
      }
    }
  }
  return true;
}

DateTime? _releaseDate(String value) {
  final text = normalizeVersionLabel(value);
  if (RegExp(r'^\d{15,17}$').hasMatch(text)) {
    try {
      return DateTime.fromMicrosecondsSinceEpoch(int.parse(text), isUtc: true);
    } catch (_) {
      return null;
    }
  }
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}(?:[t ].*)?$').hasMatch(text)) return null;
  return DateTime.tryParse(text.replaceFirst('t', 'T'))?.toUtc();
}

/// Recognized release components establish order. A missing revision, different
/// flavor, ambiguous title, or opaque hash is evidence of uncertainty, not age.
VersionDecision compareVersionStrings(String installed, String latest) {
  final first = normalizeVersionLabel(installed);
  final second = normalizeVersionLabel(latest);
  if (first.isEmpty || second.isEmpty) {
    return const VersionDecision(VersionRelation.unknown, 'missingVersion');
  }
  if (first == second) {
    return const VersionDecision(VersionRelation.same, 'sameLabel');
  }
  final firstDate = _releaseDate(first);
  final secondDate = _releaseDate(second);
  if (firstDate != null && secondDate != null) {
    return _ordered(firstDate.compareTo(secondDate), 'releaseDateVersion');
  }
  if (firstDate != null || secondDate != null) {
    return const VersionDecision(VersionRelation.unknown, 'differentSchemes');
  }
  final firstRelease = _cachedRelease(first);
  final secondRelease = _cachedRelease(second);
  if (firstRelease == null || secondRelease == null) {
    return const VersionDecision(VersionRelation.unknown, 'unrecognizedFormat');
  }
  // A lone build ID and a dotted display version occupy different schemes.
  if ((firstRelease.core.length == 1) != (secondRelease.core.length == 1)) {
    return const VersionDecision(VersionRelation.unknown, 'differentSchemes');
  }
  if (firstRelease.variant != secondRelease.variant) {
    return const VersionDecision(VersionRelation.unknown, 'differentVariants');
  }
  final coreComparison = _compareComponents(
    firstRelease.core,
    secondRelease.core,
  );
  if (coreComparison != 0) return _ordered(coreComparison, 'numericRelease');
  if (firstRelease.qualifier != secondRelease.qualifier) {
    return _ordered(
      (firstRelease.qualifier == null
              ? 8
              : _prereleaseRank[firstRelease.qualifier]!)
          .compareTo(
            secondRelease.qualifier == null
                ? 8
                : _prereleaseRank[secondRelease.qualifier]!,
          ),
      'prerelease',
    );
  }
  final qualifierComparison = _compareComponents(
    firstRelease.qualifierParts,
    secondRelease.qualifierParts,
    pad: false,
  );
  if (qualifierComparison != 0) {
    return _ordered(qualifierComparison, 'prerelease');
  }
  if (firstRelease.hash != secondRelease.hash) {
    return const VersionDecision(
      VersionRelation.unknown,
      'differentBuildHashes',
    );
  }
  if ((firstRelease.revision == null) != (secondRelease.revision == null)) {
    return const VersionDecision(
      VersionRelation.unknown,
      'missingBuildRevision',
    );
  }
  if (firstRelease.revision != null) {
    return _ordered(
      _compareComponents(firstRelease.revision!, secondRelease.revision!),
      'buildRevision',
    );
  }
  return const VersionDecision(VersionRelation.same, 'sameRelease');
}
