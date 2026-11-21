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
