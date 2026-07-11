// Talks to the VirusTotal public API v3 to scan a downloaded APK before install.
// Not an [AppSource] - VirusTotal isn't a place apps come from, it's a check run
// on the file after it's already been downloaded from wherever it came from.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:http/http.dart' as http;
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/source_provider.dart';

const String virusTotalApiKeyKey = 'virustotal-api-key';

// Mirrors GitHub's validatedPATFingerprintKey/hasValidatedPAT/storePATValidation/
// clearPATValidation (lib/app_sources/github.dart) - a saved key isn't enough on
// its own; it must also have passed [VirusTotalScanner.validateApiKey] at least
// once, and the fingerprint lets us tell a validated key apart from one that was
// merely typed in (e.g. restored from a backup) without re-hitting the API.
String? _apiKeyFingerprint(String? apiKey) {
  final String trimmed = apiKey?.trim() ?? '';
  if (trimmed.isEmpty) {
    return null;
  }
  return sha256.convert(utf8.encode(trimmed)).toString();
}

bool hasValidatedApiKey(String? apiKey, SettingsProvider settingsProvider) {
  final String? fingerprint = _apiKeyFingerprint(apiKey);
  if (fingerprint == null) {
    return false;
  }
  return settingsProvider.getSettingString(
        virusTotalValidatedApiKeyFingerprintKey,
      ) ==
      fingerprint;
}

void clearApiKeyValidation(SettingsProvider settingsProvider) {
  settingsProvider.setSettingString(
    virusTotalValidatedApiKeyFingerprintKey,
    '',
  );
}

void storeApiKeyValidation(String apiKey, SettingsProvider settingsProvider) {
  final String? fingerprint = _apiKeyFingerprint(apiKey);
  if (fingerprint == null) {
    clearApiKeyValidation(settingsProvider);
    return;
  }
  settingsProvider.setSettingString(
    virusTotalValidatedApiKeyFingerprintKey,
    fingerprint,
  );
}

const String virusTotalValidatedApiKeyFingerprintKey =
    'virustotal-api-key-validated-fingerprint';

const String _apiBase = 'https://www.virustotal.com/api/v3';

// VirusTotal's free-tier direct-upload cap. Files larger than this must go
// through the upload_url two-step flow instead of POSTing to /files directly.
const int virusTotalDirectUploadLimitBytes = 32 * 1024 * 1024;

// First 3 poll attempts wait 5s, the rest wait 10s - mirrors the backoff
// Orion-Store (D:\git\Others\Orion-Store) uses for the same VT analysis-polling endpoint.
const List<Duration> _pollDelays = [
  Duration(seconds: 5),
  Duration(seconds: 5),
  Duration(seconds: 5),
];
const Duration _pollDelayAfterInitialAttempts = Duration(seconds: 10);
const int _maxPollAttempts = 18;

class VirusTotalScanResult {
  final String status;
  final String? detail;
  final String? reportUrl;

  VirusTotalScanResult({required this.status, this.detail, this.reportUrl});
}

class _VirusTotalApiError implements Exception {
  final int statusCode;
  _VirusTotalApiError(this.statusCode);
}

class _VirusTotalAnalysisTimeoutError implements Exception {}

String _detailForApiError(int statusCode) {
  if (statusCode == 401 || statusCode == 403) {
    return tr('virusTotalErrorApiKeyRejected');
  }
  if (statusCode == 429) {
    return tr('virusTotalErrorRateLimited');
  }
  if (statusCode >= 500) {
    return tr('virusTotalErrorServerTrouble');
  }
  return tr('virusTotalErrorRequestFailed', args: [statusCode.toString()]);
}

String _reportUrlForHash(String sha256Hex) =>
    'https://www.virustotal.com/gui/file/$sha256Hex';

