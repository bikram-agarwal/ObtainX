// HTTP client creation, streaming requests, redirect/error handling.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/http/obtainx_user_agent.dart';
import 'package:obtainium/http/response_bytes.dart';

// ========================================================================
// HttpService — HTTP client creation, streaming requests, and error mapping.
// ========================================================================

class HttpService {
  static const int maxRedirects = 10;

  /// Headers that may be forwarded to a different origin on redirect.
  /// Source-configured auth headers (e.g. PRIVATE-TOKEN, X-Api-Key) and other
  /// caller-supplied headers are dropped, since a redirect can point at an
  /// arbitrary third-party host.
  static const Set<String> safeRedirectHeaders = {
    'accept',
    'accept-charset',
    'accept-encoding',
    'accept-language',
    'cache-control',
    'content-length',
    'content-type',
    'if-modified-since',
    'if-none-match',
    'if-range',
    'origin',
    'pragma',
    'range',
    'referer',
    'user-agent',
    'x-requested-with',
  };

  /// Opt-in certificate pinning (the `enableCertificatePinning` setting): the
  /// CA roots each pinned host (and its subdomains) may chain to.
  static final Map<String, Future<List<Uint8List>>> _certificatePins = {
    'github.com': _loadCertificateFromAsset([
      'assets/ca-certs/sectigo-pub-serv-auth-r46.crt',
      'assets/ca-certs/sectigo-pub-serv-auth-e46.crt',

      // redirects from api.github.com for obtaining release assets point to
      // release-assets.githubusercontent.com which uses ISRG (Let's Encrypt)
      // adding that as another section doesn't work because of
      // HttpClient follows redirects (as intended)
      'assets/ca-certs/isrg-root-x1.crt',
      'assets/ca-certs/isrg-root-x2.crt',
      'assets/ca-certs/isrg-root-ye.crt',
      'assets/ca-certs/isrg-root-yr.crt',
    ]),
    'codeberg.org': _loadCertificateFromAsset([
      'assets/ca-certs/isrg-root-x1.crt',
      'assets/ca-certs/isrg-root-x2.crt',
      'assets/ca-certs/isrg-root-ye.crt',
      'assets/ca-certs/isrg-root-yr.crt',
    ]),
    'gitlab.com': _loadCertificateFromAsset([
      'assets/ca-certs/sectigo-pub-serv-auth-r46.crt',
      'assets/ca-certs/sectigo-pub-serv-auth-e46.crt',
    ]),
    'rustore.ru': _loadCertificateFromAsset([
      'assets/ca-certs/harica-tls-root-2021-rsa.crt',
      'assets/ca-certs/harica-tls-root-2021-ecc.crt',
      'assets/ca-certs/russian-mintsifry-root.crt',
    ]),
  };

  final Duration responseTimeout;

  HttpService({this.responseTimeout = sourceResponseTimeout});

  static Future<List<Uint8List>> _loadCertificateFromAsset(
    List<String> assetsPath,
  ) async {
    final List<Uint8List> certsBytes = [];
    for (final certPath in assetsPath) {
      final cert = await rootBundle.load(certPath);
      certsBytes.add(cert.buffer.asUint8List());
    }
    return certsBytes;
  }

  static String extractRootHost(String host) {
    final parts = host.split('.');
    return parts.length > 2 ? parts.sublist(parts.length - 2).join('.') : host;
  }

  /// Whether certificate pinning, when enabled, applies to [host].
  static bool isPinnedHost(String host) =>
      _certificatePins.containsKey(host) ||
      _certificatePins.containsKey(extractRootHost(host));

  /// Whether a request to [url] needs a client with its own trust store, and
  /// so must not run on a shared or pooled client: RuStore hosts always (they
  /// may be signed by the Mintsifry root), pinned hosts while pinning is on.
  static bool needsDedicatedClient(
    Uri url, {
    required bool certificatePinning,
  }) =>
      extractRootHost(url.host) == 'rustore.ru' ||
      (certificatePinning && isPinnedHost(url.host));

