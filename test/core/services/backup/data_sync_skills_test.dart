import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:Kelivo/core/database/app_database.dart';
import 'package:Kelivo/core/database/business_repository.dart';
import 'package:Kelivo/core/database/business_restore_service.dart';
import 'package:Kelivo/core/models/backup.dart';
import 'package:Kelivo/core/services/backup/data_sync.dart';
import 'package:Kelivo/core/services/chat/chat_service.dart';

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DataSync skills backup', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('kelivo_data_sync_skills_');
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

    test(
      'includes skills directory in backup when includeFiles is true',
      () async {
        // Arrange: write a skill file into the app data skills directory.
        final skillsDir = Directory('${root.path}/skills');
        await skillsDir.create(recursive: true);
        final skillFile = File('${skillsDir.path}/test-skill.json');
        await skillFile.writeAsString(
          jsonEncode({
            'id': 'test-skill',
            'name': 'Test Skill',
            'description': 'A skill used in backup tests',
            'content': 'Always answer in rhyme.',
            'triggerKeywords': ['rhyme'],
            'createdAt': '2026-08-17T10:00:00.000Z',
            'updatedAt': '2026-08-17T10:00:00.000Z',
          }),
        );

        final database = AppDatabase.open(
          file: File('${root.path}/business.sqlite'),
        );
        final repository = BusinessRepository(database);
        File? backup;
        try {
          await BusinessRestoreService(repository).overwrite({
            'provider_configs_v1': jsonEncode({}),
            'providers_order_v1': <String>[],
            'assistants_v1': jsonEncode([]),
          });

          backup =
              await DataSync(
                chatService: ChatService(),
                businessRepository: repository,
              ).prepareBackupFile(
                const WebDavConfig(includeChats: false, includeFiles: true),
              );

          final archive = ZipDecoder().decodeBytes(await backup.readAsBytes());
          final skillEntry = archive.findFile('skills/test-skill.json');
          expect(
            skillEntry,
            isNotNull,
            reason: 'skills/test-skill.json should be in backup',
          );
          final restoredContent =
              jsonDecode(utf8.decode(skillEntry!.readBytes()!))
                  as Map<String, dynamic>;
          expect(restoredContent['id'], 'test-skill');
          expect(restoredContent['name'], 'Test Skill');

          final manifestEntry = archive.findFile('manifest.json');
          expect(manifestEntry, isNotNull);
          final manifest =
              jsonDecode(utf8.decode(manifestEntry!.readBytes()!))
                  as Map<String, dynamic>;
          final entries = manifest['entries'] as Map<String, dynamic>;
          expect(entries.containsKey('skills/test-skill.json'), isTrue);
          expect(
            (entries['skills/test-skill.json']
                as Map<String, dynamic>)['bytes'],
            await skillFile.length(),
          );
        } finally {
          await DataSync.cleanupTemporaryBackupFile(backup);
          await database.close();
        }
      },
    );

    test(
      'does not include skills directory when includeFiles is false',
      () async {
        final skillsDir = Directory('${root.path}/skills');
        await skillsDir.create(recursive: true);
        await File(
          '${skillsDir.path}/ignored.json',
        ).writeAsString('{"id":"ignored"}');

        final database = AppDatabase.open(
          file: File('${root.path}/business.sqlite'),
        );
        final repository = BusinessRepository(database);
        File? backup;
        try {
          await BusinessRestoreService(repository).overwrite({
            'provider_configs_v1': jsonEncode({}),
            'providers_order_v1': <String>[],
            'assistants_v1': jsonEncode([]),
          });

          backup =
              await DataSync(
                chatService: ChatService(),
                businessRepository: repository,
              ).prepareBackupFile(
                const WebDavConfig(includeChats: false, includeFiles: false),
              );

          final archive = ZipDecoder().decodeBytes(await backup.readAsBytes());
          expect(archive.findFile('skills/ignored.json'), isNull);

          final manifestEntry = archive.findFile('manifest.json')!;
          final manifest =
              jsonDecode(utf8.decode(manifestEntry.readBytes()!))
                  as Map<String, dynamic>;
          final entries = manifest['entries'] as Map<String, dynamic>;
          expect(entries.containsKey('skills/ignored.json'), isFalse);
        } finally {
          await DataSync.cleanupTemporaryBackupFile(backup);
          await database.close();
        }
      },
    );

    test('restores skills directory from a local backup (no chats)', () async {
      // Arrange: seed a skill that must survive a full restore cycle.
      final skillsDir = Directory('${root.path}/skills');
      await skillsDir.create(recursive: true);
      final skillFile = File('${skillsDir.path}/restore-me.json');
      await skillFile.writeAsString(
        jsonEncode({
          'id': 'restore-me',
          'name': 'Restore Me',
          'description': 'skill restored from backup',
          'content': 'Be terse.',
          'triggerKeywords': <String>[],
          'createdAt': '2026-08-17T11:00:00.000Z',
          'updatedAt': '2026-08-17T11:00:00.000Z',
        }),
      );

      final database = AppDatabase.open(
        file: File('${root.path}/business.sqlite'),
      );
      final repository = BusinessRepository(database);
      File? backup;
      try {
        await BusinessRestoreService(repository).overwrite({
          'provider_configs_v1': jsonEncode({}),
          'providers_order_v1': <String>[],
          'assistants_v1': jsonEncode([]),
        });

        final dataSync = DataSync(
          chatService: ChatService(),
          businessRepository: repository,
        );
        backup = await dataSync.prepareBackupFile(
          const WebDavConfig(includeChats: false, includeFiles: true),
        );

        // Simulate a wiped device: remove the live skills directory.
        await skillsDir.delete(recursive: true);
        expect(await Directory('${root.path}/skills').exists(), isFalse);

        await dataSync.restoreFromLocalFile(
          backup,
          const WebDavConfig(includeChats: false, includeFiles: true),
        );

        final restored = File('${root.path}/skills/restore-me.json');
        expect(
          await restored.exists(),
          isTrue,
          reason: 'skills should be restored from backup',
        );
        final restoredJson =
            jsonDecode(await restored.readAsString()) as Map<String, dynamic>;
        expect(restoredJson['id'], 'restore-me');
        expect(restoredJson['name'], 'Restore Me');
      } finally {
        await DataSync.cleanupTemporaryBackupFile(backup);
        await database.close();
      }
    });
  });
}
