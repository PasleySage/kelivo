import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;

import '../../models/skill.dart';
import '../../services/logging/flutter_logger.dart';
import '../../../utils/app_directories.dart';

/// Incremental file-backed store for skills.
///
/// Each skill is persisted as a standalone JSON file `<dir>/<id>.json`. This
/// replaces the previous single-key persistent blob so that:
///  - a single corrupt or oversized skill file can no longer invalidate the
///    whole store (P1, and a graceful-degradation requirement),
///  - add/update/delete become O(1) writes instead of rewriting the entire
///    skill list on every change.
///
/// Secret handling (S4 → OS keychain): when a skill's content contains a secret
/// (API key, token, ...), the secret substring is replaced with an in-file
/// placeholder (`__KELIVO_SKILL_SECRET_n__`) while the real value is stored in
/// the OS keychain via [FlutterSecureStorage]. On load the placeholder is
/// restored from the keychain, so the plaintext JSON never holds the live
/// secret.
class SkillFileStorage {
  SkillFileStorage(this.directory, [FlutterSecureStorage? secure])
      : _secure = secure ??
            FlutterSecureStorage(
            // Persist to encrypted storage on Android so secrets
            // survive app reinstalls and avoid the KeyStore entry limits
              // that the default backend can hit with many keys (#7).
              aOptions: const AndroidOptions(encryptedSharedPreferences: true),
            );

  /// Resolves the default on-disk location under the app data directory,
  /// reusing Kelivo's platform-specific [AppDirectories] convention.
  static Future<SkillFileStorage> appSupport() async {
    return SkillFileStorage(await AppDirectories.getSkillsDirectory());
  }

  final Directory directory;
  final FlutterSecureStorage _secure;

  /// Backstop on disk size per skill file. Imported content is already capped
  /// at ~30k chars, so this only guards against accidental oversized writes.
  static const int maxFileBytes = 2 * 1024 * 1024;

  static String _vaultKey(String skillId, int index) =>
      'kelivo_skill::$skillId::secret::$index';

  static final RegExp _placeholderRe =
      RegExp(r'__KELIVO_SKILL_SECRET_(\d+)__');

  Future<Directory> ensureDir() async {
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory;
  }

  Future<List<Skill>> loadAll() async {
    if (!await directory.exists()) return const <Skill>[];
    final all = await directory.list().toList();
    final files = all
        .whereType<File>()
        .where((f) => p.extension(f.path).toLowerCase() == '.json')
        .toList(growable: false);
    final skills = <Skill>[];
    for (final file in files) {
      try {
        final raw = await file.readAsString();
        final decoded = jsonDecode(raw);
        if (decoded is! Map) continue;
        final map = Map<String, dynamic>.from(decoded);
        final id = (map['id'] as String?) ?? '';
        if (map['content'] is String) {
          final content = map['content'] as String;
          if (content.contains(_placeholderRe)) {
            final restored = await _restoreSecrets(id, content);
            if (restored.contains(_placeholderRe)) {
              // A keychain secret could not be restored (missing/locked) → do
              // NOT surface a broken skill whose placeholder would otherwise
              // leak into the LLM system prompt (#2).
              FlutterLogger.log(
                'Skill $id has an unrestorable keychain secret; skipping.',
                tag: 'Skill',
              );
              continue;
            }
            map['content'] = restored;
          }
        }
        final skill = Skill.fromJson(map);
        if (skill.id.isNotEmpty) skills.add(skill);
      } catch (_) {
        // G2: a single corrupt file must not break the rest of the store.
        FlutterLogger.log('Skipping unreadable skill file: ${file.path}', tag: 'Skill');
      }
    }
    return skills;
  }

  Future<void> save(Skill skill) async {
    await ensureDir();
    final byOccurrence = _extractSecrets(skill.content);
    // Index each secret by its first occurrence so placeholder numbering is
    // stable and matches the order a reader sees in the content (#7). Replacement
    // still runs longest-first to avoid a shorter secret aliasing a substring of
    // a longer one during global replaceAll (#9).
    final indexOf = <String, int>{};
    for (var i = 0; i < byOccurrence.length; i++) {
      indexOf[byOccurrence[i]] = i;
    }
    final forReplace = List<String>.from(byOccurrence)
      ..sort((a, b) => b.length.compareTo(a.length));
    var safeContent = skill.content;
    for (final secret in forReplace) {
      safeContent = safeContent.replaceAll(
        secret,
        '__KELIVO_SKILL_SECRET_${indexOf[secret]}__',
      );
    }
    final redacted = skill.copyWith(
      content: safeContent,
      secretCount: byOccurrence.length,
    );
    final json = jsonEncode(redacted.toJson());
    // Size check MUST run before any keychain write, so a rejected write never
    // leaves orphaned keychain entries (#3).
    if (utf8.encode(json).length > maxFileBytes) {
      throw StateError('Skill "${skill.name}" exceeds the max file size.');
    }
    // Clear the previous version's secrets (count read from the existing file),
    // persist the redacted file, then write the new secrets. Writing secrets
    // only after the file is on disk means a crash can't leave a placeholder
    // in the file with no matching keychain entry.
    final oldCount = await _readStoredSecretCount(skill.id);
    await _clearSecrets(skill.id, oldCount);
    final file = File(p.join(directory.path, _safeFileName(skill.id)));
    await file.writeAsString(json, flush: true);
    for (var i = 0; i < byOccurrence.length; i++) {
      await _secure.write(key: _vaultKey(skill.id, i), value: byOccurrence[i]);
    }
    if (byOccurrence.isNotEmpty) {
      FlutterLogger.log(
        'Skill "${skill.name}" contains ${byOccurrence.length} secret(s); '
        'stored in OS keychain, plaintext JSON keeps only placeholders.',
        tag: 'Skill',
      );
    }
  }

