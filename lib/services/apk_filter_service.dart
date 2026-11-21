// APK file detection, filtering, and architecture selection.

import 'dart:async';

import 'package:device_info_plus/device_info_plus.dart';

// ========================================================================
// ApkFilterService — APK file detection, filtering, and arch-splitting.
// ========================================================================

class ApkFilterService {
  static const List<String> apkContainerExtensions = [
    '.apk',
    '.xapk',
    '.apkm',
    '.apks',
  ];

  static const List<String> archiveExtensions = ['.zip'];

  static const List<String> tarballExtensions = [
    '.tar.gz',
    '.tgz',
    '.tar.bz2',
    '.tar.xz',
  ];

  static bool isApkOrContainerFile(
    String name, {
    bool includeArchives = false,
    bool includeTarballs = false,
  }) {
    final lower = name.toLowerCase();
    bool endsWithAny(List<String> exts) => exts.any(lower.endsWith);
    return endsWithAny(apkContainerExtensions) ||
        (includeArchives && endsWithAny(archiveExtensions)) ||
        (includeTarballs && endsWithAny(tarballExtensions));
  }

  /// Separates the URLs of a split APK set stored in a single `apkUrls` value
  /// (base first, splits after). A newline cannot appear in a legal URL, so it
  /// cannot collide with real URLs.
  static const String multiApkUrlSeparator = '\n';

  static List<String> splitMultiApkUrl(String value) {
    if (value.isEmpty) return [];
    return value.contains(multiApkUrlSeparator)
        ? value.split(multiApkUrlSeparator).where((e) => e.isNotEmpty).toList()
        : [value];
  }

  static String joinMultiApkUrl(Iterable<String> urls) =>
      urls.join(multiApkUrlSeparator);

  List<MapEntry<String, String>> getApkUrlsFromUrls(List<String> urls) =>
      urls.map((e) {
        final segments = e.split('/').where((el) => el.trim().isNotEmpty);
        final apkSegs = segments.where((s) => isApkOrContainerFile(s));
        return MapEntry(apkSegs.isNotEmpty ? apkSegs.last : segments.last, e);
      }).toList();

  /// Keeps the APKs [apkFilterRegEx] matches (or, with [invert], those it
  /// doesn't). It's matched against the APK's name, and also its link URL
  /// when [matchUrl] is set (see [AppSource.apkFilterMatchesLinkUrl]).
  List<MapEntry<String, String>> filterApks(
    List<MapEntry<String, String>> apkUrls,
    String? apkFilterRegEx,
    bool? invert, {
    bool matchUrl = false,
  }) {
    if (apkFilterRegEx?.isNotEmpty == true) {
      final reg = RegExp(apkFilterRegEx!);
      apkUrls = apkUrls.where((element) {
        final hasMatch =
            reg.hasMatch(element.key) ||
            (matchUrl && reg.hasMatch(element.value));
        return invert == true ? !hasMatch : hasMatch;
      }).toList();
    }
    return apkUrls;
  }

  /// Non-canonical ABI names commonly used in APK filenames, mapped to the
  /// canonical device ABI strings they correspond to (see #3249).
  static const Map<String, List<String>> abiNameAliases = {
    'arm64-v8a': ['aarch64', 'arm64'],
    'armeabi-v7a': ['armv7', 'armeabi'],
    'x86_64': ['x64'],
  };

  static RegExp _abiRegex(String abi) {
    final variants = [abi, ...?abiNameAliases[abi]];
    return RegExp('.*(?:${variants.join('|')}).*', caseSensitive: false);
  }

  /// The fork matches an ABI on the asset name OR its URL (some stores put
  /// the ABI only in the URL).
  static bool _matchesAbi(MapEntry<String, String> apk, RegExp abiRegex) =>
      abiRegex.hasMatch(apk.key) || abiRegex.hasMatch(apk.value);

  /// Whether [apkName] (an asset name, not a URL) names a universal APK.
  /// Only the name counts, so a host or path containing "universal" doesn't
  /// make every APK of a source look universal.
  static bool isUniversalApkName(String apkName) =>
      apkName.toLowerCase().contains('universal');

  /// Keeps the APKs matching the device's first matched ABI. Universal APKs
  /// (upstream #3349) stay too, as alternatives placed **first**, so the
  /// ABI-specific match stays last and remains the default selection.
  Future<List<MapEntry<String, String>>> filterApksByArch(
    List<MapEntry<String, String>> apkUrls,
    List<String> abis, {
    bool preferSplits = true,
  }) async {
    if (apkUrls.length > 1) {
      for (var abi in abis) {
        final RegExp architecturePattern = _abiRegex(abi);
        final urls2 = apkUrls
            .where((element) => _matchesAbi(element, architecturePattern))
            .toList();
        if (urls2.isNotEmpty && urls2.length < apkUrls.length) {
          final universal = apkUrls.where(
            (element) =>
                isUniversalApkName(element.key) &&
                !urls2.any((match) => match.value == element.value),
          );
          apkUrls = [...universal, ...urls2];
          break;
        }
      }
    }
    return apkUrls;
  }

