import 'package:flick/domain/rename_rule.dart';
import 'package:flick/domain/rule_configuration_history.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'records meaningful configurations, deduplicates, and promotes recency',
    () {
      final incomplete = RenameRule.create(RenameRuleType.newName);
      expect(
        recordRecentRuleConfiguration(history: const [], rules: [incomplete]),
        isEmpty,
      );

      final firstRules = [incomplete.copyWith(value: 'holiday-{n}')];
      final first = recordRecentRuleConfiguration(
        history: const [],
        rules: firstRules,
        savedAt: DateTime.utc(2026, 8, 6, 12),
        snapshotId: 'first',
      );
      final unchanged = recordRecentRuleConfiguration(
        history: first,
        rules: firstRules,
        savedAt: DateTime.utc(2026, 8, 6, 13),
        snapshotId: 'duplicate',
      );
      expect(identical(unchanged, first), isTrue);

      final secondRules = [firstRules.single.copyWith(value: 'work-{n}')];
      final second = recordRecentRuleConfiguration(
        history: first,
        rules: secondRules,
        savedAt: DateTime.utc(2026, 8, 6, 14),
        snapshotId: 'second',
      );
      final promoted = recordRecentRuleConfiguration(
        history: second,
        rules: firstRules,
        savedAt: DateTime.utc(2026, 8, 6, 15),
        snapshotId: 'promoted',
      );

      expect(promoted.map((snapshot) => snapshot.id), ['promoted', 'second']);
      expect(promoted.first.rules.single.value, 'holiday-{n}');
    },
  );

  test('history round-trips and instantiated rules receive fresh ids', () {
    final history = [
      RuleConfigurationSnapshot(
        id: 'snapshot',
        savedAt: DateTime.utc(2026, 8, 6, 12, 34),
        rules: const [
          RenameRule(id: 'prefix', type: RenameRuleType.prefix, value: 'Trip-'),
        ],
      ),
    ];

    final restored = decodeRuleConfigurationHistory(
      encodeRuleConfigurationHistory(history),
    ).single;
    final rules = restored.instantiateRules(instanceId: 'test');

    expect(restored.savedAt, DateTime.utc(2026, 8, 6, 12, 34));
    expect(restored.rules.single.value, 'Trip-');
    expect(rules.single.id, 'history-test-0');
  });

  test('history keeps only the newest twenty distinct configurations', () {
    var history = const <RuleConfigurationSnapshot>[];
    for (var index = 0; index < 25; index++) {
      history = recordRecentRuleConfiguration(
        history: history,
        rules: [
          RenameRule(
            id: 'rule-$index',
            type: RenameRuleType.prefix,
            value: '$index-',
          ),
        ],
        savedAt: DateTime.utc(2026, 8, 6).add(Duration(minutes: index)),
        snapshotId: 'snapshot-$index',
      );
    }

    expect(history, hasLength(maxRecentRuleConfigurations));
    expect(history.first.id, 'snapshot-24');
    expect(history.last.id, 'snapshot-5');
  });

  test('decoder rejects unsupported schema versions', () {
    expect(
      () => decodeRuleConfigurationHistory('{"schemaVersion":2,"history":[]}'),
      throwsFormatException,
    );
  });
}
