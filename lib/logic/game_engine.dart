import '../core/game_config.dart';

class GameStats {
  final int level, xp, hp, gold;
  const GameStats({this.level = 1, this.xp = 0, this.hp = 50, this.gold = 0});
  GameStats copyWith({int? level, int? xp, int? hp, int? gold}) => GameStats(
    level: level ?? this.level,
    xp: xp ?? this.xp,
    hp: hp ?? this.hp,
    gold: gold ?? this.gold,
  );
}

class GameResult {
  final GameStats stats;
  final bool levelUp, fainted;
  const GameResult(this.stats, {this.levelUp = false, this.fainted = false});
}

GameResult earn(GameStats s, int difficulty) {
  var xp = s.xp + GameConfig.reward(difficulty, 10), level = s.level, hp = s.hp;
  var levelUp = false;
  while (xp >= GameConfig.xpToNext(level)) {
    xp -= GameConfig.xpToNext(level);
    level++;
    hp = GameConfig.maxHp;
    levelUp = true;
  }
  return GameResult(
    s.copyWith(
      level: level,
      xp: xp,
      hp: hp,
      gold: s.gold + GameConfig.reward(difficulty, 5),
    ),
    levelUp: levelUp,
  );
}

GameResult damage(GameStats s, int difficulty, {bool hardMode = true}) {
  final hp = s.hp - GameConfig.reward(difficulty, 5);
  if (!hardMode && hp < 1) return GameResult(s.copyWith(hp: 1));
  if (hp > 0) return GameResult(s.copyWith(hp: hp));
  return GameResult(
    s.copyWith(
      level: (s.level - 1).clamp(1, 999999),
      xp: 0,
      hp: GameConfig.maxHp,
      gold: 0,
    ),
    fainted: true,
  );
}
