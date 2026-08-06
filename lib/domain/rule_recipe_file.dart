import 'dart:convert';

import 'rename_rule.dart';

const ruleRecipeFileKind = 'flick.rename-recipe';
const currentRuleRecipeSchemaVersion = 1;
const maxRuleRecipeRules = 1000;

class RuleRecipeDocument {
  RuleRecipeDocument({required List<RenameRule> rules, this.exportedAt})
    : rules = List.unmodifiable(rules);

  final List<RenameRule> rules;
  final DateTime? exportedAt;
}

String encodeRuleRecipeFile(List<RenameRule> rules, {DateTime? exportedAt}) {
  _validateRuleCount(rules.length);
  return jsonEncode({
    'kind': ruleRecipeFileKind,
    'schemaVersion': currentRuleRecipeSchemaVersion,
    'exportedAt': (exportedAt ?? DateTime.now()).toUtc().toIso8601String(),
    'rules': rules
        .map((rule) => rule.toJson(includeId: false))
        .toList(growable: false),
  });
}

RuleRecipeDocument decodeRuleRecipeFile(String encoded, {String? instanceId}) {
  final decoded = jsonDecode(encoded);
  if (decoded is! Map) {
    throw const FormatException('規則配方格式無效');
  }
  var document = Map<String, Object?>.from(decoded);
  final rawVersion = document['schemaVersion'];
  if (rawVersion != null && rawVersion is! int) {
    throw const FormatException('規則配方版本無效');
  }
  var version = rawVersion as int? ?? 0;
  if (version < 0) throw const FormatException('規則配方版本無效');
  if (version > currentRuleRecipeSchemaVersion) {
    throw FormatException('不支援的規則配方版本：$version');
  }
  while (version < currentRuleRecipeSchemaVersion) {
    document = _migrateRuleRecipe(document, version);
    version = document['schemaVersion']! as int;
  }

  if (document['kind'] != ruleRecipeFileKind) {
    throw const FormatException('檔案不是 Flick 規則配方');
  }
  final encodedRules = document['rules'];
  if (encodedRules is! List) {
    throw const FormatException('規則配方缺少規則清單');
  }
  _validateRuleCount(encodedRules.length);
  final exportedAtValue = document['exportedAt'];
  final exportedAt = exportedAtValue == null
      ? null
      : DateTime.tryParse(exportedAtValue as String? ?? '');
  if (exportedAtValue != null && exportedAt == null) {
    throw const FormatException('規則配方匯出時間無效');
  }

  final prefix = instanceId ?? DateTime.now().microsecondsSinceEpoch.toString();
  final rules = <RenameRule>[];
  for (var index = 0; index < encodedRules.length; index++) {
    final encodedRule = encodedRules[index];
    if (encodedRule is! Map) {
      throw const FormatException('規則配方項目無效');
    }
    rules.add(
      RenameRule.fromJson({
        ...Map<String, Object?>.from(encodedRule),
        'id': 'recipe-$prefix-$index',
      }),
    );
  }
  return RuleRecipeDocument(rules: rules, exportedAt: exportedAt?.toUtc());
}

Map<String, Object?> _migrateRuleRecipe(
  Map<String, Object?> document,
  int fromVersion,
) {
  return switch (fromVersion) {
    0 => {
      'kind': ruleRecipeFileKind,
      'schemaVersion': 1,
      'rules': document['rules'],
    },
    _ => throw FormatException('缺少規則配方版本 $fromVersion 的遷移程序'),
  };
}

void _validateRuleCount(int count) {
  if (count < 1) throw const FormatException('規則配方不可為空');
  if (count > maxRuleRecipeRules) {
    throw const FormatException('規則配方超過 1000 個規則的上限');
  }
}
