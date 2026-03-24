import 'package:flutter/material.dart';

class CustomAppBar extends StatefulWidget {
  const CustomAppBar({
    super.key,
    required this.title,
    this.leading,
    this.actions,
    this.bottom,
    this.searchWidget,
    this.titleStyle,
  });

  final String title;

  /// Toolbar leading widget (e.g. back). When null, no leading slot is shown.
  final Widget? leading;
  final List<Widget>? actions;

  /// Optional widget pinned below the flexible title (e.g. a search field).
  /// Pass a [PreferredSizeWidget] such as [PreferredSize].
  final PreferredSizeWidget? bottom;

  /// When provided, replaces the expanding-title layout with a compact inline
  /// row: [Title text]  [Expanded(searchWidget)]  [actions].
  /// This puts the search bar on the same line as the title, eliminating any
  /// visual overlap between the "Apps" heading and the search field.
  final Widget? searchWidget;

  /// Optional style override for the compact layout title.
  /// When null the title inherits the app bar theme's default style.
  final TextStyle? titleStyle;

  @override
  State<CustomAppBar> createState() => _CustomAppBarState();
}

class _CustomAppBarState extends State<CustomAppBar> {
  @override
  Widget build(BuildContext context) {
    if (widget.searchWidget != null) {
      // Compact layout: title and search bar share the same toolbar row.
      return SliverAppBar(
        pinned: true,
        automaticallyImplyLeading: false,
        leading: widget.leading,
        actions: widget.actions,
        titleSpacing: 0,
        bottom: widget.bottom,
        title: Padding(
          padding: EdgeInsets.only(
            left: widget.leading != null ? 0 : 20,
            right: 4,
          ),
          child: Row(
            children: [
              AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 200),
                style: widget.titleStyle ??
                    (Theme.of(context).appBarTheme.titleTextStyle ??
                        Theme.of(context).textTheme.titleLarge!),
                child: Text(widget.title),
              ),
              const SizedBox(width: 10),
              Expanded(child: widget.searchWidget!),
            ],
          ),
        ),
      );
    }

    // Default: large expanding title with optional pinned bottom widget.
    return SliverAppBar(
      pinned: true,
      automaticallyImplyLeading: false,
      leading: widget.leading,
      actions: widget.actions,
      expandedHeight: 100,
      bottom: widget.bottom,
      flexibleSpace: FlexibleSpaceBar(
        titlePadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        title: Text(
          widget.title,
          style: TextStyle(
            color: Theme.of(context).textTheme.bodyMedium!.color,
          ),
        ),
      ),
    );
  }
}
