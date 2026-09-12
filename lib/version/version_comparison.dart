/// A comparison result is separate from either original version string.
enum VersionRelation { same, older, newer, unknown, sourceChanged }

class VersionDecision {
  final VersionRelation relation;
  final String reason;

  const VersionDecision(this.relation, this.reason);

  int? get comparison => switch (relation) {
    VersionRelation.same => 0,
    VersionRelation.older => -1,
    VersionRelation.newer => 1,
    VersionRelation.unknown || VersionRelation.sourceChanged => null,
  };
}

final _decimal = RegExp(r'^\d+$');
final _numericCore = RegExp(r'^(\d+(?:\.\d+)*)(.*)$');

/// Candidate labels retain qualifiers and revisions for the shared parser.
final releaseVersionPattern = RegExp(
  r'(?<![a-z0-9.])v?\d+(?:\.\d+)+[a-z0-9.+_-]*(?:[ \t]+(?:dev|snapshot|nightly|alpha|beta|preview|pre|rc)(?:[.-][a-z0-9-]+(?:\.[a-z0-9-]+)*|\d+(?:\.[a-z0-9-]+)*)?\b)?(?:\s*\([^)]*\))?',
  caseSensitive: false,
);
final _hashToken = RegExp(r'(?<![a-z0-9])[a-f0-9]{6,}(?![a-z0-9])');
final _prerelease = RegExp(
  r'^[.-]?(dev|snapshot|nightly|alpha|beta|preview|pre|rc)(?:\.([a-z][a-z0-9-]*(?:\.[a-z0-9-]+)*|\d+(?:\.[a-z0-9-]+)*)|-?(\d+(?:\.[a-z0-9-]+)*))?$',
);
final _embeddedPrerelease = RegExp(
  r'(?<![a-z0-9])(dev|snapshot|nightly|alpha|beta|preview|pre|rc)(?:[.-]?(\d+(?:\.\d+)*))?(?=$|[.\-_\s()])',
);
final _descriptiveSuffix = RegExp(
  r'^[.\-_\s()]*\p{L}[\p{L}\p{N}.\-_\s()]*$',
  unicode: true,
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
  final String scheme;

  const _ParsedRelease(
    this.core,
    this.qualifier,
    this.qualifierParts,
    this.revision,
    this.variant,
    this.hash, {
    this.scheme = 'release',
  });
}

final _googleDeviceRelease = RegExp(
  r'^(?:[a-z]\.)?(\d+)\.(playstore\.[a-z0-9_-]+|odad-stub)\.(\d{6,})$',
);
final _satelliteRelease = RegExp(
  r'^(?:stargate\.android_)?(\d{8})_(\d+)_rc(\d+)\.(release_[a-z_]+)$',
);
final _meetRelease = RegExp(
  r'^(\d+\.\d+\.\d+)\.(public_beta\.)?duo\.android_(\d{8})\.(\d+)_p(\d+)(?:\.[a-z])?$',
);
final _playStoreRelease = RegExp(
  r'^(\d+\.\d+\.\d+)-(\d+)\s+\[\d+\]\s+\[pr\]\s+(\d+)$',
);

/// Descriptive labels are retained for source/asset matching, but have no
/// ordering weight. No manufacturer or distribution names are needed here.
String? releaseDescription(String version) {
  final release = _cachedRelease(version);
  return release?.scheme == 'release' ? release?.variant : null;
}

String? releaseBuildHash(String version, {String? assetName}) {
  final parsed = _cachedRelease(version);
  if (parsed?.hash != null) return parsed!.hash;
  final label = normalizeVersionLabel(version);
  if (RegExp(r'^[a-f0-9]{7,40}$').hasMatch(label) &&
      RegExp(r'[a-f]').hasMatch(label)) {
    return label;
  }
  if (assetName == null || parsed?.scheme != 'release') return null;
  final filename = assetName.toLowerCase();
  if (!RegExp(r'\.(apk|apks|apkm|xapk)$').hasMatch(filename)) return null;
  if (RegExp(r'(?<![a-z0-9.])v?\d+(?:\.\d+)+').allMatches(filename).length !=
      1) {
    return null;
  }
  final candidates = releaseVersionPattern.allMatches(filename).toList();
  if (candidates.length != 1) return null;
  var candidate = candidates.single
      .group(0)!
      .replaceFirst(RegExp(r'\.(apk|apks|apkm|xapk)$'), '');
  final hashes = _hashToken.allMatches(candidate).where((match) {
    final token = match.group(0)!;
    return RegExp(r'[a-f]').hasMatch(token) &&
        (RegExp(r'\d').hasMatch(token) || token.length >= 7);
  }).toList();
  if (hashes.length != 1) return null;
  final hash = hashes.single;
  // APK names can append a packaging build number after the commit. It is
  // neither another release component nor evidence of an Android versionCode.
  final packagingBuild = RegExp(
    r'^[.-]\d+(?:\.\d+)*(?=$|[._-])',
  ).firstMatch(candidate.substring(hash.end));
  if (packagingBuild != null) {
    candidate = candidate.replaceRange(
      hash.end,
      hash.end + packagingBuild.end,
      '',
    );
  }
  // Match the whole release, including prerelease markers and any revision
  // before the hash. A hash elsewhere in a filename is not release evidence.
  if (compareVersionStrings(version, candidate).relation !=
      VersionRelation.same) {
    return null;
  }
  return hash.group(0);
}

