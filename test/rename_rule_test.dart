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
}
