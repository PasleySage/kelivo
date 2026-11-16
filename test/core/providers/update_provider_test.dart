import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:Kelivo/core/providers/update_provider.dart';

String _feed({
  required String version,
  required int build,
  Map<String, String> downloads = const {},
}) =>
    jsonEncode({
      'app': 'KelivoMeow',
      'latest': {
        'version': version,
        'build': build,
        'releasedAt': '2026-11-16T00:00:00Z',
        'notes': 'test notes',
        'downloads': downloads,
      },
    });

Future<PackageInfo> _pkg(String version) async {
  PackageInfo.setMockInitialValues(
    appName: 'KelivoMeow',
    packageName: 'com.psyche.kelivomeow.app',
    version: version,
    buildNumber: '85',
    buildSignature: 'test',
  );
  return PackageInfo.fromPlatform();
}

void main() {
  group('isRemoteNewer', () {
    test('compares x.y.z only and ignores build metadata', () {
      expect(isRemoteNewer(remoteVersion: '1.3.6', currentVersion: '1.3.5'), isTrue);
      expect(isRemoteNewer(remoteVersion: '1.4.0', currentVersion: '1.3.9'), isTrue);
      expect(isRemoteNewer(remoteVersion: '2.0.0', currentVersion: '1.9.9'), isTrue);
      expect(isRemoteNewer(remoteVersion: '1.3.5', currentVersion: '1.3.5'), isFalse);
      expect(isRemoteNewer(remoteVersion: '1.2.6', currentVersion: '1.3.5'), isFalse);
      expect(isRemoteNewer(remoteVersion: '1.3.4', currentVersion: '1.3.5'), isFalse);
    });
  });

  test('self update.json: notice shown and Android keeps direct APK link', () async {
    const apk = 'https://github.com/PasleySage/kelivo/releases/download/v1.3.6-meow.1/KelivoMeow_android_1.3.6%2B88.apk';
    final client = MockClient((req) async {
      if (req.url.path.contains('update.json') &&
          req.url.host == 'github.com') {
        return http.Response(
          _feed(version: '1.3.6', build: 88, downloads: {'android': apk}),
          200,
        );
      }
      return http.Response('not found', 404);
    });
    final provider = UpdateProvider(
      httpClient: client,
      packageInfoLoader: () => _pkg('1.3.5'),
    );
    addTearDown(provider.dispose);

    await provider.checkForUpdates();

    expect(provider.error, isNull);
    expect(provider.available, isNotNull);
    expect(provider.available!.version, '1.3.6');
    // The whole point of this change: a real APK link, not the releases page.
    // Assert the android entry directly — bestDownloadUrl() is platform-gated
    // and these tests run on the host, not on Android.
    expect(provider.available!.downloads['android'], apk);
  });

  test('self feed missing: falls back upstream but never sends user to official Kelivo', () async {
    final client = MockClient((req) async {
      if (req.url.host == 'kelivo.psycheas.top') {
        return http.Response(
          _feed(
            version: '1.3.6',
            build: 88,
            downloads: {'android': 'https://kelivo.psycheas.top/downloads'},
          ),
          200,
        );
      }
      return http.Response('not found', 404);
    });
    final provider = UpdateProvider(
      httpClient: client,
      packageInfoLoader: () => _pkg('1.3.5'),
    );
    addTearDown(provider.dispose);

    await provider.checkForUpdates();

    expect(provider.error, isNull);
    expect(provider.available, isNotNull);
    expect(provider.available!.downloads['android'], selfReleasesUrl);
  });

  test('upstream fallback still respects version comparison (old 1.2.6 is ignored)', () async {
    final client = MockClient((req) async {
      if (req.url.host == 'kelivo.psycheas.top') {
        return http.Response(_feed(version: '1.2.6', build: 73), 200);
      }
      return http.Response('not found', 404);
    });
    final provider = UpdateProvider(
      httpClient: client,
      packageInfoLoader: () => _pkg('1.3.5'),
    );
    addTearDown(provider.dispose);

    await provider.checkForUpdates();

    expect(provider.error, isNull);
    expect(provider.available, isNull);
  });

  test('already on newest version: no notice even though feed is reachable', () async {
    final client = MockClient((req) async {
      return http.Response(
        _feed(version: '1.3.6', build: 88, downloads: {'android': 'x'}),
        200,
      );
    });
    final provider = UpdateProvider(
      httpClient: client,
      packageInfoLoader: () => _pkg('1.3.6'),
    );
    addTearDown(provider.dispose);

    await provider.checkForUpdates();

    expect(provider.available, isNull);
  });
}
