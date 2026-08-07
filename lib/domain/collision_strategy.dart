enum CollisionStrategy {
  fail,
  appendNumber;

  String get wireName => switch (this) {
    CollisionStrategy.fail => 'fail',
    CollisionStrategy.appendNumber => 'appendNumber',
  };

  String get label => switch (this) {
    CollisionStrategy.fail => '發現衝突時阻止',
    CollisionStrategy.appendNumber => '自動附加流水號',
  };

  static CollisionStrategy fromWireName(String? value) {
    return CollisionStrategy.values.firstWhere(
      (strategy) => strategy.wireName == value,
      orElse: () => CollisionStrategy.fail,
    );
  }
}
