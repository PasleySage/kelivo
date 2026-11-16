import 'dart:convert';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

/// KelivoMeow publishes its own releases here. The Android entry is a direct
/// APK download link so tapping the in-app update banner can hand a real
/// installable file to the browser / package installer.
const String selfReleasesUrl = 'https://github.com/PasleySage/kelivo/releases';

/// update.json is shipped as a Release asset. `latest/download` always points
/// at the newest release, so publishing a new release is the only step needed
/// to roll out an update notice — no separate hosting.
const String selfUpdateUrl =
    'https://github.com/PasleySage/kelivo/releases/latest/download/update.json';

/// Upstream feed is kept only as a fallback. Its downloads all point at the
/// official Kelivo site, so we rewrite them to our own releases page.
const String upstreamUpdateUrl = 'https://kelivo.psycheas.top/update.json';

/// Compare only the semantic x.y.z part; internal build numbers are ignored.
bool isRemoteNewer({
  required String remoteVersion,
  required String currentVersion,
}) {
  List<int> parseVer(String v) {
    final parts = v.split('.');
    final nums = <int>[];
    for (int i = 0; i < 3; i++) {
      nums.add(i < parts.length ? int.tryParse(parts[i]) ?? 0 : 0);
    }
    return nums;
  }

  final a = parseVer(remoteVersion);
  final b = parseVer(currentVersion);
  for (var i = 0; i < 3; i++) {
    if (a[i] != b[i]) return a[i] > b[i];
  }
  return false;
}

class UpdateInfo {
  final String app;
  final String version;
  final int? build;
  final DateTime? releasedAt;
  final String? notes;
  final bool mandatory;
  final Map<String, String> downloads;

  const UpdateInfo({
    required this.app,
    required this.version,
    this.build,
    this.releasedAt,
    this.notes,
    this.mandatory = false,
    this.downloads = const {},
  });

  String? bestDownloadUrl() {
    if (Platform.isIOS) {
      return downloads['ios'] ??
          downloads['iosAppStore'] ??
          downloads['universal'];
    }
    if (Platform.isAndroid) {
      return downloads['android'] ?? downloads['universal'];
    }
    if (Platform.isMacOS) {
      return downloads['macos'] ??
          downloads['mac'] ??
          downloads['darwin'] ??
          downloads['universal'];
    }
    if (Platform.isWindows) {
      return downloads['windows'] ?? downloads['win'] ?? downloads['universal'];
    }
    if (Platform.isLinux) {
      return downloads['linux'] ?? downloads['universal'];
    }
    return downloads['universal'] ?? downloads['android'] ?? downloads['ios'];
  }

  factory UpdateInfo.fromJson(Map<String, dynamic> json) {
    final latest = (json['latest'] as Map?) ?? const {};
    final downloads =
        (latest['downloads'] as Map?)?.map(
          (k, v) => MapEntry(k.toString(), v.toString()),
        ) ??
        const {};
    DateTime? released;
    final releasedRaw = latest['releasedAt']?.toString();
    if (releasedRaw != null && releasedRaw.isNotEmpty) {
      try {
        released = DateTime.parse(releasedRaw);
      } catch (_) {}
    }
    return UpdateInfo(
      app: (json['app'] ?? '').toString(),
      version: (latest['version'] ?? '').toString(),
      build: int.tryParse((latest['build'] ?? '').toString()),
      releasedAt: released,
      notes: (latest['notes'] ?? '').toString(),
      mandatory: (latest['mandatory'] as bool?) ?? false,
      downloads: downloads,
    );
  }

  /// Our own update.json carries direct asset links. Any platform the feed
  /// forgot falls back to the releases landing page so the banner still works.
  UpdateInfo withSelfDownloads() {
    final merged = <String, String>{
      'windows': selfReleasesUrl,
      'android': selfReleasesUrl,
      'macos': selfReleasesUrl,
      'linux': selfReleasesUrl,
      'ios': selfReleasesUrl,
    };
    for (final entry in downloads.entries) {
      if (entry.value.trim().isNotEmpty) merged[entry.key] = entry.value;
    }
    return UpdateInfo(
      app: 'KelivoMeow',
      version: version,
      build: build,
      releasedAt: releasedAt,
      notes: notes,
      mandatory: mandatory,
      downloads: merged,
    );
  }

  /// Upstream feed downloads point at the official Kelivo site — never let a
  /// KelivoMeow user land there. Rewrite every platform to our own releases.
  UpdateInfo rewrittenToSelfReleases() => UpdateInfo(
        app: 'KelivoMeow',
        version: version,
        build: build,
        releasedAt: releasedAt,
        notes: notes,
        mandatory: mandatory,
        downloads: const {
          'windows': selfReleasesUrl,
          'android': selfReleasesUrl,
          'macos': selfReleasesUrl,
          'linux': selfReleasesUrl,
          'ios': selfReleasesUrl,
        },
      );
}

class UpdateProvider extends ChangeNotifier {
  final http.Client _httpClient;
  final Future<PackageInfo> Function() _packageInfoLoader;

  UpdateProvider({
    http.Client? httpClient,
    Future<PackageInfo> Function()? packageInfoLoader,
  })  : _httpClient = httpClient ?? http.Client(),
        _packageInfoLoader = packageInfoLoader ?? PackageInfo.fromPlatform;

  UpdateInfo? _available;
  UpdateInfo? get available => _available;
  bool _checking = false;
  bool get checking => _checking;
  String? _error;
  String? get error => _error;

  Future<UpdateInfo?> _fetch(Uri url) async {
    final resp = await _httpClient.get(url);
    if (resp.statusCode != 200) {
      throw Exception('HTTP ${resp.statusCode}');
    }
    final data = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    final info = UpdateInfo.fromJson(data);
    if (info.version.isEmpty) throw const FormatException('missing version');
    return info;
  }

  Future<void> checkForUpdates() async {
    if (_checking) return;
    _checking = true;
    _error = null;
    notifyListeners();
    try {
      final ts = DateTime.now().millisecondsSinceEpoch;
      final pkg = await _packageInfoLoader();
      final currentVer = pkg.version; // e.g., 1.3.5

      final uri = Uri.parse('$selfUpdateUrl?ts=$ts');
      bool fromSelf = true;
      UpdateInfo raw;
      try {
        raw = (await _fetch(uri))!;
      } catch (_) {
        // Release asset missing (e.g. first-ever release) or offline CDN:
        // fall back to upstream feed for the version notice only.
        raw = (await _fetch(Uri.parse('$upstreamUpdateUrl?ts=$ts')))!;
        fromSelf = false;
      }

      final info = fromSelf
          ? raw.withSelfDownloads()
          : raw.rewrittenToSelfReleases();

      _available = isRemoteNewer(
              remoteVersion: info.version, currentVersion: currentVer)
          ? info
          : null;
    } catch (e) {
      _error = e.toString();
    } finally {
      _checking = false;
      notifyListeners();
    }
  }
}