  Future<void> delete(String id) async {
    final oldCount = await _readStoredSecretCount(id);
    await _clearSecrets(id, oldCount);
    final file = File(p.join(directory.path, _safeFileName(id)));
    if (await file.exists()) {
      try {
        await file.delete();
      } catch (_) {
        // best-effort; a missing file is already the desired end state
      }
    }
  }

  /// Only `[A-Za-z0-9_-]` ids (UUIDs) get their name used directly; anything
  /// else is hashed so the on-disk filename can never escape the directory.
  String _safeFileName(String id) {
    if (id.isEmpty) return 'unknown.json';
    if (RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(id)) return '$id.json';
    final hash = md5.convert(utf8.encode(id)).toString();
    return '$hash.json';
  }

  /// Restores keychain-backed secrets into [content] by replacing placeholders.
  Future<String> _restoreSecrets(String skillId, String content) async {
    var result = content;
    for (final m in _placeholderRe.allMatches(content)) {
      final idx = int.parse(m.group(1)!);
      final secret = await _secure.read(key: _vaultKey(skillId, idx));
      if (secret != null) {
        result = result.replaceAll(m.group(0)!, secret);
      } else {
        FlutterLogger.log(
          'Keychain secret missing for skill $skillId index $idx',
          tag: 'Skill',
        );
      }
    }
    return result;
  }

  /// Reads how many keychain secrets the on-disk copy of [id] currently
  /// records, so we can clear exactly that many without scanning the whole
  /// OS keychain (#4). Returns 0 when the file is absent or unreadable.
  Future<int> _readStoredSecretCount(String id) async {
    final file = File(p.join(directory.path, _safeFileName(id)));
    if (!await file.exists()) return 0;
    try {
      final raw = await file.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return (decoded['secretCount'] as num?)?.toInt() ?? 0;
      }
    } catch (_) {
      // Unreadable -> safest to assume no stale secrets to clear.
    }
    return 0;
  }

  /// Removes [count] keychain entries for [skillId] (used before overwrite/
  /// delete). Bounded by the stored count so we never scan the whole keychain
  /// (#4).
  Future<void> _clearSecrets(String skillId, int count) async {
    for (var i = 0; i < count; i++) {
      await _secure.delete(key: _vaultKey(skillId, i));
    }
  }

  /// Returns the distinct secret substrings found in [content] (S4 detection,
  /// extended to support keychain extraction).
  ///
  /// Secrets are returned ordered by their first occurrence in [content] so the
  /// placeholder index assigned in [save] is stable and matches what a reader
  /// sees (#7). Length-based substring protection happens separately at replace
  /// time (#9).
  List<String> _extractSecrets(String content) {
    if (content.isEmpty) return const <String>[];
    final firstIndex = <String, int>{};
    for (final re in _secretPatterns) {
      for (final m in re.allMatches(content)) {
        final s = m.group(0)!;
        firstIndex.putIfAbsent(s, () => m.start);
      }
    }
    final sorted = firstIndex.keys.toList()
      ..sort((a, b) => firstIndex[a]!.compareTo(firstIndex[b]!));
    return sorted;
  }
}

/// Heuristic detector for secret material that should never be persisted in a
/// plaintext skill file (S4). Intentionally broad — false positives only emit
/// a log warning and never block an import.
bool skillContentLooksSecret(String content) {
  if (content.isEmpty) return false;
  return _secretPatterns.any((re) => re.hasMatch(content));
}

/// True when [content] still contains an unresolved keychain placeholder.
/// Used by the prompt builder as a defense-in-depth guard so a secret that
/// failed to restore can never reach the LLM context (#2).
bool contentHasUnresolvedSecret(String content) =>
    SkillFileStorage._placeholderRe.hasMatch(content);

final List<RegExp> _secretPatterns = <RegExp>[
  RegExp(r'sk-[A-Za-z0-9]{20,}'), // OpenAI / generic
  RegExp(r'AIza[0-9A-Za-z_-]{35}'), // Google API key
  RegExp(r'AKIA[0-9A-Z]{16}'), // AWS access key id
  RegExp(r'xox[baprs]-[0-9A-Za-z-]{10,}'), // Slack token
  RegExp(r'ghp_[0-9A-Za-z]{36}'), // GitHub PAT
  RegExp(r'Bearer\s+[A-Za-z0-9._-]{16,}'), // Bearer token
  RegExp(r'(api[_-]?key|secret|token|password)\s*[:=]\s*[A-Za-z0-9._-]{16,}'),
];
