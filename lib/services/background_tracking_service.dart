import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_background_service_android/flutter_background_service_android.dart';
import 'package:geolocator/geolocator.dart' as geolocator;

import '../config/api_config.dart';
import 'api_service.dart';
import 'offline_storage_service.dart';
import 'tracking_state_service.dart';

// Jadwal lokasi Android tidak presisi: titik boleh datang sedikit lebih awal dari interval.
// Tanpa toleransi, titik yang datang di detik ke-298 dibuang dan interval efektif jadi 2x.
const int _intervalToleranceSeconds = 20;
// Kalau stream lokasi tidak memberi titik selama interval + batas ini, ambil posisi sendiri.
// (Stream bisa berhenti diam-diam, mis. saat aplikasi di-swipe plugin lokasi ikut melepasnya.)
const int _stallGraceSeconds = 10;
// Titik pertama setelah check-in dikirim beberapa detik setelah layanan mulai.
const int _firstPointDelaySeconds = 10;
// Posisi terakhir dari sistem dianggap masih berlaku kalau umurnya paling lama ini.
const int _freshPositionSeconds = 120;

class BackgroundTrackingService {
  static const String _channelId = 'atenim_tracking';
  static const int _notificationId = 888;

  static Future<void> initialize() async {
    final service = FlutterBackgroundService();
    await service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: backgroundTrackingEntryPoint,
        autoStart: false, // Jangan auto start - akan dimulai manual saat check-in
        isForegroundMode: true,
        notificationChannelId: "atenim_service",
        initialNotificationTitle: 'Atenim Active',
        initialNotificationContent: 'Layanan pelacakan lokasi berjalan',
        foregroundServiceNotificationId: _notificationId,
      ),
      iosConfiguration: IosConfiguration(
        autoStart: false,
        onForeground: backgroundTrackingEntryPoint,
        onBackground: _onIosBackground,
      ),
    );
  }

  static Future<void> ensureRunning() async {
    final service = FlutterBackgroundService();
    final isRunning = await service.isRunning();
    if (!isRunning) {
      await service.startService();
    }
  }

  static Future<void> stop() async {
    final service = FlutterBackgroundService();
    final isRunning = await service.isRunning();
    if (isRunning) {
      service.invoke('stopService');
    }
  }
}

@pragma('vm:entry-point')
Future<bool> _onIosBackground(ServiceInstance service) async {
  return true;
}

geolocator.LocationSettings _buildLocationSettings(int intervalSeconds) {
  if (defaultTargetPlatform == TargetPlatform.android) {
    // distanceFilter 0: HP yang diam tetap memberi titik tiap interval, jadi peta tahu
    // karyawan masih bertugas selama check-in.
    return geolocator.AndroidSettings(
      accuracy: geolocator.LocationAccuracy.high,
      distanceFilter: 0,
      intervalDuration: Duration(seconds: intervalSeconds),
      foregroundNotificationConfig: null, // Disabled - handled by background service
      forceLocationManager: false, // Use default provider
    );
  }
  return const geolocator.LocationSettings(
    accuracy: geolocator.LocationAccuracy.high,
    distanceFilter: 0,
  );
}

enum _SendResult { sent, queued, sessionEnded, trackingDisabled }

