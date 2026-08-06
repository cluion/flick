import 'dart:convert';

import 'package:flick/domain/rename_rule.dart';
import 'package:flick/domain/rule_preset.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('starter presets are unique, complete, and safe to preview', () {
    expect(starterRulePresets, hasLength(4));
    expect(
      starterRulePresets.map((preset) => preset.id).toSet(),
      hasLength(starterRulePresets.length),
    );
    expect(
      starterRulePresets.map((preset) => preset.name.toLowerCase()).toSet(),
      hasLength(starterRulePresets.length),
    );
    for (final starter in starterRulePresets) {
      expect(starter.rules, isNotEmpty);
      expect(starter.rules.every((rule) => rule.isComplete), isTrue);
      final recipe = jsonDecode(encodeRenameRecipe(starter.rules)) as Map;
      final rules = recipe['rules'] as List;
      expect(rules.every((rule) => (rule as Map)['enabled'] == true), isTrue);
    }

    final numbered = starterRulePresets.first;
    expect(numbered.rules.map((rule) => rule.type), [
      RenameRuleType.suffix,
      RenameRuleType.sequence,
    ]);
    expect(numbered.rules.first.value, '-');
    expect(numbered.rules.last.padding, 2);
  });

  test('presets round-trip rules and schema version', () {
    final preset = RulePreset(
      id: 'photos',
      name: '照片整理',
      rules: [
        RenameRule(
          id: 'replace',
          type: RenameRuleType.replace,
          value: r'^IMG_',
          replacement: 'trip-',
          useRegex: true,
          condition: const RenameRuleCondition(
            enabled: true,
            field: RenameConditionField.extension,
            operator: RenameConditionOperator.equals,
            value: 'jpg',
          ),
        ),
        const RenameRule(
          id: 'sequence',
          type: RenameRuleType.sequence,
          start: 5,
          padding: 3,
        ),
      ],
    );

    final encoded = encodeRulePresets([preset]);
    final document = jsonDecode(encoded) as Map;
    final restored = decodeRulePresets(encoded).single;

    expect(document['schemaVersion'], currentRulePresetSchemaVersion);
    expect(restored.id, 'photos');
    expect(restored.name, '照片整理');
    expect(restored.rules, hasLength(2));
    expect(restored.rules.first.type, RenameRuleType.replace);
    expect(restored.rules.first.useRegex, isTrue);
    expect(restored.rules.first.condition.enabled, isTrue);
    expect(restored.rules.last.start, 5);
    expect(restored.rules.last.padding, 3);
  });

  test('instantiating a preset gives every working rule a fresh id', () {
    final preset = RulePreset(
      id: 'preset',
      name: '常用',
      rules: const [
        RenameRule(id: 'one', type: RenameRuleType.prefix, value: 'A-'),
        RenameRule(id: 'two', type: RenameRuleType.suffix, value: '-B'),
      ],
    );

    final first = preset.instantiateRules(instanceId: 'first');
    final second = preset.instantiateRules(instanceId: 'second');

    expect(first.map((rule) => rule.id), ['preset-first-0', 'preset-first-1']);
    expect(second.map((rule) => rule.id), [
      'preset-second-0',
      'preset-second-1',
    ]);
    expect(first.map((rule) => rule.value), ['A-', '-B']);
  });

  test('decoder rejects unsupported versions and duplicate names', () {
    expect(
      () => decodeRulePresets('{"schemaVersion":2,"presets":[]}'),
      throwsFormatException,
    );
    expect(
      () => decodeRulePresets(
        '{"schemaVersion":1,"presets":['
        '{"id":"one","name":"Photos","rules":[]},'
        '{"id":"two","name":"photos","rules":[]}'
        ']}',
      ),
      throwsFormatException,
    );
  });

  test('imports preserve existing presets and resolve conflicts safely', () {
    final existing = RulePreset(id: 'existing', name: '照片', rules: const []);
    final imported = [
      RulePreset(id: 'foreign-one', name: '照片', rules: const []),
      RulePreset(id: 'foreign-two', name: '照片（匯入）', rules: const []),
    ];

    final merged = mergeImportedRulePresets(
      existing: [existing],
      imported: imported,
      importId: 'test',
    );

    expect(merged.map((preset) => preset.id), [
      'existing',
      'import-test-0',
      'import-test-1',
    ]);
    expect(merged.map((preset) => preset.name), ['照片', '照片（匯入）', '照片（匯入 2）']);
  });

  test('export file stems are safe across desktop platforms', () {
    expect(rulePresetFileStem(r'  Trip: 2026 / JPG  '), 'Trip- 2026 - JPG');
    expect(rulePresetFileStem('...'), 'flick-preset');
    expect(
      rulePresetFileStem(List.filled(100, 'A').join()),
      List.filled(80, 'A').join(),
    );
  });

  test('preset documents enforce the collection limit', () {
    final preset = RulePreset(id: 'one', name: '常用', rules: const []);
    expect(
      () => encodeRulePresets(List.filled(maxRulePresetCount + 1, preset)),
      throwsFormatException,
    );
  });
}
