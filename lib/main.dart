import 'dart:async';
import 'dart:ui';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:uuid/uuid.dart';
import 'core/app_colors.dart';
import 'core/game_config.dart';
import 'logic/game_engine.dart';
import 'logic/rollover_service.dart';
import 'logic/stored_map_decoder.dart';
import 'services/ad_startup_service.dart';
import 'services/unity_ads_service.dart';

const _uuid = Uuid();
final appStateProvider = ChangeNotifierProvider((ref) => AppState());

class AppState extends ChangeNotifier {
  late Box box;
  GameStats stats = const GameStats();
  String name = 'Hero';
  int avatar = 0, tab = 0;
  bool dark = true, hardMode = true, onboarded = false;
  final List<Map<String, dynamic>> habits = [],
      dailies = [],
      todos = [],
      rewards = [],
      activity = [];
  Future<void> load(Box b) async {
    box = b;
    final m = Map<String, dynamic>.from(box.get('state', defaultValue: {}));
    name = m['name'] ?? name;
    avatar = m['avatar'] ?? 0;
    dark = m['dark'] ?? true;
    hardMode = m['hard'] ?? true;
    onboarded = m['onboarded'] ?? false;
    stats = GameStats(
      level: m['level'] ?? 1,
      xp: m['xp'] ?? 0,
      hp: m['hp'] ?? 50,
      gold: m['gold'] ?? 0,
    );
    _restoreList(m['habits'], habits);
    _restoreList(m['dailies'], dailies);
    _restoreList(m['todos'], todos);
    _restoreList(m['rewards'], rewards);
    _restoreList(m['activity'], activity);
    if (rewards.isEmpty) {
      rewards.addAll([
        _reward('☕', 'Coffee break', 10),
        _reward('📺', 'Watch an episode', 30),
        _reward('🎁', 'Treat yourself', 50),
      ]);
    }
    if (!onboarded && habits.isEmpty) {
      habits.add(
        _task(
          'Read 10 pages',
          'Make a little progress',
          type: 'habit',
          difficulty: 1,
        ),
      );
      dailies.add(
        _task('Drink water', 'Stay hydrated', type: 'daily', difficulty: 0)
          ..['days'] = [1, 2, 3, 4, 5, 6, 7],
      );
      todos.add(_task('Plan the week', '', type: 'todo', difficulty: 1));
    }
    notifyListeners();
  }

  void _restoreList(dynamic stored, List<Map<String, dynamic>> target) {
    target.addAll(decodeStoredMaps(stored));
  }

  Map<String, dynamic> _task(
    String title,
    String notes, {
    required String type,
    required int difficulty,
  }) => {
    'id': _uuid.v4(),
    'title': title,
    'notes': notes,
    'type': type,
    'difficulty': difficulty,
    'positive': true,
    'negative': true,
    'score': 0,
    'done': false,
    'streak': 0,
    'days': [1, 2, 3, 4, 5, 6, 7],
    'due': null,
    'created': DateTime.now().toIso8601String(),
  };
  Map<String, dynamic> _reward(String icon, String title, int cost) => {
    'id': _uuid.v4(),
    'icon': icon,
    'title': title,
    'cost': cost,
  };
  Future<void> save() async {
    await box.put('state', {
      'name': name,
      'avatar': avatar,
      'dark': dark,
      'hard': hardMode,
      'onboarded': onboarded,
      'level': stats.level,
      'xp': stats.xp,
      'hp': stats.hp,
      'gold': stats.gold,
      'habits': habits,
      'dailies': dailies,
      'todos': todos,
      'rewards': rewards,
      'activity': activity.take(20).toList(),
    });
    notifyListeners();
  }

  void selectTab(int index) {
    if (index == tab) return;
    tab = index;
    notifyListeners();
  }

  Future<void> add(String type, Map<String, dynamic> item) async {
    final list = type == 'habit'
        ? habits
        : type == 'daily'
        ? dailies
        : todos;
    list.add(item);
    await save();
  }

  Future<GameResult> complete(
    Map<String, dynamic> item, {
    bool positive = true,
  }) async {
    if (item['type'] == 'daily' && item['done'] == true) {
      item['done'] = false;
      item['streak'] = 0;
      await save();
      return GameResult(stats);
    }
    if (item['type'] == 'habit' && !positive) {
      item['score'] = (item['score'] as int) - 1;
      final result = damage(
        stats,
        item['difficulty'] as int,
        hardMode: hardMode,
      );
      stats = result.stats;
      await _log(item['title'], -GameConfig.reward(item['difficulty'], 5), 0);
      await save();
      HapticFeedback.mediumImpact();
      return result;
    }
    if (item['type'] == 'habit') item['score'] = (item['score'] as int) + 1;
    if (item['type'] == 'daily') {
      item['done'] = true;
      item['completedDate'] = DateUtils.dateOnly(
        DateTime.now(),
      ).toIso8601String();
      item['streak'] = (item['streak'] as int) + 1;
    }
    if (item['type'] == 'todo') {
      item['done'] = true;
      item['completed'] = true;
    }
    final result = earn(stats, item['difficulty'] as int);
    stats = result.stats;
    await _log(
      item['title'],
      GameConfig.reward(item['difficulty'], 10),
      GameConfig.reward(item['difficulty'], 5),
    );
    await save();
    HapticFeedback.lightImpact();
    return result;
  }

