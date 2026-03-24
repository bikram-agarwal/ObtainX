/// Centralised definitions for installable Android package file extensions.
///
/// All app sources and the download pipeline use these helpers instead of
/// scattering literal extension strings throughout the codebase.
library;

// Bare extension strings (no leading dot).
const kApkExt = 'apk';
const kXapkExt = 'xapk';
const kObbExt = 'obb';
const kZipExt = 'zip';

bool _ends(String path, String ext) =>
    path.toLowerCase().endsWith('.$ext');

/// Path ends with `.apk`.
bool isApk(String path) => _ends(path, kApkExt);

/// Path ends with `.xapk`.
bool isXapk(String path) => _ends(path, kXapkExt);

/// Path ends with `.obb`.
bool isObb(String path) => _ends(path, kObbExt);

/// Path ends with `.zip`.
bool isZip(String path) => _ends(path, kZipExt);

/// Path ends with `.apk` or `.xapk` (optionally `.zip`).
bool isInstallable(String path, {bool includeZips = false}) =>
    isApk(path) || isXapk(path) || (includeZips && isZip(path));

/// Same as [isInstallable] but operates on a bare extension string
/// (no leading dot), as returned by e.g. `filename.split('.').last`.
bool isInstallableExt(String ext, {bool includeZips = false}) {
  final lower = ext.toLowerCase();
  return lower == kApkExt ||
      lower == kXapkExt ||
      (includeZips && lower == kZipExt);
}