  Future<SecurityContext?> _createCertPinning(Uri url) async {
    final host = url.host;
    final rootHost = extractRootHost(host);
    final String? pinKey = _certificatePins.containsKey(host)
        ? host
        : (_certificatePins.containsKey(rootHost) ? rootHost : null);
    if (pinKey == null) return null;
    final certsBytes = await _certificatePins[pinKey]!;
    final securityContext = SecurityContext();
    for (final certBytes in certsBytes) {
      securityContext.setTrustedCertificatesBytes(certBytes);
    }
    return securityContext;
  }

  /* Basically RuStore switched partially (and in the future it may be fully)
     to russian government Mintsifry CA, which isnt trusted by Android nor
     Chrome Root Store. This is workaround to trust Mintsifry CA for network
     requests made to RuStore domains and subdomains
   */
  Future<SecurityContext> _ruStoreWorkaroundSecurityContext() async {
    final securityContext = SecurityContext(withTrustedRoots: true);
    final cert = await rootBundle.load(
      'assets/ca-certs/russian-mintsifry-root.crt',
    );
    securityContext.setTrustedCertificatesBytes(cert.buffer.asUint8List());
    return securityContext;
  }

  HttpClient createHttpClient(bool insecure) {
    final client = HttpClient()..connectionTimeout = sourceConnectionTimeout;
    if (insecure) {
      client.badCertificateCallback =
          (X509Certificate cert, String host, int port) => true;
    }
    return client;
  }

  /// Host-aware [createHttpClient]: a pinned trust store for pinned hosts
  /// while [certificatePinning] is on, the RuStore Mintsifry root on top of the
  /// system roots for RuStore hosts, and the plain client for everything else.
  Future<HttpClient> createHttpClientForUrl(
    Uri url, {
    required bool insecure,
    bool certificatePinning = false,
  }) async {
    SecurityContext? securityContext;
    if (certificatePinning) {
      securityContext = await _createCertPinning(url);
    }
    if (securityContext == null && extractRootHost(url.host) == 'rustore.ru') {
      securityContext = await _ruStoreWorkaroundSecurityContext();
    }
    if (securityContext == null) return createHttpClient(insecure);
    final client = HttpClient(context: securityContext)
      ..connectionTimeout = sourceConnectionTimeout;
    if (insecure) {
      client.badCertificateCallback =
          (X509Certificate cert, String host, int port) {
            // Pinned sites (and subdomains of a pinned root) must still
            // reject bad certificates even when insecure mode is enabled.
            return !(certificatePinning && isPinnedHost(host));
          };
    }
    return client;
  }

  /// Whether two URIs share the same origin (scheme, host, and port — Dart
  /// normalizes default ports for http/https, so explicit and implicit
  /// default ports compare equal).
  static bool isSameOrigin(Uri a, Uri b) =>
      a.scheme.toLowerCase() == b.scheme.toLowerCase() &&
      a.host.toLowerCase() == b.host.toLowerCase() &&
      a.port == b.port;

  String ensureAbsoluteUrl(String ambiguousUrl, Uri referenceAbsoluteUrl) {
    try {
      ambiguousUrl = ambiguousUrl.trim();
      if (Uri.parse(ambiguousUrl).isAbsolute) {
        return ambiguousUrl;
      }
    } on FormatException {
      // Non-parsable URL, fall through to resolve logic below
    }
    return referenceAbsoluteUrl.resolve(ambiguousUrl).toString();
  }

