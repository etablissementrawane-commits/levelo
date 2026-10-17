import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:unity_ads_plugin/unity_ads_plugin.dart';

/// Owns Unity Ads initialization, placement loading, and click-based pacing.
class UnityAdsService {
  UnityAdsService._();

  static final UnityAdsService instance = UnityAdsService._();

  static const _clickConfigUrl =
      'https://drive.google.com/uc?export=download&id=1kXvJk71Ujlu-azY3hXC3nPMrPNtncixs';
  static const _androidInterstitial = 'Interstitial_Android';
  static const _iosInterstitial = 'Interstitial_iOS';
  static const _androidRewarded = 'Rewarded_Android';
  static const _iosRewarded = 'Rewarded_iOS';

  // Start with a usable frequency so ads still work when the remote config is
  // temporarily unavailable. A valid Drive response replaces this value.
  int _clickNumber = 20;
  int _clickCount = 0;
  bool _initialized = false;
  bool _showingRewarded = false;
  // Reward ads stay off until the remote config explicitly enables them.
  bool _rewardAdsEnabled = false;
  bool _interstitialReady = false;
  bool _rewardedReady = false;
  bool _loadingInterstitial = false;
  int _interstitialRetrySeconds = 5;
  Timer? _interstitialRetryTimer;
  DateTime? _lastClickConfigAttempt;
  Future<void>? _clickConfigRequest;
  Future<bool>? _rewardedLoad;
  String? _interstitialPlacement;
  String? _rewardedPlacement;

  Future<void> initialize() async {
    if (kIsWeb) return;
    await _refreshClickNumber(force: true);

    final target = defaultTargetPlatform;
    final gameId = switch (target) {
      TargetPlatform.android => '6207097',
      TargetPlatform.iOS => '6207096',
      _ => null,
    };
    if (gameId == null) return;

    _interstitialPlacement = target == TargetPlatform.android
        ? _androidInterstitial
        : _iosInterstitial;
    _rewardedPlacement = target == TargetPlatform.android
        ? _androidRewarded
        : _iosRewarded;

    try {
      await UnityAds.init(
        gameId: gameId,
        testMode: false,
        onComplete: () {
          _initialized = true;
          unawaited(_loadInterstitial());
          if (_rewardAdsEnabled) unawaited(_loadRewarded());
        },
        onFailed: (error, message) {
          debugPrint('Unity Ads initialization failed: $error $message');
        },
      );
    } catch (error) {
      debugPrint('Unity Ads initialization error: $error');
    }
  }

  Future<void> _loadClickNumber() async {
    // A failed or stale response must not keep an old enabled value active.
    _rewardAdsEnabled = false;
    try {
      final configUri = Uri.parse(_clickConfigUrl).replace(
        queryParameters: {
          ...Uri.parse(_clickConfigUrl).queryParameters,
          '_': DateTime.now().millisecondsSinceEpoch.toString(),
        },
      );
      final response = await http
          .get(
            configUri,
            headers: const {
              'Accept': 'application/json',
              'Cache-Control': 'no-cache, no-store, max-age=0',
              'Pragma': 'no-cache',
            },
          )
          .timeout(const Duration(seconds: 6));
      if (response.statusCode != 200) {
        debugPrint('Click config request returned ${response.statusCode}.');
        return;
      }
      final config = jsonDecode(utf8.decode(response.bodyBytes));
      if (config is Map) {
        final clickNumber = config['click_number'];
        if (clickNumber is num && clickNumber > 0) {
          _clickNumber = clickNumber.toInt().clamp(1, 1000);
          debugPrint('Interstitial frequency loaded: $_clickNumber clicks.');
        }
        final rewardOn = config['reward_on'];
        if (rewardOn is bool) {
          _rewardAdsEnabled = rewardOn;
          debugPrint(
            'Rewarded ads ${rewardOn ? 'enabled' : 'disabled'} by config.',
          );
        } else {
          debugPrint('Config is missing boolean reward_on; rewarded ads stay off.');
        }
        return;
      }
      debugPrint(
        'Remote ad config was not a JSON object; keeping current ad settings.',
      );
    } catch (error) {
      debugPrint('Unable to read click config from Google Drive: $error');
    }
  }

  Future<void> _refreshClickNumber({bool force = false}) {
    final pending = _clickConfigRequest;
    if (pending != null) return pending;
    final lastAttempt = _lastClickConfigAttempt;
    if (!force &&
        lastAttempt != null &&
        DateTime.now().difference(lastAttempt) < const Duration(minutes: 1)) {
      return Future<void>.value();
    }

    _lastClickConfigAttempt = DateTime.now();
    final request = _loadClickNumber();
    _clickConfigRequest = request;
    return request.whenComplete(() => _clickConfigRequest = null);
  }

  /// Runs a gameplay action and shows an interstitial every configured number
  /// of gameplay actions when a placement is ready.
  Future<void> runGameplayAction(Future<void> Function() action) async {
    await _refreshClickNumber();
    final clickNumber = _clickNumber;
    if (_clickCount < clickNumber) _clickCount++;
    if (_clickCount >= clickNumber) {
      debugPrint(
        'Unity interstitial click threshold reached ($clickNumber).',
      );
      final shown = await _showInterstitialIfReady();
      if (shown) _clickCount = 0;
    }
    await action();
  }