/// Scans a downloaded APK against the VirusTotal public API v3. Every public
/// method that can fail resolves to a [VirusTotalScanResult] with
/// [malwareScanStatusError] rather than throwing - callers never need to wrap
/// this in a try/catch, but MUST treat an error result as something to act on
/// (see the install-flow rules in apps_provider.dart), not something to ignore.
class VirusTotalScanner {
  Future<Map<String, dynamic>?> _lookupByHash(
    String sha256Hex,
    String apiKey,
  ) async {
    final response = await http.get(
      Uri.parse('$_apiBase/files/$sha256Hex'),
      headers: {'x-apikey': apiKey},
    );
    if (response.statusCode == 404) {
      return null;
    }
    if (response.statusCode != 200) {
      throw _VirusTotalApiError(response.statusCode);
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<String> _requestUploadUrl(String apiKey) async {
    final response = await http.get(
      Uri.parse('$_apiBase/files/upload_url'),
      headers: {'x-apikey': apiKey},
    );
    if (response.statusCode != 200) {
      throw _VirusTotalApiError(response.statusCode);
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return body['data'] as String;
  }

  // Streams the file from disk via MultipartFile.fromPath rather than reading
  // it into memory - loading the whole APK into RAM here is what caused OOM
  // risk on low-end devices in the earlier attempt at this feature (PR #123).
  Future<String> _uploadFile(
    File file,
    String apiKey, {
    String? uploadUrl,
  }) async {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse(uploadUrl ?? '$_apiBase/files'),
    );
    // VT's docs say to POST to the upload_url the same way as the regular
    // /files endpoint, so the api key header is sent either way.
    request.headers['x-apikey'] = apiKey;
    request.files.add(await http.MultipartFile.fromPath('file', file.path));
    final streamedResponse = await request.send();
    final response = await http.Response.fromStream(streamedResponse);
    if (response.statusCode != 200) {
      throw _VirusTotalApiError(response.statusCode);
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['data'] as Map<String, dynamic>)['id'] as String;
  }

  Future<Map<String, dynamic>> _pollAnalysis(
    String analysisId,
    String apiKey,
  ) async {
    for (var attempt = 0; attempt < _maxPollAttempts; attempt++) {
      await Future.delayed(
        attempt < _pollDelays.length
            ? _pollDelays[attempt]
            : _pollDelayAfterInitialAttempts,
      );
      final response = await http.get(
        Uri.parse('$_apiBase/analyses/$analysisId'),
        headers: {'x-apikey': apiKey},
      );
      if (response.statusCode != 200) {
        throw _VirusTotalApiError(response.statusCode);
      }
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final attributes =
          (body['data'] as Map<String, dynamic>)['attributes']
              as Map<String, dynamic>;
      if (attributes['status'] == 'completed') {
        final fileInfo =
            (body['meta'] as Map<String, dynamic>?)?['file_info']
                as Map<String, dynamic>?;
        return {
          'stats': attributes['stats'] as Map<String, dynamic>,
          'sha256': fileInfo?['sha256'] as String?,
        };
      }
    }
    throw _VirusTotalAnalysisTimeoutError();
  }

  VirusTotalScanResult _classify(Map<String, dynamic> stats, String sha256Hex) {
    final malicious = (stats['malicious'] as int?) ?? 0;
    final suspicious = (stats['suspicious'] as int?) ?? 0;
    final total = stats.values.whereType<int>().fold(0, (a, b) => a + b);
    final flagged = malicious + suspicious > 0;
    return VirusTotalScanResult(
      status: flagged ? malwareScanStatusFlagged : malwareScanStatusClean,
      detail: flagged
          ? tr(
              'virusTotalDetectionSummary',
              args: [(malicious + suspicious).toString(), total.toString()],
            )
          : null,
      reportUrl: _reportUrlForHash(sha256Hex),
    );
  }

  /// Hashes, looks up, uploads (if needed) and polls - see the "Flow" section
  /// of the implementation plan for the full sequence. [sha256Hex] is
  /// precomputed by the caller (apps_provider.dart reuses the same
  /// sha256.bind(file.openRead()).first idiom it already uses for GitHub
  /// attestation) so this class doesn't need its own crypto dependency.
  Future<VirusTotalScanResult> scan(
    File file,
    String sha256Hex,
    String apiKey,
  ) async {
    try {
      final existingReport = await _lookupByHash(sha256Hex, apiKey);
      Map<String, dynamic> stats;
      String reportHash = sha256Hex;
      if (existingReport != null) {
        final attributes =
            (existingReport['data'] as Map<String, dynamic>)['attributes']
                as Map<String, dynamic>;
        stats =
            (attributes['last_analysis_stats'] as Map<String, dynamic>?) ??
            <String, dynamic>{};
      } else {
        final int fileSize = await file.length();
        final String? uploadUrl = fileSize > virusTotalDirectUploadLimitBytes
            ? await _requestUploadUrl(apiKey)
            : null;
        final String analysisId = await _uploadFile(
          file,
          apiKey,
          uploadUrl: uploadUrl,
        );
        final analysis = await _pollAnalysis(analysisId, apiKey);
        stats = analysis['stats'] as Map<String, dynamic>;
        reportHash = (analysis['sha256'] as String?) ?? sha256Hex;
      }
      return _classify(stats, reportHash);
    } on _VirusTotalApiError catch (e) {
      return VirusTotalScanResult(
        status: malwareScanStatusError,
        detail: _detailForApiError(e.statusCode),
      );
    } on _VirusTotalAnalysisTimeoutError {
      return VirusTotalScanResult(
        status: malwareScanStatusError,
        detail: tr('virusTotalErrorAnalysisTimedOut'),
      );
    } catch (e) {
      return VirusTotalScanResult(
        status: malwareScanStatusError,
        detail: tr('virusTotalErrorGeneric', args: [e.toString()]),
      );
    }
  }

  /// Cheap authenticated request used by the "validate key" action in
  /// Settings - returns null if the key looks valid, or an error detail.
  Future<String?> validateApiKey(String apiKey) async {
    try {
      final response = await http.get(
        Uri.parse('$_apiBase/users/$apiKey'),
        headers: {'x-apikey': apiKey},
      );
      if (response.statusCode == 200 || response.statusCode == 404) {
        // 404 still means the key was accepted (the lookup target - the
        // key's own user object - just doesn't resolve the way expected);
        // 401/403 is the actual "bad key" signal.
        return null;
      }
      return _detailForApiError(response.statusCode);
    } catch (e) {
      return tr('virusTotalErrorGeneric', args: [e.toString()]);
    }
  }
}
