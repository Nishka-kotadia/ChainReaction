import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'models.dart';

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();
  bool _isInitialized = false;

  Future<void> init() async {
    if (_isInitialized) return;

    await Permission.notification.request();

    const AndroidInitializationSettings initializationSettingsAndroid = AndroidInitializationSettings('@mipmap/ic_launcher');
    const InitializationSettings initializationSettings = InitializationSettings(android: initializationSettingsAndroid);

    await flutterLocalNotificationsPlugin.initialize(initializationSettings);

    // Create the channel
    const AndroidNotificationChannel channel = AndroidNotificationChannel(
      'emergency_channel',
      'Emergency Alerts',
      description: 'High priority notifications for incoming emergency broadcasts',
      importance: Importance.max,
      enableVibration: true,
      playSound: true,
    );

    await flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);

    _isInitialized = true;
  }

  Future<void> showEmergencyAlert(Alert alert) async {
    if (!_isInitialized) await init();

    const AndroidNotificationDetails androidPlatformChannelSpecifics = AndroidNotificationDetails(
      'emergency_channel',
      'Emergency Alerts',
      channelDescription: 'High priority notifications for incoming emergency broadcasts',
      importance: Importance.max,
      priority: Priority.high,
      ticker: 'URGENT EMERGENCY ALERT',
      color: const Color(0xFFF43F5E), // Rose red
      enableLights: true,
      ledColor: const Color(0xFFF43F5E),
      ledOnMs: 1000,
      ledOffMs: 500,
      styleInformation: BigTextStyleInformation(''),
    );

    const NotificationDetails platformChannelSpecifics = NotificationDetails(android: androidPlatformChannelSpecifics);

    final title = 'URGENT: ${alert.alertType.name.toUpperCase()} ALERT';
    final body = alert.description.isNotEmpty ? alert.description : 'Emergency broadcast received nearby!';

    await flutterLocalNotificationsPlugin.show(
      alert.id.hashCode,
      title,
      body,
      platformChannelSpecifics,
    );
  }
}
