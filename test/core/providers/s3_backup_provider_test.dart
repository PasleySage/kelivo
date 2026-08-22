import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
// ignore: depend_on_referenced_packages
import 'package:path/path.dart' as p;
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:Kelivo/core/database/app_database.dart';
import 'package:Kelivo/core/database/business_preferences.dart';
import 'package:Kelivo/core/database/business_repository.dart';
import 'package:Kelivo/core/database/business_restore_service.dart';
import 'package:Kelivo/core/models/backup.dart';
import 'package:Kelivo/core/providers/s3_backup_provider.dart';
import 'package:Kelivo/core/services/backup/s3_client.dart';
import 'package:Kelivo/core/services/chat/chat_service.dart';

/// Minimal path_provider stub so DataSync resolves the app data directory to a
/// temp root shared by the skills storage and the S3 provider's temp dirs.
class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.root);

  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getApplicationSupportPath() async => root;

  @override
  Future<String?> getApplicationCachePath() async => '$root/cache';

  @override
  Future<String?> getTemporaryPath() async => '$root/tmp';
}

/// In-memory stand-in for an S3 bucket: it copies the uploaded ZIP into a local
/// directory and hands it back on download. SigV4 / network code is never hit,
/// so we exercise the S3BackupProvider glue (prepareBackupFile + upload,
/// download + restoreFromLocalFile) without real credentials.
class _FakeS3Client extends S3BackupClient {
  _FakeS3Client(this._bucket);

  final Directory _bucket;
  String? lastUploadedKey;

  @override
  Future<void> uploadFile(
    S3Config cfg, {
    required String key,
    required File file,
  }) async {
    lastUploadedKey = key;
    final dest = File(p.join(_bucket.path, key));
    await dest.parent.create(recursive: true);
    await file.copy(dest.path);
  }

  @override
  Future<void> downloadToFile(
    S3Config cfg, {
    required String key,
    required File destination,
  }) async {
    final src = File(p.join(_bucket.path, key));
    await destination.parent.create(recursive: true);
    await destination.writeAsBytes(await src.readAsBytes());
  }

  @override
  Future<List<BackupFileItem>> listObjects(S3Config cfg) async => const [];

  @override
  Future<void> deleteObject(S3Config cfg, {required String key}) async {
    final f = File(p.join(_bucket.path, key));
    if (await f.exists()) await f.delete();
  }

  @override
  Future<void> test(S3Config cfg) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('S3BackupProvider skills backup', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('kelivo_s3_provider_');
      PathProviderPlatform.instance = _FakePathProvider(root.path);
      PackageInfo.setMockInitialValues(
        appName: 'Kelivo',
        packageName: 'Kelivo',
        version: '1.0.0-test',
        buildNumber: '1',
        buildSignature: 'test',
      );
      SharedPreferences.setMockInitialValues({});
    });

    tearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    test('S3 backup round-trips skills directory through upload/restore', () async {
      final bucket = await Directory.systemTemp.createTemp('kelivo_s3_bucket_');
      final fakeClient = _FakeS3Client(bucket);

      // Seed a skill that must survive the S3 backup + restore cycle.
      final skillsDir = Directory('${root.path}/skills');
      await skillsDir.create(recursive: true);
      final skillFile = File('${skillsDir.path}/restore-me.json');
      await skillFile.writeAsString(
        jsonEncode({
          'id': 'restore-me',
          'name': 'Restore Me',
          'description': 'skill restored from S3 backup',
          'content': 'Be concise.',
          'triggerKeywords': <String>[],
          'createdAt': '2026-08-18T08:00:00.000Z',
          'updatedAt': '2026-08-18T08:00:00.000Z',
        }),
      );

      final database = AppDatabase.open(
        file: File('${root.path}/business.sqlite'),
      );
      final repository = BusinessRepository(database);
      try {
        await BusinessRestoreService(repository).overwrite({
          'provider_configs_v1': jsonEncode({}),
          'providers_order_v1': <String>[],
          'assistants_v1': jsonEncode([]),
        });

        final provider = S3BackupProvider(
          chatService: ChatService(),
          businessRepository: repository,
          businessPreferences: BusinessPreferences(repository),
          client: fakeClient,
          initialConfig: const S3Config(includeChats: false, includeFiles: true),
        );

        // 1) Backup uploads a ZIP that contains the skills directory.
        final uploaded = await provider.backup();
        expect(uploaded, isTrue, reason: provider.message ?? 'backup failed');
        expect(fakeClient.lastUploadedKey, isNotNull);

        final remote = File(p.join(bucket.path, fakeClient.lastUploadedKey!));
        expect(await remote.exists(), isTrue, reason: 'ZIP should be on the bucket');
        final archive = ZipDecoder().decodeBytes(await remote.readAsBytes());
        expect(
          archive.findFile('skills/restore-me.json'),
          isNotNull,
          reason: 'skills/restore-me.json must be packed into the S3 backup',
        );

        // 2) Simulate a wiped device: remove the live skills directory.
        await skillsDir.delete(recursive: true);
        expect(await Directory('${root.path}/skills').exists(), isFalse);

        // 3) Restore from the uploaded object and verify skills come back.
        final item = BackupFileItem(
          href: Uri(
            scheme: 's3',
            host: 'test-bucket',
            pathSegments: fakeClient.lastUploadedKey!.split('/'),
          ),
          displayName: fakeClient.lastUploadedKey!.split('/').last,
          size: await remote.length(),
          lastModified: null,
        );
        await provider.restoreFromItem(item, mode: RestoreMode.overwrite);

        final restored = File('${root.path}/skills/restore-me.json');
        expect(
          await restored.exists(),
          isTrue,
          reason: 'skills should be restored from the S3 backup',
        );
        final restoredJson =
            jsonDecode(await restored.readAsString()) as Map<String, dynamic>;
        expect(restoredJson['id'], 'restore-me');
        expect(restoredJson['name'], 'Restore Me');
      } finally {
        await database.close();
        if (await bucket.exists()) await bucket.delete(recursive: true);
      }
    });
  });
}
