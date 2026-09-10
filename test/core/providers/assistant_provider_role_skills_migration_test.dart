import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:Kelivo/core/providers/assistant_provider.dart';

import '../../support/business_preferences_test_harness.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.path);

  final String path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;

  @override
  Future<String?> getApplicationSupportPath() async => path;

  @override
  Future<String?> getApplicationCachePath() async => '$path/cache';

  @override
  Future<String?> getTemporaryPath() async => '$path/tmp';
}

Future<AssistantProvider> _loadedProvider({
  required BusinessPreferencesTestSession session,
  required List<Map<String, Object?>> assistants,
}) async {
  await session.preferences.setString('assistants_v1', jsonEncode(assistants));
  final provider = AssistantProvider(preferences: session.preferences);
  for (var i = 0; i < 25; i++) {
    if (provider.assistants.length == assistants.length) return provider;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  return provider;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late PathProviderPlatform previousPathProvider;
  late BusinessPreferencesTestHarness harness;
  late BusinessPreferencesTestSession session;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'kelivo_role_skills_migration_test_',
    );
    previousPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir.path);
    harness = await BusinessPreferencesTestHarness.create();
    session = await harness.open();
  });

  tearDown(() async {
    PathProviderPlatform.instance = previousPathProvider;
    await harness.dispose();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test(
    'moves legacy skillIds bindings into roleSkillIds on first load',
    () async {
      final provider = await _loadedProvider(
        session: session,
        assistants: const [
          {
            'id': 'assistant-a',
            'name': 'Assistant A',
            'skillIds': ['shalom', 'selin'],
          },
        ],
      );

      expect(provider.assistants.single.roleSkillIds, ['shalom', 'selin']);
      // The one-shot flag is persisted so the migration never runs twice.
      expect(
        session.preferences.getBool('kelivomeow_role_skills_migrated_v1'),
        isTrue,
      );
    },
  );

  test(
    'does not mistake workspace skill bindings for role skills once migrated',
    () async {
      // Simulates the post-merge layout: upstream stores workspace bindings
      // under `skillIds`, role bindings live in `roleSkillIds`.
      await session.preferences.setBool(
        'kelivomeow_role_skills_migrated_v1',
        true,
      );
      final provider = await _loadedProvider(
        session: session,
        assistants: const [
          {
            'id': 'assistant-a',
            'name': 'Assistant A',
            'skillIds': ['workspace-skill'],
          },
        ],
      );

      expect(provider.assistants.single.roleSkillIds, isEmpty);
    },
  );

  test('keeps existing roleSkillIds untouched', () async {
    final provider = await _loadedProvider(
      session: session,
      assistants: const [
        {
          'id': 'assistant-a',
          'name': 'Assistant A',
          'roleSkillIds': ['mine'],
          'skillIds': ['legacy'],
        },
      ],
    );

    expect(provider.assistants.single.roleSkillIds, ['mine']);
  });
}
