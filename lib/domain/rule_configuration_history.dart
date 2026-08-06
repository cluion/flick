import 'dart:convert';

import 'rename_rule.dart';

const currentRuleConfigurationHistorySchemaVersion = 1;
const maxRecentRuleConfigurations = 20;

class RuleConfigurationSnapshot {
  RuleConfigurationSnapshot({
    required this.id,
    required this.savedAt,
    required List<RenameRule> rules,
  }) : rules = List.unmodifiable(rules);

  factory RuleConfigurationSnapshot.fromJson(Map<String, Object?> json) {
    final id = json['id'];
    final savedAt = DateTime.tryParse(json['savedAt'] as String? ?? '');
    final encodedRules = json['rules'];
    if (id is! String || id.isEmpty) {
      throw const FormatException('最近規則設定缺少識別碼');
    }
    if (savedAt == null) {
      throw const FormatException('最近規則設定缺少有效時間');
    }
    if (encodedRules is! List) {
      throw const FormatException('最近規則設定缺少規則清單');
    }
    final rules = decodeSavedRules(jsonEncode(encodedRules));
    if (rules.isEmpty) {
      throw const FormatException('最近規則設定不可為空');
    }
    return RuleConfigurationSnapshot(
      id: id,
      savedAt: savedAt.toUtc(),
      rules: rules,
    );
  }

  final String id;
  final DateTime savedAt;
  final List<RenameRule> rules;

  List<RenameRule> instantiateRules({String? instanceId}) {
    final prefix =
        instanceId ?? DateTime.now().microsecondsSinceEpoch.toString();
    return List.unmodifiable([
      for (var index = 0; index < rules.length; index++)
        RenameRule.fromJson({
          ...rules[index].toJson(includeId: false),
          'id': 'history-$prefix-$index',
        }),
    ]);
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'savedAt': savedAt.toUtc().toIso8601String(),
    'rules': jsonDecode(encodeSavedRules(rules)),
  };
}

String encodeRuleConfigurationHistory(List<RuleConfigurationSnapshot> history) {
  if (history.length > maxRecentRuleConfigurations) {
    throw const FormatException('最近規則設定超過 20 筆的上限');
  }
  return jsonEncode({
    'schemaVersion': currentRuleConfigurationHistorySchemaVersion,
    'history': history
        .map((snapshot) => snapshot.toJson())
        .toList(growable: false),
  });
}

List<RuleConfigurationSnapshot> decodeRuleConfigurationHistory(String encoded) {
  final decoded = jsonDecode(encoded);
  if (decoded is! Map) {
    throw const FormatException('最近規則設定格式無效');
  }
  final document = Map<String, Object?>.from(decoded);
  final schemaVersion = document['schemaVersion'];
  if (schemaVersion != currentRuleConfigurationHistorySchemaVersion) {
    throw FormatException('不支援的最近規則設定版本：$schemaVersion');
  }
  final encodedHistory = document['history'];
  if (encodedHistory is! List) {
    throw const FormatException('最近規則設定清單無效');
  }
  if (encodedHistory.length > maxRecentRuleConfigurations) {
    throw const FormatException('最近規則設定超過 20 筆的上限');
  }

  final history = <RuleConfigurationSnapshot>[];
  final ids = <String>{};
  for (final encodedSnapshot in encodedHistory) {
    if (encodedSnapshot is! Map) {
      throw const FormatException('最近規則設定項目無效');
    }
    final snapshot = RuleConfigurationSnapshot.fromJson(
      Map<String, Object?>.from(encodedSnapshot),
    );
    if (!ids.add(snapshot.id)) {
      throw FormatException('最近規則設定識別碼重複：${snapshot.id}');
    }
    history.add(snapshot);
  }
  return List.unmodifiable(history);
}

List<RuleConfigurationSnapshot> recordRecentRuleConfiguration({
  required List<RuleConfigurationSnapshot> history,
  required List<RenameRule> rules,
  DateTime? savedAt,
  String? snapshotId,
}) {
  if (rules.isEmpty || !rules.any((rule) => rule.enabled && rule.isComplete)) {
    return history;
  }
  final fingerprint = _ruleConfigurationFingerprint(rules);
  if (history.isNotEmpty &&
      _ruleConfigurationFingerprint(history.first.rules) == fingerprint) {
    return history;
  }

  final timestamp = (savedAt ?? DateTime.now()).toUtc();
  final snapshot = RuleConfigurationSnapshot(
    id: snapshotId ?? 'rules-${timestamp.microsecondsSinceEpoch}',
    savedAt: timestamp,
    rules: decodeSavedRules(encodeSavedRules(rules)),
  );
  final updated = <RuleConfigurationSnapshot>[
    snapshot,
    for (final previous in history)
      if (_ruleConfigurationFingerprint(previous.rules) != fingerprint)
        previous,
  ];
  return List.unmodifiable(updated.take(maxRecentRuleConfigurations));
}

String _ruleConfigurationFingerprint(List<RenameRule> rules) {
  return jsonEncode(
    rules.map((rule) => rule.toJson(includeId: false)).toList(growable: false),
  );
}
