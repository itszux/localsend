import 'dart:io';

import 'package:localsend_app/util/native/channel/android_channel.dart';
import 'package:logging/logging.dart';

final _logger = Logger('OpenOnReceive');

/// Brings the app to the front because a file request arrived (Android only).
/// Desktop already shows the window from the tray for requests that need an answer.
Future<void> openAppOnReceive() async {
  if (!Platform.isAndroid) {
    return;
  }

  try {
    final allowed = await bringToFrontAndroid();
    if (!allowed) {
      _logger.warning('"Appear on top" is not granted, Android may block opening the app from the background');
    }
  } catch (e) {
    _logger.warning('Could not bring the app to the front', e);
  }
}

/// Asks for "Appear on top" if it is missing, which opening the app from the background requires.
Future<void> ensureOpenOnReceivePermission() async {
  if (!Platform.isAndroid) {
    return;
  }

  try {
    if (!await canBringToFrontAndroid()) {
      await requestBringToFrontPermissionAndroid();
    }
  } catch (e) {
    _logger.warning('Could not request "Appear on top"', e);
  }
}
