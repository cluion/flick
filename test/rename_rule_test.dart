import 'dart:convert';

import 'package:flick/domain/rename_rule.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('incomplete text rules are disabled only in preview recipes', () {
    final rule = RenameRule.create(RenameRuleType.newName);

    final recipe = jsonDecode(encodeRenameRecipe([rule])) as Map;
    final recipeRule = (recipe['rules'] as List).single as Map;
    final savedRule =
        (jsonDecode(encodeSavedRules([rule])) as List).single as Map;

    expect(recipeRule['enabled'], isFalse);
    expect(savedRule['enabled'], isTrue);
  });

  test('completed new name rules remain enabled', () {
    final rule = RenameRule.create(
      RenameRuleType.newName,
    ).copyWith(value: 'holiday-{n}');

    final recipe = jsonDecode(encodeRenameRecipe([rule])) as Map;
    final encodedRule = (recipe['rules'] as List).single as Map;

    expect(encodedRule['type'], 'newName');
    expect(encodedRule['enabled'], isTrue);
    expect(encodedRule['value'], 'holiday-{n}');
  });

  test('advanced replace settings survive recipe and saved-rule encoding', () {
    final rule = RenameRule.create(RenameRuleType.replace).copyWith(
      value: r'(.*) - (.*)',
      replacement: r'\2 - \1',
      target: RenameRuleTarget.both,
      caseSensitive: false,
      useRegex: true,
    );

    final recipe = jsonDecode(encodeRenameRecipe([rule])) as Map;
    final encodedRule = (recipe['rules'] as List).single as Map;
    final restored = decodeSavedRules(encodeSavedRules([rule])).single;

    expect(encodedRule['applyTo'], 'both');
    expect(encodedRule['caseSensitive'], isFalse);
    expect(encodedRule['useRegex'], isTrue);
    expect(restored.target, RenameRuleTarget.both);
    expect(restored.caseSensitive, isFalse);
    expect(restored.useRegex, isTrue);
    expect(restored.replacement, r'\2 - \1');
  });

  test('old saved rules keep compatible defaults', () {
    final restored = decodeSavedRules(
      '[{"id":"legacy","type":"replace","enabled":true,"value":"A"}]',
    ).single;

    expect(restored.target, RenameRuleTarget.name);
    expect(restored.caseSensitive, isTrue);
    expect(restored.useRegex, isFalse);
    expect(restored.condition.enabled, isFalse);
  });

  test('rule conditions survive recipe and saved-rule encoding', () {
    final rule = RenameRule.create(RenameRuleType.prefix).copyWith(
      condition: const RenameRuleCondition(
        enabled: true,
        field: RenameConditionField.newName,
        operator: RenameConditionOperator.regex,
        value: r'^IMG_\d+$',
        negate: true,
      ),
    );

    final recipe = jsonDecode(encodeRenameRecipe([rule])) as Map;
    final encodedCondition =
        ((recipe['rules'] as List).single as Map)['condition'] as Map;
    final restored = decodeSavedRules(encodeSavedRules([rule])).single;

    expect(encodedCondition['field'], 'newName');
    expect(encodedCondition['operator'], 'regex');
    expect(encodedCondition['negate'], isTrue);
    expect(restored.condition.enabled, isTrue);
    expect(restored.condition.field, RenameConditionField.newName);
    expect(restored.condition.operator, RenameConditionOperator.regex);
    expect(restored.condition.value, r'^IMG_\d+$');
    expect(restored.condition.negate, isTrue);
  });

  test('disabled conditions stay out of preview recipes', () {
    final rule = RenameRule.create(RenameRuleType.prefix);
    final recipe = jsonDecode(encodeRenameRecipe([rule])) as Map;
    final previewRule = (recipe['rules'] as List).single as Map;
    final savedRule =
        (jsonDecode(encodeSavedRules([rule])) as List).single as Map;

    expect(previewRule.containsKey('condition'), isFalse);
    expect(savedRule.containsKey('condition'), isTrue);
  });
}
