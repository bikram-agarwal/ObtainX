import 'package:obtainium/app_distribution.dart';

import 'main.dart' as m;

void main() async {
  AppDistribution.fdroid = true;
  m.main();
}
