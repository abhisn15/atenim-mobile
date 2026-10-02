import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import '../config/api_config.dart';
import '../app_keys.dart';
import '../providers/patrol_provider.dart';
import '../screens/notifications/notification_screen.dart';
import '../utils/html_text.dart';
import 'api_service.dart';
import 'device_id_service.dart';

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  debugPrint('[PushNotificationService] Background message: ${message.messageId}');
}

class PushNotificationService {
  static bool _initialized = false;
  static StreamSubscription<String>? _tokenRefreshSubscription;
  static StreamSubscription<RemoteMessage>? _foregroundSubscription;
  static final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();

  /// Naik 1 setiap pesan push masuk saat app terbuka. Layar yang menampilkan hitungan
  /// "belum dibaca" (bel di Home) mendengarkan ini supaya hitungannya langsung diperbarui.
  static final ValueNotifier<int> incomingMessageTick = ValueNotifier<int>(0);

  static const _androidChannel = AndroidNotificationChannel(
    'admin_broadcast',
    'Pemberitahuan',
    description: 'Notifikasi dari admin',
    importance: Importance.high,
  );

  static Future<void> initialize() async {
    if (_initialized) return;

    try {
      await Firebase.initializeApp();
    } catch (error) {
      debugPrint('[PushNotificationService] Firebase belum siap: $error');
      return;
    }

    try {
      FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
        provisional: false,
      );

      if (!kIsWeb && Platform.isIOS) {
        await messaging.setForegroundNotificationPresentationOptions(
          alert: true,
          badge: true,
          sound: true,
        );
      }

      // Set up local notifications for foreground display
      await _setupLocalNotifications();

      // Listen to foreground messages
      _foregroundSubscription?.cancel();
      _foregroundSubscription =
          FirebaseMessaging.onMessage.listen(_handleForegroundMessage);

      await syncCurrentToken();
      _tokenRefreshSubscription?.cancel();
      _tokenRefreshSubscription = messaging.onTokenRefresh.listen((token) {
        unawaited(_registerToken(token));
      });

      _initialized = true;
      debugPrint('[PushNotificationService] Initialized');
    } catch (error) {
      debugPrint('[PushNotificationService] Initialize error: $error');
    }
  }

  static Future<void> _setupLocalNotifications() async {
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosInit = DarwinInitializationSettings();
    const initSettings =
        InitializationSettings(android: androidInit, iOS: iosInit);

    await _localNotifications.initialize(initSettings);

    if (!kIsWeb && Platform.isAndroid) {
      final androidPlugin =
          _localNotifications.resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();
      await androidPlugin?.createNotificationChannel(_androidChannel);
    }
  }

  static void _handleForegroundMessage(RemoteMessage message) {
    incomingMessageTick.value++;
    // Hasil tinjauan patroli: segarkan paket supaya "Scan saya" langsung berubah tanpa menunggu 15 menit.
    if (message.data['type'] == 'patrol_review') {
      final ctx = navigatorKey.currentContext;
      if (ctx != null) unawaited(Provider.of<PatrolProvider>(ctx, listen: false).refresh());
    }
    final notification = message.notification;
    if (notification == null) return;

    // Server lama masih mengirim isi HTML mentah; bersihkan di sini supaya tag <img> tidak ikut tampil.
    final rawBody = notification.body ?? '';
    final body = htmlToPlainText(rawBody);
    final displayBody = body.isNotEmpty ? body : (htmlHasImage(rawBody) ? 'Mengirim gambar' : '');
    final title = notification.title ?? 'Pemberitahuan';
    final imageUrl = _extractImageUrl(message) ?? firstHtmlImageUrl(rawBody);

    unawaited(_showSystemNotification(
      id: message.hashCode,
      title: title,
      body: displayBody,
      imageUrl: imageUrl,
    ));

    _showInAppNotificationSnackBar(
      title: title,
      body: displayBody,
      imageUrl: imageUrl,
      notificationId: _extractNotificationIdFromPayload(message),
    );
  }

  /// Notifikasi di bilah sistem. Bila ada gambar, ditampilkan sebagai gambar besar (BigPicture);
  /// bila gambar gagal diunduh, tetap tampil sebagai teks biasa.
  static Future<void> _showSystemNotification({
    required int id,
    required String title,
    required String body,
    String? imageUrl,
  }) async {
    StyleInformation? style;
    if (imageUrl != null && imageUrl.isNotEmpty) {
      final bytes = await _downloadImageBytes(imageUrl);
      if (bytes != null) {
        final bitmap = ByteArrayAndroidBitmap(bytes);
        style = BigPictureStyleInformation(
          bitmap,
          largeIcon: bitmap,
          hideExpandedLargeIcon: true,
          contentTitle: title,
          summaryText: body,
        );
      }
    }
    style ??= body.length > 40 ? BigTextStyleInformation(body, contentTitle: title) : null;

    await _localNotifications.show(
      id,
      title,
      body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          _androidChannel.id,
          _androidChannel.name,
          channelDescription: _androidChannel.description,
          importance: Importance.high,
          priority: Priority.high,
          icon: '@mipmap/ic_launcher',
          styleInformation: style,
        ),
        iOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
    );
  }

  static Future<Uint8List?> _downloadImageBytes(String url) async {
    try {
      final response = await Dio().get<List<int>>(
        url,
        options: Options(
          responseType: ResponseType.bytes,
          receiveTimeout: const Duration(seconds: 8),
          sendTimeout: const Duration(seconds: 8),
        ),
      );
      final data = response.data;
      // Batasi 3 MB supaya notifikasi tidak menahan memori.
      if (data == null || data.isEmpty || data.length > 3 * 1024 * 1024) return null;
      return Uint8List.fromList(data);
    } catch (error) {
      debugPrint('[PushNotificationService] Gambar notifikasi gagal diunduh: $error');
      return null;
    }
  }

  static String? _extractImageUrl(RemoteMessage message) {
    final possibleKeys = [
      'image',
      'imageUrl',
      'image_url',
      'picture',
      'thumbnail',
      'photo',
    ];

    for (final key in possibleKeys) {
      final value = message.data[key];
      if (value != null && value.trim().startsWith('http')) {
        return value.trim();
      }
    }

    return null;
  }

  static void _showInAppNotificationSnackBar({
    required String title,
    required String body,
    String? imageUrl,
    String? notificationId,
  }) {
    void openNotificationScreen() {
      final nav = navigatorKey.currentState;
      if (nav == null) return;
      nav.push(
        MaterialPageRoute(
          builder: (_) => NotificationScreen(
            initialNotificationId: notificationId,
          ),
        ),
      );
    }

    final messenger = scaffoldMessengerKey.currentState;
    if (messenger == null) return;

    messenger.hideCurrentSnackBar();
    final hasImage = imageUrl != null && imageUrl.isNotEmpty;
    messenger.showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        padding: EdgeInsets.zero,
        backgroundColor: Colors.transparent,
        elevation: 0,
        duration: Duration(seconds: hasImage ? 7 : 5),
        content: _InAppNotificationCard(
          title: title,
          body: body,
          imageUrl: imageUrl,
          onOpen: () {
            messenger.hideCurrentSnackBar();
            openNotificationScreen();
          },
        ),
      ),
    );
  }

  static String? _extractNotificationIdFromPayload(RemoteMessage message) {
    final possibleKeys = [
      'notificationId',
      'notification_id',
      'id',
      'notifId',
      'notif_id',
    ];

    for (final key in possibleKeys) {
      final value = message.data[key];
      if (value != null && value.trim().isNotEmpty) {
        return value.trim();
      }
    }

    return null;
  }

  static Future<void> syncCurrentToken() async {
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token == null || token.trim().isEmpty) {
        return;
      }
      await _registerToken(token);
    } catch (error) {
      debugPrint('[PushNotificationService] Sync token error: $error');
    }
  }

  static Future<void> unregisterCurrentToken() async {
    try {
      final token = await FirebaseMessaging.instance.getToken();
      final deviceId = await DeviceIdService.getOrCreateDeviceId();

      await ApiService().delete(
        ApiConfig.pushToken,
        data: {
          'token': token,
          'deviceId': deviceId,
        },
      );
    } catch (error) {
      debugPrint('[PushNotificationService] Unregister token error: $error');
    }
  }

  static Future<void> _registerToken(String token) async {
    if (token.trim().isEmpty) return;

    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final deviceId = await DeviceIdService.getOrCreateDeviceId();
      final platform = Platform.isAndroid
          ? 'android'
          : Platform.isIOS
              ? 'ios'
              : 'other';

      await ApiService().post(
        ApiConfig.pushToken,
        data: {
          'token': token.trim(),
          'platform': platform,
          'deviceId': deviceId,
          'appVersion': packageInfo.version,
        },
        headers: {
          'x-device-id': deviceId,
        },
      );
    } catch (error) {
      debugPrint('[PushNotificationService] Register token error: $error');
    }
  }
}

