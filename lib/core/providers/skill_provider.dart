import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/skill.dart';
import '../services/skills/skill_file_storage.dart';
import '../services/skills/skill_importer.dart';
import '../services/logging/flutter_logger.dart';

class SkillProvider extends ChangeNotifier {
  /// Legacy single-blob key. Kept only to migrate existing users once, then
  /// removed. Do not write to it anymore.
  static const String _legacyPrefsKey = 'skills_v1';

  final SkillFileStorage? _storageOverride;
  late final SkillFileStorage _storage;

  final List<Skill> _skills = <Skill>[];
  bool _initialized = false;

  List<Skill> get skills => List.unmodifiable(_skills);
  bool get initialized => _initialized;

  SkillProvider([SkillFileStorage? storage]) : _storageOverride = storage;

  Future<void> initialize() async {
    if (_initialized) return;
    _storage = _storageOverride ?? await SkillFileStorage.appSupport();
    try {
      await _storage.ensureDir();
      await _migrateLegacyPrefs();
      final loaded = await _storage.loadAll();
      _skills
        ..clear()
        ..addAll(loaded.where((s) => s.id.isNotEmpty));
      _sortSkills();
    } catch (e, st) {
      // G2 (graceful degradation): a broken or unavailable store must never
      // crash the app. Degrade to an empty skill set and keep the provider
      // usable so Kelivo's core keeps running.
      FlutterLogger.log(
        'SkillProvider init failed, using empty skill set: $e\n$st',
        tag: 'Skill',
      );
      _skills.clear();
    }
    _initialized = true;
    notifyListeners();
  }

