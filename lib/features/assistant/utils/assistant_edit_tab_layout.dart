const String assistantEditTabWorkspace = 'workspace';
const String assistantEditTabBasic = 'basic';
const String assistantEditTabPrompts = 'prompts';
const String assistantEditTabMemory = 'memory';
const String assistantEditTabMcp = 'mcp';
const String assistantEditTabLocalTools = 'localTools';
const String assistantEditTabSkills = 'skills';
const String assistantEditTabQuickPhrase = 'quickPhrase';
const String assistantEditTabCustom = 'custom';
const String assistantEditTabRegex = 'regex';
const String assistantEditTabSkills = 'skills';

const List<String> defaultAssistantEditTabIds = [
  assistantEditTabBasic,
  assistantEditTabPrompts,
  assistantEditTabMemory,
  assistantEditTabLocalTools,
  assistantEditTabSkills,
  assistantEditTabMcp,
  assistantEditTabQuickPhrase,
  assistantEditTabCustom,
  assistantEditTabRegex,
  assistantEditTabWorkspace,
];

List<String> orderAssistantEditTabIds({
  required List<String> savedOrder,
  List<String> defaultOrder = defaultAssistantEditTabIds,
}) {
  final validIds = defaultOrder.toSet();
  final seen = <String>{};
  final result = <String>[];
  for (final id in savedOrder) {
    if (validIds.contains(id) && seen.add(id)) result.add(id);
  }
  for (final id in defaultOrder) {
    if (seen.add(id)) result.add(id);
  }
  return List.unmodifiable(result);
}

List<String> visibleAssistantEditTabIds({
  required List<String> savedOrder,
  required Set<String> hiddenIds,
  List<String> defaultOrder = defaultAssistantEditTabIds,
}) {
  final ordered = orderAssistantEditTabIds(
    savedOrder: savedOrder,
    defaultOrder: defaultOrder,
  );
  final knownIds = savedOrder.toSet();
  final visible = ordered.where((id) {
    // New tabs that did not exist in the user's saved order should never be
    // hidden by stale hidden-id data (e.g. restored from a backup that did not
    // yet know about them). Only ids the user has actually configured can be
    // hidden.
    if (!knownIds.contains(id)) return true;
    return !hiddenIds.contains(id);
  }).toList();
  return List.unmodifiable(visible.isNotEmpty ? visible : [ordered.first]);
}

int visualAssistantEditTabIndex({
  required double animationValue,
  required int tabCount,
}) {
  if (tabCount <= 0) return 0;
  return animationValue.round().clamp(0, tabCount - 1);
}
