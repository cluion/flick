import 'dart:convert';

enum RenameRuleType {
  newName,
  replace,
  prefix,
  suffix,
  letterCase,
  sequence,
  trim,
}

enum RenameRuleTarget { name, extension, both }

enum RenameConditionField { name, newName, extension, newExtension, path }

extension RenameConditionFieldLabel on RenameConditionField {
  String get wireName => switch (this) {
    RenameConditionField.name => 'name',
    RenameConditionField.newName => 'newName',
    RenameConditionField.extension => 'extension',
    RenameConditionField.newExtension => 'newExtension',
    RenameConditionField.path => 'path',
  };

  String get label => switch (this) {
    RenameConditionField.name => '原始主檔名',
    RenameConditionField.newName => '目前主檔名',
    RenameConditionField.extension => '原始副檔名',
    RenameConditionField.newExtension => '目前副檔名',
    RenameConditionField.path => '資料夾路徑',
  };
}

enum RenameConditionOperator { contains, startsWith, endsWith, equals, regex }

extension RenameConditionOperatorLabel on RenameConditionOperator {
  String get wireName => switch (this) {
    RenameConditionOperator.contains => 'contains',
    RenameConditionOperator.startsWith => 'startsWith',
    RenameConditionOperator.endsWith => 'endsWith',
    RenameConditionOperator.equals => 'equals',
    RenameConditionOperator.regex => 'regex',
  };

  String get label => switch (this) {
    RenameConditionOperator.contains => '包含',
    RenameConditionOperator.startsWith => '開頭是',
    RenameConditionOperator.endsWith => '結尾是',
    RenameConditionOperator.equals => '完全等於',
    RenameConditionOperator.regex => '正規表示式',
  };
}

class RenameRuleCondition {
  const RenameRuleCondition({
    this.enabled = false,
    this.field = RenameConditionField.name,
    this.operator = RenameConditionOperator.contains,
    this.value = '',
    this.negate = false,
  });

  factory RenameRuleCondition.fromJson(Map<String, Object?> json) {
    return RenameRuleCondition(
      enabled: json['enabled'] as bool? ?? false,
      field: RenameConditionField.values.firstWhere(
        (field) => field.wireName == json['field'],
        orElse: () => RenameConditionField.name,
      ),
      operator: RenameConditionOperator.values.firstWhere(
        (operator) => operator.wireName == json['operator'],
        orElse: () => RenameConditionOperator.contains,
      ),
      value: json['value'] as String? ?? '',
      negate: json['negate'] as bool? ?? false,
    );
  }

  final bool enabled;
  final RenameConditionField field;
  final RenameConditionOperator operator;
  final String value;
  final bool negate;

  RenameRuleCondition copyWith({
    bool? enabled,
    RenameConditionField? field,
    RenameConditionOperator? operator,
    String? value,
    bool? negate,
  }) {
    return RenameRuleCondition(
      enabled: enabled ?? this.enabled,
      field: field ?? this.field,
      operator: operator ?? this.operator,
      value: value ?? this.value,
      negate: negate ?? this.negate,
    );
  }

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'field': field.wireName,
    'operator': operator.wireName,
    if (value.isNotEmpty) 'value': value,
    'negate': negate,
  };
}

extension RenameRuleTargetLabel on RenameRuleTarget {
  String get wireName => switch (this) {
    RenameRuleTarget.name => 'name',
    RenameRuleTarget.extension => 'extension',
    RenameRuleTarget.both => 'both',
  };

  String get label => switch (this) {
    RenameRuleTarget.name => '主檔名',
    RenameRuleTarget.extension => '副檔名',
    RenameRuleTarget.both => '主檔名與副檔名',
  };
}

extension RenameRuleTypeLabel on RenameRuleType {
  String get wireName => switch (this) {
    RenameRuleType.newName => 'newName',
    RenameRuleType.replace => 'replace',
    RenameRuleType.prefix => 'prefix',
    RenameRuleType.suffix => 'suffix',
    RenameRuleType.letterCase => 'case',
    RenameRuleType.sequence => 'sequence',
    RenameRuleType.trim => 'trim',
  };

  String get label => switch (this) {
    RenameRuleType.newName => '設定新檔名',
    RenameRuleType.replace => '取代文字',
    RenameRuleType.prefix => '加入前綴',
    RenameRuleType.suffix => '加入後綴',
    RenameRuleType.letterCase => '變更大小寫',
    RenameRuleType.sequence => '加入流水號',
    RenameRuleType.trim => '清除頭尾空白',
  };

  String get description => switch (this) {
    RenameRuleType.newName => '直接設定主檔名，可使用 {name} 與 {n}',
    RenameRuleType.replace => '搜尋檔名中的文字並全部取代',
    RenameRuleType.prefix => '在原檔名前方加上固定文字',
    RenameRuleType.suffix => '在副檔名前加上固定文字',
    RenameRuleType.letterCase => '統一檔名的英文大小寫',
    RenameRuleType.sequence => '依照目前排序加入連續編號',
    RenameRuleType.trim => '移除檔名頭尾的空白',
  };
}

