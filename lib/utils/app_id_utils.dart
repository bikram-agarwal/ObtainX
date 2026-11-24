import 'package:obtainium/models/app.dart';

bool isValidAppId(String appId) {
  if (appId.isEmpty || appId.length > 255) return false;
  if (appId.contains('/') || appId.contains('\\') || appId.contains('\x00')) {
    return false;
  }
  return appId != '.' && appId != '..';
}

/// Whether [app]'s IDs are safe to name files with.
///
/// ObtainX (v1.7.5 sync D-01): a record is stored as `<listing key>.json`, its
/// APKs as `<listing key>-…`, and its icons as `<package ID>.png`. A backup can
/// carry the listing key (`listingId`) as well as the package ID, so both are
/// checked. Upstream names files after the package ID alone and checks only
/// that.
bool hasSafeStorageIds(App app) =>
    isValidAppId(app.id) && isValidAppId(app.listingKey);
