String formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var size = bytes.toDouble();
  var unit = 0;
  while (size >= 1024 && unit < units.length - 1) {
    size /= 1024;
    unit++;
  }
  var value = unit == 0 ? size.toStringAsFixed(0) : size.toStringAsFixed(1);
  // Rounding can push the value up to the next unit (e.g. 1048525 B would
  // otherwise display as "1024.0 KB" instead of "1.0 MB").
  if (unit > 0 && unit < units.length - 1 && double.parse(value) >= 1024) {
    size /= 1024;
    unit++;
    value = size.toStringAsFixed(1);
  }
  return '$value ${units[unit]}';
}

String? formatDownloadSize(int? receivedBytes, int? totalBytes) {
  if (receivedBytes == null) return null;
  if (totalBytes != null && totalBytes > 0) {
    return '${formatBytes(receivedBytes)} / ${formatBytes(totalBytes)}';
  }
  return formatBytes(receivedBytes);
}

/// Formats a byte count with coarse, fixed per-unit precision (e.g. "5.0 GB",
/// "512 MB", "128 KB"). Used for download-size labels in the UI.
String formatBytesForDisplay(int bytes) {
  if (bytes >= 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  } else if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB';
  } else if (bytes >= 1024) {
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  } else {
    return '$bytes B';
  }
}

/// Formats a repository star count compactly (e.g. "910", "5.8K", "36K", "1.2M").
String formatCompactStarCount(int starCount) {
  if (starCount <= 0) return '0';
  if (starCount < 1000) return '$starCount';

  String formatScaledUnit(double scaledValue, String suffix) {
    final String formatted = scaledValue < 9.95
        ? scaledValue.toStringAsFixed(1)
        : scaledValue.round().toString();
    final String trimmed = formatted.endsWith('.0')
        ? formatted.substring(0, formatted.length - 2)
        : formatted;
    return '$trimmed$suffix';
  }

  if (starCount < 999500) {
    return formatScaledUnit(starCount / 1000, 'K');
  }
  return formatScaledUnit(starCount / 1000000, 'M');
}
