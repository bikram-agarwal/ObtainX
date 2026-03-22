import 'package:flutter/material.dart';

/// Local PNG paths for store branding (list badges, app page source rows).
class StoreSourceIconPaths {
  StoreSourceIconPaths._();

  static const String playStore = 'assets/graphics/ic_playstore.png';
  static const String fdroid = 'assets/graphics/ic_fdroid.png';
  static const String apkmirror = 'assets/graphics/ic_apkmirror.png';
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
