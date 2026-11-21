import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:obtainium/components/custom_app_bar.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/widgets/app_toast.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher_string.dart';

Future<void> copyToClipboard(BuildContext context, String text) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (context.mounted) {
    ScaffoldMessenger.of(context)
        .showSnackBar(buildAppSnackBar(context, tr('copiedToClipboard')));
  }
}

/// [child], a button or switch that's off, still answering a tap with a
/// warning that says why ([reason]), as Settings' switches do. With a null
/// [reason] it's on, and taps go to [child] alone.
///
/// Works because a control that's off claims no taps, so this one gets them.
///
/// Set [scaffoldHasBottomBar] on a page whose Scaffold has its own bottom bar,
/// as for [buildAppSnackBar]; without it the warning floats far above that bar.
class ExplainedWhenOff extends StatelessWidget {
  const ExplainedWhenOff({
    super.key,
    required this.reason,
    required this.child,
    this.scaffoldHasBottomBar = false,
  });

  final String? reason;
  final Widget child;
  final bool scaffoldHasBottomBar;

  @override
  Widget build(BuildContext context) {
    final String? why = reason;
    if (why == null) return child;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          buildAppSnackBar(
            context,
            why,
            type: ToastType.warning,
            scaffoldHasBottomBar: scaffoldHasBottomBar,
          ),
        ),
      child: child,
    );
  }
}

/// A Material switch that supplies the platform tap feedback omitted by
/// Flutter's stock [Switch]. On Android this respects the system's touch-sound
/// setting and plays the same click as buttons and tappable list rows.
///
/// Pass [semanticLabel] when the switch sits next to its label instead of
/// inside a [SwitchListTile] (which merges its title in): TalkBack otherwise
/// announces a bare "switch" with no name (upstream #3398).
class AppSwitch extends StatelessWidget {
  const AppSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.semanticLabel,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final ValueChanged<bool>? handler = onChanged == null
        ? null
        : (bool newValue) {
            unawaited(Feedback.forTap(context));
            onChanged!(newValue);
          };
    final Widget control = Switch(value: value, onChanged: handler);
    final String? label = semanticLabel;
    if (label == null) return control;
    // One labelled node; its tap action goes through [handler], so a
    // TalkBack double-tap gets the same feedback as a finger tap.
    return Semantics(
      container: true,
      label: label,
      toggled: value,
      enabled: handler != null,
      excludeSemantics: true,
      onTap: handler == null ? null : () => handler(!value),
      child: control,
    );
  }
}

/// A [SwitchListTile] with exactly one platform click whether the user taps
/// the row or the switch itself. The stock tile only supplies feedback for its
/// row gesture because [Switch] does not call [Feedback.forTap].
class AppSwitchListTile extends StatelessWidget {
  const AppSwitchListTile({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    this.contentPadding,
    this.visualDensity,
  });

  final Widget title;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final EdgeInsetsGeometry? contentPadding;
  final VisualDensity? visualDensity;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      title: title,
      value: value,
      onChanged: onChanged == null
          ? null
          : (bool newValue) {
              unawaited(Feedback.forTap(context));
              onChanged!(newValue);
            },
      contentPadding: contentPadding,
      visualDensity: visualDensity,
      // The wrapper callback supplies feedback for both activation paths.
      // Leaving ListTile feedback enabled would double-play on row taps.
      enableFeedback: false,
    );
  }
}

