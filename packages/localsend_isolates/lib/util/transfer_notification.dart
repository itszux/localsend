import 'package:flutter_foreground_task/flutter_foreground_task.dart' show ForegroundServiceTypes;
import 'package:localsend_isolates/util/file_size_helper.dart';
import 'package:localsend_isolates/util/file_speed_helper.dart';
import 'package:localsend_isolates/util/foreground_service.dart';
import 'package:localsend_isolates/util/notification_strings.dart';

/// A transfer only becomes fast enough to measure after a while; the first chunks are not
/// representative. Same threshold as `ProgressPage`.
const _minBytesForSpeed = 500 * 1024;

/// Drives the single foreground service notification on behalf of all running transfers.
///
/// There is one notification but there can be several transfers: receiving is limited to one
/// session, sending is not, and both directions can run at the same time. So the service is
/// reference counted here - it starts with the first transfer, ends with the last one, and the
/// notification shows the sum of everything in flight.
class TransferNotification {
  TransferNotification._();

  static final _transfers = <String, _Transfer>{};
  static NotificationStrings? _strings;

  /// The idle notification while background mode keeps the service running without any transfer.
  /// Null while background mode is off.
  static _IdleNotification? _idle;

  /// Injects the translated strings. Must be called before the first transfer starts.
  /// The locale is pinned on app start, so one call is enough.
  static void init(NotificationStrings strings) {
    _strings = strings;
  }

  /// Whether [update] would reach the notification, so that callers can skip summing up the
  /// progress of every file for an update that gets throttled away.
  ///
  /// While several transfers run, they take turns passing this check, which means each of them
  /// refreshes its share of the total a bit less often. The numbers stay close enough: every
  /// running transfer reports progress continuously.
  static bool get shouldUpdate => ForegroundService.shouldUpdateNotification;

  /// Background mode (Android): keeps the service, and with it the app process, running while there is
  /// no transfer, so that other devices can still discover this one and send to it.
  ///
  /// Enabling must happen while the app is in the foreground: Android 12+ rejects starting a
  /// foreground service from the background.
  static void setBackgroundMode({required bool enabled, required String title, required String text}) {
    if (!enabled) {
      _idle = null;
      if (_transfers.isEmpty) {
        ForegroundService.stop();
      }
      return;
    }

    _idle = _IdleNotification(title: title, text: text);
    if (_transfers.isEmpty) {
      ForegroundService.start(
        channelName: _requiredStrings.titleReceiving,
        title: title,
        text: text,
        // dataSync would be stopped by the system after a few hours.
        serviceTypes: const [ForegroundServiceTypes.connectedDevice],
      );
      // Applies the new text if the service was already running.
      ForegroundService.updateNotification(title: title, text: text, force: true);
    }
    // Otherwise a transfer owns the notification, and [stop] switches to the idle text afterwards.
  }

  /// Registers a transfer, starting the service if it is the first one.
  ///
  /// Must be called while the app is in the foreground: Android 12+ rejects starting a foreground
  /// service from the background.
  static void start({required String sessionId, required bool receiving}) {
    if (_transfers.containsKey(sessionId)) {
      return;
    }

    final isFirst = _transfers.isEmpty;
    _transfers[sessionId] = _Transfer(receiving: receiving);

    if (isFirst) {
      // No-op if background mode is already running the service.
      ForegroundService.start(
        channelName: _requiredStrings.titleReceiving,
        title: _title(),
        text: _text(),
      );
      if (_idle != null) {
        // Replace the idle text right away instead of waiting for the first progress update.
        ForegroundService.updateNotification(title: _title(), text: _text(), force: true);
      }
    }
  }

  /// Reports the progress of a single transfer and refreshes the notification.
  /// Unknown sessions are ignored, so a late progress event cannot revive a finished transfer.
  static void update({
    required String sessionId,
    required int currentBytes,
    required int totalBytes,
    required int? startTime,
    required int? endTime,
  }) {
    final transfer = _transfers[sessionId];
    if (transfer == null) {
      return;
    }

    transfer.currentBytes = currentBytes;
    transfer.totalBytes = totalBytes;
    transfer.speedInBytes = _speed(currentBytes: currentBytes, startTime: startTime, endTime: endTime);

    ForegroundService.updateNotification(title: _title(), text: _text());
  }

  /// Unregisters a transfer, stopping the service once the last one is gone.
  static void stop(String sessionId) {
    if (_transfers.remove(sessionId) == null) {
      return;
    }

    final idle = _idle;
    if (_transfers.isEmpty && idle != null) {
      ForegroundService.updateNotification(title: idle.title, text: idle.text, force: true);
    } else if (_transfers.isEmpty) {
      ForegroundService.stop();
    } else {
      ForegroundService.updateNotification(title: _title(), text: _text());
    }
  }

  /// The transfer speed in bytes per second, or null while it cannot be measured yet.
  static int? _speed({required int currentBytes, required int? startTime, required int? endTime}) {
    if (startTime == null || currentBytes < _minBytesForSpeed) {
      return null;
    }

    final end = endTime ?? DateTime.now().millisecondsSinceEpoch;
    if (end <= startTime) {
      // guards the division in [getFileSpeed]
      return null;
    }

    return getFileSpeed(start: startTime, end: end, bytes: currentBytes);
  }

  static NotificationStrings get _requiredStrings {
    final strings = _strings;
    if (strings == null) {
      throw StateError('TransferNotification.init() must be called before a transfer starts');
    }
    return strings;
  }

  static String _title() {
    final receiving = _transfers.values.any((transfer) => transfer.receiving);
    final sending = _transfers.values.any((transfer) => !transfer.receiving);
    final strings = _requiredStrings;

    if (receiving && sending) {
      return '${strings.titleReceiving} · ${strings.titleSending}';
    }
    return receiving ? strings.titleReceiving : strings.titleSending;
  }

  /// The combined progress of all running transfers:
  /// 42% (1.2 MB / 3.4 MB)
  /// 0:45 · 1.2 MB/s
  static String _text() {
    int currentBytes = 0;
    int totalBytes = 0;
    int? speedInBytes;
    for (final transfer in _transfers.values) {
      currentBytes += transfer.currentBytes;
      totalBytes += transfer.totalBytes;
      final speed = transfer.speedInBytes;
      if (speed != null) {
        speedInBytes = (speedInBytes ?? 0) + speed;
      }
    }

    final percentage = totalBytes == 0 ? 0 : (100 * currentBytes / totalBytes).floor();
    final text = StringBuffer('$percentage% (${currentBytes.asReadableFileSize} / ${totalBytes.asReadableFileSize})');

    if (speedInBytes != null) {
      text.write('\n${getRemainingTime(bytesPerSeconds: speedInBytes, remainingBytes: totalBytes - currentBytes, strings: _requiredStrings)}');
      text.write(' · ${speedInBytes.asReadableFileSize}/s');
    }

    return text.toString();
  }
}

class _IdleNotification {
  final String title;
  final String text;

  _IdleNotification({required this.title, required this.text});
}

class _Transfer {
  final bool receiving;
  int currentBytes = 0;
  int totalBytes = 0;
  int? speedInBytes;

  _Transfer({required this.receiving});
}
