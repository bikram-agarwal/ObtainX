import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';

enum ToastType { info, success, warning, error }

class _ToastVisuals {
  const _ToastVisuals({
    required this.iconColor,
    required this.iconBackgroundColor,
    required this.defaultIcon,
  });

  final Color iconColor;
  final Color iconBackgroundColor;
  final IconData defaultIcon;
}

_ToastVisuals _resolveToastVisuals(ColorScheme colorScheme, ToastType type) {
  switch (type) {
    case ToastType.success:
      return _ToastVisuals(
        iconColor: colorScheme.onSecondaryContainer,
        iconBackgroundColor: colorScheme.secondaryContainer,
        defaultIcon: Icons.check_circle_rounded,
      );
    case ToastType.warning:
      return _ToastVisuals(
        iconColor: colorScheme.onTertiaryContainer,
        iconBackgroundColor: colorScheme.tertiaryContainer,
        defaultIcon: Icons.warning_amber_rounded,
      );
    case ToastType.error:
      return _ToastVisuals(
        iconColor: colorScheme.onErrorContainer,
        iconBackgroundColor: colorScheme.errorContainer,
        defaultIcon: Icons.error_outline_rounded,
      );
    case ToastType.info:
      return _ToastVisuals(
        iconColor: colorScheme.onPrimaryContainer,
        iconBackgroundColor: colorScheme.primaryContainer,
        defaultIcon: Icons.info_outline_rounded,
      );
  }
}

/// Builds a [SnackBar] sharing [showAppToast]'s per-[ToastType] icon/color
/// scheme, so screen-tied feedback (which must stay a SnackBar for actions,
/// queueing, and accessibility) looks consistent with the toast pipe used by
/// background/installer flows.
SnackBar buildAppSnackBar(
  BuildContext context,
  String message, {
  ToastType type = ToastType.info,
  IconData? icon,
  Duration duration = const Duration(seconds: 4),
  String? actionLabel,
  VoidCallback? onAction,
  bool? persist,
  ThemeData? theme,
}) {
  final ColorScheme colorScheme = (theme ?? Theme.of(context)).colorScheme;
  final _ToastVisuals visuals = _resolveToastVisuals(colorScheme, type);
  final Color backgroundColor = Color.lerp(
    colorScheme.surfaceContainerHighest,
    colorScheme.inverseSurface,
    0.18,
  )!;

  return SnackBar(
    duration: duration,
    persist: persist,
    backgroundColor: backgroundColor,
    action: actionLabel == null || onAction == null
        ? null
        : SnackBarAction(
            label: actionLabel,
            textColor: colorScheme.primary,
            onPressed: onAction,
          ),
    content: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        DecoratedBox(
          decoration: ShapeDecoration(
            color: visuals.iconBackgroundColor,
            shape: RoundedSuperellipseBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Icon(
              icon ?? visuals.defaultIcon,
              color: visuals.iconColor,
              size: 18,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Flexible(
          child: Text(message, style: TextStyle(color: colorScheme.onSurface)),
        ),
      ],
    ),
  );
}

class _PendingAppToast {
  const _PendingAppToast({
    required this.message,
    required this.icon,
    required this.type,
    required this.duration,
    required this.theme,
  });

  final String message;
  final IconData? icon;
  final ToastType type;
  final Duration duration;
  final ThemeData? theme;
}

final List<_PendingAppToast> _pendingAppToasts = <_PendingAppToast>[];
BuildContext? _appToastContext;
bool _pendingToastFlushScheduled = false;

class AppToastHost extends StatefulWidget {
  const AppToastHost({super.key, required this.child});

  final Widget child;

  @override
  State<AppToastHost> createState() => _AppToastHostState();
}

class _AppToastHostState extends State<AppToastHost> {
  @override
  Widget build(BuildContext context) {
    _appToastContext = context;
    if (_pendingAppToasts.isNotEmpty && !_pendingToastFlushScheduled) {
      _pendingToastFlushScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((Duration _) {
        _pendingToastFlushScheduled = false;
        if (!mounted || _pendingAppToasts.isEmpty) {
          return;
        }
        final List<_PendingAppToast> pendingToasts =
            List<_PendingAppToast>.from(_pendingAppToasts);
        _pendingAppToasts.clear();
        for (final _PendingAppToast pendingToast in pendingToasts) {
          showAppToast(
            pendingToast.message,
            context: context,
            icon: pendingToast.icon,
            type: pendingToast.type,
            duration: pendingToast.duration,
            theme: pendingToast.theme,
          );
        }
      });
    }
    return widget.child;
  }

  @override
  void dispose() {
    if (identical(_appToastContext, context)) {
      _appToastContext = null;
    }
    super.dispose();
  }
}

void showAppToast(
  String message, {
  BuildContext? context,
  IconData? icon,
  ToastType type = ToastType.info,
  Duration duration = const Duration(seconds: 3),
  ThemeData? theme,
}) {
  final BuildContext? overlayContext = _appToastContext?.mounted == true
      ? _appToastContext
      : context?.mounted == true
      ? context
      : null;
  final BuildContext? themeContext = context?.mounted == true
      ? context
      : overlayContext;

  if (overlayContext != null && themeContext != null) {
    final fToast = FToast();
    fToast.init(overlayContext);

    final ThemeData effectiveTheme = theme ?? Theme.of(themeContext);
    final ColorScheme colorScheme = effectiveTheme.colorScheme;

    final Color backgroundColor = Color.lerp(
      colorScheme.surfaceContainerHighest,
      colorScheme.inverseSurface,
      0.18,
    )!;
    final Color foregroundColor = colorScheme.onSurface;
    final _ToastVisuals visuals = _resolveToastVisuals(colorScheme, type);
    final IconData effectiveIcon = icon ?? visuals.defaultIcon;

    final Widget toastWidget = Material(
      color: Colors.transparent,
      child: GestureDetector(
        onTap: () {
          try {
            fToast.removeCustomToast();
          } catch (_) {}
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
          margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          decoration: ShapeDecoration(
            color: backgroundColor,
            shape: RoundedSuperellipseBorder(
              borderRadius: BorderRadius.circular(28),
              side: BorderSide(color: colorScheme.outlineVariant),
            ),
            shadows: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.14),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              DecoratedBox(
                decoration: ShapeDecoration(
                  color: visuals.iconBackgroundColor,
                  shape: RoundedSuperellipseBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Icon(
                    effectiveIcon,
                    color: visuals.iconColor,
                    size: 18,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  message,
                  style: effectiveTheme.textTheme.labelLarge?.copyWith(
                    color: foregroundColor,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    fToast.showToast(
      child: toastWidget,
      toastDuration: duration,
      gravity: ToastGravity.BOTTOM,
      isDismissible: true,
    );
  } else {
    _pendingAppToasts.add(
      _PendingAppToast(
        message: message,
        icon: icon,
        type: type,
        duration: duration,
        theme: theme,
      ),
    );
  }
}
