import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:Kelivo/core/models/skill.dart';
import 'package:Kelivo/core/services/skills/skill_file_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SkillFileStorage keychain secrets (S4)', () {
    late Directory dir;
    late SkillFileStorage storage;

    setUp(() {
      // Route FlutterSecureStorage through an in-memory mock for tests.
      FlutterSecureStorage.setMockInitialValues({});
      dir = Directory.systemTemp.createTempSync('skill_kc_');
      storage = SkillFileStorage(dir);
    });

    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    Skill makeSkill(String id, String content) => Skill(
          id: id,
          name: 'Test',
          content: content,
          createdAt: DateTime(2026, 1, 1),
          updatedAt: DateTime(2026, 1, 1),
        );

    test('save stores secret in keychain and leaves placeholder in JSON', () async {
      final secret = 'sk-ABCDEFGHIJKLMNOPQRSTUVWXYZ12'; // matches sk- pattern
      final skill = makeSkill('s1', 'my key is $secret please use it');
      await storage.save(skill);

      final file = File(p.join(dir.path, 's1.json'));
      final json =
          (jsonDecode(await file.readAsString()) as Map).cast<String, dynamic>();
      expect(json['content'], contains('__KELIVO_SKILL_SECRET_0__'));
      expect(json['content'], isNot(contains(secret)));

      final vault = await const FlutterSecureStorage().readAll();
      expect(vault['kelivo_skill::s1::secret::0'], secret);
    });

    test('load restores secret from keychain', () async {
      final secret = 'AIzaSyA1234567890abcdefghijklmnopqrstuvwxyz'; // 35 chars
      final skill = makeSkill('s2', 'token=$secret end');
      await storage.save(skill);

      final loaded = (await storage.loadAll()).first;
      expect(loaded.content, contains(secret));
      expect(loaded.content, isNot(contains('__KELIVO_SKILL_SECRET_')));
    });

    test('multiple secrets are indexed and restored independently', () async {
      final s1 = 'sk-ABCDEFGHIJKLMNOPQRSTUVWXYZab';
      final s2 = 'ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
      final skill = makeSkill('s3', 'first $s1 second $s2 done');
      await storage.save(skill);

      final loaded = (await storage.loadAll()).first;
      expect(loaded.content, contains(s1));
      expect(loaded.content, contains(s2));

      final vault = await const FlutterSecureStorage().readAll();
      expect(vault['kelivo_skill::s3::secret::0'], s1);
      expect(vault['kelivo_skill::s3::secret::1'], s2);
    });

    test('overwrite clears old secrets before writing new ones', () async {
      final oldSecret = 'sk-OLDSECRETABCDEFGHIJKLMNOPQRSTUVWXY';
      await storage.save(makeSkill('s4', 'old=$oldSecret'));
      final newSecret = 'sk-NEWSECRETABCDEFGHIJKLMNOPQRSTUVWXY';
      await storage.save(makeSkill('s4', 'new=$newSecret'));

      final loaded = (await storage.loadAll()).first;
      expect(loaded.content, contains(newSecret));
      expect(loaded.content, isNot(contains(oldSecret)));

      final vault = await const FlutterSecureStorage().readAll();
      expect(vault['kelivo_skill::s4::secret::0'], newSecret);
      expect(vault.containsKey('kelivo_skill::s4::secret::0'), isTrue);
      // No stale index should remain from the previous save.
      final stale = vault.keys
          .where((k) => k.startsWith('kelivo_skill::s4::'))
          .where((k) => k != 'kelivo_skill::s4::secret::0')
          .toList();
      expect(stale, isEmpty);
    });

    test('delete clears keychain entries', () async {
      final secret = 'sk-DELETESECRETABCDEFGHIJKLMNOPQRSTUVWX';
      await storage.save(makeSkill('s5', 'key=$secret'));
      await storage.delete('s5');

      final vault = await const FlutterSecureStorage().readAll();
      expect(vault.keys.any((k) => k.startsWith('kelivo_skill::s5::')), isFalse);
      expect(File(p.join(dir.path, 's5.json')).existsSync(), isFalse);
    });

    test('skill without secrets is stored verbatim (no placeholders)', () async {
      final skill = makeSkill('s6', 'just plain instructions, no keys');
      await storage.save(skill);
      final loaded = (await storage.loadAll()).first;
      expect(loaded.content, 'just plain instructions, no keys');

      final vault = await const FlutterSecureStorage().readAll();
      expect(vault.keys.any((k) => k.startsWith('kelivo_skill::s6::')), isFalse);
    });

    test('secretCount is persisted in the skill JSON (#4)', () async {
      final s1 = 'sk-ABCDEFGHIJKLMNOPQRSTUVWXYZab';
      final s2 = 'ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
      await storage.save(makeSkill('s8', 'first $s1 second $s2'));

      final raw = await File(p.join(dir.path, 's8.json')).readAsString();
      final json = (jsonDecode(raw) as Map).cast<String, dynamic>();
      expect(json['secretCount'], 2);
    });

    test('skill with an unrestorable keychain secret is skipped on load (#2)',
        () async {
      final secret = 'sk-ABCDEFGHIJKLMNOPQRSTUVWXYZ12';
      await storage.save(makeSkill('s7', 'key=$secret'));
      // Simulate the OS keychain entry going missing (cleared / locked).
      await const FlutterSecureStorage().delete(
        key: 'kelivo_skill::s7::secret::0',
      );

      final loaded = await storage.loadAll();
      // The placeholder must never reach the model, so the broken skill is
      // dropped rather than returned with an unresolved placeholder.
      expect(loaded.any((s) => s.id == 's7'), isFalse);
    });
  });
}
