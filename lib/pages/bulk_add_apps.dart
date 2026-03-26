import 'package:flutter/material.dart';
import 'package:obtainium/components/bulk_add_widget.dart';

/// Standalone page wrapper around [BulkAddWidget].
///
/// Kept as a separate route so that any existing [Navigator.push] to this
/// page continues to work unchanged. All logic lives in [BulkAddWidget].
class BulkAddAppsPage extends StatelessWidget {
  const BulkAddAppsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const BulkAddWidget(standalone: true);
  }
}
