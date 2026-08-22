import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/models/skill.dart';
import 'package:Kelivo/core/providers/skill_provider.dart';
import 'package:Kelivo/core/services/skills/skill_file_storage.dart';
import 'package:Kelivo/core/services/skills/skill_prompt_builder.dart';

Skill _skill({
  String id = 's1',
  String name = 'N',
  String description = 'D',
  String content = 'C',
  List<String> triggerKeywords = const <String>[],
  bool enabled = true,
}) =>
    Skill(
      id: id,
      name: name,
      description: description,
      content: content,
      triggerKeywords: triggerKeywords,
      enabled: enabled,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    );

Directory _tempDir() => Directory.systemTemp.createTempSync('mumukelivo_skill_test_');

List<int> _zipWithEntries(Map<String, List<int>> entries) {
  final archive = Archive();
  entries.forEach((name, bytes) {
    archive.addFile(ArchiveFile(name, bytes.length, Uint8List.fromList(bytes)));
  });
  return ZipEncoder().encodeBytes(archive);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late SkillFileStorage storage;
  late SkillProvider provider;

  setUp(() {
    tempDir = _tempDir();
    storage = SkillFileStorage(tempDir);
  });

  tearDown(() {
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {
      // best-effort cleanup
    }
  });

  group('Skill.decodeList degradation', () {
    test('returns empty list on invalid input instead of throwing', () {
      expect(Skill.decodeList('<<<not json<<<'), isEmpty);
      expect(Skill.decodeList(''), isEmpty);
      expect(Skill.decodeList('null'), isEmpty);
      expect(Skill.decodeList('{"id":1}'), isEmpty); // object, not a list
      expect(Skill.decodeList('[1,2,3]'), isEmpty); // list of non-maps
    });
  });

  group('buildSkillSystemText (pure, S1/P4)', () {
    test('returns null when there are no skills', () {
      expect(buildSkillSystemText(<Skill>[]), isNull);
    });

    test('wraps each skill and adds the follow-instructions meta instruction', () {
      final text = buildSkillSystemText(<Skill>[_skill()])!;
      expect(text, contains('Follow them when relevant to the task'));
      expect(text, contains('<SKILL name="N">'));
      expect(text, contains('</SKILL>'));
      expect(text, contains('Description: D'));
      expect(text, contains('C'));
    });

    test('escapes XML-significant characters so injected text cannot break out', () {
      final text = buildSkillSystemText(<Skill>[
        _skill(name: 'A&B <x> "y"', content: '<script> & "q"'),
      ])!;
      expect(text, isNot(contains('<script>')));
      expect(text, contains('&lt;script&gt;'));
      expect(text, contains('&amp;'));
      expect(text, contains('&quot;'));
    });

    test('truncates content past the per-skill cap and bounds the total block', () {
      // Per-skill cap is 40000; total cap is 60000. A 42000-char skill must be
      // cut down to the per-skill cap.
      final long = 'z' * 42000;
      final text = buildSkillSystemText(<Skill>[_skill(content: long)])!;
      expect(text, contains('[truncated]'));
      expect(text.length, lessThanOrEqualTo(40500));
    });

    test('bounds the total block when multiple large skills exceed the cap', () {
      final text = buildSkillSystemText(<Skill>[
        _skill(content: 'a' * 40000),
        _skill(content: 'b' * 40000),
      ])!;
      expect(text, contains('[truncated]'));
      expect(text.length, lessThanOrEqualTo(60200));
    });
  });

  group('SkillFileStorage incremental I/O (P1)', () {
    test('save writes one file per skill and loadAll reads it back', () async {
      await storage.save(_skill(id: 'abc', name: 'N', content: 'hello'));
      final file = File('${tempDir.path}/abc.json');
      expect(await file.exists(), isTrue);
      final loaded = await storage.loadAll();
      expect(loaded.length, 1);
      expect(loaded.first.content, 'hello');
    });

    test('delete removes only that skill file', () async {
      await storage.save(_skill(id: 'a'));
      await storage.save(_skill(id: 'b'));
      await storage.delete('a');
      expect(await File('${tempDir.path}/a.json').exists(), isFalse);
      expect(await File('${tempDir.path}/b.json').exists(), isTrue);
    });

    test('corrupt file is skipped while valid files still load (G2)', () async {
      await File('${tempDir.path}/good.json')
          .writeAsString(jsonEncode(_skill(id: 'g', name: 'G').toJson()));
      await File('${tempDir.path}/bad.json').writeAsString('<<<not json');
      final loaded = await storage.loadAll();
      expect(loaded.length, 1);
      expect(loaded.first.id, 'g');
    });

    test('unsafe id is hashed into a safe filename contained in the dir', () async {
      await storage.save(_skill(id: '../../etc/passwd'));
      final files = tempDir.listSync().whereType<File>().toList();
      expect(files.length, 1);
      expect(files.first.parent.path, tempDir.path); // never escapes the dir
    });
  });

  group('SkillProvider incremental persist (P1)', () {
    test('addSkill persists a file and deleteSkill removes it', () async {
      provider = SkillProvider(storage);
      await provider.initialize();
      final id = await provider.addSkill(name: 'X', content: 'c');
      expect(await File('${tempDir.path}/$id.json').exists(), isTrue);
      await provider.deleteSkill(id);
      expect(await File('${tempDir.path}/$id.json').exists(), isFalse);
      expect(provider.skills, isEmpty);
    });

    test('updateSkill rewrites the same file in place', () async {
      provider = SkillProvider(storage);
      await provider.initialize();
      final id = await provider.addSkill(name: 'X', content: 'old');
      final before = await File('${tempDir.path}/$id.json').readAsString();
      await provider.updateSkill(provider.getById(id)!.copyWith(content: 'new'));
      final after = await File('${tempDir.path}/$id.json').readAsString();
      expect(after, isNot(equals(before)));
      expect(after, contains('"content":"new"'));
    });

    test('importManyFromBytes writes one file per imported skill', () async {
      provider = SkillProvider(storage);
      await provider.initialize();
      final zip = _zipWithEntries(<String, List<int>>{
        'skills/skillA.md': utf8.encode('# Skill A\nbody A'),
        'skills/skillB.md': utf8.encode('# Skill B\nbody B'),
      });
      final imported = await provider.importManyFromBytes(
        bytes: zip,
        fileName: 'pack.zip',
      );
      expect(imported.length, 2);
      expect(tempDir.listSync().whereType<File>().length, 2);
    });
  });

  group('SkillProvider graceful degradation (G2)', () {
    test('broken store file never throws and keeps the provider usable', () async {
      await File('${tempDir.path}/broken.json').writeAsString('<<<corrupted<<<');
      provider = SkillProvider(storage);
      await provider.initialize();
      expect(provider.initialized, isTrue);
      expect(provider.skills, isEmpty);
      // Core flow still works instead of crashing.
      expect(provider.resolveActiveSkills(explicitSkillIds: const <String>[]), isEmpty);
      expect(provider.getById('nope'), isNull);
    });

    test('loads valid store files into the skill list', () async {
      await storage.save(_skill(id: 's1', name: 'N'));
      provider = SkillProvider(storage);
      await provider.initialize();
      expect(provider.skills.length, 1);
      expect(provider.skills.first.name, 'N');
    });

    test('resolveActiveSkills is safe on an empty provider', () async {
      provider = SkillProvider(storage);
      await provider.initialize();
      expect(
        provider.resolveActiveSkills(
          explicitSkillIds: const <String>['missing'],
          latestUserMessage: 'anything',
        ),
        isEmpty,
      );
    });

    test('explicitly bound skill is injected even when globally disabled', () async {
      await storage.save(_skill(id: 's1', name: 'Bound', enabled: false));
      provider = SkillProvider(storage);
      await provider.initialize();
      final resolved = provider.resolveActiveSkills(
        explicitSkillIds: const <String>['s1'],
        latestUserMessage: 'anything',
      );
      expect(resolved.length, 1);
      expect(resolved.first.id, 's1');
    });

    test('globally disabled skill is not keyword-triggered implicitly', () async {
      await storage.save(
        _skill(id: 's1', name: 'Off', enabled: false, triggerKeywords: const ['hello']),
      );
      provider = SkillProvider(storage);
      await provider.initialize();
      final resolved = provider.resolveActiveSkills(
        explicitSkillIds: const <String>[],
        latestUserMessage: 'hello world',
      );
      expect(resolved, isEmpty);
    });
  });

  group('Zip import safety (S2)', () {
    test('per-entry size guard skips oversized files but keeps valid ones', () async {
      final big = List<int>.filled(6 * 1024 * 1024, 0x20); // 6 MB > 5 MB guard
      final zip = _zipWithEntries(<String, List<int>>{
        'big.md': big,
        'skill.md': utf8.encode('# Real\nvalid skill'),
      });
      provider = SkillProvider(storage);
      await provider.initialize();
      final imported = await provider.importManyFromBytes(
        bytes: zip,
        fileName: 'p.zip',
      );
      expect(imported.length, 1);
      expect(imported.first.name, 'Real');
    });

    test('archive over total decompression budget throws', () async {
      final entries = <String, List<int>>{};
      for (var i = 0; i < 11; i++) {
        entries['f$i.md'] = List<int>.filled(5 * 1024 * 1024, 0x20);
      }
      final zip = _zipWithEntries(entries);
      provider = SkillProvider(storage);
      await provider.initialize();
      expect(
        () => provider.importManyFromBytes(bytes: zip, fileName: 'bomb.zip'),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects paths deeper than 3 segments', () async {
      final zip = _zipWithEntries(<String, List<int>>{
        'a/b/c/d/skill.md': utf8.encode('# Deep\nx'), // 4 segments -> rejected
        'a/skill.md': utf8.encode('# Shallow\ny'), // 2 segments -> accepted
      });
      provider = SkillProvider(storage);
      await provider.initialize();
      final imported = await provider.importManyFromBytes(
        bytes: zip,
        fileName: 'd.zip',
      );
      expect(imported.length, 1);
      expect(imported.first.name, 'Shallow');
    });

    test('imports only the primary SKILL.md from a multi-file package', () async {
      // Claude Skills style package: primary SKILL.md + references/ + agents/
      // companion files. The archive must collapse to ONE skill, not flatten
      // every companion into its own skill.
      final zip = _zipWithEntries(<String, List<int>>{
        'SKILL.md': utf8.encode(
          '---\nname: novel-editor\n---\n# Novel Editor\ncore rules',
        ),
        'references/dialogue-editing.md': utf8.encode('# Dialogue\nsubtext'),
        'references/story-bible-template.md': utf8.encode('# Bible\ntemplate'),
        'agents/openai.yaml': utf8.encode(
          'interface:\n  display_name: "Novel Editor"',
        ),
      });
      provider = SkillProvider(storage);
      await provider.initialize();
      final imported = await provider.importManyFromBytes(
        bytes: zip,
        fileName: 'pkg.zip',
      );
      expect(imported.length, 1);
      expect(imported.first.name, 'novel-editor');
    });

    test('loose archive without a primary SKILL.md imports all files', () async {
      final zip = _zipWithEntries(<String, List<int>>{
        'a.md': utf8.encode('# A\none'),
        'b.md': utf8.encode('# B\ntwo'),
      });
      provider = SkillProvider(storage);
      await provider.initialize();
      final imported = await provider.importManyFromBytes(
        bytes: zip,
        fileName: 'loose.zip',
      );
      expect(imported.length, 2);
    });
  });

  group('Secret detection (S4)', () {
    test('flags common secret patterns', () {
      expect(skillContentLooksSecret('use sk-ABCD1234EFGH5678IJKL90'), isTrue);
      expect(skillContentLooksSecret('token: AIzaSyA1234567890abcdefghijklmnop'), isTrue);
      expect(skillContentLooksSecret('Bearer abcdef1234567890abcdef'), isTrue);
    });

    test('does not flag ordinary skill text', () {
      expect(
        skillContentLooksSecret('You are a helpful assistant for scheduling.'),
        isFalse,
      );
      expect(skillContentLooksSecret(''), isFalse);
    });
  });
}
