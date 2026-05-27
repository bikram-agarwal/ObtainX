import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/services/shared_url_receiver.dart';

void main() {
  group('SharedUrlReceiver.extractFirstUrl', () {
    test('returns a plain URL', () {
      expect(
        SharedUrlReceiver.extractFirstUrl('https://github.com/example/app'),
        'https://github.com/example/app',
      );
    });

    test('returns the URL from browser title plus URL text', () {
      expect(
        SharedUrlReceiver.extractFirstUrl(
          'Example App\nhttps://github.com/example/app',
        ),
        'https://github.com/example/app',
      );
    });

    test('chooses the first URL when multiple URLs are shared', () {
      expect(
        SharedUrlReceiver.extractFirstUrl(
          'https://first.example/app https://second.example/app',
        ),
        'https://first.example/app',
      );
    });

    test('removes trailing punctuation from the shared URL', () {
      expect(
        SharedUrlReceiver.extractFirstUrl(
          'Install this: https://github.com/example/app.',
        ),
        'https://github.com/example/app',
      );
    });

    test('returns null when shared text has no URL', () {
      expect(SharedUrlReceiver.extractFirstUrl('Example App'), isNull);
    });
  });
}
