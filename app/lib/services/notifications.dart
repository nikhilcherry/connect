import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../data/models.dart';
import '../l10n.dart';
import 'push.dart';

/// Local notifications: incoming alerts while the app is on screen, and
/// scheduled reminders. Alerts that arrive while the app is closed come by
/// FCM push (services/push.dart) on the same channels, created here up front.
class Notifications {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _ready = false;

  static const _alerts = AndroidNotificationDetails(
    'alerts',
    'Car alerts',
    channelDescription: 'Someone scanned your Connect tag',
    importance: Importance.max,
    priority: Priority.high,
    category: AndroidNotificationCategory.message,
  );

  static const _reminders = AndroidNotificationDetails(
    'reminders',
    'Renewal reminders',
    channelDescription: 'PUC, insurance and service due dates',
    importance: Importance.defaultImportance,
  );

  static Future<void> init() async {
    if (kIsWeb || _ready) return;
    tzdata.initializeTimeZones();
    try {
      final zone = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(zone.identifier));
    } catch (_) {
      tz.setLocalLocation(tz.getLocation('Asia/Kolkata'));
    }
    await _plugin.initialize(
      settings: const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')),
      onDidReceiveNotificationResponse: (r) {
        final p = r.payload;
        if (p != null && p.isNotEmpty) Push.opened.add({'alert_id': p});
      },
    );
    final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    for (final c in const [
      AndroidNotificationChannel('alerts', 'Car alerts', description: 'Someone scanned your Connect tag', importance: Importance.max),
      AndroidNotificationChannel('society', 'Society notices', description: 'Notices from your housing society admin', importance: Importance.high),
      AndroidNotificationChannel('reminders', 'Renewal reminders', description: 'PUC, insurance and service due dates'),
      AndroidNotificationChannel('parking', 'Parking reminders', description: 'Before your parking time runs out', importance: Importance.high),
    ]) {
      await android?.createNotificationChannel(c);
    }
    final launch = await _plugin.getNotificationAppLaunchDetails();
    final p = launch?.didNotificationLaunchApp == true ? launch?.notificationResponse?.payload : null;
    if (p != null && p.isNotEmpty) launchAlertId = p;
    _ready = true;
  }

  /// Set when tapping a local alert notification started the app.
  static String? launchAlertId;

  static Future<void> requestPermission() async {
    if (kIsWeb) return;
    await _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
  }

  static Future<void> showAlert(CarAlert a, Vehicle? v) async {
    if (!_ready) return;
    final car = v == null ? tr('your car') : v.title;
    await _plugin.show(
      id: a.id.hashCode & 0x7fffffff,
      title: '${tr(a.kind.label)}: $car',
      body: a.note?.isNotEmpty == true ? a.note : tr('Someone near your car needs you. Tap to reply.'),
      notificationDetails: const NotificationDetails(android: _alerts),
      payload: a.id,
    );
  }

  /// A message a nearby phone sent by sound about one of this phone's cars.
  /// It has not been to the server, so there is no thread to open yet.
  static Future<void> showWhisper(AlertKind kind, Vehicle? v, int nonce) async {
    if (!_ready) return;
    await _plugin.show(
      id: 3000 + (nonce & 0xFFF),
      title: '${tr(kind.label)}: ${v == null ? tr('your car') : v.title}',
      body: tr('Someone next to your car said this by sound. No internet was needed.'),
      notificationDetails: const NotificationDetails(android: _alerts),
    );
  }

  static const _parking = AndroidNotificationDetails(
    'parking',
    'Parking reminders',
    channelDescription: 'Before your parking time runs out',
    importance: Importance.high,
    priority: Priority.high,
  );

  /// 10 minutes before paid parking runs out, and when it does.
  static Future<void> scheduleParkingReminder(DateTime? endsAt) async {
    if (!_ready) return;
    await _plugin.cancel(id: 2000);
    await _plugin.cancel(id: 2001);
    if (endsAt == null) return;
    final end = tz.TZDateTime.from(endsAt, tz.local);
    final now = tz.TZDateTime.now(tz.local);
    final shots = [
      (2000, end.subtract(const Duration(minutes: 10)), tr('Parking ends in 10 minutes'), tr('Head back or extend your parking.')),
      (2001, end, tr('Parking time is up'), tr('Your paid parking has run out.')),
    ];
    for (final (id, at, title, body) in shots) {
      if (at.isBefore(now)) continue;
      await _plugin.zonedSchedule(
        id: id,
        title: title,
        body: body,
        scheduledDate: at,
        notificationDetails: const NotificationDetails(android: _parking),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      );
    }
  }

  /// Reminders at 9am, 30 and 7 days before and on the day. Ids are fixed per
  /// document so rescheduling replaces rather than duplicates.
  static Future<void> scheduleExpiryReminders(Vehicle? v) async {
    if (!_ready) return;
    for (var id = 1000; id < 1012; id++) {
      await _plugin.cancel(id: id);
    }
    if (v == null) return;
    final docs = <(int, String, DateTime?)>[
      (1000, tr('PUC certificate'), v.pucExpiry),
      (1004, tr('Car insurance'), v.insuranceExpiry),
      (1008, tr('Service'), v.serviceDue),
    ];
    final now = tz.TZDateTime.now(tz.local);
    for (final (i, (base, label, due)) in docs.indexed) {
      if (due == null) continue;
      final offsets = [30, 7, 0];
      for (var k = 0; k < offsets.length; k++) {
        final d = offsets[k];
        final at = tz.TZDateTime(tz.local, due.year, due.month, due.day, 9).subtract(Duration(days: d));
        if (at.isBefore(now)) continue;
        final title = switch ((i == 2, d)) {
          (true, 0) => tr('{doc} due today', {'doc': label}),
          (true, _) => tr('{doc} due in {n} days', {'doc': label, 'n': d}),
          (false, 0) => tr('{doc} expires today', {'doc': label}),
          (false, _) => tr('{doc} expires in {n} days', {'doc': label, 'n': d}),
        };
        await _plugin.zonedSchedule(
          id: base + k,
          title: title,
          body: tr('For {car} ({reg}). Renew in time to avoid fines.', {'car': v.title, 'reg': v.prettyReg}),
          scheduledDate: at,
          notificationDetails: const NotificationDetails(android: _reminders),
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        );
      }
    }
  }
}
