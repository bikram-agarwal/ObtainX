import 'dart:isolate';

import 'package:html/dom.dart' show Document;
import 'package:html/parser.dart' show parse;

/// Parses [body] as HTML on a background isolate so the UI isolate doesn't
/// stall on the synchronous DOM build.
///
/// `package:html`'s [parse] is pure-Dart and synchronous; on a 50-app
/// pull-to-refresh with 2-4 parallel workers, having every source parse on
/// the UI isolate is what bursts main-thread frame budget and produces the
/// scroll stutter we saw before. Pushing the parse into an [Isolate.run]
/// callback lets the worker isolate eat the CPU cost while the UI thread
/// stays free to scroll, repaint, and tick the progress bar.
///
/// The returned [Document] is deep-copied across the isolate boundary by
/// Dart's SendPort serialization - that copy is roughly an order of
/// magnitude cheaper than the parse itself, so the net is still a big win
/// for any HTML body of meaningful size.
///
/// All call sites in `lib/app_sources/*.dart` should prefer this over the
/// raw `parse(body)` import for refresh-time response bodies.
Future<Document> parseHtmlOffIsolate(String body) {
  // `Isolate.run` (Dart 3+) handles spawning, lifecycle, and (with
  // `--enable-experiment=isolate-groups`) keeps a warm pool, so we don't
  // need to manage a long-lived worker ourselves.
  return Isolate.run<Document>(() => parse(body), debugName: 'html-parse');
}
