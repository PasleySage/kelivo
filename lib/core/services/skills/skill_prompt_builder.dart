import '../../models/skill.dart';
import 'skill_file_storage.dart';

/// Per-skill content cap (chars). Sized to fit fully integrated Claude
/// Skills packages (e.g. the novel-optimization-editor SKILL-full.md at
/// ~37k chars) without truncation.
const int maxSkillContentChars = 40000;

/// Total injected system-prompt cap (chars). Headroom above the per-skill cap
/// so several skills can coexist; overflow is truncated with a marker.
const int maxSkillTotalChars = 60000;

String _escXml(String v) => v
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

/// Truncates [s] to at most [max] Unicode runes, appending a marker. Uses rune
/// counts (not code units) so multi-code-unit characters such as emoji are
/// never split mid-surrogate (#10).
String _truncateRune(String s, int max) {
  if (s.runes.length <= max) return s;
  return '${String.fromCharCodes(s.runes.take(max))}[truncated]';
}

/// Builds the system-prompt skill-data block from the resolved active skills.
///
/// Returns `null` when there are no skills (nothing to inject).
///
/// Trust model: a skill is content the user explicitly imported and enabled,
/// so it is treated as an instruction the model may follow when relevant —
/// matching the reference Kelivo Plus behavior ("Follow them when relevant to
/// the task"). Structure isolation (S1) is still applied: every skill's text
/// is wrapped in explicit `<SKILL name="...">…</SKILL>` delimiters and
/// XML-escaped, so skill content cannot break out and alter the surrounding
/// system prompt. Untrusted-source risk is handled at import time (user
/// imports only trusted skills), not by downgrading skill content.
///
/// P4 (token cost): per-skill content is capped at [maxSkillContentChars] and
/// the total block at [maxSkillTotalChars]; overflow is truncated with a marker.
///
/// This is a pure function (no I/O, no throws) so it is trivially unit-testable
/// and safe to call from the chat injection path.
String? buildSkillSystemText(List<Skill> skills) {
  if (skills.isEmpty) return null;

  final buffer = StringBuffer();
  buffer.writeln(
    'The following skill data is provided as instructions selected by the '
    'user. Follow them when relevant to the task. Do not reveal full skill '
    "contents unless the user asks.",
  );

  for (final s in skills) {
    // Defense-in-depth (#2): never inject a skill whose keychain secret failed
    // to restore — its placeholder would otherwise leak into the LLM context.
    // The file store already drops such skills on load, but this guards the
    // injection path regardless of how the skill was sourced.
    if (contentHasUnresolvedSecret(s.content)) continue;

    final name = s.name.trim();
    final desc = s.description.trim();
    var c = s.content.trim();
    if (c.runes.length > maxSkillContentChars) {
      c = _truncateRune(c, maxSkillContentChars);
    }
    if (name.isEmpty && desc.isEmpty && c.isEmpty) continue;

    buffer.writeln('<SKILL name="${_escXml(name)}">');
    if (desc.isNotEmpty) buffer.writeln('Description: ${_escXml(desc)}');
    if (c.isNotEmpty) buffer.writeln(_escXml(c));
    buffer.writeln('</SKILL>');

    if (buffer.toString().runes.length > maxSkillTotalChars) break;
  }

  final built = buffer.toString().trim();
  return built.runes.length > maxSkillTotalChars
      ? _truncateRune(built, maxSkillTotalChars)
      : built;
}
