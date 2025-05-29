import 'dart:async';
import 'dart:isolate';
import 'dart:ui';
import 'package:flutter/services.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'connection_service.dart';
import 'clipboard_service.dart';

class BackgroundService {
  static final BackgroundService _instance = BackgroundService._internal();
  factory BackgroundService() => _instance;
  BackgroundService._internal();

  static const String portName = 'clipboard_sync_port';
  static const String notificationChannelId = 'clipboard_sync_channel';

  final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();

  Future<void> initializeBackgroundService() async {
    final service = FlutterBackgroundService();
    await _initializeNotifications();
    await service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: onStart,
        autoStart: true,
        isForegroundMode: true,
        notificationChannelId: notificationChannelId,
        initialNotificationTitle: 'Clipboard Sync',
        initialNotificationContent: 'Syncing clipboard across devices',
      ),
      iosConfiguration: IosConfiguration(
        autoStart: true,
        onForeground: onStart,
        onBackground: onIosBackground,
      ),
    );


  }

  Future<void> _initializeNotifications() async {
    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('ic_launcher');

    const DarwinInitializationSettings initializationSettingsIOS =
        DarwinInitializationSettings();

    const InitializationSettings initializationSettings = InitializationSettings(
      android: initializationSettingsAndroid,
      iOS: initializationSettingsIOS,
    );

    await _notificationsPlugin.initialize(initializationSettings);

    // Create notification channel for Android
    const AndroidNotificationChannel channel = AndroidNotificationChannel(
      notificationChannelId,
      'Clipboard Sync Service',
      description: 'Background service for clipboard synchronization',
      importance: Importance.low,
    );

    await _notificationsPlugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);
  }

  Future<void> startBackgroundService() async {
    final service = FlutterBackgroundService();
    bool isRunning = await service.isRunning();

    if (!isRunning) {
      await service.startService();
    }
  }

  Future<void> stopBackgroundService() async {
    final service = FlutterBackgroundService();
    service.invoke('stop');
  }

  static Future<bool> onIosBackground(ServiceInstance service) async {
    return true;
  }

  static void onStart(ServiceInstance service) async {
    DartPluginRegistrant.ensureInitialized();

    final receivePort = ReceivePort();
    IsolateNameServer.registerPortWithName(receivePort.sendPort, portName);

    service.on('stop').listen((event) {
      service.stopSelf();
    });

    // Store last clipboard content to detect changes
    String? lastClipboardContent;
    bool isServiceActive = true;

    // Listen for service stop events
    service.on('stop').listen((event) {
      isServiceActive = false;
     // timer?.cancel();
    });

    // Start the background clipboard monitoring
    Timer.periodic(const Duration(seconds: 1), (timer) async {
      try {
        // Check if service should still be running
        if (!isServiceActive) {
          timer.cancel();
          return;
        }

        // Get current clipboard content
        final clipboardData = await Clipboard.getData(Clipboard.kTextPlain);
        final currentContent = clipboardData?.text;

        // Check if clipboard content has changed
        if (currentContent != null &&
            currentContent.isNotEmpty &&
            currentContent != lastClipboardContent) {

          lastClipboardContent = currentContent;

          // Notify about clipboard change
          service.invoke('clipboard_changed', {
            'content': currentContent,
            'timestamp': DateTime.now().millisecondsSinceEpoch,
          });

          // Send message to main isolate via ReceivePort
          final mainPort = IsolateNameServer.lookupPortByName('main_isolate_port');
          mainPort?.send({
            'type': 'clipboard_changed',
            'content': currentContent,
            'timestamp': DateTime.now().millisecondsSinceEpoch,
          });

          // Optional: Log the clipboard change (for debugging)
          print('Clipboard changed: ${currentContent.length > 50 ? currentContent.substring(0, 50) + '...' : currentContent}');
        }

        // Periodic status update (every 30 seconds)
        if (DateTime.now().second % 30 == 0) {
          service.invoke('status_update', {
            'status': 'active',
            'timestamp': DateTime.now().millisecondsSinceEpoch,
          });
        }

      } catch (e) {
        // Handle any errors that might occur during clipboard access
        print('Error in clipboard monitoring: $e');

        // Notify about error
        service.invoke('error', {
          'message': e.toString(),
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        });
      }
    });

    // Listen for messages from main isolate
    receivePort.listen((message) {
      if (message is Map) {
        switch (message['type']) {
          case 'clipboard_changed':
            _handleClipboardChanged(service, message['content']);
            break;
          case 'device_connected':
            _handleDeviceConnected(service, message['deviceName']);
            break;
          case 'device_disconnected':
            _handleDeviceDisconnected(service);
            break;
          case 'sync_clipboard':
            _handleSyncClipboard(service, message['content']);
            break;
          case 'pause_monitoring':
            isServiceActive = false;
            break;
          case 'resume_monitoring':
            isServiceActive = true;
            break;
        }
      }
    });
  }

  static void _handleClipboardChanged(ServiceInstance service, String content) {
    // Since we can't update the foreground notification directly from ServiceInstance,
    // we'll send a message to the main isolate to show a regular notification
    service.invoke('show_notification', {
      'title': 'Clipboard Sync',
      'content': 'Clipboard synced: ${content.length > 30 ? content.substring(0, 30) + '...' : content}',
    });
  }

  static void _handleDeviceConnected(ServiceInstance service, String deviceName) {
    service.invoke('show_notification', {
      'title': 'Clipboard Sync - Connected',
      'content': 'Connected to $deviceName',
    });
  }

  static void _handleDeviceDisconnected(ServiceInstance service) {
    service.invoke('show_notification', {
      'title': 'Clipboard Sync - Disconnected',
      'content': 'Looking for devices...',
    });
  }

  static void _handleSyncClipboard(ServiceInstance service, String content) {
    // Set clipboard content when syncing from another device
    Clipboard.setData(ClipboardData(text: content));

    service.invoke('show_notification', {
      'title': 'Clipboard Received',
      'content': 'Synced from remote device: ${content.length > 30 ? content.substring(0, 30) + '...' : content}',
    });
  }

  void sendMessageToBackground(Map<String, dynamic> message) {
    final sendPort = IsolateNameServer.lookupPortByName(portName);
    sendPort?.send(message);
  }

  // Listen for messages from background service
  void listenToBackgroundMessages() {
    final service = FlutterBackgroundService();

    service.on('show_notification').listen((event) {
      if (event != null) {
        showNotification(
          event['title'] ?? 'Clipboard Sync',
          event['content'] ?? 'Service running',
        );
      }
    });

    service.on('clipboard_changed').listen((event) {
      if (event != null) {
        // Handle clipboard change from background service
        _onClipboardChanged(event['content'], event['timestamp']);
      }
    });

    service.on('status_update').listen((event) {
      if (event != null) {
        // Handle status updates
        _onStatusUpdate(event['status'], event['timestamp']);
      }
    });

    service.on('error').listen((event) {
      if (event != null) {
        // Handle errors from background service
        _onError(event['message'], event['timestamp']);
      }
    });
  }

  // Set up main isolate port for receiving messages from background
  void setupMainIsolatePort() {
    final receivePort = ReceivePort();
    IsolateNameServer.registerPortWithName(receivePort.sendPort, 'main_isolate_port');

    receivePort.listen((message) {
      if (message is Map) {
        switch (message['type']) {
          case 'clipboard_changed':
            _onClipboardChanged(message['content'], message['timestamp']);
            break;
        }
      }
    });
  }

  // Callback methods for handling background service events
  void _onClipboardChanged(String content, int timestamp) {
    print('Clipboard changed at ${DateTime.fromMillisecondsSinceEpoch(timestamp)}: $content');
    // Add your clipboard change handling logic here
    // For example, sync with other devices, update UI, etc.
  }

  void _onStatusUpdate(String status, int timestamp) {
    print('Service status: $status at ${DateTime.fromMillisecondsSinceEpoch(timestamp)}');
    // Handle status updates
  }

  void _onError(String error, int timestamp) {
    print('Background service error at ${DateTime.fromMillisecondsSinceEpoch(timestamp)}: $error');
    // Handle errors
  }

  // Methods to control the background service
  void pauseClipboardMonitoring() {
    sendMessageToBackground({'type': 'pause_monitoring'});
  }

  void resumeClipboardMonitoring() {
    sendMessageToBackground({'type': 'resume_monitoring'});
  }

  void syncClipboardContent(String content) {
    sendMessageToBackground({
      'type': 'sync_clipboard',
      'content': content,
    });
  }

  Future<void> showNotification(String title, String body) async {
    const AndroidNotificationDetails androidPlatformChannelSpecifics =
        AndroidNotificationDetails(
      notificationChannelId,
      'Clipboard Sync',
      channelDescription: 'Clipboard synchronization notifications',
      importance: Importance.low,
      priority: Priority.low,
    );

    const NotificationDetails platformChannelSpecifics =
        NotificationDetails(android: androidPlatformChannelSpecifics);

    await _notificationsPlugin.show(
      DateTime.now().millisecondsSinceEpoch % 100000, // Use timestamp for unique ID
      title,
      body,
      platformChannelSpecifics,
    );
  }
}