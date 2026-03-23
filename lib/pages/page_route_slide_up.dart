import 'package:flutter/material.dart';

/// Full-screen route that enters from the bottom (e.g. app detail / options from the bar).
PageRouteBuilder<T> slideUpPageRoute<T>(WidgetBuilder builder) =>
    PageRouteBuilder<T>(
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