  /// Upstream #3473: a saved choice that points at a universal APK resolves
  /// to the first APK matching the device's ABIs, so the arch filter keeps
  /// installing the specific build. Any other choice is kept.
  int preferredApkIndexForArchFilter(
    List<MapEntry<String, String>> apkUrls,
    int preferredIndex,
    List<String> abis,
  ) {
    if (preferredIndex < 0 || preferredIndex >= apkUrls.length) {
      return preferredIndex;
    }
    final MapEntry<String, String> preferred = apkUrls[preferredIndex];
    if (abis.any((abi) => _matchesAbi(preferred, _abiRegex(abi)))) {
      return preferredIndex;
    }
    if (!isUniversalApkName(preferred.key)) {
      return preferredIndex;
    }
    for (final abi in abis) {
      final abiRegex = _abiRegex(abi);
      final index = apkUrls.indexWhere((e) => _matchesAbi(e, abiRegex));
      if (index >= 0) return index;
    }
    return preferredIndex;
  }

  /// Whether every APK other than [apkUrls]'s ABI-specific ones is a
  /// universal alternative, i.e. the choice between them is one the user
  /// needn't be asked about (v1.7.4 sync, D12 C: no picker for that alone).
  static bool onlyUniversalAlternatives(
    List<MapEntry<String, String>> apkUrls,
  ) {
    final nonUniversal = apkUrls
        .where((apk) => !isUniversalApkName(apk.key))
        .toList();
    return nonUniversal.length == 1 && apkUrls.length > 1;
  }

  static int _leadingUniversalCount(List<MapEntry<String, String>> apkUrls) =>
      apkUrls.takeWhile((apk) => isUniversalApkName(apk.key)).length;

  /// Carries a stored APK choice from [previousApkUrls] to the newly fetched,
  /// arch-filtered [apkUrls].
  ///
  /// The choice is stored as a position, and [filterApksByArch] puts universal
  /// APKs first (D12 C). So when the number of leading universal APKs changes
  /// (the first check after the v1.7.4 sync, whose earlier lists held only the
  /// ABI builds, or a release that adds or drops a universal asset), a choice
  /// past them is shifted by the difference, keeping the same build or
  /// flavour. A choice of a universal APK is left for
  /// [preferredApkIndexForArchFilter], which resolves it to the ABI build.
  static int carryPreferredApkIndex(
    int storedIndex,
    List<MapEntry<String, String>> previousApkUrls,
    List<MapEntry<String, String>> apkUrls,
  ) {
    final int previousLead = _leadingUniversalCount(previousApkUrls);
    if (storedIndex < previousLead) return storedIndex;
    return storedIndex + _leadingUniversalCount(apkUrls) - previousLead;
  }
}

/// Delegates to [ApkFilterService.getApkUrlsFromUrls].
List<MapEntry<String, String>> getApkUrlsFromUrls(List<String> urls) =>
    ApkFilterService().getApkUrlsFromUrls(urls);

/// Delegates to [ApkFilterService.splitMultiApkUrl].
List<String> splitMultiApkUrl(String value) =>
    ApkFilterService.splitMultiApkUrl(value);

/// Delegates to [ApkFilterService.joinMultiApkUrl].
String joinMultiApkUrl(Iterable<String> urls) =>
    ApkFilterService.joinMultiApkUrl(urls);

/// Delegates to [ApkFilterService.filterApksByArch].
Future<List<MapEntry<String, String>>> filterApksByArch(
  List<MapEntry<String, String>> apkUrls,
) async {
  final abis = (await DeviceInfoPlugin().androidInfo).supportedAbis;
  return ApkFilterService().filterApksByArch(apkUrls, abis);
}

/// Delegates to [ApkFilterService.preferredApkIndexForArchFilter] with the
/// device's ABIs.
Future<int> resolvePreferredApkIndexForArchFilter(
  List<MapEntry<String, String>> apkUrls,
  int preferredIndex,
) async {
  final abis = (await DeviceInfoPlugin().androidInfo).supportedAbis;
  return ApkFilterService().preferredApkIndexForArchFilter(
    apkUrls,
    preferredIndex,
    abis,
  );
}

/// Delegates to [ApkFilterService.filterApks].
List<MapEntry<String, String>> filterApks(
  List<MapEntry<String, String>> apkUrls,
  String? apkFilterRegEx,
  bool? invert, {
  bool matchUrl = false,
}) => ApkFilterService().filterApks(
  apkUrls,
  apkFilterRegEx,
  invert,
  matchUrl: matchUrl,
);
