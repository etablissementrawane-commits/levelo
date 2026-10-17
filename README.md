# Levelo: Gamify Habits

Levelo is an offline, single-player habit and task tracker with lightweight RPG rewards.

## Run

```sh
flutter pub get
flutter run
```

## Architecture

- `lib/core` contains game balance and shared colors.
- `lib/logic/game_engine.dart` contains pure XP, gold, level, and damage calculations.
- `lib/main.dart` contains the Hive-backed local app state, glass UI kit, onboarding, task/reward flows, profile, and settings.
- Hive stores local state as JSON-compatible maps; Riverpod exposes that state to the UI.
- `test/` covers game balance and a basic glass widget render.

The MVP keeps all data on device. No account or backend is used.