  /// Performs an HTTP request with redirect following, returning the final URL, client, and streamed response.
  ///
  /// Ordinary hops run on [sharedClient] when given (a request session's
  /// pooled client), otherwise on one client owned by this call. A hop that
  /// [needsDedicatedClient] gets its own client, closed once the hop is done.
  /// The returned client is the one that served the final hop: callers close
  /// it unless it is [sharedClient].
  ///
  /// A redirect from HTTPS to cleartext HTTP is refused unless the app allows
  /// insecure connections or [allowInsecureRedirects] is set (a source opt-in).
  /// A redirect to a different origin forwards only [safeRedirectHeaders] and
  /// no cookies.
  Future<MapEntry<Uri, MapEntry<HttpClient, HttpClientResponse>>>
  sourceRequestStreamResponse(
    String method,
    String url,
    Map<String, String>? requestHeaders,
    Map<String, dynamic> additionalSettings, {
    bool followRedirects = true,
    Object? postBody,
    HttpClient? sharedClient,
    bool allowInsecureRedirects = false,
    bool certificatePinning = false,
  }) async {
    var currentUrl = Uri.parse(url);
    var redirectCount = 0;
    List<Cookie> cookies = [];
    final bool allowInsecure = additionalSettings['allowInsecure'] == true;
    HttpClient? ownedClient;
    try {
      while (redirectCount < maxRedirects) {
        final bool dedicated = needsDedicatedClient(
          currentUrl,
          certificatePinning: certificatePinning,
        );
        final HttpClient httpClient = dedicated
            ? await createHttpClientForUrl(
                currentUrl,
                insecure: allowInsecure,
                certificatePinning: certificatePinning,
              )
            : (sharedClient ??
                  (ownedClient ??= createHttpClient(allowInsecure)));
        try {
          bool openTimedOut = false;
          final pendingRequest = httpClient.openUrl(method, currentUrl).then((
            request,
          ) {
            if (openTimedOut) request.abort();
            return request;
          });
          final request = await pendingRequest.timeout(
            responseTimeout,
            onTimeout: () {
              openTimedOut = true;
              throw TimeoutException(tr('unexpectedError'), responseTimeout);
            },
          );
          withDefaultObtainXUserAgent(requestHeaders).forEach((
            String headerName,
            String headerValue,
          ) {
            request.headers.set(headerName, headerValue);
          });
          request.cookies.addAll(cookies);
          request.followRedirects = false;
          if (postBody != null) {
            if (postBody is String) {
              request.write(postBody);
            } else {
              request.headers.contentType = ContentType.json;
              request.write(jsonEncode(postBody));
            }
          }
          final response = await request.close().timeout(
            responseTimeout,
            onTimeout: () {
              request.abort();
              throw TimeoutException(tr('unexpectedError'), responseTimeout);
            },
          );

          if (followRedirects &&
              (response.statusCode >= 300 && response.statusCode <= 399)) {
            final location = response.headers.value(HttpHeaders.locationHeader);
            if (location != null) {
              final nextUrl = Uri.parse(
                ensureAbsoluteUrl(location, currentUrl),
              );
              await response.timeout(responseTimeout).drain<void>();
              if (currentUrl.scheme == 'https' &&
                  nextUrl.scheme == 'http' &&
                  !allowInsecure &&
                  !allowInsecureRedirects) {
                // Never follow a redirect that downgrades to cleartext HTTP.
                throw ObtainiumError(tr('insecureRedirect'));
              }
              if (!isSameOrigin(currentUrl, nextUrl)) {
                // Do not forward credentials or any other caller-supplied
                // headers to a different origin; keep only protocol-level ones.
                requestHeaders = requestHeaders == null
                    ? null
                    : Map<String, String>.fromEntries(
                        requestHeaders.entries.where(
                          (e) =>
                              safeRedirectHeaders.contains(e.key.toLowerCase()),
                        ),
                      );
                cookies = [];
              } else {
                cookies = response.cookies;
              }
              currentUrl = nextUrl;
              redirectCount++;
              if (dedicated) httpClient.close();
              continue;
            }
          }

          if (ownedClient != null && !identical(ownedClient, httpClient)) {
            // Earlier hops ran on the owned client; this hop's client is the
            // one handed back, so the owned one is no longer needed.
            ownedClient.close();
            ownedClient = null;
          }
          return MapEntry(currentUrl, MapEntry(httpClient, response));
        } catch (_) {
          if (dedicated) httpClient.close(force: true);
          rethrow;
        }
      }
      throw ObtainiumError(tr('tooManyRedirects'));
    } catch (_) {
      ownedClient?.close(force: true);
      rethrow;
    }
  }

