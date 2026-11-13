import 'dart:io';

import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/util/native/channel/android_channel.dart';
import 'package:localsend_isolates/util/transfer_notification.dart';
import 'package:logging/logging.dart';

final _logger = Logger('BackgroundMode');

bool _active = false;

/// Whether background mode is currently applied, i.e. the engine outlives the activity.
/// Then the child isolates must survive the activity being detached as well.
bool get isBackgroundModeActive => _active;

/// Background mode (Android only): keeps the app running after it has been closed, so that other
/// devices can still discover this device and send files to it.
///
/// - a foreground service with a notification keeps the process alive
/// - the Flutter engine (and with it the server and discovery isolates) survives the activity
/// - a multicast lock lets discovery announcements through while the screen is off
///
/// Enabling must happen while the app is in the foreground (Android 12+ restriction).
Future<void> applyBackgroundMode(bool enabled) async {
  if (!Platform.isAndroid) {
    return;
  }

  _logger.info('Applying background mode: $enabled');
  _active = enabled;
  TransferNotification.setBackgroundMode(
    enabled: enabled,
    title: t.appName,
    text: t.settingsTab.general.backgroundModeNotification,
  );

  try {
    await setBackgroundModeAndroid(enabled);
  } catch (e) {
    _logger.warning('Could not apply background mode', e);
  }
}