Future<bool> showConfirmDialog(
  BuildContext context, {
  required String title,
  Widget? content,
  String? confirmText,
  String? cancelText,
  bool autofocusConfirm = false,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: content,
      actions: [
        TextButton(
          // On TV, focus the safe option unless the caller asked for the
          // confirm button: an unfocused dialog would let remote input fall
          // through to the page behind it.
          autofocus: !autofocusConfirm && context.read<SettingsProvider>().isTV,
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(cancelText ?? tr('no')),
        ),
        FilledButton(
          autofocus: autofocusConfirm,
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(confirmText ?? tr('yes')),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}

// showMessage / showError intentionally live ONLY in custom_errors.dart (the
// themed versions, with a SnackBar duration and a dialog Theme wrapper).
// Callers that need them should import custom_errors.dart directly; a local
// copy here previously shadowed those and silently dropped dialog theming.

class AppIcon extends StatelessWidget {
  final Uint8List? bytes;
  final double size;
  final double radius;

  final double glyphSize;

  final bool dimmed;

  const AppIcon({
    super.key,
    required this.bytes,
    required this.size,
    this.radius = 12,
    this.glyphSize = 24,
    this.dimmed = false,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
    final cacheDim = (size * devicePixelRatio).round();
    return ClipRSuperellipse(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        width: size,
        height: size,
        child: bytes != null
            ? Image.memory(
                bytes!,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                excludeFromSemantics: true,
                cacheWidth: cacheDim,
                cacheHeight: cacheDim,
                opacity: dimmed ? const AlwaysStoppedAnimation(0.6) : null,
              )
            : ColoredBox(
                color: colorScheme.surfaceContainerHighest,
                child: Center(
                  child: Image(
                    image: const AssetImage('assets/graphics/icon_small.png'),
                    color: Theme.of(context).brightness == Brightness.dark
                        ? Colors.white.withValues(alpha: 0.5)
                        : Colors.white.withValues(alpha: 0.4),
                    colorBlendMode: BlendMode.modulate,
                    gaplessPlayback: true,
                    excludeFromSemantics: true,
                    width: glyphSize,
                    height: glyphSize,
                  ),
                ),
              ),
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  final IconData icon;
  final String? message;

  const EmptyState({super.key, required this.icon, this.message});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ExcludeSemantics(
              child: Icon(
                icon,
                size: 56,
                color: colorScheme.onSurfaceVariant,
                // The message is rendered below (announced once by the Text).
                semanticLabel: message,
              ),
            ),
            if (message != null) ...[
              const SizedBox(height: 16),
              Text(
                message!,
                style: Theme.of(context).textTheme.headlineSmall
                    ?.copyWith(color: colorScheme.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Compact "X" button used to cancel an in-progress download.
class DownloadCancelButton extends StatelessWidget {
  final VoidCallback onPressed;

  const DownloadCancelButton({super.key, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.close),
      iconSize: 20,
      visualDensity: VisualDensity.compact,
      tooltip: tr('cancel'),
      onPressed: () {
        context.read<SettingsProvider>().lightImpact();
        onPressed();
      },
    );
  }
}

class LinkText extends StatelessWidget {
  final String text;
  final String url;
  final TextStyle? style;

  const LinkText({
    super.key,
    required this.text,
    required this.url,
    this.style,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      link: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: () => unawaited(
          launchUrlString(url, mode: LaunchMode.externalApplication),
        ),
        child: Text(
          text,
          style: (style ?? const TextStyle()).copyWith(
            decoration: TextDecoration.underline,
          ),
        ),
      ),
    );
  }
}

class ActionListTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool autoPop;
  final BorderRadius? borderRadius;
  final Color? iconColor;
  final Color? textColor;

  const ActionListTile({
    super.key,
    required this.icon,
    required this.label,
    this.trailing,
    this.onTap,
    this.autoPop = false,
    this.borderRadius,
    this.iconColor,
    this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: iconColor),
      title: Text(
        label,
        style: textColor != null ? TextStyle(color: textColor) : null,
      ),
      trailing: trailing,
      enabled: onTap != null,
      shape: borderRadius != null
          ? RoundedRectangleBorder(borderRadius: borderRadius!)
          : null,
      onTap: onTap == null
          ? null
          : () {
              if (autoPop) Navigator.of(context).pop();
              onTap?.call();
            },
    );
  }
}

/// Whether this is a TV, for the TV focus helpers below. A subtree without a
/// [SettingsProvider] (a widget test, say) counts as not a TV.
bool _isTV(BuildContext context, {required bool listen}) {
  try {
    return listen
        ? context.select<SettingsProvider, bool>((p) => p.isTV)
        : context.read<SettingsProvider>().isTV;
  } on ProviderNotFoundException {
    return false;
  }
}

/// Draws a high-contrast ring around [child] while focus is anywhere inside
/// it, on TV only (v1.7.4 sync D23, ported from upstream).
///
/// Material's focus overlay is built for a mouse or keyboard and is barely
/// visible from a sofa; on a TV the focus position is the only cursor. Does
/// nothing on other devices.
class TvFocusRing extends StatefulWidget {
  const TvFocusRing({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(16)),
    this.width = 3,
    this.color,
  });

  final Widget child;
  final BorderRadiusGeometry borderRadius;
  final double width;
  final Color? color;

  @override
  State<TvFocusRing> createState() => _TvFocusRingState();
}

class _TvFocusRingState extends State<TvFocusRing> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    if (!_isTV(context, listen: true)) return widget.child;
    final Color color = widget.color ?? Theme.of(context).colorScheme.primary;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      includeSemantics: false,
      onFocusChange: (bool focused) {
        if (focused != _focused) setState(() => _focused = focused);
      },
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          border: _focused
              ? Border.all(color: color, width: widget.width)
              : null,
          borderRadius: widget.borderRadius,
        ),
        child: widget.child,
      ),
    );
  }
}

