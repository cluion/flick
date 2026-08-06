import 'dart:convert';

import 'package:flick/domain/rename_rule.dart';
import 'package:flick/domain/rule_recipe_file.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('v1 recipe files round-trip without persisting widget ids', () {
    final encoded = encodeRuleRecipeFile(const [
      RenameRule(
        id: 'local-widget-id',
        type: RenameRuleType.replace,
        value: 'IMG_',
        replacement: 'Trip-',
      ),
    ], exportedAt: DateTime.utc(2026, 8, 6, 12, 34));
    final json = jsonDecode(encoded) as Map;
    final encodedRule = (json['rules'] as List).single as Map;
    final restored = decodeRuleRecipeFile(encoded, instanceId: 'test');

    expect(json['kind'], ruleRecipeFileKind);
    expect(json['schemaVersion'], currentRuleRecipeSchemaVersion);
    expect(encodedRule.containsKey('id'), isFalse);
    expect(restored.exportedAt, DateTime.utc(2026, 8, 6, 12, 34));
    expect(restored.rules.single.id, 'recipe-test-0');
    expect(restored.rules.single.replacement, 'Trip-');
  });

  test('migrates legacy unversioned backend recipes', () {
    final restored = decodeRuleRecipeFile(
      '{"rules":['
      '{"type":"sequence","enabled":true,"start":5,"padding":3}'
      ']}',
      instanceId: 'legacy',
    );

    expect(restored.exportedAt, isNull);
    expect(restored.rules.single.id, 'recipe-legacy-0');
    expect(restored.rules.single.type, RenameRuleType.sequence);
    expect(restored.rules.single.start, 5);
    expect(restored.rules.single.padding, 3);
  });

  test('rejects newer versions, wrong kinds, and empty recipes', () {
    expect(
      () => decodeRuleRecipeFile(
        '{"kind":"$ruleRecipeFileKind","schemaVersion":2,"rules":[]}',
      ),
      throwsFormatException,
    );
    expect(
      () => decodeRuleRecipeFile(
        '{"kind":"other","schemaVersion":1,"rules":[{}]}',
      ),
      throwsFormatException,
    );
    expect(() => encodeRuleRecipeFile(const []), throwsFormatException);
  });
}
