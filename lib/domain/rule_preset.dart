import 'dart:convert';

import 'rename_rule.dart';

const currentRulePresetSchemaVersion = 1;
const maxRulePresetCount = 1000;

class StarterRulePreset {
  const StarterRulePreset({
    required this.id,
    required this.name,
    required this.description,
    required this.rules,
  });

  final String id;
  final String name;
  final String description;
  final List<RenameRule> rules;
}

const starterRulePresets = <StarterRulePreset>[
  StarterRulePreset(
    id: 'numbered',
    name: '加上兩位流水號',
    description: '在主檔名後加入 -01、-02，副檔名保持不變',
    rules: [
      RenameRule(
        id: 'numbered-separator',
        type: RenameRuleType.suffix,
        value: '-',
      ),
      RenameRule(
        id: 'numbered-sequence',
        type: RenameRuleType.sequence,
        start: 1,
        padding: 2,
      ),
    ],
  ),
  StarterRulePreset(
    id: 'clean-lowercase',
    name: '清理空白並轉小寫',
    description: '移除主檔名頭尾空白，再將英文字母統一為小寫',
    rules: [
      RenameRule(id: 'clean-trim', type: RenameRuleType.trim),
      RenameRule(
        id: 'clean-lowercase',
        type: RenameRuleType.letterCase,
        mode: 'lower',
      ),
    ],
  ),
  StarterRulePreset(
    id: 'camera-prefix',
    name: '移除常見相機前綴',
    description: '移除 IMG_、DSC_、PXL_ 開頭；其他檔名不受影響',
    rules: [
      RenameRule(
        id: 'camera-prefix-replace',
        type: RenameRuleType.replace,
        value: r'^(IMG_|DSC_|PXL_)',
        caseSensitive: false,
        useRegex: true,
      ),
    ],
  ),
  StarterRulePreset(
    id: 'lowercase-extension',
    name: '副檔名轉小寫',
    description: '只統一副檔名大小寫，例如 JPG 轉為 jpg',
    rules: [
      RenameRule(
        id: 'lowercase-extension',
        type: RenameRuleType.letterCase,
        mode: 'lower',
        target: RenameRuleTarget.extension,
      ),
    ],
  ),
];

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
  if (presets.length > maxRulePresetCount) {
    throw const FormatException('規則預設超過 1000 個的上限');
  }
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
  if (encodedPresets.length > maxRulePresetCount) {
    throw const FormatException('規則預設超過 1000 個的上限');
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

List<RulePreset> mergeImportedRulePresets({
  required List<RulePreset> existing,
  required List<RulePreset> imported,
  String? importId,
}) {
  if (existing.length + imported.length > maxRulePresetCount) {
    throw const FormatException('匯入後會超過 1000 個規則預設的上限');
  }

  final merged = [...existing];
  final ids = existing.map((preset) => preset.id).toSet();
  final names = existing.map((preset) => preset.name.toLowerCase()).toSet();
  final prefix = importId ?? DateTime.now().microsecondsSinceEpoch.toString();
  for (var index = 0; index < imported.length; index++) {
    final preset = imported[index];
    var id = 'import-$prefix-$index';
    var idSuffix = 2;
    while (!ids.add(id)) {
      id = 'import-$prefix-$index-$idSuffix';
      idSuffix++;
    }
    final name = _availableImportedName(preset.name, names);
    names.add(name.toLowerCase());
    merged.add(preset.copyWith(id: id, name: name));
  }
  return List.unmodifiable(merged);
}

String _availableImportedName(String name, Set<String> existingNames) {
  if (!existingNames.contains(name.toLowerCase())) return name;
  final importedSuffix = RegExp(r'^(.*)（匯入(?: \d+)?）$').firstMatch(name);
  final root = importedSuffix?.group(1) ?? name;
  final base = '$root（匯入）';
  if (!existingNames.contains(base.toLowerCase())) return base;
  var suffix = 2;
  while (existingNames.contains('$root（匯入 $suffix）'.toLowerCase())) {
    suffix++;
  }
  return '$root（匯入 $suffix）';
}

String rulePresetFileStem(String name) {
  final sanitized = name
      .trim()
      .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '-')
      .replaceAll(RegExp(r'[. ]+$'), '');
  if (sanitized.isEmpty) return 'flick-preset';
  return sanitized.length <= 80 ? sanitized : sanitized.substring(0, 80);
}
