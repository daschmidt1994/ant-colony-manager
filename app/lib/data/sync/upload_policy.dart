import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

import '../local/database.dart';

const photosWifiOnlyKey = 'photos_wifi_only';

/// Setting „Fotos nur im WLAN“ (Android): photo uploads wait for Wi-Fi or
/// Ethernet. Records and all other data always sync.
Future<bool> Function() uploadPolicy(AppDatabase db) => () async {
  if (kIsWeb || db.getMeta(photosWifiOnlyKey) != '1') return true;
  try {
    final c = await Connectivity().checkConnectivity();
    return c.contains(ConnectivityResult.wifi) || c.contains(ConnectivityResult.ethernet);
  } on Exception {
    return true;
  }
};