/// On TV, gives each newly opened dialog, bottom sheet or popup a focused
/// control when it opens without one (v1.7.4 sync D23).
///
/// Unfocused, the remote's first SELECT does nothing. The first control in
/// reading order gets focus; dialogs list their actions safe option first
/// (Cancel before the confirming button), so a confirmation opens on Cancel.
/// A dialog that autofocuses something itself is left alone.
class TvPopupFocusObserver extends NavigatorObserver {
  TvPopupFocusObserver(this.isTV);

  final bool Function() isTV;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is! PopupRoute || !isTV()) return;
    // After the first frame builds the route, and one microtask later: the
    // focus manager applies a pending autofocus in a microtask queued during
    // that frame, which then runs first.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      scheduleMicrotask(() {
        // The route's own focus scope, found through its content (the scope
        // node itself isn't public). Something focused in it already (an
        // autofocus) wins.
        final BuildContext? content = route.subtreeContext;
        if (!route.isActive || content == null) return;
        final FocusScopeNode scope = FocusScope.of(content);
        if (scope.focusedChild != null) return;
        final FocusTraversalPolicy policy =
            FocusTraversalGroup.maybeOf(content) ??
            ReadingOrderTraversalPolicy();
        policy.findFirstFocus(scope, ignoreCurrentFocus: true)?.requestFocus();
      });
    });
  }
}

/// On TV, focuses the first control below the app bar once [child] is shown,
/// unless something there already has focus (v1.7.4 sync D23, ported from
/// upstream).
///
/// Without it a new page or sheet opens unfocused, so the first SELECT does
/// nothing until a direction key is pressed. Arrow-up still reaches the app
/// bar.
class TvInitialFocus extends StatefulWidget {
  const TvInitialFocus({super.key, required this.child});

  final Widget child;

  @override
  State<TvInitialFocus> createState() => _TvInitialFocusState();
}

class _TvInitialFocusState extends State<TvInitialFocus> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_isTV(context, listen: false)) return;
      final FocusScopeNode scope = FocusScope.of(context);
      if (scope.hasFocus) return;
      final FocusTraversalPolicy? policy = FocusTraversalGroup.maybeOf(context);
      if (policy == null) return;
      FocusNode? first = policy.findFirstFocus(scope, ignoreCurrentFocus: true);
      // Skip leading app-bar buttons (Back, say) so the first content
      // control gets the ring.
      for (int i = 0; i < 4 && first != null; i++) {
        final BuildContext? nodeContext = first.context;
        final bool inAppBar =
            nodeContext?.findAncestorWidgetOfExactType<CustomAppBar>() !=
                null ||
            nodeContext?.findAncestorWidgetOfExactType<SliverAppBar>() !=
                null ||
            nodeContext?.findAncestorWidgetOfExactType<AppBar>() != null;
        if (!inAppBar) break;
        if (!first.nextFocus()) return;
        first = FocusManager.instance.primaryFocus;
      }
      first?.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
