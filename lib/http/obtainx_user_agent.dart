import 'dart:io';

/// Default User-Agent for source HTTP. Sources that already set a User-Agent
/// (APKMirror's identifying ones, a browser impersonation, curl, F-Droid, …)
/// keep theirs; this is only the fallback for everyone else.
const String obtainXUserAgent = 'ObtainX';

/// Stands in for the running version in [obtainXIdentifyingUserAgent] when it
/// can't be read, so the UA never goes out without one (upstream uses the
/// same value).
const String obtainXUserAgentFallbackVersion = '1.0.0';

/// `ObtainX/<version> (+<projectUrl>)`: the self-identifying UA a host can
/// allowlist and attribute, as APKMirror asked for its feed (#339).
String obtainXIdentifyingUserAgent(String? version, String projectUrl) {
  final String trimmed = version?.trim() ?? '';
  return 'ObtainX/${trimmed.isEmpty ? obtainXUserAgentFallbackVersion : trimmed} (+$projectUrl)';
}

bool headersSpecifyUserAgent(Map<String, String>? headers) {
  if (headers == null) {
    return false;
  }
  return headers.keys.any(
    (String headerName) => headerName.toLowerCase() == 'user-agent',
  );
}

/// Copy of [headers] with [obtainXUserAgent] filled in when the source did not
/// already send one (any casing).
Map<String, String> withDefaultObtainXUserAgent(Map<String, String>? headers) {
  final Map<String, String> merged = Map<String, String>.from(headers ?? {});
  if (!headersSpecifyUserAgent(merged)) {
    merged[HttpHeaders.userAgentHeader] = obtainXUserAgent;
  }
  return merged;
}