class RenameRule {
  const RenameRule({
    required this.id,
    required this.type,
    this.enabled = true,
    this.value = '',
    this.replacement = '',
    this.mode = 'lower',
    this.target = RenameRuleTarget.name,
    this.caseSensitive = true,
    this.useRegex = false,
    this.start = 1,
    this.padding = 2,
    this.condition = const RenameRuleCondition(),
  });

  factory RenameRule.create(RenameRuleType type) => RenameRule(
    id: DateTime.now().microsecondsSinceEpoch.toString(),
    type: type,
    value: switch (type) {
      RenameRuleType.prefix => 'Project-',
      RenameRuleType.suffix => '-final',
      _ => '',
    },
  );

  factory RenameRule.fromJson(Map<String, Object?> json) {
    final wireType = json['type'] as String? ?? '';
    final condition = json['condition'];
    return RenameRule(
      id:
          json['id'] as String? ??
          DateTime.now().microsecondsSinceEpoch.toString(),
      type: RenameRuleType.values.firstWhere(
        (type) => type.wireName == wireType,
        orElse: () => RenameRuleType.newName,
      ),
      enabled: json['enabled'] as bool? ?? true,
      value: json['value'] as String? ?? '',
      replacement: json['replacement'] as String? ?? '',
      mode: json['mode'] as String? ?? 'lower',
      target: RenameRuleTarget.values.firstWhere(
        (target) => target.wireName == json['applyTo'],
        orElse: () => RenameRuleTarget.name,
      ),
      caseSensitive: json['caseSensitive'] as bool? ?? true,
      useRegex: json['useRegex'] as bool? ?? false,
      start: json['start'] as int? ?? 1,
      padding: json['padding'] as int? ?? 2,
      condition: condition is Map
          ? RenameRuleCondition.fromJson(Map<String, Object?>.from(condition))
          : const RenameRuleCondition(),
    );
  }

  final String id;
  final RenameRuleType type;
  final bool enabled;
  final String value;
  final String replacement;
  final String mode;
  final RenameRuleTarget target;
  final bool caseSensitive;
  final bool useRegex;
  final int start;
  final int padding;
  final RenameRuleCondition condition;

  bool get isComplete => switch (type) {
    RenameRuleType.newName ||
    RenameRuleType.replace ||
    RenameRuleType.prefix ||
    RenameRuleType.suffix => value.isNotEmpty,
    RenameRuleType.letterCase ||
    RenameRuleType.sequence ||
    RenameRuleType.trim => true,
  };

  RenameRule copyWith({
    bool? enabled,
    String? value,
    String? replacement,
    String? mode,
    RenameRuleTarget? target,
    bool? caseSensitive,
    bool? useRegex,
    int? start,
    int? padding,
    RenameRuleCondition? condition,
  }) {
    return RenameRule(
      id: id,
      type: type,
      enabled: enabled ?? this.enabled,
      value: value ?? this.value,
      replacement: replacement ?? this.replacement,
      mode: mode ?? this.mode,
      target: target ?? this.target,
      caseSensitive: caseSensitive ?? this.caseSensitive,
      useRegex: useRegex ?? this.useRegex,
      start: start ?? this.start,
      padding: padding ?? this.padding,
      condition: condition ?? this.condition,
    );
  }

  Map<String, Object?> toJson({
    bool includeId = false,
    bool disableIncomplete = false,
  }) => {
    if (includeId) 'id': id,
    'type': type.wireName,
    'enabled': enabled && (!disableIncomplete || isComplete),
    if (value.isNotEmpty) 'value': value,
    if (replacement.isNotEmpty) 'replacement': replacement,
    if (type == RenameRuleType.letterCase) 'mode': mode,
    'applyTo': target.wireName,
    if (type == RenameRuleType.replace) ...{
      'caseSensitive': caseSensitive,
      'useRegex': useRegex,
    },
    if (type == RenameRuleType.sequence) ...{
      'start': start,
      'padding': padding,
    },
    if (condition.enabled || includeId) 'condition': condition.toJson(),
  };
}

String encodeRenameRecipe(List<RenameRule> rules) {
  return jsonEncode({
    'rules': rules
        .map((rule) => rule.toJson(disableIncomplete: true))
        .toList(growable: false),
  });
}

String encodeSavedRules(List<RenameRule> rules) {
  return jsonEncode(
    rules.map((rule) => rule.toJson(includeId: true)).toList(growable: false),
  );
}

List<RenameRule> decodeSavedRules(String encoded) {
  final decoded = jsonDecode(encoded);
  if (decoded is! List) return const [];
  return decoded
      .whereType<Map>()
      .map((json) => RenameRule.fromJson(Map<String, Object?>.from(json)))
      .toList(growable: false);
}
