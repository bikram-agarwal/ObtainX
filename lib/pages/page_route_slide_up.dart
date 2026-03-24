import 'package:flutter/material.dart';

/// Full-screen route that enters from the bottom (e.g. app detail / options from the bar).
PageRouteBuilder<T> slideUpPageRoute<T>(WidgetBuilder builder) =>
    PageRouteBuilder<T>(
      opaque: true,
      maintainState: true,
      pageBuilder: (context, _, _) => builder(context),
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        final Animation<double> curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 1),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        );
      },
      transitionDuration: const Duration(milliseconds: 320),
      reverseTransitionDuration: const Duration(milliseconds: 280),
    );

/// Fade transition so [Hero] flights (e.g. app list icon to app page) are not broken by a full-screen slide.
PageRouteBuilder<T> heroFriendlyAppPageRoute<T>(WidgetBuilder builder) =>
    PageRouteBuilder<T>(
      opaque: true,
      maintainState: true,
      pageBuilder: (context, _, _) => builder(context),
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        return FadeTransition(
          opacity: CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          ),
          child: child,
        );
      },
      transitionDuration: const Duration(milliseconds: 260),
      reverseTransitionDuration: const Duration(milliseconds: 220),
    );