  /// One-time migration from the old single-blob SharedPreferences store to the
  /// incremental file store. Best-effort: any failure is logged and ignored so
  /// it can never block startup (G2).
  Future<void> _migrateLegacyPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_legacyPrefsKey);
      if (raw == null || raw.isEmpty) return;
      final legacy = Skill.decodeList(
        raw,
      ).where((s) => s.id.isNotEmpty).toList();
      for (final skill in legacy) {
        try {
          await _storage.save(skill);
        } catch (e, st) {
          FlutterLogger.log(
            'Skill migration skipped for ${skill.id}: $e\n$st',
            tag: 'Skill',
          );
        }
      }
      await prefs.remove(_legacyPrefsKey);
    } catch (_) {
      // SharedPreferences unavailable or unreadable — nothing to migrate.
    }
  }

  Skill? getById(String id) {
    final index = _skills.indexWhere((skill) => skill.id == id);
    if (index == -1) return null;
    return _skills[index];
  }

  Future<Skill> importFromFile(File file) async {
    await initialize();
    // Import every skill the file contains and add them all to the provider;
    // the singular API only returns the first one rather than dropping the
    // rest (#5).
    final imported = await SkillImporter.importManyFromFile(file);
    final skills = await _addManyImported(imported, sourcePath: file.path);
    return skills.first;
  }

  Future<List<Skill>> importManyFromFile(File file) async {
    await initialize();
    final imported = await SkillImporter.importManyFromFile(file);
    return _addManyImported(imported, sourcePath: file.path);
  }

  Future<Skill> importFromBytes({
    required List<int> bytes,
    required String fileName,
    String? sourcePath,
  }) async {
    await initialize();
    final imported = SkillImporter.importManyFromBytes(
      bytes: bytes,
      fileName: fileName,
    );
    final skills = await _addManyImported(
      imported,
      sourcePath: sourcePath ?? fileName,
    );
    return skills.first;
  }

  Future<List<Skill>> importManyFromBytes({
    required List<int> bytes,
    required String fileName,
    String? sourcePath,
  }) async {
    await initialize();
    final imported = SkillImporter.importManyFromBytes(
      bytes: bytes,
      fileName: fileName,
    );
    return _addManyImported(imported, sourcePath: sourcePath ?? fileName);
  }

  Future<List<Skill>> _addManyImported(
    List<ImportedSkill> imported, {
    String? sourcePath,
  }) async {
    final now = DateTime.now();
    final skills = imported
        .map(
          (item) => Skill(
            id: const Uuid().v4(),
            name: item.name,
            description: item.description,
            content: item.content,
            triggerKeywords: item.triggerKeywords,
            sourcePath: sourcePath,
            createdAt: now,
            updatedAt: now,
          ),
        )
        .toList(growable: false);
    _skills.addAll(skills);
    _sortSkills();
    // P1: incremental persist — write each new skill as its own file.
    for (final skill in skills) {
      await _persistOne(skill);
    }
    notifyListeners();
    return skills;
  }

  Future<String> addSkill({
    required String name,
    required String content,
    String description = '',
    List<String> triggerKeywords = const <String>[],
    int priority = 0,
  }) async {
    await initialize();
    final now = DateTime.now();
    final skill = Skill(
      id: const Uuid().v4(),
      name: name.trim().isEmpty ? '技能' : name.trim(),
      description: description.trim(),
      content: content,
      triggerKeywords: triggerKeywords,
      priority: priority,
      createdAt: now,
      updatedAt: now,
    );
    _skills.add(skill);
    _sortSkills();
    await _persistOne(skill);
    notifyListeners();
    return skill.id;
  }

  Future<void> updateSkill(Skill updated) async {
    await initialize();
    final index = _skills.indexWhere((skill) => skill.id == updated.id);
    if (index == -1) return;
    _skills[index] = updated.copyWith(updatedAt: DateTime.now());
    _sortSkills();
    await _persistOne(updated.copyWith(updatedAt: DateTime.now()));
    notifyListeners();
  }

  Future<void> deleteSkill(String id) async {
    await initialize();
    _skills.removeWhere((skill) => skill.id == id);
    // P1: delete only this skill's file.
    try {
      await _storage.delete(id);
    } catch (e, st) {
      FlutterLogger.log(
        'SkillProvider delete file failed (kept in memory): $e\n$st',
        tag: 'Skill',
      );
    }
    notifyListeners();
  }

  Future<void> setEnabled(String id, bool enabled) async {
    final skill = getById(id);
    if (skill == null || skill.enabled == enabled) return;
    await updateSkill(skill.copyWith(enabled: enabled));
  }

  List<Skill> resolveActiveSkills({
    required List<String> explicitSkillIds,
    String latestUserMessage = '',
    int maxSkills = 5,
  }) {
    final explicit = explicitSkillIds.toSet();
    final query = latestUserMessage.toLowerCase();
    final candidates = <({Skill skill, bool explicit})>[];

    for (final skill in _skills) {
      final isExplicit = explicit.contains(skill.id);
      if (isExplicit) {
        // Explicitly bound skills (assistant.roleSkillIds) are injected regardless
        // of the global enabled toggle: binding is the user's clear intent.
        // The global toggle only gates keyword-triggered implicit skills below.
        candidates.add((skill: skill, explicit: true));
        continue;
      }
      if (!skill.enabled) continue;
      final triggered = _matchesKeywords(skill, query);
      if (triggered) {
        candidates.add((skill: skill, explicit: false));
      }
    }

    candidates.sort((a, b) {
      if (a.explicit != b.explicit) return a.explicit ? -1 : 1;
      final priority = b.skill.priority.compareTo(a.skill.priority);
      if (priority != 0) return priority;
      return b.skill.updatedAt.compareTo(a.skill.updatedAt);
    });

    return candidates
        .take(maxSkills)
        .map((candidate) => candidate.skill)
        .toList(growable: false);
  }

  bool _matchesKeywords(Skill skill, String query) {
    if (query.trim().isEmpty || skill.triggerKeywords.isEmpty) return false;
    for (final raw in skill.triggerKeywords) {
      final keyword = raw.trim().toLowerCase();
      if (keyword.isNotEmpty && query.contains(keyword)) return true;
    }
    return false;
  }

  void _sortSkills() {
    _skills.sort((a, b) {
      final priority = b.priority.compareTo(a.priority);
      if (priority != 0) return priority;
      return b.updatedAt.compareTo(a.updatedAt);
    });
  }

  /// Persist a single skill. On store failure we keep the in-memory state
  /// correct (G2) so the UI keeps working; the change simply isn't saved.
  Future<void> _persistOne(Skill skill) async {
    try {
      await _storage.save(skill);
    } catch (e, st) {
      FlutterLogger.log(
        'SkillProvider persist failed, kept in memory only: $e\n$st',
        tag: 'Skill',
      );
    }
  }
}