  Future<http.Response> httpClientResponseStreamToFinalResponse(
    HttpClient httpClient,
    String method,
    String url,
    HttpClientResponse response, {
    bool closeClient = true,
  }) async {
    try {
      final bytes =
          (await response
                  .timeout(responseTimeout)
                  .fold<BytesBuilder>(
                    BytesBuilder(copy: false),
                    (b, d) => b..add(d),
                  ))
              .takeBytes();

      final headers = <String, String>{};
      response.headers.forEach((name, values) {
        headers[name] = values.join(', ');
      });

      return http.Response.bytes(
        bytes,
        response.statusCode,
        headers: headers,
        request: http.Request(method, Uri.parse(url)),
      );
    } finally {
      if (closeClient) httpClient.close();
    }
  }

  ObtainiumError getHttpError(http.Response res) {
    if (res.statusCode == 404) return NoReleasesError();

    final reasonLower = res.reasonPhrase?.toLowerCase() ?? '';
    final body = res.body;
    final bodySample = body.length > 1000
        ? body.substring(0, 1000).toLowerCase()
        : body.toLowerCase();
    final isRateLimit =
        res.statusCode == 429 ||
        res.statusCode == 403 ||
        reasonLower.contains('rate limit') ||
        reasonLower.contains('too many requests') ||
        bodySample.contains('rate limit') ||
        bodySample.contains('too many requests');

    if (isRateLimit) {
      final retryAfter = res.headers['retry-after'];
      final secs = retryAfter != null ? int.tryParse(retryAfter) : null;
      if (secs != null) return RateLimitError((secs / 60).ceil());

      final resetHeader = res.headers['x-ratelimit-reset'];
      if (resetHeader != null) {
        final parsed = int.tryParse(resetHeader);
        if (parsed != null) {
          final nowSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
          final remainingMinutes = ((parsed - nowSeconds) / 60).ceil().clamp(
            1,
            9999,
          );
          return RateLimitError(remainingMinutes);
        }
      }
      return RateLimitError(30); // Default to a conservative 30 minutes
    }
    return ObtainiumError(
      (res.reasonPhrase != null && res.reasonPhrase!.isNotEmpty)
          ? res.reasonPhrase!
          : tr('errorWithHttpStatusCode', args: [res.statusCode.toString()]),
      code: 'HTTP_ERROR',
      // Lets callers tell a transient server error from a rejected request.
      data: {'statusCode': res.statusCode},
    );
  }
}

/// Delegates to [HttpService.ensureAbsoluteUrl].
String ensureAbsoluteUrl(String ambiguousUrl, Uri referenceAbsoluteUrl) =>
    HttpService().ensureAbsoluteUrl(ambiguousUrl, referenceAbsoluteUrl);

/// Delegates to [HttpService.createHttpClient].
HttpClient createHttpClient(bool insecure) =>
    HttpService().createHttpClient(insecure);

// ------------------------------------------------------------------------
// More top-level delegation helpers (continued)
// ------------------------------------------------------------------------

/// Delegates to [HttpService.sourceRequestStreamResponse].
Future<MapEntry<Uri, MapEntry<HttpClient, HttpClientResponse>>>
sourceRequestStreamResponse(
  String method,
  String url,
  Map<String, String>? requestHeaders,
  Map<String, dynamic> additionalSettings, {
  bool followRedirects = true,
  Object? postBody,
  bool allowInsecureRedirects = false,
  bool certificatePinning = false,
}) => HttpService().sourceRequestStreamResponse(
  method,
  url,
  requestHeaders,
  additionalSettings,
  followRedirects: followRedirects,
  postBody: postBody,
  allowInsecureRedirects: allowInsecureRedirects,
  certificatePinning: certificatePinning,
);

/// Delegates to [HttpService.httpClientResponseStreamToFinalResponse].
Future<http.Response> httpClientResponseStreamToFinalResponse(
  HttpClient httpClient,
  String method,
  String url,
  HttpClientResponse response,
) => HttpService().httpClientResponseStreamToFinalResponse(
  httpClient,
  method,
  url,
  response,
);

/// Delegates to [HttpService.getHttpError].
ObtainiumError getObtainiumHttpError(http.Response res) =>
    HttpService().getHttpError(res);

/// Throws an [ObtainiumError] carrying [res]'s status code unless the response
/// is a 200 OK.
void ensureHttpSuccess(http.Response res) {
  if (res.statusCode != 200) {
    throw getObtainiumHttpError(res);
  }
}
