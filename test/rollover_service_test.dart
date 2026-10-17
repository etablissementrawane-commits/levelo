import 'package:flutter_test/flutter_test.dart';
import 'package:habgame/logic/game_engine.dart';
import 'package:habgame/logic/rollover_service.dart';

void main() {
  test('missed scheduled daily damages HP and resets streak', () {
    final outcome = runRollover(
      RolloverInput(
        stats: const GameStats(),
        lastRollover: DateTime(2026, 10, 12),
        now: DateTime(2026, 10, 13),
        dailies: [
          {
            'difficulty': 1,
            'days': [1, 2, 3, 4, 5, 6, 7],
            'streak': 4,
            'done': false,
          },
        ],
      ),
    );
    expect(outcome.missedCount, 1);
    expect(outcome.stats.hp, 45);
    expect(outcome.dailies.single['streak'], 0);
  });

  test('completed scheduled dates are spared across a multi-day gap', () {
    final outcome = runRollover(
      RolloverInput(
        stats: const GameStats(),
        lastRollover: DateTime(2026, 10, 12),
        now: DateTime(2026, 10, 15),
        dailies: [
          {
            'difficulty': 0,
            'days': [1, 2, 3, 4, 5, 6, 7],
            'streak': 2,
            'done': true,
            'completedDate': '2026-10-13T00:00:00.000',
          },
        ],
      ),
    );
    expect(outcome.missedCount, 2);
    expect(outcome.stats.hp, 44);
    expect(outcome.dailies.single['done'], isFalse);
  });

  test('rollover caps a long gap at seven days and carries death penalty', () {
    final outcome = runRollover(
      RolloverInput(
        stats: const GameStats(hp: 10, gold: 20),
        lastRollover: DateTime(2026, 10, 1),
        now: DateTime(2026, 10, 15),
        dailies: [
          {
            'difficulty': 1,
            'days': [1, 2, 3, 4, 5, 6, 7],
            'streak': 5,
          },
        ],
      ),
    );
    expect(outcome.missedCount, 7);
    expect(outcome.stats.hp, 25);
    expect(outcome.stats.gold, 0);
  });
}