  Future<void> _log(String title, int xp, int gold) async {
    activity.insert(0, {
      'title': title,
      'date': DateTime.now().toIso8601String(),
      'xp': xp,
      'gold': gold,
    });
  }

  Future<bool> buy(Map<String, dynamic> r) async {
    if (stats.gold < r['cost']) return false;
    stats = stats.copyWith(gold: stats.gold - (r['cost'] as int));
    await save();
    return true;
  }

  Future<void> rollover() async {
    final last =
        DateTime.tryParse(box.get('rollover', defaultValue: '')) ??
        DateTime.now();
    final today = DateUtils.dateOnly(DateTime.now());
    if (DateUtils.dateOnly(last).isBefore(today)) {
      final outcome = runRollover(
        RolloverInput(
          stats: stats,
          lastRollover: last,
          now: today,
          dailies: dailies,
        ),
        hardMode: hardMode,
      );
      stats = outcome.stats;
      dailies
        ..clear()
        ..addAll(outcome.dailies);
      await box.put('rollover', today.toIso8601String());
      await save();
    }
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const LeveloBootstrap());
}

class LeveloBootstrap extends StatefulWidget {
  const LeveloBootstrap({super.key});

  @override
  State<LeveloBootstrap> createState() => _LeveloBootstrapState();
}

class _LeveloBootstrapState extends State<LeveloBootstrap> {
  late Future<Box> _boxFuture;

  @override
  void initState() {
    super.initState();
    _boxFuture = _openBox();
  }

  Future<Box> _openBox() async {
    await Hive.initFlutter();
    return Hive.openBox('questlog');
  }

  void _retry() => setState(() => _boxFuture = _openBox());

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Levelo: Gamify Habits',
    home: FutureBuilder<Box>(
      future: _boxFuture,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return LeveloLoadingScreen(
            error: 'Could not load your save data.',
            onRetry: _retry,
          );
        }
        final box = snapshot.data;
        if (box == null) return const LeveloLoadingScreen();
        return ProviderScope(child: QuestApp(box: box));
      },
    ),
  );
}

class LeveloLoadingScreen extends StatefulWidget {
  final String? error;
  final VoidCallback? onRetry;
  const LeveloLoadingScreen({super.key, this.error, this.onRetry});

  @override
  State<LeveloLoadingScreen> createState() => _LeveloLoadingScreenState();
}

class _LeveloLoadingScreenState extends State<LeveloLoadingScreen>
    with TickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 950),
  )..repeat(reverse: true);
  late final AnimationController _loadingDots = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _pulse.dispose();
    _loadingDots.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFFE6F8ED),
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ScaleTransition(
            scale: Tween<double>(begin: .94, end: 1.04).animate(
              CurvedAnimation(parent: _pulse, curve: Curves.easeInOut),
            ),
            child: Image.asset(
              'assets/levelo_splash.png',
              width: 160,
              height: 160,
              filterQuality: FilterQuality.high,
            ),
          ),
          const SizedBox(height: 22),
          if (widget.error == null)
            Column(
              children: [
                const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(
                    strokeWidth: 3,
                    color: Color(0xFF4F9B63),
                  ),
                ),
                const SizedBox(height: 12),
                AnimatedBuilder(
                  animation: _loadingDots,
                  builder: (context, _) {
                    final dotCount = (_loadingDots.value * 4).floor() % 4;
                    final dots = List.filled(dotCount, '.').join();
                    return Text(
                      'Loading$dots',
                      style: const TextStyle(
                        color: Color(0xFF285A37),
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        letterSpacing: .3,
                      ),
                    );
                  },
                ),
              ],
            )
          else ...[
            Text(
              widget.error!,
              style: const TextStyle(color: Color(0xFF285A37)),
            ),
            const SizedBox(height: 12),
            FilledButton(onPressed: widget.onRetry, child: const Text('Retry')),
          ],
        ],
      ),
    ),
  );
}

class QuestApp extends ConsumerStatefulWidget {
  final Box box;
  const QuestApp({super.key, required this.box});
  @override
  ConsumerState<QuestApp> createState() => _QuestAppState();
}