@pragma('vm:entry-point')
void backgroundTrackingEntryPoint(ServiceInstance service) async {
  // Safety checks untuk mencegah FlutterJNI.ensureAttachedToNative crash
  // Wrap semua initialization dalam try-catch untuk mencegah crash
  try {
    WidgetsFlutterBinding.ensureInitialized();
  } catch (e) {
    debugPrint('[BackgroundTracking] ⚠️ Failed to initialize WidgetsBinding: $e');
    // Continue anyway - service might still work without full Flutter binding
  }

  try {
    DartPluginRegistrant.ensureInitialized();
  } catch (e) {
    debugPrint('[BackgroundTracking] ⚠️ Failed to initialize DartPluginRegistrant: $e');
    // Continue anyway - service might still work
  }

  try {
    await dotenv.load(fileName: '.env');
  } catch (_) {
    // Silently continue if .env file not found
  }

  try {
    if (service is AndroidServiceInstance) {
      service.setAsForegroundService();
    }
  } catch (e) {
    debugPrint('[BackgroundTracking] ⚠️ Failed to set foreground service: $e');
    // Continue anyway
  }

  final apiService = ApiService();
  final offlineStorage = OfflineStorageService();
  StreamSubscription<geolocator.Position>? subscription;
  TrackingState? currentState;
  DateTime? lastSentAt;
  DateTime? streamStartedAt;
  DateTime? lastSyncAt;
  bool isStopping = false; // Flag untuk mencegah race condition
  bool isSending = false;
  bool isShuttingDown = false;

  Future<void> stopStream() async {
    if (isStopping) {
      debugPrint('[BackgroundTracking] ⚠️ Already stopping stream, skipping...');
      return;
    }
    isStopping = true;
    try {
      await subscription?.cancel();
      subscription = null;
      streamStartedAt = null;
    } catch (e) {
      debugPrint('[BackgroundTracking] ⚠️ Error stopping stream: $e');
    } finally {
      isStopping = false;
    }
  }

  Future<void> shutdown(String reason) async {
    if (isShuttingDown) return;
    isShuttingDown = true;
    debugPrint('[BackgroundTracking] Stopping service: $reason');
    await stopStream();
    try {
      service.stopSelf();
    } catch (_) {}
  }

  Map<String, dynamic> buildPayload(TrackingState state, geolocator.Position position) {
    return {
      'userId': state.userId,
      'attendanceId': state.attendanceId,
      'date': state.checkInDate.toIso8601String().split('T')[0],
      'latitude': position.latitude,
      'longitude': position.longitude,
      if (position.accuracy >= 0) 'accuracy': position.accuracy,
      if (position.speed >= 0) 'speed': position.speed,
      if (position.heading >= 0) 'heading': position.heading,
      // Jam titik diambil (UTC), supaya titik dari antrean offline tetap di urutan yang benar
      'capturedAt': position.timestamp.toUtc().toIso8601String(),
    };
  }

  Future<_SendResult> sendLocation({
    required TrackingState state,
    required geolocator.Position position,
  }) async {
    final payload = buildPayload(state, position);
    try {
      final response = await apiService.post(ApiConfig.realtimeLog, data: payload);
      final status = response.statusCode ?? 0;
      // Hanya respons JSON dari server MMS yang dipercaya; halaman error gateway (HTML) dianggap gangguan sementara
      final data = response.data;
      final fromServer = data is Map;
      if (status == 200) {
        // Monitoring dimatikan (per site atau global): berhenti sampai aplikasi mengaktifkan lagi
        if (fromServer && (data['disabledBySite'] == true || data['trackingDisabled'] == true)) {
          return _SendResult.trackingDisabled;
        }
        return _SendResult.sent;
      }
      // Sesi sudah selesai di server (check-out dari perangkat lain/admin, lewat 24 jam, atau attendance hilang)
      if (fromServer && (status == 404 || status == 409)) {
        return _SendResult.sessionEnded;
      }
      // Ditolak permanen (payload tidak valid atau sesi milik user lain): tidak ada gunanya diantre
      if (fromServer && (status == 400 || status == 403)) {
        return _SendResult.sent;
      }
      await offlineStorage.savePendingLocationLog(payload);
      return _SendResult.queued;
    } catch (e) {
      // Tanpa sinyal: simpan dulu, dikirim saat sinyal kembali
      await offlineStorage.savePendingLocationLog(payload);
      return _SendResult.queued;
    }
  }

  // Kirim kalau sudah waktunya. Aplikasi (saat terbuka) juga bisa mengirim titik;
  // penanda bersama mencegah titik ganda dalam satu interval.
  Future<void> maybeSend(geolocator.Position position) async {
    final state = currentState;
    if (state == null || isSending || isShuttingDown) return;

    isSending = true;
    try {
      // Android sering mengulang posisi tersimpan (fix yang sama) saat stream dimulai lagi:
      // abaikan fix yang tidak lebih baru dari titik terakhir yang terkirim. Dibandingkan antar
      // jam fix, bukan dengan jam HP, supaya tetap benar walau jam HP salah setel.
      final lastFix = await TrackingStateService.getLastFixTime();
      if (lastFix != null && !position.timestamp.isAfter(lastFix)) {
        return;
      }

      final now = DateTime.now();
      final sharedLast = await TrackingStateService.getLastLocationSentAt();
      DateTime? last = lastSentAt;
      if (sharedLast != null && (last == null || sharedLast.isAfter(last))) {
        last = sharedLast;
      }
      if (last != null &&
          now.difference(last).inSeconds < state.intervalSeconds - _intervalToleranceSeconds) {
        return;
      }

      final result = await sendLocation(state: state, position: position);
      if (result == _SendResult.sessionEnded) {
        // Tandai supaya aplikasi tidak menyalakan lagi pelacakan untuk sesi ini
        await TrackingStateService.markAttendanceEnded(state.attendanceId);
        await TrackingStateService.clearTrackingState();
        await shutdown('sesi check-in sudah selesai di server');
        return;
      }
      if (result == _SendResult.trackingDisabled) {
        await TrackingStateService.clearTrackingState();
        await shutdown('monitoring realtime dinonaktifkan');
        return;
      }
      lastSentAt = now;
      await TrackingStateService.markLocationSent(now, fixTime: position.timestamp);
    } finally {
      isSending = false;
    }
  }

  Future<void> startStream(TrackingState state) async {
    // Prevent race condition dengan menunggu stop selesai
    if (isStopping) {
      debugPrint('[BackgroundTracking] ⚠️ Waiting for stream to stop...');
      await Future.delayed(const Duration(milliseconds: 500));
    }
    await stopStream();

    final permission = await geolocator.Geolocator.checkPermission();
    if (permission != geolocator.LocationPermission.always &&
        permission != geolocator.LocationPermission.whileInUse) {
      debugPrint('[BackgroundTracking] Location permission not granted, stream not started');
      return;
    }

    final serviceEnabled = await geolocator.Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      debugPrint('[BackgroundTracking] Location service disabled, stream not started');
      return;
    }

    streamStartedAt = DateTime.now();
    subscription = geolocator.Geolocator.getPositionStream(
      locationSettings: _buildLocationSettings(state.intervalSeconds),
    ).listen(
      (position) => maybeSend(position),
      onError: (Object e) {
        debugPrint('[BackgroundTracking] ⚠️ Position stream error: $e');
      },
    );
  }

  // Stream bisa diam (Doze, GPS sempat mati): ambil posisi sendiri kalau sudah lewat interval
  // tanpa titik. Hanya dipakai sebagai cadangan karena getCurrentPosition lebih berat.
  Future<void> checkStalled() async {
    final state = currentState;
    if (state == null || isSending || isShuttingDown) return;
    if (subscription == null) {
      await startStream(state);
      return;
    }
    final sharedLast = await TrackingStateService.getLastLocationSentAt();
    DateTime? reference = lastSentAt ?? sharedLast;
    if (sharedLast != null && reference != null && sharedLast.isAfter(reference)) {
      reference = sharedLast;
    }
    // Titik pertama sesi dikirim segera: Android baru memberi posisi dari stream setelah satu interval.
    final threshold = reference == null ? _firstPointDelaySeconds : state.intervalSeconds + _stallGraceSeconds;
    final since = reference ?? streamStartedAt;
    if (since == null || DateTime.now().difference(since).inSeconds < threshold) {
      return;
    }
    geolocator.Position? position;
    // Posisi terakhir yang masih segar (dan bukan fix yang sudah terkirim) cukup, tanpa menyalakan GPS lagi
    try {
      final known = await geolocator.Geolocator.getLastKnownPosition();
      final lastFix = await TrackingStateService.getLastFixTime();
      if (known != null &&
          DateTime.now().difference(known.timestamp).inSeconds.abs() <= _freshPositionSeconds &&
          (lastFix == null || known.timestamp.isAfter(lastFix))) {
        position = known;
      }
    } catch (_) {}
    if (position == null) {
      try {
        position = await geolocator.Geolocator.getCurrentPosition(
          desiredAccuracy: geolocator.LocationAccuracy.high,
          timeLimit: const Duration(seconds: 30),
        );
      } catch (e) {
        debugPrint('[BackgroundTracking] ⚠️ getCurrentPosition failed: $e');
      }
    }
    if (position != null) {
      await maybeSend(position);
      // Stream yang diam dinyalakan ulang supaya titik berikutnya kembali tepat tiap interval
      if (!isShuttingDown && currentState != null) {
        await startStream(currentState!);
      }
    }
  }

  Future<void> syncPendingLogs() async {
    final pending = await offlineStorage.getPendingLocationLogs();
    if (pending.isEmpty) {
      return;
    }

    for (int i = pending.length - 1; i >= 0; i--) {
      final item = pending[i];
      final userId = item['userId']?.toString() ?? '';
      final attendanceId = item['attendanceId']?.toString() ?? '';
      final date = item['date']?.toString() ?? '';
      final latitude = item['latitude'];
      final longitude = item['longitude'];

      if (userId.isEmpty || attendanceId.isEmpty || date.isEmpty) {
        await offlineStorage.removePendingLocationLog(i);
        continue;
      }

      if (latitude == null || longitude == null) {
        await offlineStorage.removePendingLocationLog(i);
        continue;
      }

      try {
        final response = await apiService.post(
          ApiConfig.realtimeLog,
          data: {
            'userId': userId,
            'attendanceId': attendanceId,
            'date': date,
            'latitude': latitude,
            'longitude': longitude,
            if (item['accuracy'] != null) 'accuracy': item['accuracy'],
            if (item['speed'] != null) 'speed': item['speed'],
            if (item['heading'] != null) 'heading': item['heading'],
            if (item['capturedAt'] != null) 'capturedAt': item['capturedAt'],
          },
        );

        final status = response.statusCode ?? 0;
        // 200 tersimpan; 400/403/404/409 dari server ditolak permanen (mis. titik setelah check-out,
        // sesi user lain): buang supaya antrean tidak macet
        final fromServer = response.data is Map;
        if (status == 200 ||
            (fromServer && (status == 400 || status == 403 || status == 404 || status == 409))) {
          await offlineStorage.removePendingLocationLog(i);
        } else {
          break;
        }
      } catch (_) {
        // Masih tanpa sinyal: berhenti dulu, dicoba lagi di putaran berikutnya
        break;
      }
    }
  }

  Future<void> refreshTrackingState() async {
    final nextState = await TrackingStateService.getTrackingState();
    if (nextState == null) {
      // Tanpa check-in aktif layanan tidak punya tugas (mis. dinyalakan ulang saat HP boot)
      currentState = null;
      await shutdown('tidak ada check-in aktif');
      return;
    }

    final shouldRestart = currentState == null ||
        currentState!.attendanceId != nextState.attendanceId ||
        currentState!.intervalSeconds != nextState.intervalSeconds;

    if (currentState != null && currentState!.attendanceId != nextState.attendanceId) {
      lastSentAt = null;
    }
    currentState = nextState;
    if (shouldRestart || subscription == null) {
      await startStream(nextState);
    }
  }

  service.on('stopService').listen((_) async {
    try {
      isShuttingDown = true;
      await stopStream();
      // Check-out/logout: kirim dulu titik yang masih antre supaya ujung rute sesi tidak hilang
      try {
        await syncPendingLogs().timeout(const Duration(seconds: 20));
      } catch (_) {}
      // Small delay untuk memastikan semua operasi selesai sebelum stop
      await Future.delayed(const Duration(milliseconds: 100));
      service.stopSelf();
    } catch (e) {
      debugPrint('[BackgroundTracking] ⚠️ Error stopping service: $e');
      // Force stop even if there's an error
      try {
        service.stopSelf();
      } catch (_) {}
    }
  });

  bool isTicking = false;
  Future<void> tick() async {
    if (isShuttingDown || isTicking) return;
    isTicking = true;
    try {
      await refreshTrackingState();
      if (isShuttingDown) return;
      await checkStalled();
      final now = DateTime.now();
      if (lastSyncAt == null || now.difference(lastSyncAt!).inSeconds >= 60) {
        lastSyncAt = now;
        await syncPendingLogs();
      }
    } catch (e) {
      debugPrint('[BackgroundTracking] ⚠️ Tick error: $e');
    } finally {
      isTicking = false;
    }
  }

  await tick();
  Timer.periodic(const Duration(seconds: 15), (timer) async {
    if (isShuttingDown) {
      timer.cancel();
      return;
    }
    await tick();
  });
}
