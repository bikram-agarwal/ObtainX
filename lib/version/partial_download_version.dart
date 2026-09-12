const partialDownloadFingerprintKey = 'partialDownloadFingerprint';

/// The legacy eight-character label hashed HTTP chunk boundaries, which cannot
/// be reconstructed from a saved label. Keep that label for the first bounded
/// observation of the same URL. This establishes a baseline, not evidence of an
/// install; subsequent byte changes produce a new label. A changed URL or hash
/// method must never inherit the old baseline.
String resolvePartialDownloadVersion({
  required String fingerprint,
  required String downloadUrl,
  required Map<String, dynamic> settings,
  String? previousVersion,
  bool samePreviousDownload = false,
}) {
  final saved = settings[partialDownloadFingerprintKey];
  String label = fingerprint;
  if (saved is Map &&
      saved['url'] == downloadUrl &&
      saved['fingerprint'] == fingerprint &&
      saved['label'] is String) {
    label = saved['label'] as String;
  } else if (saved == null &&
      samePreviousDownload &&
      previousVersion != null &&
      RegExp(r'^[a-f0-9]{8}$').hasMatch(previousVersion)) {
    label = previousVersion;
  }
  settings[partialDownloadFingerprintKey] = {
    'url': downloadUrl,
    'fingerprint': fingerprint,
    'label': label,
  };
  return label;
}
