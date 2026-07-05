import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/store_source_icons.dart';

void main() {
  const maxBundledSourceIconDimension = 40;

  test('fixed source hosts resolve to bundled icons', () {
    final expectedAssetByHost = <String, String>{
      'github.com': StoreSourceIconPaths.github,
      'gitlab.com': StoreSourceIconPaths.gitlab,
      'codeberg.org': StoreSourceIconPaths.codeberg,
      'f-droid.org': StoreSourceIconPaths.fdroid,
      'izzysoft.de': StoreSourceIconPaths.izzydroid,
      'git.sr.ht': StoreSourceIconPaths.sourcehut,
      'sourceforge.net': StoreSourceIconPaths.sourceforge,
      'itch.io': StoreSourceIconPaths.itchio,
      'example.itch.io': StoreSourceIconPaths.itchio,
      'apkpure.net': StoreSourceIconPaths.apkpure,
      'apkpure.com': StoreSourceIconPaths.apkpure,
      'apkmirror.com': StoreSourceIconPaths.apkmirror,
      'apkcombo.com': StoreSourceIconPaths.apkcombo,
      'aptoide.com': StoreSourceIconPaths.aptoide,
      'uptodown.com': StoreSourceIconPaths.uptodown,
      'appgallery.huawei.com': StoreSourceIconPaths.huaweiAppGallery,
      'appgallery.cloud.huawei.com': StoreSourceIconPaths.huaweiAppGallery,
      'sj.qq.com': StoreSourceIconPaths.tencent,
      'h5.appstore.vivo.com.cn': StoreSourceIconPaths.vivoAppStore,
      'h5coml.vivo.com.cn': StoreSourceIconPaths.vivoAppStore,
      'rustore.ru': StoreSourceIconPaths.rustore,
      'apk4free.net': StoreSourceIconPaths.apk4free,
      'farsroid.com': StoreSourceIconPaths.farsroid,
      'www.coolapk.com': StoreSourceIconPaths.coolapk,
      'api2.coolapk.com': StoreSourceIconPaths.coolapk,
      'rockmods.net': StoreSourceIconPaths.rockmods,
      'liteapks.com': StoreSourceIconPaths.liteapks,
      'telegram.org': StoreSourceIconPaths.telegram,
      'neutroncode.com': StoreSourceIconPaths.neutroncode,
      'mullvad.net': StoreSourceIconPaths.mullvad,
    };

    for (final entry in expectedAssetByHost.entries) {
      final assetPath = storeSourceAssetPathForHost(entry.key);
      expect(assetPath, entry.value, reason: entry.key);
      expect(File(assetPath!).existsSync(), isTrue, reason: assetPath);
      final dimensions = _pngDimensions(File(assetPath).readAsBytesSync());
      expect(
        dimensions.width <= maxBundledSourceIconDimension,
        isTrue,
        reason: assetPath,
      );
      expect(
        dimensions.height <= maxBundledSourceIconDimension,
        isTrue,
        reason: assetPath,
      );
    }

    expect(
      storeSourceAssetPathForClassName('ItchIO'),
      StoreSourceIconPaths.itchio,
    );
  });

  test('custom hosts do not resolve to bundled icons', () {
    expect(storeSourceAssetPathForHost('example.com'), isNull);
  });
}

({int width, int height}) _pngDimensions(Uint8List bytes) {
  expect(bytes.length, greaterThanOrEqualTo(24));
  expect(bytes[0], 0x89);
  expect(bytes[1], 0x50);
  expect(bytes[2], 0x4E);
  expect(bytes[3], 0x47);
  return (
    width: _readBigEndianInt32(bytes, 16),
    height: _readBigEndianInt32(bytes, 20),
  );
}

int _readBigEndianInt32(Uint8List bytes, int offset) {
  return bytes[offset] << 24 |
      bytes[offset + 1] << 16 |
      bytes[offset + 2] << 8 |
      bytes[offset + 3];
}