class _QuestAppState extends ConsumerState<QuestApp>
    with WidgetsBindingObserver {
  bool _stateReady = false;
  bool _adsStartupScheduled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final s = ref.read(appStateProvider);
      await s.load(widget.box);
      await s.rollover();
      if (mounted) setState(() => _stateReady = true);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ref.read(appStateProvider).rollover();
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(appStateProvider);
    if (_stateReady && s.onboarded && !_adsStartupScheduled) {
      _adsStartupScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(AdStartupService.initialize());
      });
    }
    final dark = s.dark;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Levelo: Gamify Habits',
      theme: ThemeData(
        useMaterial3: true,
        brightness: dark ? Brightness.dark : Brightness.light,
        scaffoldBackgroundColor: dark ? AppColors.base : AppColors.lightBase,
        colorScheme: ColorScheme.fromSeed(
          seedColor: dark ? AppColors.accent : AppColors.lightAccent,
          brightness: dark ? Brightness.dark : Brightness.light,
        ),
        textTheme: const TextTheme(
          bodyLarge: TextStyle(fontSize: 17),
          titleLarge: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
        ),
      ),
      home: !_stateReady
          ? const LeveloLoadingScreen()
          : s.onboarded
          ? const HomeScreen()
          : const Onboarding(),
    );
  }
}

class Glass extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  final double radius;
  final VoidCallback? onTap;
  final bool blur;
  const Glass({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.radius = 24,
    this.onTap,
    this.blur = false,
  });
  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final reduce = MediaQuery.of(context).accessibleNavigation;
    Widget w = ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(
          sigmaX: blur && !reduce ? 20 : 0,
          sigmaY: blur && !reduce ? 20 : 0,
        ),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: (dark ? Colors.white : Colors.white).withValues(
              alpha: reduce ? .94 : (dark ? .10 : .68),
            ),
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(color: Colors.white.withValues(alpha: .18)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: .18),
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: child,
        ),
      ),
    );
    return onTap == null ? w : GestureDetector(onTap: onTap, child: w);
  }
}

class Background extends StatefulWidget {
  final Widget child;
  const Background({super.key, required this.child});
  @override
  State<Background> createState() => _BackgroundState();
}