/// Distribution identity is separate from build order. A version can be
/// newer on the device even when the source offers another distribution.
bool releaseVariantsDiffer(String installed, String latest) {
  final first = _cachedRelease(installed);
  final second = _cachedRelease(latest);
  if (first == null || second == null) return false;
  if (first.scheme != second.scheme) return true;
  if (first.variant == second.variant) return false;
  // Arbitrary suffix text does not establish incompatible APKs. Sources can
  // validate a selected artifact separately using their actual metadata.
  return first.scheme != 'release';
}

_ParsedRelease? _parseRelease(String input) {
  var text = normalizeVersionLabel(input);
  final deviceRelease = _googleDeviceRelease.firstMatch(text);
  if (deviceRelease != null) {
    return _ParsedRelease(
      [deviceRelease.group(1)!, deviceRelease.group(3)!],
      null,
      const [],
      null,
      '${deviceRelease.group(1)}.${deviceRelease.group(2)}',
      null,
      scheme: 'googleDevice',
    );
  }
  final satellite = _satelliteRelease.firstMatch(text);
  if (satellite != null) {
    return _ParsedRelease(
      [satellite.group(1)!, satellite.group(2)!, satellite.group(3)!],
      null,
      const [],
      null,
      satellite.group(4)!,
      null,
      scheme: 'satellite',
    );
  }
  final meet = _meetRelease.firstMatch(text);
  if (meet != null) {
    return _ParsedRelease(
      meet.group(1)!.split('.'),
      meet.group(2) == null ? null : 'beta',
      const [],
      [meet.group(3)!, meet.group(4)!, meet.group(5)!],
      '',
      null,
    );
  }
  final playStore = _playStoreRelease.firstMatch(text);
  if (playStore != null) {
    return _ParsedRelease(
      playStore.group(1)!.split('.'),
      null,
      const [],
      [playStore.group(2)!, playStore.group(3)!],
      '',
      null,
    );
  }
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
    return RegExp(r'[a-f]').hasMatch(token) &&
        (RegExp(r'\d').hasMatch(token) || token.length >= 7);
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
  final parenthesizedBuilds = RegExp(r'\s*\((\d+)\)').allMatches(text).toList();
  if (parenthesizedBuilds.length > 1) return null;
  if (parenthesizedBuilds.isNotEmpty) {
    final build = parenthesizedBuilds.single;
    revision = [build.group(1)!];
    text = text.replaceRange(build.start, build.end, '');
  }
  final coreMatch = _numericCore.firstMatch(text);
  if (coreMatch == null) return null;
  final core = coreMatch.group(1)!.split('.');
  var suffix = coreMatch.group(2)!.trim();
  // Only a leading numeric suffix denotes a revision. Numbers embedded in a
  // descriptive label (such as a device or architecture name) are not versions.
  final build = RegExp(r'^-(\d+(?:\.\d+)*)(?=$|[.\-_\s()])').firstMatch(suffix);
  if (build != null) {
    if (revision != null) return null;
    revision = build.group(1)!.split('.');
    suffix = suffix.substring(build.end).trim();
  }
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
  if (!_descriptiveSuffix.hasMatch(suffix) ||
      RegExp(r'(?:^|\s)v?\d+(?:\.\d+)+').hasMatch(suffix)) {
    return null;
  }
  // Recognized prerelease markers remain meaningful even when accompanied by
  // descriptive text, e.g. a channel before or after a distribution label.
  final markers = _embeddedPrerelease.allMatches(suffix).toList();
  if (markers.isNotEmpty) {
    final completeQualifier = _prerelease.firstMatch(
      suffix.substring(markers.first.start),
    );
    if (completeQualifier != null) {
      return _ParsedRelease(
        core,
        completeQualifier.group(1),
        (completeQualifier.group(2) ?? completeQualifier.group(3))?.split(
              '.',
            ) ??
            const [],
        revision,
        suffix.substring(0, markers.first.start),
        hash,
      );
    }
  }
  if (markers.length > 1) return null;
  final marker = markers.isEmpty ? null : markers.single;
  return _ParsedRelease(
    core,
    marker?.group(1),
    marker?.group(2)?.split('.') ?? const [],
    revision,
    marker == null ? suffix : suffix.replaceRange(marker.start, marker.end, ''),
    hash,
  );
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
  final distinct = labels.toSet();
  if (distinct.length < 2) return true;
  final normalized = distinct.map(normalizeVersionLabel).toSet();
  if (normalized.contains('')) return false;
  if (normalized.length == 1) return true;

  bool? dateScheme;
  bool? buildIdScheme;
  String? scheme;
  String? deviceVariant;
  final builds = <String, (String?, bool)>{};
  for (final label in normalized) {
    final isDate = _releaseDate(label) != null;
    dateScheme ??= isDate;
    if (dateScheme != isDate) return false;
    if (isDate) continue;
    final release = _cachedRelease(label);
    if (release == null) return false;
    buildIdScheme ??= release.core.length == 1;
    scheme ??= release.scheme;
    if (scheme != release.scheme) return false;
    if (release.scheme == 'googleDevice') {
      deviceVariant ??= release.core.first;
      if (compareDecimalIdentifiers(deviceVariant, release.core.first) != 0) {
        return false;
      }
      continue;
    }
    if (release.scheme != 'release') {
      deviceVariant ??= release.variant;
      if (deviceVariant != release.variant) return false;
    }
    if (buildIdScheme != (release.core.length == 1) ||
        scheme != release.scheme) {
      return false;
    }

    // Hash and revision ambiguity only matters within the same numeric release
    // and prerelease. Group equivalent components once instead of checking
    // every pair (and churning the bounded parser cache on large source lists).
    final core = release.core.map(_canonicalComponent).toList();
    while (core.length > 1 && core.last == '0') {
      core.removeLast();
    }
    final group =
        '${core.join('.')}|${release.qualifier}|'
        '${release.qualifierParts.map(_canonicalComponent).join('.')}';
    final build = (release.hash, release.revision != null);
    final previous = builds[group];
    if (previous != null &&
        (previous.$2 != build.$2 ||
            (previous.$1 != null &&
                build.$1 != null &&
                previous.$1 != build.$1))) {
      return false;
    }
    // Keep the known hash when a coarse label appears later. Otherwise it
    // could conceal a second, conflicting hash in the same release group.
    builds[group] = (previous?.$1 ?? build.$1, build.$2);
  }
  return true;
}

