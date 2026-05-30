import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:obtainium/favicon_cache.dart';

/// Inversion filter: swaps black ↔ white while preserving alpha.
const ColorFilter invertColorFilter = ColorFilter.matrix([
  -1,
  0,
  0,
  0,
  255,
  0,
  -1,
  0,
  0,
  255,
  0,
  0,
  -1,
  0,
  255,
  0,
  0,
  0,
  1,
  0,
]);

/// Returns true if [assetPath]'s icon should be colour-inverted for the current
/// brightness. GitHub ships a black mark (needs inversion in dark mode);
/// APKMirror ships a white mark (needs inversion in light mode).
bool iconNeedsInversion(String assetPath, bool isDark) {
  if (assetPath == StoreSourceIconPaths.github && isDark) return true;
  if (assetPath == StoreSourceIconPaths.apkmirror && !isDark) return true;
  return false;
}

/// Logo widget for store chips: bundled asset for known hosts, favicon for others.
/// Suitable as a [FilterChip] avatar — transparent background, no container border.
class StoreSourceChipAvatar extends StatefulWidget {
  const StoreSourceChipAvatar({super.key, required this.host, this.size = 18});

  final String host;
  final double size;

  @override
  State<StoreSourceChipAvatar> createState() => _StoreSourceChipAvatarState();
}

class _StoreSourceChipAvatarState extends State<StoreSourceChipAvatar> {
  Future<Uint8List?>? _iconFuture;

  @override
  void initState() {
    super.initState();
    if (widget.host.isNotEmpty &&
        storeSourceAssetPathForHost(widget.host) == null) {
      _iconFuture = FaviconCache.get(widget.host);
    }
  }

  @override
  void didUpdateWidget(StoreSourceChipAvatar old) {
    super.didUpdateWidget(old);
    if (old.host != widget.host &&
        widget.host.isNotEmpty &&
        storeSourceAssetPathForHost(widget.host) == null) {
      setState(() => _iconFuture = FaviconCache.get(widget.host));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.host.isEmpty) {
      return SizedBox(width: widget.size, height: widget.size);
    }

    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    final String? localAsset = storeSourceAssetPathForHost(widget.host);
    if (localAsset != null) {
      Widget img = StoreSourceIconImage(
        assetPath: localAsset,
        size: widget.size,
      );
      if (iconNeedsInversion(localAsset, isDark)) {
        img = ColorFiltered(colorFilter: invertColorFilter, child: img);
      }
      return img;
    }

    return FutureBuilder<Uint8List?>(
      future: _iconFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done ||
            snapshot.data == null) {
          return SizedBox(width: widget.size, height: widget.size);
        }
        final int cachePx =
            (widget.size * MediaQuery.devicePixelRatioOf(context)).round();
        return Image.memory(
          snapshot.data!,
          width: widget.size,
          height: widget.size,
          fit: BoxFit.contain,
          gaplessPlayback: true,
          cacheWidth: cachePx,
          cacheHeight: cachePx,
        );
      },
    );
  }
}

/// Local PNG paths for store branding (list badges, app page source rows).
class StoreSourceIconPaths {
  StoreSourceIconPaths._();

  static const String playStore = 'assets/graphics/ic_playstore.png';
  static const String fdroid = 'assets/graphics/ic_fdroid.png';
  static const String apkmirror = 'assets/graphics/ic_apkmirror.png';
  static const String apkpure = 'assets/graphics/ic_apkpure.png';
  static const String github = 'assets/graphics/ic_github.png';

  /// IzzyOnDroid logo from https://codeberg.org/IzzyOnDroid/assets (IzzyOnDroidLogo.png).
  static const String izzydroid = 'assets/graphics/ic_izzydroid.png';
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
  if (normalized.contains('izzysoft.de')) {
    return StoreSourceIconPaths.izzydroid;
  }
  return null;
}

/// Maps a full [url] (tracked source, etc.) to the same bundled icon, or null.
String? storeSourceAssetPathForUrl(String url) {
  final Uri? uri = Uri.tryParse(url);
  if (uri == null || uri.host.isEmpty) return null;
  return storeSourceAssetPathForHost(uri.host);
}

