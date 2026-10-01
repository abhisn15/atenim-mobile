import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_android/shared_preferences_android.dart';

class TrackingState {
  final String userId;
  final String attendanceId;
  final DateTime checkInDate;
  final int intervalSeconds;

  const TrackingState({
    required this.userId,
    required this.attendanceId,
    required this.checkInDate,
    required this.intervalSeconds,
  });
}

/// Status pelacakan yang dibaca bersama oleh aplikasi dan layanan latar belakang
/// (dua isolate berbeda). Disimpan lewat SharedPreferencesAsync tanpa cache supaya
/// kedua sisi selalu membaca nilai terbaru dan tidak menimpa cache SharedPreferences
/// biasa (antrean absen/aktivitas/patroli).
class TrackingStateService {
  static const String _trackingActiveKey = 'tracking_active';
  static const String _trackingUserIdKey = 'tracking_user_id';
  static const String _trackingAttendanceIdKey = 'tracking_attendance_id';
  static const String _trackingCheckInDateKey = 'tracking_check_in_date';
  static const String _trackingIntervalKey = 'tracking_interval_seconds';
  static const String _appForegroundKey = 'app_foreground';
  static const String _lastLocationSentAtKey = 'tracking_last_location_sent_at';
  static const String _endedAttendanceIdKey = 'tracking_ended_attendance_id';
  static const String _lastFixTimeKey = 'tracking_last_fix_time';

  /// Interval kirim lokasi kalau belum ada pengaturan dari server (5 menit).
  static const int defaultIntervalSeconds = 300;

  static SharedPreferencesAsync _store() {
    if (defaultTargetPlatform == TargetPlatform.android) {
      // Backend SharedPreferences Android: satu instance per proses, aman dipakai dua isolate
      // (DataStore menolak dua instance aktif untuk file yang sama).
      return SharedPreferencesAsync(
        options: const SharedPreferencesAsyncAndroidOptions(
          backend: SharedPreferencesAndroidBackendLibrary.SharedPreferences,
          originalSharedPreferencesOptions: AndroidSharedPreferencesStoreOptions(
            fileName: 'mms_tracking_state',
          ),
        ),
      );
    }
    return SharedPreferencesAsync();
  }

  static Future<void> saveTrackingState(TrackingState state) async {
    final store = _store();
    // Tanda aktif ditulis paling akhir supaya layanan tidak membaca state setengah jadi
    await store.setString(_trackingUserIdKey, state.userId);
    await store.setString(_trackingAttendanceIdKey, state.attendanceId);
    await store.setString(_trackingCheckInDateKey, state.checkInDate.toIso8601String());
    await store.setInt(_trackingIntervalKey, state.intervalSeconds);
    await store.setBool(_trackingActiveKey, true);
  }

  static Future<void> clearTrackingState() async {
    final store = _store();
    await store.setBool(_trackingActiveKey, false);
    await store.remove(_trackingUserIdKey);
    await store.remove(_trackingAttendanceIdKey);
    await store.remove(_trackingCheckInDateKey);
    await store.remove(_trackingIntervalKey);
    await store.remove(_lastLocationSentAtKey);
    await store.remove(_lastFixTimeKey);
  }

  static Future<TrackingState?> getTrackingState() async {
    final store = _store();
    final active = await store.getBool(_trackingActiveKey) ?? false;
    if (!active) return null;

    final userId = await store.getString(_trackingUserIdKey);
    final attendanceId = await store.getString(_trackingAttendanceIdKey);
    final checkInDateRaw = await store.getString(_trackingCheckInDateKey);
    if (userId == null || attendanceId == null || checkInDateRaw == null) {
      return null;
    }

    final checkInDate = DateTime.tryParse(checkInDateRaw);
    if (checkInDate == null) {
      return null;
    }

    final intervalSeconds = await store.getInt(_trackingIntervalKey) ?? defaultIntervalSeconds;
    return TrackingState(
      userId: userId,
      attendanceId: attendanceId,
      checkInDate: checkInDate,
      intervalSeconds: intervalSeconds,
    );
  }

  /// Dicatat oleh aplikasi dan layanan latar belakang setiap kali titik lokasi terkirim,
  /// supaya keduanya tidak mengirim titik ganda dalam satu interval.
  static Future<void> markLocationSent(DateTime at, {DateTime? fixTime}) async {
    final store = _store();
    await store.setString(_lastLocationSentAtKey, at.toUtc().toIso8601String());
    if (fixTime != null) {
      await store.setString(_lastFixTimeKey, fixTime.toUtc().toIso8601String());
    }
  }

  /// Jam fix GPS dari titik terakhir yang dikirim layanan latar belakang.
  static Future<DateTime?> getLastFixTime() async {
    final raw = await _store().getString(_lastFixTimeKey);
    return raw == null ? null : DateTime.tryParse(raw);
  }

  static Future<DateTime?> getLastLocationSentAt() async {
    final raw = await _store().getString(_lastLocationSentAtKey);
    return raw == null ? null : DateTime.tryParse(raw);
  }

  /// Sesi check-in yang sudah selesai (check-out, termasuk yang masih antre offline, atau
  /// ditolak server). Pelacakan untuk ID ini tidak dinyalakan lagi walau data absen di HP
  /// masih menganggapnya aktif.
  static Future<void> markAttendanceEnded(String attendanceId) async {
    await _store().setString(_endedAttendanceIdKey, attendanceId);
  }

  static Future<String?> getEndedAttendanceId() async {
    return _store().getString(_endedAttendanceIdKey);
  }

  static Future<void> setAppForeground(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_appForegroundKey, value);
  }

  static Future<bool> isAppForeground() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_appForegroundKey) ?? false;
  }
}