String _canonicalComponent(String value) {
  if (!_decimal.hasMatch(value)) return value;
  final digits = value.replaceFirst(RegExp(r'^0+'), '');
  return digits.isEmpty ? '0' : digits;
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

/// Recognized release components establish order. Descriptive labels do not.
/// Missing revisions, ambiguous titles and opaque hashes retain their meaning.
VersionDecision compareVersionStrings(
  String installed,
  String latest, {
  String? latestBuildHash,
}) {
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
  if (RegExp(r'^[a-f0-9]{7,40}$').hasMatch(first) &&
      RegExp(r'^[a-f0-9]{7,40}$').hasMatch(second) &&
      RegExp(r'[a-f]').hasMatch(first) &&
      RegExp(r'[a-f]').hasMatch(second)) {
    return const VersionDecision(
      VersionRelation.unknown,
      'differentBuildHashes',
    );
  }
  final firstRelease = _cachedRelease(first);
  final secondRelease = _cachedRelease(second);
  if (firstRelease == null || secondRelease == null) {
    return const VersionDecision(VersionRelation.unknown, 'unrecognizedFormat');
  }
  // A lone build ID and a dotted display version occupy different schemes.
  if (firstRelease.scheme != secondRelease.scheme ||
      (firstRelease.core.length == 1) != (secondRelease.core.length == 1)) {
    return const VersionDecision(VersionRelation.unknown, 'differentSchemes');
  }
  if (firstRelease.scheme == 'googleDevice') {
    if (compareDecimalIdentifiers(
          firstRelease.core.first,
          secondRelease.core.first,
        ) !=
        0) {
      return const VersionDecision(
        VersionRelation.unknown,
        'differentVariants',
      );
    }
    return _ordered(
      compareDecimalIdentifiers(
        firstRelease.core.last,
        secondRelease.core.last,
      ),
      'googleBuild',
    );
  }
  if (firstRelease.scheme != 'release' &&
      firstRelease.variant != secondRelease.variant) {
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
  final secondHash = secondRelease.hash ?? latestBuildHash;
  if (firstRelease.hash != null &&
      secondHash != null &&
      firstRelease.hash != secondHash) {
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
  return VersionDecision(
    VersionRelation.same,
    firstRelease.hash != null && secondHash != null
        ? 'sameBuildHash'
        : 'sameRelease',
  );
}