  Future<bool> showRewardedAd() async {
    // Guard at the service boundary too, so no call site can show a disabled ad.
    if (!_rewardAdsEnabled) return false;
    if (_showingRewarded) return false;
    _showingRewarded = true;
    try {
      final placement = _rewardedPlacement;
      if (!_initialized || placement == null) return false;
      if (!_rewardedReady && !await _loadRewarded()) return false;

      _rewardedReady = false;
      final result = Completer<bool>();
      void finish(bool earnedReward) {
        if (!result.isCompleted) result.complete(earnedReward);
      }

      await UnityAds.showVideoAd(
        placementId: placement,
        onComplete: (_) => finish(true),
        onSkipped: (_) => finish(false),
        onFailed: (_, error, message) {
          debugPrint('Rewarded ad failed: $error $message');
          finish(false);
        },
      );
      final earned = await result.future.timeout(
        const Duration(minutes: 2),
        onTimeout: () => false,
      );
      unawaited(_loadRewarded());
      return earned;
    } catch (error) {
      debugPrint('Unable to show rewarded ad: $error');
      unawaited(_loadRewarded());
      return false;
    } finally {
      _showingRewarded = false;
    }
  }

  /// Refreshes the shared remote ad config and returns whether reward videos
  /// should be required before buying a reward.
  Future<bool> rewardAdsEnabled() async {
    await _refreshClickNumber(force: true);
    return _rewardAdsEnabled;
  }

  Future<bool> _loadRewarded() {
    if (_rewardedReady) return Future.value(true);
    final pending = _rewardedLoad;
    if (pending != null) return pending;
    final placement = _rewardedPlacement;
    if (!_initialized || placement == null) return Future.value(false);

    final completer = Completer<bool>();
    _rewardedLoad = completer.future;
    UnityAds.load(
      placementId: placement,
      onComplete: (_) {
        _rewardedReady = true;
        _rewardedLoad = null;
        if (!completer.isCompleted) completer.complete(true);
      },
      onFailed: (_, error, message) {
        debugPrint('Rewarded ad load failed: $error $message');
        _rewardedReady = false;
        _rewardedLoad = null;
        if (!completer.isCompleted) completer.complete(false);
      },
    ).catchError((Object error) {
      debugPrint('Unable to load rewarded ad: $error');
      _rewardedLoad = null;
      if (!completer.isCompleted) completer.complete(false);
    });
    return completer.future.timeout(
      const Duration(seconds: 20),
      onTimeout: () {
        _rewardedLoad = null;
        return false;
      },
    );
  }

  Future<void> _loadInterstitial() async {
    final placement = _interstitialPlacement;
    if (!_initialized || placement == null || _loadingInterstitial) return;
    _loadingInterstitial = true;
    final loaded = Completer<bool>();
    try {
      await UnityAds.load(
        placementId: placement,
        onComplete: (_) {
          _interstitialReady = true;
          _interstitialRetrySeconds = 5;
          _interstitialRetryTimer?.cancel();
          _interstitialRetryTimer = null;
          debugPrint('Unity interstitial is ready.');
          // If the click limit was reached while the placement was loading,
          // don't require another user tap to retry the pending interstitial.
          if (_clickCount >= _clickNumber) {
            unawaited(_showPendingInterstitial());
          }
          if (!loaded.isCompleted) loaded.complete(true);
        },
        onFailed: (_, error, message) {
          _interstitialReady = false;
          debugPrint('Interstitial load failed: $error $message');
          if (!loaded.isCompleted) loaded.complete(false);
        },
      );
      final didLoad = await loaded.future.timeout(
        const Duration(seconds: 20),
        onTimeout: () => false,
      );
      if (!didLoad) _scheduleInterstitialRetry();
    } catch (error) {
      debugPrint('Unable to load interstitial: $error');
      _scheduleInterstitialRetry();
    } finally {
      _loadingInterstitial = false;
    }
  }

  void _scheduleInterstitialRetry() {
    if (!_initialized ||
        _interstitialReady ||
        _interstitialRetryTimer != null) {
      return;
    }
    final delay = _interstitialRetrySeconds;
    _interstitialRetrySeconds = (_interstitialRetrySeconds * 2).clamp(5, 60);
    _interstitialRetryTimer = Timer(Duration(seconds: delay), () {
      _interstitialRetryTimer = null;
      unawaited(_loadInterstitial());
    });
  }

  Future<bool> _showInterstitialIfReady() async {
    final placement = _interstitialPlacement;
    if (!_initialized || !_interstitialReady || placement == null) {
      return false;
    }
    _interstitialReady = false;
    final closed = Completer<bool>();
    var wasPresented = false;
    var shown = false;
    void finish(bool wasShown) {
      if (!closed.isCompleted) closed.complete(wasShown);
    }

    try {
      await UnityAds.showVideoAd(
        placementId: placement,
        onStart: (_) => wasPresented = true,
        onComplete: (_) => finish(true),
        onSkipped: (_) => finish(true),
        onFailed: (_, error, message) {
          debugPrint('Interstitial display failed: $error $message');
          finish(false);
        },
      );
      shown = await closed.future.timeout(
        const Duration(minutes: 2),
        onTimeout: () => wasPresented,
      );
      if (shown) {
        debugPrint('Unity interstitial finished.');
      } else {
        _scheduleInterstitialRetry();
      }
      return shown;
    } catch (error) {
      debugPrint('Unable to show interstitial: $error');
      _scheduleInterstitialRetry();
      return false;
    } finally {
      if (shown) unawaited(_loadInterstitial());
    }
  }

  Future<void> _showPendingInterstitial() async {
    if (_clickCount < _clickNumber || !_interstitialReady) return;
    final shown = await _showInterstitialIfReady();
    if (shown) _clickCount = 0;
  }
}