/// Maps an [AppSource] runtimeType class name to a bundled icon path, or null.
/// Use [storeSourceAssetPathForHost] when a URL or host is available instead.
String? storeSourceAssetPathForClassName(String className) {
  switch (className) {
    case 'GitHub':
      return StoreSourceIconPaths.github;
    case 'FDroid':
      return StoreSourceIconPaths.fdroid;
    case 'APKMirror':
      return StoreSourceIconPaths.apkmirror;
    case 'APKPure':
      return StoreSourceIconPaths.apkpure;
    case 'IzzyOnDroid':
      return StoreSourceIconPaths.izzydroid;
    default:
      return null;
  }
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
          errorBuilder:
              errorBuilder ??
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

/// Icon for a tracked source URL: bundled asset for known hosts, favicon from
/// cache for unknown hosts, [Icons.link] if neither resolves.
class StoreSourceIconForUrl extends StatefulWidget {
  const StoreSourceIconForUrl({
    super.key,
    required this.url,
    required this.size,
  });

  final String url;
  final double size;

  @override
  State<StoreSourceIconForUrl> createState() => _StoreSourceIconForUrlState();
}

class _StoreSourceIconForUrlState extends State<StoreSourceIconForUrl> {
  Future<Uint8List?>? _iconFuture;
  late final String _host;

  @override
  void initState() {
    super.initState();
    _host = Uri.tryParse(widget.url)?.host ?? '';
    if (_host.isNotEmpty && storeSourceAssetPathForHost(_host) == null) {
      _iconFuture = FaviconCache.get(_host);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    final String? localAsset = storeSourceAssetPathForHost(_host);
    if (localAsset != null) {
      Widget img = StoreSourceIconImage(
        assetPath: localAsset,
        size: widget.size,
      );
      if (iconNeedsInversion(localAsset, isDark)) {
        img = ColorFiltered(colorFilter: invertColorFilter, child: img);
      }
      return img;
    }
    return FutureBuilder<Uint8List?>(
      future: _iconFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.done &&
            snapshot.data != null) {
          final int cachePx =
              (widget.size * MediaQuery.devicePixelRatioOf(context)).round();
          return Image.memory(
            snapshot.data!,
            width: widget.size,
            height: widget.size,
            fit: BoxFit.contain,
            gaplessPlayback: true,
            cacheWidth: cachePx,
            cacheHeight: cachePx,
          );
        }
        return Icon(
          Icons.link,
          size: widget.size * 0.75,
          color: Theme.of(context).colorScheme.primary,
        );
      },
    );
  }
}

/// Small source favicon badge overlaid on the app icon (Apps list, bulk import results).
/// Known hosts use bundled assets; unknown hosts use a persistent disk-cached
/// DuckDuckGo favicon so the network is only hit once per host.
class StoreSourceListBadge extends StatefulWidget {
  const StoreSourceListBadge({super.key, required this.host});

  final String host;

  @override
  State<StoreSourceListBadge> createState() => _StoreSourceListBadgeState();
}

class _StoreSourceListBadgeState extends State<StoreSourceListBadge> {
  Future<Uint8List?>? _iconFuture;

  @override
  void initState() {
    super.initState();
    if (widget.host.isNotEmpty &&
        storeSourceAssetPathForHost(widget.host) == null) {
      _iconFuture = FaviconCache.get(widget.host);
    }
  }

  @override
  void didUpdateWidget(StoreSourceListBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.host != widget.host &&
        widget.host.isNotEmpty &&
        storeSourceAssetPathForHost(widget.host) == null) {
      _iconFuture = FaviconCache.get(widget.host);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.host.isEmpty) return const SizedBox.shrink();

    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    final String? localAsset = storeSourceAssetPathForHost(widget.host);

    Widget image;
    if (localAsset != null) {
      image = StoreSourceIconImage(assetPath: localAsset, size: 13);
      if (iconNeedsInversion(localAsset, isDark)) {
        image = ColorFiltered(colorFilter: invertColorFilter, child: image);
      }
    } else {
      image = FutureBuilder<Uint8List?>(
        future: _iconFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done ||
              snapshot.data == null) {
            return const SizedBox.shrink();
          }
          final int cachePx = (13 * MediaQuery.devicePixelRatioOf(context))
              .round();
          return Image.memory(
            snapshot.data!,
            width: 13,
            height: 13,
            fit: BoxFit.contain,
            gaplessPlayback: true,
            cacheWidth: cachePx,
            cacheHeight: cachePx,
          );
        },
      );
    }

    return SizedBox(
      width: 16,
      height: 16,
      child: Padding(padding: const EdgeInsets.all(1.5), child: image),
    );
  }
}
