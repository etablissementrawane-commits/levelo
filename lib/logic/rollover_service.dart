import 'game_engine.dart';

class RolloverInput {
  final GameStats stats;
  final DateTime lastRollover;
  final DateTime now;
  final List<Map<String, dynamic>> dailies;
  const RolloverInput({
    required this.stats,
    required this.lastRollover,
    required this.now,
    required this.dailies,
  });
}

class RolloverOutcome {
  final GameStats stats;
  final List<Map<String, dynamic>> dailies;
  final int missedCount;
  const RolloverOutcome(this.stats, this.dailies, this.missedCount);
}

/// Applies scheduled missed-daily damage for at most the preceding seven days.
RolloverOutcome runRollover(RolloverInput input, {bool hardMode = true}) {
  final today = DateTime(input.now.year, input.now.month, input.now.day);
  var day = DateTime(
    input.lastRollover.year,
    input.lastRollover.month,
    input.lastRollover.day,
  );
  if (!day.isBefore(today)) {
    return RolloverOutcome(input.stats, input.dailies, 0);
  }
  var stats = input.stats;
  final dailies = input.dailies
      .map((daily) => Map<String, dynamic>.from(daily))
      .toList();
  var missed = 0;
  final daysToCheck = today.difference(day).inDays.clamp(0, 7);
  for (var offset = 0; offset < daysToCheck; offset++) {
    day = day.add(const Duration(days: 1));
    for (final daily in dailies) {
      final weekdays = List<int>.from(
        daily['days'] ?? const [1, 2, 3, 4, 5, 6, 7],
      );
      final completed = DateTime.tryParse(daily['completedDate'] ?? '');
      final completedThatDay =
          completed != null &&
          completed.year == day.year &&
          completed.month == day.month &&
          completed.day == day.day;
      if (weekdays.contains(day.weekday) && !completedThatDay) {
        stats = damage(
          stats,
          daily['difficulty'] as int,
          hardMode: hardMode,
        ).stats;
        daily['streak'] = 0;
        missed++;
      }
    }
  }
  for (final daily in dailies) {
    daily['done'] = false;
  }
  return RolloverOutcome(stats, dailies, missed);
}
