// 更新产物的挑选契约测试。
//
// 这块逻辑横跨两边：CI 按约定命名上传（.github/workflows/build.yml 的发布作业），
// App 按同样的约定挑包。一旦对不上，用户拿到的是【装不上的包】或【源码压缩包】，
// 而且表面上一切正常——所以把名字约定钉在测试里。

import 'package:flutter_test/flutter_test.dart';

import 'package:contact_flutter/services/app_update.dart';

void main() {
  group('UpdateArtifact.matches 认得出 CI 产出的真实文件名', () {
    test('默认包：arm + arm64，不带后缀', () {
      expect(UpdateArtifact.androidArm.matches('contact_flutter_v1.0.0.apk'), isTrue);
      expect(UpdateArtifact.androidArm.matches('contact_flutter_v1.2.3.apk'), isTrue);
      // 旧命名（曾用过 _arm 后缀）也要能认出来，否则老版本的包永远挑不到
      expect(UpdateArtifact.androidArm.matches('contact_flutter_1.0.0_arm.apk'), isTrue);
    });

    test('x86_64 包：带后缀', () {
      expect(UpdateArtifact.androidX86.matches('contact_flutter_v1.0.0_x86_64.apk'), isTrue);
    });

    test('Windows 免安装包', () {
      expect(
        UpdateArtifact.windowsZip.matches('contact_flutter_windows_x64_v1.0.0.zip'),
        isTrue,
      );
    });

    test('两种 APK 不会互相认错', () {
      expect(UpdateArtifact.androidArm.matches('contact_flutter_v1.0.0_x86_64.apk'), isFalse);
      expect(UpdateArtifact.androidX86.matches('contact_flutter_v1.0.0.apk'), isFalse);
    });

    test('平台之间不会串（Android 不会拿 zip，Windows 不会拿 apk）', () {
      expect(UpdateArtifact.androidArm.matches('contact_flutter_windows_x64_v1.0.0.zip'), isFalse);
      expect(UpdateArtifact.windowsZip.matches('contact_flutter_v1.0.0.apk'), isFalse);
      expect(UpdateArtifact.windowsZip.matches('contact_flutter_v1.0.0_x86_64.apk'), isFalse);
    });

    test('平台自动附的源码归档绝不能被当成本平台的包', () {
      // GitCode 与 GitHub 都会给每个 Release 自动附上源码归档，
      // 其中就有一个与 tag 同名的 .zip —— 把它当 Windows 包下发给用户就糟了
      expect(UpdateArtifact.windowsZip.matches('v1.0.0.zip'), isFalse);
      expect(UpdateArtifact.windowsZip.matches('source.zip'), isFalse);
      expect(UpdateArtifact.windowsZip.matches('v1.0.0.tar.gz'), isFalse);

      // 显式排除 type=source 是第二道防线，两条都要在
      final assets = <Object>[
        {'name': 'v1.0.0.zip', 'type': 'source', 'browser_download_url': 'http://x/source.zip'},
        {
          'name': 'contact_flutter_windows_x64_v1.0.0.zip',
          'type': 'attach',
          'browser_download_url': 'http://x/win.zip',
        },
      ];
      expect(pickUpdateAsset(assets, UpdateArtifact.windowsZip)?.name,
          'contact_flutter_windows_x64_v1.0.0.zip');
    });

    test('大小写不敏感', () {
      expect(UpdateArtifact.windowsZip.matches('Contact_Flutter_Windows_x64_V1.0.0.ZIP'), isTrue);
      expect(UpdateArtifact.androidArm.matches('contact_flutter_v1.0.0.APK'), isTrue);
    });
  });
}