class _BackgroundState extends State<Background>
    with SingleTickerProviderStateMixin {
  late final AnimationController c = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 16),
  )..repeat(reverse: true);
  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: c,
    builder: (context, _) {
      return Stack(
        fit: StackFit.expand,
        children: [
          Container(
            color: Theme.of(context).brightness == Brightness.dark
                ? AppColors.base
                : AppColors.lightBase,
          ),
          Positioned(
            top: -70 + 50 * c.value,
            left: -60 + 120 * c.value,
            child: _blob(AppColors.accent),
          ),
          Positioned(
            top: 250 - 70 * c.value,
            right: -130 + 80 * c.value,
            child: _blob(const Color(0xFF55D6B1)),
          ),
          Positioned(
            bottom: -120,
            left: 40 + 160 * c.value,
            child: _blob(const Color(0xFFD7F28A)),
          ),
          widget.child,
        ],
      );
    },
  );
  Widget _blob(Color c) => ImageFiltered(
    imageFilter: ImageFilter.blur(sigmaX: 75, sigmaY: 75),
    child: Container(
      width: 250,
      height: 250,
      decoration: BoxDecoration(
        color: c.withValues(alpha: .38),
        shape: BoxShape.circle,
      ),
    ),
  );
}

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});
  static const titles = ['Habits', 'Dailies', 'To-Dos', 'Rewards', 'Profile'];
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(appStateProvider);
    return Background(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Column(
            children: [
              if (s.tab < 4) PlayerHeader(s: s),
              Expanded(
                child: IndexedStack(
                  index: s.tab,
                  children: const [
                    TaskScreen(type: 'habit'),
                    TaskScreen(type: 'daily'),
                    TaskScreen(type: 'todo'),
                    RewardsScreen(),
                    ProfileScreen(),
                  ],
                ),
              ),
            ],
          ),
        ),
        bottomNavigationBar: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
            child: Glass(
              blur: true,
              radius: 30,
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: List.generate(
                  5,
                  (i) => Semantics(
                    label: titles[i],
                    button: true,
                    child: IconButton(
                      onPressed: () => UnityAdsService.instance
                          .runGameplayAction(() async => s.selectTab(i)),
                      icon: Icon(
                        [
                          CupertinoIcons.checkmark_circle,
                          CupertinoIcons.sun_max,
                          CupertinoIcons.list_bullet,
                          CupertinoIcons.gift,
                          CupertinoIcons.person,
                        ][i],
                        color: s.tab == i ? AppColors.accent : null,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class GoldCoinIcon extends StatelessWidget {
  final double size;
  const GoldCoinIcon({super.key, this.size = 18});

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      gradient: const LinearGradient(
        colors: [Color(0xFFFFE680), Color(0xFFFFB800)],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ),
      border: Border.all(color: const Color(0xFFFFF1B8), width: 1),
      boxShadow: const [
        BoxShadow(color: Color(0x40FFB800), blurRadius: 4, offset: Offset(0, 1)),
      ],
    ),
    alignment: Alignment.center,
    child: Icon(
      Icons.star_rounded,
      size: size * .66,
      color: const Color(0xFF9A5A00),
    ),
  );
}

class PlayerHeader extends StatelessWidget {
  final AppState s;
  const PlayerHeader({super.key, required this.s});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
    child: Glass(
      blur: true,
      padding: const EdgeInsets.all(14),
      child: Column(
        children: [
          Row(
            children: [
              Text(
                [
                  '🧙',
                  '🦊',
                  '🐱',
                  '🐼',
                  '🦁',
                  '🐸',
                  '🐨',
                  '🐯',
                  '🐵',
                  '🐰',
                  '🐻',
                  '🐲',
                ][s.avatar % 12],
                style: const TextStyle(fontSize: 30),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      s.name,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Text(
                      'LEVEL ${s.stats.level}',
                      style: const TextStyle(
                        color: AppColors.accent,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const GoldCoinIcon(size: 18),
                  const SizedBox(width: 5),
                  Text(
                    '${s.stats.gold}',
                    style: const TextStyle(
                      color: AppColors.gold,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          _progress('HP', s.stats.hp / GameConfig.maxHp, AppColors.hp),
          const SizedBox(height: 7),
          _progress(
            'XP',
            s.stats.xp / GameConfig.xpToNext(s.stats.level),
            AppColors.xp,
          ),
        ],
      ),
    ),
  );
}

Widget _progress(String label, double value, Color color) => Row(
  children: [
    SizedBox(
      width: 25,
      child: Text(label, style: const TextStyle(fontSize: 10)),
    ),
    Expanded(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(9),
        child: LinearProgressIndicator(
          value: value.clamp(0, 1),
          minHeight: 8,
          backgroundColor: Colors.white12,
          color: color,
        ),
      ),
    ),
    const SizedBox(width: 8),
    Text('${(value * 100).round()}%', style: const TextStyle(fontSize: 10)),
  ],
);

class TaskScreen extends ConsumerWidget {
  final String type;
  const TaskScreen({super.key, required this.type});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(appStateProvider);
    final items = type == 'habit'
        ? state.habits
        : type == 'daily'
        ? state.dailies
        : state.todos;
    final visible = type == 'todo'
        ? items.where((item) => item['completed'] != true).toList()
        : items;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 10),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  type == 'todo'
                      ? 'To-Dos'
                      : type == 'daily'
                      ? 'Dailies'
                      : 'Habits',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
              ),
              IconButton(
                onPressed: () => UnityAdsService.instance.runGameplayAction(
                  () => _edit(context, ref, type),
                ),
                icon: const Icon(
                  CupertinoIcons.add_circled_solid,
                  color: AppColors.accent,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: visible.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        CupertinoIcons.sparkles,
                        size: 54,
                        color: AppColors.accent,
                      ),
                      const Text('Nothing here yet'),
                      FilledButton(
                        onPressed: () => UnityAdsService.instance
                            .runGameplayAction(() => _edit(context, ref, type)),
                        child: Text('Create your first $type'),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  physics: const BouncingScrollPhysics(),
                  padding: const EdgeInsets.all(16),
                  itemCount: visible.length,
                  itemBuilder: (context, index) {
                    final item = visible[index];
                    return Dismissible(
                      key: ValueKey(item['id']),
                      onDismissed: (_) {
                        items.remove(item);
                        state.save();
                      },
                      background: const ColoredBox(color: AppColors.danger),
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Glass(
                          child: Row(
                            children: [
                              _CompletionButton(
                                key: ValueKey('complete-${item['id']}'),
                                title: item['title'].toString(),
                                isHabit: type == 'habit',
                                isComplete:
                                    item['done'] == true ||
                                    item['completed'] == true,
                                onComplete: () async {
                                  final result = await state.complete(item);
                                  if (!context.mounted) return;
                                  if (result.levelUp) {
                                    _levelUp(context, result.stats.level);
                                  }
                                  if (result.fainted) _faint(context);
                                },
                              ),
                              Expanded(
                                child: GestureDetector(
                                  onTap: () => UnityAdsService.instance
                                      .runGameplayAction(
                                        () => _edit(
                                          context,
                                          ref,
                                          type,
                                          existing: item,
                                        ),
                                      ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        item['title'],
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      if ((item['notes'] ?? '')
                                          .toString()
                                          .isNotEmpty)
                                        Text(
                                          item['notes'],
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      Text(
                                        type == 'habit'
                                            ? 'Score ${item['score']}'
                                            : type == 'daily'
                                            ? '🔥 ${item['streak']} day streak'
                                            : _difficulty(item['difficulty']),
                                        style: const TextStyle(
                                          color: AppColors.accent,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              if (type == 'habit' && item['negative'] == true)
                                IconButton(
                                  tooltip: 'Negative habit action',
                                  icon: const Icon(
                                    CupertinoIcons.minus_circle_fill,
                                    color: AppColors.hp,
                                  ),
                                  onPressed: () async {
                                    await UnityAdsService.instance
                                        .runGameplayAction(() async {
                                          final result = await state.complete(
                                            item,
                                            positive: false,
                                          );
                                          if (!context.mounted) return;
                                          if (result.fainted) _faint(context);
                                        });
                                  },
                                ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

String _difficulty(dynamic d) =>
    ['Trivial', 'Easy', 'Medium', 'Hard'][(d as int).clamp(0, 3)];

class _CompletionButton extends StatefulWidget {
  const _CompletionButton({
    super.key,
    required this.title,
    required this.isHabit,
    required this.isComplete,
    required this.onComplete,
  });

  final String title;
  final bool isHabit;
  final bool isComplete;
  final Future<void> Function() onComplete;

  @override
  State<_CompletionButton> createState() => _CompletionButtonState();
}

class _CompletionButtonState extends State<_CompletionButton> {
  bool _busy = false;
  bool _showHabitSuccess = false;

  Future<void> _complete() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _showHabitSuccess = widget.isHabit;
    });
    try {
      await UnityAdsService.instance.runGameplayAction(widget.onComplete);
      if (widget.isHabit) {
        await Future<void>.delayed(const Duration(milliseconds: 650));
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _showHabitSuccess = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final checked = widget.isComplete || _showHabitSuccess;
    return IconButton(
      tooltip: _busy
          ? 'Saving ${widget.title}'
          : checked
          ? 'Completed ${widget.title}'
          : 'Complete ${widget.title}',
      onPressed: _busy ? null : _complete,
      icon: AnimatedScale(
        scale: _showHabitSuccess ? 1.28 : 1,
        duration: const Duration(milliseconds: 320),
        curve: Curves.elasticOut,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          switchInCurve: Curves.easeOutBack,
          transitionBuilder: (child, animation) =>
              ScaleTransition(scale: animation, child: child),
          child: Icon(
            key: ValueKey(checked),
            checked
                ? CupertinoIcons.checkmark_circle_fill
                : CupertinoIcons.circle,
            color: checked ? AppColors.success : AppColors.accent,
          ),
        ),
      ),
    );
  }
}

Future<void> _edit(
  BuildContext context,
  WidgetRef ref,
  String type, {
  Map<String, dynamic>? existing,
}) async {
  final state = ref.read(appStateProvider);
  final title = TextEditingController(text: existing?['title'] ?? '');
  final notes = TextEditingController(text: existing?['notes'] ?? '');
  var difficulty = existing?['difficulty'] ?? 1;
  var positive = existing?['positive'] ?? true;
  var negative = existing?['negative'] ?? true;
  String? titleError;
  final isDark = Theme.of(context).brightness == Brightness.dark;
  final names = {'habit': 'habit', 'daily': 'daily', 'todo': 'to-do'};
  final label = names[type] ?? type;

  final navigator = Navigator.of(context, rootNavigator: true);
  final route = DialogRoute<Map<String, dynamic>>(
    context: context,
    themes: InheritedTheme.capture(from: context, to: navigator.context),
    barrierColor: Colors.black.withValues(alpha: .66),
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setDialogState) {
        final maxHeight =
            MediaQuery.sizeOf(context).height -
            MediaQuery.viewInsetsOf(context).bottom -
            36;
        return AnimatedPadding(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: Dialog(
            backgroundColor: Colors.transparent,
            insetPadding: const EdgeInsets.symmetric(
              horizontal: 28,
              vertical: 20,
            ),
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: .94, end: 1),
              duration: const Duration(milliseconds: 280),
              curve: Curves.easeOutBack,
              builder: (context, scale, child) => Opacity(
                opacity: ((scale - .94) / .06).clamp(0, 1),
                child: Transform.scale(scale: scale, child: child),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(30),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                  child: Container(
                    constraints: BoxConstraints(
                      maxWidth: 380,
                      maxHeight: maxHeight,
                    ),
                    decoration: BoxDecoration(
                      color: isDark
                          ? AppColors.dialogSurface.withValues(alpha: .96)
                          : const Color(0xFFF7FAF4).withValues(alpha: .97),
                      borderRadius: BorderRadius.circular(30),
                      border: Border.all(
                        color: AppColors.accent.withValues(alpha: .24),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: .35),
                          blurRadius: 34,
                          offset: const Offset(0, 14),
                        ),
                      ],
                    ),
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(22, 20, 22, 18),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  existing == null
                                      ? 'New $label'
                                      : 'Edit $label',
                                  style: Theme.of(context).textTheme.titleLarge
                                      ?.copyWith(fontWeight: FontWeight.w700),
                                ),
                              ),
                              DecoratedBox(
                                decoration: BoxDecoration(
                                  color: AppColors.accent.withValues(
                                    alpha: .14,
                                  ),
                                  shape: BoxShape.circle,
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.all(9),
                                  child: Icon(
                                    type == 'habit'
                                        ? CupertinoIcons.flame_fill
                                        : type == 'daily'
                                        ? CupertinoIcons.sun_max_fill
                                        : CupertinoIcons.flag_fill,
                                    size: 18,
                                    color: AppColors.lightAccent,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 18),
                          _editorField(
                            title,
                            'Title',
                            error: titleError,
                            onChanged: (_) {
                              if (titleError != null) {
                                setDialogState(() => titleError = null);
                              }
                            },
                          ),
                          const SizedBox(height: 10),
                          _editorField(notes, 'Notes (optional)', maxLines: 2),
                          const SizedBox(height: 15),
                          Text(
                            'DIFFICULTY',
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(
                                  letterSpacing: 1.2,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.lightAccent,
                                ),
                          ),
                          const SizedBox(height: 7),
                          CupertinoTheme(
                            data: CupertinoThemeData(
                              primaryColor: AppColors.lightAccent,
                            ),
                            child: CupertinoSlidingSegmentedControl<int>(
                              groupValue: difficulty,
                              backgroundColor: isDark
                                  ? Colors.white.withValues(alpha: .09)
                                  : Colors.black.withValues(alpha: .06),
                              thumbColor: AppColors.accent,
                              children: {
                                for (var i = 0; i < 4; i++)
                                  i: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 5,
                                      vertical: 8,
                                    ),
                                    child: Text(
                                      ['Tiny', 'Easy', 'Med', 'Hard'][i],
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: difficulty == i
                                            ? FontWeight.w700
                                            : FontWeight.w500,
                                        color: difficulty == i
                                            ? const Color(0xFF182116)
                                            : null,
                                      ),
                                    ),
                                  ),
                              },
                              onValueChanged: (value) => setDialogState(
                                () => difficulty = value ?? difficulty,
                              ),
                            ),
                          ),
                          if (type == 'habit') ...[
                            const SizedBox(height: 13),
                            _actionToggle(
                              'Positive action (+)',
                              'Earn XP and gold',
                              positive,
                              (v) => setDialogState(() => positive = v),
                            ),
                            const SizedBox(height: 5),
                            _actionToggle(
                              'Negative action (−)',
                              'Lose HP',
                              negative,
                              (v) => setDialogState(() => negative = v),
                            ),
                          ],
                          const SizedBox(height: 18),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              TextButton(
                                onPressed: () => Navigator.pop(dialogContext),
                                child: const Text('Cancel'),
                              ),
                              const SizedBox(width: 8),
                              FilledButton.icon(
                                style: FilledButton.styleFrom(
                                  backgroundColor: AppColors.accent,
                                  foregroundColor: const Color(0xFF182116),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 20,
                                    vertical: 12,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                ),
                                onPressed: () {
                                  if (title.text.trim().isEmpty) {
                                    setDialogState(
                                      () => titleError =
                                          'Give this quest a title',
                                    );
                                    return;
                                  }
                                  final item = Map<String, dynamic>.from(
                                    existing ??
                                        state._task(
                                          title.text.trim(),
                                          notes.text.trim(),
                                          type: type,
                                          difficulty: difficulty,
                                        ),
                                  );
                                  item['title'] = title.text.trim();
                                  item['notes'] = notes.text.trim();
                                  item['difficulty'] = difficulty;
                                  item['positive'] = positive;
                                  item['negative'] = negative;
                                  Navigator.pop(dialogContext, item);
                                },
                                icon: const Icon(
                                  CupertinoIcons.checkmark,
                                  size: 17,
                                ),
                                label: const Text('Save quest'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    ),
  );
  final draft = await navigator.push<Map<String, dynamic>>(route);
  // The push future resolves as soon as pop begins. Keep the controllers alive
  // until the reverse animation has removed the dialog's overlay entries.
  await route.completed;
  if (draft != null) {
    if (existing == null) {
      await state.add(type, draft);
    } else {
      final items = type == 'habit'
          ? state.habits
          : type == 'daily'
          ? state.dailies
          : state.todos;
      final index = items.indexWhere((item) => item['id'] == draft['id']);
      if (index != -1) items[index] = draft;
      await state.save();
    }
  }
  title.dispose();
  notes.dispose();
}

Widget _editorField(
  TextEditingController controller,
  String label, {
  int maxLines = 1,
  String? error,
  ValueChanged<String>? onChanged,
}) => TextField(
  controller: controller,
  maxLines: maxLines,
  textCapitalization: TextCapitalization.sentences,
  onChanged: onChanged,
  decoration: InputDecoration(
    labelText: label,
    errorText: error,
    filled: true,
    fillColor: Colors.white.withValues(alpha: .075),
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(18),
      borderSide: BorderSide.none,
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(18),
      borderSide: BorderSide(color: Colors.white.withValues(alpha: .05)),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(18),
      borderSide: const BorderSide(color: AppColors.lightAccent, width: 1.3),
    ),
  ),
);

Widget _actionToggle(
  String title,
  String subtitle,
  bool value,
  ValueChanged<bool> onChanged,
) => Row(
  children: [
    Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
          Text(
            subtitle,
            style: const TextStyle(fontSize: 12, color: Colors.white60),
          ),
        ],
      ),
    ),
    const SizedBox(width: 8),
    Switch.adaptive(
      value: value,
      activeThumbColor: AppColors.lightAccent,
      onChanged: onChanged,
    ),
  ],
);
Widget _field(TextEditingController controller, String label) => TextField(
  controller: controller,
  decoration: InputDecoration(
    labelText: label,
    floatingLabelBehavior: FloatingLabelBehavior.always,
    filled: true,
    fillColor: Colors.white.withValues(alpha: .07),
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(18),
      borderSide: BorderSide.none,
    ),
  ),
);

class RewardsScreen extends ConsumerWidget {
  const RewardsScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(appStateProvider);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 18),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Rewards',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
              ),
              IconButton(
                onPressed: () => UnityAdsService.instance.runGameplayAction(
                  () => _addReward(context, ref),
                ),
                icon: const Icon(
                  CupertinoIcons.add_circled_solid,
                  color: AppColors.accent,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.all(16),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              // Keep enough vertical room for the reward label, cost and
              // button even on devices with scaled text and tight rounding.
              childAspectRatio: .92,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
            ),
            itemCount: state.rewards.length,
            itemBuilder: (context, index) {
              final reward = state.rewards[index];
              return Glass(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(reward['icon'], style: const TextStyle(fontSize: 34)),
                    Text(reward['title'], textAlign: TextAlign.center),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const GoldCoinIcon(size: 16),
                        const SizedBox(width: 5),
                        Text(
                          '${reward['cost']}',
                          style: const TextStyle(color: AppColors.gold),
                        ),
                      ],
                    ),
                    FilledButton.tonal(
                      onPressed: state.stats.gold >= reward['cost']
                          ? () => _buyReward(context, ref, reward)
                          : null,
                      child: const Text('Buy'),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

Future<void> _addReward(BuildContext context, WidgetRef ref) async {
  final title = TextEditingController();
  final cost = TextEditingController(text: '10');
  final icon = TextEditingController(text: '🎁');
  final navigator = Navigator.of(context, rootNavigator: true);
  final route = DialogRoute<Map<String, dynamic>>(
    context: context,
    themes: InheritedTheme.capture(from: context, to: navigator.context),
    builder: (ctx) => AlertDialog(
      title: const Text('New reward'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _field(title, 'Title'),
          const SizedBox(height: 12),
          _field(icon, 'Emoji'),
          const SizedBox(height: 12),
          _field(cost, 'Gold cost'),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.pop(ctx, {
              'id': _uuid.v4(),
              'title': title.text,
              'icon': icon.text,
              'cost': int.tryParse(cost.text) ?? 10,
            });
          },
          child: const Text('Save'),
        ),
      ],
    ),
  );
  final draft = await navigator.push<Map<String, dynamic>>(route);
  await route.completed;
  if (draft != null) {
    final state = ref.read(appStateProvider);
    state.rewards.add(draft);
    await state.save();
  }
  title.dispose();
  cost.dispose();
  icon.dispose();
}

Future<void> _buyReward(
  BuildContext context,
  WidgetRef ref,
  Map<String, dynamic> reward,
) async {
  final appState = ref.read(appStateProvider);
  if (appState.stats.gold < reward['cost']) return;

  final ads = UnityAdsService.instance;
  final requireRewardAd = await ads.rewardAdsEnabled();
  if (!context.mounted) return;

  final messenger = ScaffoldMessenger.of(context);
  if (requireRewardAd) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(content: Text('Preparing your reward video…')),
      );
    final earnedReward = await ads.showRewardedAd();
    if (!context.mounted) return;
    messenger.hideCurrentSnackBar();
    if (!earnedReward) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text(
              'Watch the full video to unlock this reward. If no ad loads, try again shortly.',
            ),
          ),
        );
      return;
    }
  }

  final state = ref.read(appStateProvider);
  if (await state.buy(reward) && context.mounted) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('${reward['title']} unlocked!')));
  }
}

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(appStateProvider);
    final totalXp = state.activity.fold<int>(
      state.stats.xp,
      (sum, e) => sum + (e['xp'] as int),
    );
    const avatars = [
      '🧙',
      '🦊',
      '🐱',
      '🐼',
      '🦁',
      '🐸',
      '🐨',
      '🐯',
      '🐵',
      '🐰',
      '🐻',
      '🐲',
    ];
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text('Your Hero', style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 16),
        Glass(
          child: Column(
            children: [
              Text(
                avatars[state.avatar % avatars.length],
                style: const TextStyle(fontSize: 60),
              ),
              Text(state.name, style: Theme.of(context).textTheme.titleLarge),
              Wrap(
                children: List.generate(
                  avatars.length,
                  (i) => ChoiceChip(
                    label: Text(avatars[i]),
                    selected: state.avatar == i,
                    onSelected: (_) {
                      state.avatar = i;
                      state.save();
                    },
                  ),
                ),
              ),
              TextField(
                controller: TextEditingController(text: state.name),
                decoration: const InputDecoration(labelText: 'Hero name'),
                onSubmitted: (v) {
                  state.name = v;
                  state.save();
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            _stat('Level', '${state.stats.level}'),
            _stat('Total XP', '$totalXp'),
            _stat('Gold', '${state.stats.gold}'),
          ],
        ),
        const SizedBox(height: 12),
        Glass(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Recent activity',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              ...state.activity
                  .take(10)
                  .map(
                    (a) => ListTile(
                      dense: true,
                      title: Text(a['title']),
                      trailing: Text('+${a['xp']} XP'),
                    ),
                  ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Glass(
          onTap: () => Navigator.push(
            context,
            CupertinoPageRoute<void>(builder: (_) => const SettingsScreen()),
          ),
          child: const Row(
            children: [
              Icon(CupertinoIcons.gear),
              SizedBox(width: 12),
              Text('Settings'),
              Spacer(),
              Icon(CupertinoIcons.chevron_right),
            ],
          ),
        ),
      ],
    );
  }
}

Widget _stat(String label, String value) => Expanded(
  child: Padding(
    padding: const EdgeInsets.all(4),
    child: Glass(
      child: Column(
        children: [
          Text(value, style: const TextStyle(fontSize: 20)),
          Text(label),
        ],
      ),
    ),
  ),
);

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(appStateProvider);
    return Background(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: const Text('Settings'),
          backgroundColor: Colors.transparent,
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Glass(
              child: Column(
                children: [
                  SwitchListTile(
                    title: const Text('Dark appearance'),
                    value: state.dark,
                    onChanged: (v) {
                      state.dark = v;
                      state.save();
                    },
                  ),
                  SwitchListTile(
                    title: const Text('Hard mode'),
                    value: state.hardMode,
                    onChanged: (v) {
                      state.hardMode = v;
                      state.save();
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Glass(
              onTap: () async {
                final confirmed = await showCupertinoDialog<bool>(
                  context: context,
                  builder: (ctx) => CupertinoAlertDialog(
                    title: const Text('Reset all progress?'),
                    actions: [
                      CupertinoDialogAction(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('Cancel'),
                      ),
                      CupertinoDialogAction(
                        isDestructiveAction: true,
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('Reset'),
                      ),
                    ],
                  ),
                );
                if (confirmed == true) {
                  await state.box.clear();
                  state.habits.clear();
                  state.dailies.clear();
                  state.todos.clear();
                  state.rewards.clear();
                  state.activity.clear();
                  state.stats = const GameStats();
                  state.onboarded = false;
                  await state.save();
                  if (context.mounted) Navigator.pop(context);
                }
              },
              child: const Text(
                'Reset all data',
                style: TextStyle(color: AppColors.danger),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class Onboarding extends ConsumerStatefulWidget {
  const Onboarding({super.key});
  @override
  ConsumerState<Onboarding> createState() => _OnboardingState();
}

class _OnboardingState extends ConsumerState<Onboarding> {
  final controller = PageController();
  final name = TextEditingController(text: 'Hero');
  int page = 0, avatar = 0;
  static const avatars = [
    '🧙',
    '🦊',
    '🐱',
    '🐼',
    '🦁',
    '🐸',
    '🐨',
    '🐯',
    '🐵',
    '🐰',
    '🐻',
    '🐲',
  ];
  @override
  Widget build(BuildContext context) => Background(
    child: Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: PageView(
                controller: controller,
                onPageChanged: (v) => setState(() => page = v),
                children: [
                  _intro(
                    'Welcome to Levelo',
                    'Turn small wins into a great adventure.',
                  ),
                  _intro(
                    'How it works',
                    'Build habits, finish daily routines, complete to-dos, and spend gold on rewards.',
                  ),
                  Center(
                    child: Glass(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text(
                            'Choose your hero',
                            style: TextStyle(fontSize: 26),
                          ),
                          Wrap(
                            children: List.generate(
                              avatars.length,
                              (i) => ChoiceChip(
                                label: Text(avatars[i]),
                                selected: avatar == i,
                                onSelected: (_) => setState(() => avatar = i),
                              ),
                            ),
                          ),
                          TextField(
                            controller: name,
                            decoration: const InputDecoration(
                              labelText: 'Your name',
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 34),
              child: FilledButton(
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(62),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 28,
                    vertical: 16,
                  ),
                  textStyle: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
                onPressed: () async {
                  if (page < 2) {
                    await controller.nextPage(
                      duration: const Duration(milliseconds: 280),
                      curve: Curves.easeOut,
                    );
                    return;
                  }
                  final state = ref.read(appStateProvider);
                  state.name = name.text.trim().isEmpty
                      ? 'Hero'
                      : name.text.trim();
                  state.avatar = avatar;
                  state.onboarded = true;
                  await state.save();
                },
                child: Text(page == 2 ? 'Start your adventure' : 'Continue'),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  Widget _intro(String title, String body) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Glass(
        blur: true,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '✦',
              style: TextStyle(fontSize: 56, color: AppColors.accent),
            ),
            Text(
              title,
              style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
            ),
            Text(body, textAlign: TextAlign.center),
          ],
        ),
      ),
    ),
  );
}

void _levelUp(BuildContext context, int level) {
  HapticFeedback.heavyImpact();
  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('✨ Level up!'),
      content: Text('You reached level $level and your HP is restored.'),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Let’s go'),
        ),
      ],
    ),
  );
}

void _faint(BuildContext context) {
  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('You fainted'),
      content: const Text(
        'You lost one level and your gold. Your HP has been restored.',
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Continue'),
        ),
      ],
    ),
  );
}
