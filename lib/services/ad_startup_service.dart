import 'package:app_tracking_transparency/app_tracking_transparency.dart';
import 'package:flutter/foundation.dart';

import 'unity_ads_service.dart';

/// Requests iOS tracking permission before starting the ads SDK.
class AdStartupService {
  AdStartupService._();

  static Future<void> initialize() async {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      try {
        var status = await AppTrackingTransparency.trackingAuthorizationStatus;
        if (status == TrackingStatus.notDetermined) {
          status = await AppTrackingTransparency.requestTrackingAuthorization();
        }
        if (status == TrackingStatus.notDetermined) {
          debugPrint(
            'Tracking authorization is unresolved; Unity Ads startup is deferred.',
          );
          return;
        }
      } catch (error) {
        debugPrint('Unable to request iOS tracking authorization: $error');
        return;
      }
    }

    // Unity Ads can still serve contextual ads if the user denies tracking.
    await UnityAdsService.instance.initialize();
  }
}
