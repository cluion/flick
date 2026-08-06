import 'dart:convert';

import 'rename_rule.dart';

const currentRulePresetSchemaVersion = 1;

class RulePreset {
  RulePreset({
    required this.id,
    required this.name,
    required List<RenameRule> rules,
  }) : rules = List.unmodifiable(rules);

  factory RulePreset.create({
    required String name,
    required List<RenameRule> rules,
  }) {
    return RulePreset(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: name.trim(),
      rules: rules,
    );
  }

  factory RulePreset.fromJson(Map<String, Object?> json) {
    final id = json['id'];
    final name = json['name'];
    final encodedRules = json['rules'];
    if (id is! String || id.isEmpty) {
      throw const FormatException('規則預設缺少識別碼');
    }
    if (name is! String || name.trim().isEmpty) {
      throw const FormatException('規則預設缺少名稱');
    }
    if (encodedRules is! List) {
      throw const FormatException('規則預設缺少規則清單');
    }

    return RulePreset(
      id: id,
      name: name.trim(),
      rules: decodeSavedRules(jsonEncode(encodedRules)),
    );
  }

  final String id;
  final String name;
  final List<RenameRule> rules;

  RulePreset copyWith({String? id, String? name, List<RenameRule>? rules}) {
    return RulePreset(
      id: id ?? this.id,
      name: name?.trim() ?? this.name,
      rules: rules ?? this.rules,
    );
  }

  List<RenameRule> instantiateRules({String? instanceId}) {
    final prefix =
        instanceId ?? DateTime.now().microsecondsSinceEpoch.toString();
    return List.unmodifiable([
      for (var index = 0; index < rules.length; index++)
        RenameRule.fromJson({
          ...rules[index].toJson(includeId: false),
          'id': 'preset-$prefix-$index',
        }),
    ]);
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'rules': jsonDecode(encodeSavedRules(rules)),
  };
}

String encodeRulePresets(List<RulePreset> presets) {
  return jsonEncode({
    'schemaVersion': currentRulePresetSchemaVersion,
    'presets': presets.map((preset) => preset.toJson()).toList(growable: false),
  });
}

List<RulePreset> decodeRulePresets(String encoded) {
  final decoded = jsonDecode(encoded);
  if (decoded is! Map) {
    throw const FormatException('規則預設格式無效');
  }
  final document = Map<String, Object?>.from(decoded);
  final schemaVersion = document['schemaVersion'];
  if (schemaVersion != currentRulePresetSchemaVersion) {
    throw FormatException('不支援的規則預設版本：$schemaVersion');
  }
  final encodedPresets = document['presets'];
  if (encodedPresets is! List) {
    throw const FormatException('規則預設清單無效');
  }

  final presets = <RulePreset>[];
  final ids = <String>{};
  final names = <String>{};
  for (final encodedPreset in encodedPresets) {
    if (encodedPreset is! Map) {
      throw const FormatException('規則預設項目無效');
    }
    final preset = RulePreset.fromJson(
      Map<String, Object?>.from(encodedPreset),
    );
    if (!ids.add(preset.id)) {
      throw FormatException('規則預設識別碼重複：${preset.id}');
    }
    if (!names.add(preset.name.toLowerCase())) {
      throw FormatException('規則預設名稱重複：${preset.name}');
    }
    presets.add(preset);
  }
  return List.unmodifiable(presets);
}
