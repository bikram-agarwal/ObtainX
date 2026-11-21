/// Year, month, day: the order used until the phone says otherwise (and in
/// tests, which have no platform side).
const String _isoDateOrder = 'yMd';

String _systemDateOrder = _isoDateOrder;

/// Sets the order [formatDeviceOrderedNumericDate] uses, as Android's
/// `DateFormat.getDateFormatOrder` reports it for the phone's language and
/// region (e.g. "dMy"). The app's language used to decide this, which put the
/// month first for English outside the US and for languages whose date-field
/// hint doesn't use the letters d and m (#355). Anything other than one each
/// of d, M and y keeps year-month-day.
void setSystemDateOrder(String? order) {
  final bool valid =
      order != null &&
      order.length == 3 &&
      order.contains('d') &&
      order.contains('M') &&
      order.contains('y');
  _systemDateOrder = valid ? order : _isoDateOrder;
}

/// Formats a numeric date in the phone's day/month/year order, omitting the
/// year when [dateTime] falls within the current year.
String formatDeviceOrderedNumericDate(DateTime dateTime, {DateTime? now}) {
  final DateTime local = dateTime.toLocal();
  final DateTime localNow = (now ?? DateTime.now()).toLocal();
  final bool showYear = local.year != localNow.year;
  final String day = local.day.toString().padLeft(2, '0');
  final String month = local.month.toString().padLeft(2, '0');
  return [
    for (final String field in _systemDateOrder.split(''))
      if (field == 'd')
        day
      else if (field == 'M')
        month
      else if (showYear)
        '${local.year}',
  ].join('-');
}
