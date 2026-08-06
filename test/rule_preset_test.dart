import 'dart:convert';

import 'package:flick/domain/rename_rule.dart';
import 'package:flick/domain/rule_preset.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
}
