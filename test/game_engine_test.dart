import 'package:flutter_test/flutter_test.dart';
import 'package:habgame/logic/game_engine.dart';
import 'package:habgame/core/game_config.dart';

void main() {
  test('completion awards difficulty scaled XP and gold', () {
    final result = earn(const GameStats(), 2);
    expect(result.stats.xp, 15);
    expect(result.stats.gold, 8);
  });

  test('level up carries surplus XP and restores HP', () {
    final result = earn(const GameStats(xp: 30, hp: 10), 1);
    expect(result.levelUp, isTrue);
    expect(result.stats.level, 2);
    expect(result.stats.xp, 5);
    expect(result.stats.hp, GameConfig.maxHp);
  });

  test('hard mode faint penalty is forgiving', () {
    final result = damage(const GameStats(hp: 2, gold: 20), 3);
    expect(result.fainted, isTrue);
    expect(result.stats.level, 1);
    expect(result.stats.gold, 0);
    expect(result.stats.hp, GameConfig.maxHp);
  });

  test('soft mode keeps at least one HP', () {
    final result = damage(const GameStats(hp: 2), 3, hardMode: false);
    expect(result.stats.hp, 1);
    expect(result.fainted, isFalse);
  });
}
