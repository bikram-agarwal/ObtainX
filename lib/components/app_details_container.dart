import 'package:animations/animations.dart';
import 'package:flutter/material.dart';

/// The stock Material container transform used by app cards and their details.
class AppDetailsContainer extends StatelessWidget {
  const AppDetailsContainer({
    super.key,
    required this.closedShape,
    required this.closedBuilder,
    required this.openBuilder,
  });

  final ShapeBorder closedShape;
  final CloseContainerBuilder closedBuilder;
  final WidgetBuilder openBuilder;

  @override
  Widget build(BuildContext context) {
    final surfaceColor = Theme.of(context).colorScheme.surface;
    return OpenContainer<void>(
      closedColor: Colors.transparent,
      openColor: surfaceColor,
      // animations 3 uses material_ui's separate Theme, which otherwise falls
      // back to a light canvas even when this app's Flutter Theme is dark.
      middleColor: surfaceColor,
      closedElevation: 0,
      openElevation: 0,
      // Keep the card visible until details cover it, including on return.
      transitionType: ContainerTransitionType.fade,
      transitionDuration: const Duration(milliseconds: 320),
      closedShape: closedShape,
      tappable: false,
      openBuilder: (context, closeContainer) => openBuilder(context),
      closedBuilder: closedBuilder,
    );
  }
}
