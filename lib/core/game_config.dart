class GameConfig {
  static const maxHp = 50;
  static int xpToNext(int level) => 25 + level * 10;
  static const multipliers = [0.5, 1.0, 1.5, 2.0];
  static int reward(int difficulty, int base) =>
      (base * multipliers[difficulty]).round().clamp(1, 999999);
}
