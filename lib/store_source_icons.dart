import 'package:flutter/material.dart';

/// Local PNG paths for store branding (list badges, app page source rows).
class StoreSourceIconPaths {
  StoreSourceIconPaths._();

  static const String playStore = 'assets/graphics/ic_playstore.png';
  static const String fdroid = 'assets/graphics/ic_fdroid.png';
  static const String apkmirror = 'assets/graphics/ic_apkmirror.png';
  static const String apkpure = 'assets/graphics/ic_apkpure.png';
  static const String github = 'assets/graphics/ic_github.png';
}

/// Maps a source [host] (e.g. from [SourceProvider]) to a bundled icon, or null.
String? storeSourceAssetPathForHost(String host) {
  final String normalized = host.toLowerCase();
  if (normalized.contains('play.google.com')) {
    return StoreSourceIconPaths.playStore;
  }
  if (normalized.contains('f-droid.org')) {
    return StoreSourceIconPaths.fdroid;
  }
  if (normalized.contains('apkmirror.com')) {
    return StoreSourceIconPaths.apkmirror;
  }
  if (normalized.contains('apkpure.')) {
    return StoreSourceIconPaths.apkpure;
  }
  if (normalized.contains('github.com')) {
    return StoreSourceIconPaths.github;
  }
  return null;
}

/// Maps a full [url] (tracked source, etc.) to the same bundled icon, or null.
String? storeSourceAssetPathForUrl(String url) {
  final Uri? uri = Uri.tryParse(url);
  if (uri == null || uri.host.isEmpty) return null;
  return storeSourceAssetPathForHost(uri.host);
}

/// Square clip; wide assets (Play wordmark) use [BoxFit.cover] with a leading
/// alignment so the triangle reads instead of shrinking the whole bar.
class StoreSourceIconImage extends StatelessWidget {
  const StoreSourceIconImage({
    super.key,
    required this.assetPath,
    required this.size,
    this.errorBuilder,
  });

  final String assetPath;
  final double size;
  final ImageErrorWidgetBuilder? errorBuilder;

  static Alignment _cropAlignmentFor(String path) {
    if (path == StoreSourceIconPaths.playStore) {
      return Alignment.centerLeft;
    }
    return Alignment.center;
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.22),
      child: SizedBox(
        width: size,
        height: size,
        child: Image.asset(
          assetPath,
          fit: BoxFit.cover,
          alignment: _cropAlignmentFor(assetPath),
          gaplessPlayback: true,
          errorBuilder: errorBuilder ??
              (BuildContext context, Object error, StackTrace? stackTrace) {
                if (size <= 20) {
                  return const SizedBox.shrink();
                }
                return Icon(
                  Icons.link,
                  size: size * 0.72,
                  color: Theme.of(context).colorScheme.primary,
                );
              },
        ),
      ),
    );
  }
}

/// Small source favicon badge overlaid on the app icon (Apps list, bulk import results).
/// Matches host-based assets and DuckDuckGo favicon fallback used on the Apps tab.
class StoreSourceListBadge extends StatelessWidget {
  const StoreSourceListBadge({super.key, required this.host});

  final String host;

  @override
  Widget build(BuildContext context) {
    if (host.isEmpty) return const SizedBox.shrink();

    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    final String? localAsset = storeSourceAssetPathForHost(host);
    Widget image;
    if (localAsset != null) {
      image = StoreSourceIconImage(assetPath: localAsset, size: 13);
      if (isDark && localAsset == StoreSourceIconPaths.github) {
        image = ColorFiltered(
          colorFilter: const ColorFilter.matrix([
            -1, 0, 0, 0, 255,
            0, -1, 0, 0, 255,
            0, 0, -1, 0, 255,
            0, 0, 0, 1, 0,
          ]),
          child: image,
        );
      }
    } else {
      image = Image.network(
        'https://icons.duckduckgo.com/ip3/$host.ico',
        width: 13,
        height: 13,
        fit: BoxFit.contain,
        errorBuilder: (context, error, stackTrace) => const SizedBox.shrink(),
        loadingBuilder: (context, child, loadingProgress) =>
            loadingProgress == null ? child : const SizedBox.shrink(),
      );
      if (isDark && host == 'github.com') {
        image = ColorFiltered(
          colorFilter: const ColorFilter.matrix([
            -1, 0, 0, 0, 255,
            0, -1, 0, 0, 255,
            0, 0, -1, 0, 255,
            0, 0, 0, 1, 0,
          ]),
          child: image,
        );
      }
    }
    return Container(
      width: 16,
      height: 16,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(4),
      ),
      padding: const EdgeInsets.all(1.5),
      child: image,
    );
  }
}
