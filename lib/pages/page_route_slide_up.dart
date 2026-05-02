import 'package:flutter/material.dart';

// Material 3 motion spec uses an "emphasized" easing curve that starts
// briskly, decelerates through the middle, and settles slowly into the
// final position. Flutter's [Curves.fastEaseInToSlowEaseOut] is the
// closest stock approximation of that M3-emphasized cubic. Reverse uses
// the symmetric counterpart so back-pop animations feel paired.
const Curve _m3EmphasizedForward = Curves.fastEaseInToSlowEaseOut;
const Curve _m3EmphasizedReverse = Curves.fastEaseInToSlowEaseOut;

// Durations from the Material 3 spec for "incoming/outgoing on screen"
// transitions: 300ms forward, 250ms reverse. Slightly shorter than the
// previous values for a snappier feel without sacrificing the curve.
const Duration _m3ForwardDuration = Duration(milliseconds: 300);
const Duration _m3ReverseDuration = Duration(milliseconds: 250);

/// Full-screen route that enters from the bottom (e.g. app detail / options from the bar).
PageRouteBuilder<T> slideUpPageRoute<T>(WidgetBuilder builder) =>
    PageRouteBuilder<T>(
      opaque: true,
      maintainState: true,
      pageBuilder: (context, _, _) => builder(context),
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        final Animation<double> curved = CurvedAnimation(
          parent: animation,
          curve: _m3EmphasizedForward,
          reverseCurve: _m3EmphasizedReverse,
        );
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 1),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        );
      },
      transitionDuration: _m3ForwardDuration,
      reverseTransitionDuration: _m3ReverseDuration,
    );

/// Fade transition so [Hero] flights (e.g. app list icon to app page) are not broken by a full-screen slide.
///
/// NOTE: This is the lightweight "motion curves only" half of the M3
/// Container Transform migration. A full migration would replace this
/// route + the originating list rows with [OpenContainer] from the
/// `animations` package so the entire row morphs into the destination
/// page (the M3 spec for "open detail" navigation). That refactor is
/// out of scope for this change because the apps-list rows wire Hero
/// state, swipe actions, double-tap-to-launch, and selection-mode
/// toggles through the same onTap handler that triggers the push;
/// converting them to OpenContainer requires restructuring those
/// gesture paths. Filed for a follow-up PR.
PageRouteBuilder<T> heroFriendlyAppPageRoute<T>(WidgetBuilder builder) =>
    PageRouteBuilder<T>(
      opaque: true,
      maintainState: true,
      pageBuilder: (context, _, _) => builder(context),
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        return FadeTransition(
          opacity: CurvedAnimation(
            parent: animation,
            curve: _m3EmphasizedForward,
            reverseCurve: _m3EmphasizedReverse,
          ),
          child: child,
        );
      },
      transitionDuration: _m3ForwardDuration,
      reverseTransitionDuration: _m3ReverseDuration,
    );