/// Kartu notifikasi saat app terbuka. Gambar (bila ada) tampil di atas, karena isi notifikasinya
/// memang gambar; tanpa gambar, hanya ikon + teks. Melayang di atas layar, jadi diberi bayangan.
class _InAppNotificationCard extends StatelessWidget {
  const _InAppNotificationCard({
    required this.title,
    required this.body,
    required this.onOpen,
    this.imageUrl,
  });

  final String title;
  final String body;
  final String? imageUrl;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final hasImage = imageUrl != null && imageUrl!.isNotEmpty;
    return Material(
      color: Colors.white,
      elevation: 6,
      shadowColor: Colors.black26,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (hasImage)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 170),
                child: CachedNetworkImage(
                  imageUrl: ApiConfig.getImageUrl(imageUrl),
                  fit: BoxFit.cover,
                  width: double.infinity,
                  fadeInDuration: const Duration(milliseconds: 180),
                  placeholder: (context, url) => Container(
                    height: 120,
                    color: Colors.grey[200],
                  ),
                  errorWidget: (_, __, ___) => Container(
                    height: 72,
                    color: Colors.grey[100],
                    alignment: Alignment.center,
                    child: Text(
                      'Gambar tidak bisa dimuat',
                      style: TextStyle(color: Colors.grey[700], fontSize: 12),
                    ),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  if (!hasImage) ...[
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: Colors.blue[50],
                        shape: BoxShape.circle,
                      ),
                      child: Icon(Icons.notifications_outlined, color: Colors.blue[700], size: 22),
                    ),
                    const SizedBox(width: 12),
                  ],
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.grey[900],
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
                          ),
                        ),
                        if (body.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            body,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: Colors.grey[700], fontSize: 13, height: 1.3),
                          ),
                        ],
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: onOpen,
                    style: TextButton.styleFrom(
                      minimumSize: const Size(56, 48),
                      foregroundColor: Colors.blue[700],
                    ),
                    child: const Text('Buka'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
