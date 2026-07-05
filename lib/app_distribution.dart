class AppDistribution {
  AppDistribution._();

  static bool fdroid = false;

  static bool get allowDuckDuckGoFavicons => !fdroid;
}
