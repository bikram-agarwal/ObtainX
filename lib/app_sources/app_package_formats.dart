/// Centralised definitions for installable Android package file extensions.
///
/// All app sources and the download pipeline use these helpers instead of
/// scattering literal extension strings throughout the codebase.
library;

// Bare extension strings (no leading dot).
const kApkExt = 'apk';
const kXapkExt = 'xapk';
const kApkmExt = 'apkm';
const kApksExt = 'apks';
const kObbExt = 'obb';
const kZipExt = 'zip';

/// Multi-part tarball suffixes. Matched against the full path because
/// `split('.').last` cannot capture e.g. `.tar.gz`.
const kTarballSuffixes = ['.tar.gz', '.tgz', '.tar.bz2', '.tar.xz'];

bool _ends(String path, String ext) => path.toLowerCase().endsWith('.$ext');

/// Path ends with `.apk`.
bool isApk(String path) => _ends(path, kApkExt);

/// Path ends with `.xapk`.
bool isXapk(String path) => _ends(path, kXapkExt);

/// Path ends with `.apkm` (APKMirror multi-APK bundle — a ZIP variant).
bool isApkm(String path) => _ends(path, kApkmExt);

/// Path ends with `.apks` (split-APKs bundle — a ZIP variant).
bool isApks(String path) => _ends(path, kApksExt);

/// Path ends with `.obb`.
bool isObb(String path) => _ends(path, kObbExt);

/// Path ends with `.zip`.
bool isZip(String path) => _ends(path, kZipExt);

/// Path ends with a tarball suffix (`.tar.gz`/`.tgz`/`.tar.bz2`/`.tar.xz`).
bool isTarball(String path) {
  final lower = path.toLowerCase();
  return kTarballSuffixes.any(lower.endsWith);
}

/// Whether [path] is an installable APK container: `.apk`/`.xapk`/`.apkm`/`.apks`,
/// optionally a `.zip` ([includeZips]) or a tarball ([includeTarballs]).
bool isInstallable(
  String path, {
  bool includeZips = false,
  bool includeTarballs = false,
}) =>
    isApk(path) ||
    isXapk(path) ||
    isApkm(path) ||
    isApks(path) ||
    (includeZips && isZip(path)) ||
    (includeTarballs && isTarball(path));

/// Same as [isInstallable] but operates on a bare extension string
/// (no leading dot), as returned by e.g. `filename.split('.').last`.
///
/// NOTE: cannot detect multi-part tarball suffixes like `.tar.gz` — call
/// [isInstallable] on the full path when tarball support is needed.
bool isInstallableExt(String ext, {bool includeZips = false}) {
  final lower = ext.toLowerCase();
  return lower == kApkExt ||
      lower == kXapkExt ||
      lower == kApkmExt ||
      lower == kApksExt ||
      (includeZips && lower == kZipExt);
}
