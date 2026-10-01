import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'dart:convert';
import 'dart:io';

/// Service untuk menyimpan dan mengambil data offline
class OfflineStorageService {
  static const String _attendanceKey = 'offline_attendance';
  static const String _shiftsKey = 'offline_shifts';
  static const String _activitiesKey = 'offline_activities';
  static const String _requestsKey = 'offline_requests';
  static const String _pendingCheckInKey = 'pending_checkin';
  static const String _pendingCheckOutKey = 'pending_checkout';
  static const String _pendingActivitiesKey = 'pending_activities';
  static const String _pendingPatroliKey = 'pending_patroli';
  static const String _pendingRequestsKey = 'pending_requests';
  static const String _pendingLocationLogsKey = 'pending_location_logs';
  static const int _maxPendingLocationLogs = 500;

  /// Simpan attendance data
  Future<void> saveAttendance(Map<String, dynamic> data) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_attendanceKey, jsonEncode(data));
      debugPrint('[OfflineStorage] Attendance data saved');
    } catch (e) {
      debugPrint('[OfflineStorage] Error saving attendance: $e');
    }
  }

  /// Ambil attendance data
  Future<Map<String, dynamic>?> getAttendance() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final data = prefs.getString(_attendanceKey);
      if (data != null) {
        return jsonDecode(data) as Map<String, dynamic>;
      }
      return null;
    } catch (e) {
      debugPrint('[OfflineStorage] Error getting attendance: $e');
      return null;
    }
  }

  /// Simpan shifts data
  Future<void> saveShifts(Map<String, dynamic> data) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_shiftsKey, jsonEncode(data));
      debugPrint('[OfflineStorage] Shifts data saved');
    } catch (e) {
      debugPrint('[OfflineStorage] Error saving shifts: $e');
    }
  }

  /// Ambil shifts data
  Future<Map<String, dynamic>?> getShifts() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final data = prefs.getString(_shiftsKey);
      if (data != null) {
        return jsonDecode(data) as Map<String, dynamic>;
      }
      return null;
    } catch (e) {
      debugPrint('[OfflineStorage] Error getting shifts: $e');
      return null;
    }
  }

  /// Simpan activities data
  Future<void> saveActivities(Map<String, dynamic> data) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_activitiesKey, jsonEncode(data));
      debugPrint('[OfflineStorage] Activities data saved');
    } catch (e) {
      debugPrint('[OfflineStorage] Error saving activities: $e');
    }
  }

  /// Ambil activities data
  Future<Map<String, dynamic>?> getActivities() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final data = prefs.getString(_activitiesKey);
      if (data != null) {
        return jsonDecode(data) as Map<String, dynamic>;
      }
      return null;
    } catch (e) {
      debugPrint('[OfflineStorage] Error getting activities: $e');
      return null;
    }
  }

  /// Simpan requests data
  Future<void> saveRequests(Map<String, dynamic> data) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_requestsKey, jsonEncode(data));
      debugPrint('[OfflineStorage] Requests data saved');
    } catch (e) {
      debugPrint('[OfflineStorage] Error saving requests: $e');
    }
  }

  /// Ambil requests data
  Future<Map<String, dynamic>?> getRequests() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final data = prefs.getString(_requestsKey);
      if (data != null) {
        return jsonDecode(data) as Map<String, dynamic>;
      }
      return null;
    } catch (e) {
      debugPrint('[OfflineStorage] Error getting requests: $e');
      return null;
    }
  }

  /// Simpan pending check-in
  Future<void> savePendingCheckIn(Map<String, dynamic> data) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final pending = await getPendingCheckIns();
      final clientKey = data['clientKey']?.toString();
      if (clientKey != null && clientKey.isNotEmpty) {
        final exists = pending.any((item) => item['clientKey']?.toString() == clientKey);
        if (exists) {
          debugPrint('[OfflineStorage] Duplicate pending check-in ignored ($clientKey)');
          return;
        }
      }
      pending.add({
        ...data,
        'timestamp': DateTime.now().toIso8601String(),
      });
      await prefs.setString(_pendingCheckInKey, jsonEncode(pending));
      debugPrint('[OfflineStorage] Pending check-in saved');
    } catch (e) {
      debugPrint('[OfflineStorage] Error saving pending check-in: $e');
    }
  }

  /// Ambil semua pending check-ins
  Future<List<Map<String, dynamic>>> getPendingCheckIns() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final data = prefs.getString(_pendingCheckInKey);
      if (data != null) {
        final list = jsonDecode(data) as List;
        return list.cast<Map<String, dynamic>>();
      }
      return [];
    } catch (e) {
      debugPrint('[OfflineStorage] Error getting pending check-ins: $e');
      return [];
    }
  }

  /// Hapus pending check-in setelah berhasil sync
  Future<void> removePendingCheckIn(int index) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final pending = await getPendingCheckIns();
      if (index >= 0 && index < pending.length) {
        pending.removeAt(index);
        await prefs.setString(_pendingCheckInKey, jsonEncode(pending));
        debugPrint('[OfflineStorage] Pending check-in removed');
      }
    } catch (e) {
      debugPrint('[OfflineStorage] Error removing pending check-in: $e');
    }
  }

  /// Simpan pending check-out
  Future<void> savePendingCheckOut(Map<String, dynamic> data) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final pending = await getPendingCheckOuts();
      final clientKey = data['clientKey']?.toString();
      if (clientKey != null && clientKey.isNotEmpty) {
        final exists = pending.any((item) => item['clientKey']?.toString() == clientKey);
        if (exists) {
          debugPrint('[OfflineStorage] Duplicate pending check-out ignored ($clientKey)');
          return;
        }
      }
      pending.add({
        ...data,
        'timestamp': DateTime.now().toIso8601String(),
      });
      await prefs.setString(_pendingCheckOutKey, jsonEncode(pending));
      debugPrint('[OfflineStorage] Pending check-out saved');
    } catch (e) {
      debugPrint('[OfflineStorage] Error saving pending check-out: $e');
    }
  }

  /// Ambil semua pending check-outs
  Future<List<Map<String, dynamic>>> getPendingCheckOuts() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final data = prefs.getString(_pendingCheckOutKey);
      if (data != null) {
        final list = jsonDecode(data) as List;
        return list.cast<Map<String, dynamic>>();
      }
      return [];
    } catch (e) {
      debugPrint('[OfflineStorage] Error getting pending check-outs: $e');
      return [];
    }
  }

  /// Hapus pending check-out setelah berhasil sync
  Future<void> removePendingCheckOut(int index) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final pending = await getPendingCheckOuts();
      if (index >= 0 && index < pending.length) {
        pending.removeAt(index);
        await prefs.setString(_pendingCheckOutKey, jsonEncode(pending));
        debugPrint('[OfflineStorage] Pending check-out removed');
      }
    } catch (e) {
      debugPrint('[OfflineStorage] Error removing pending check-out: $e');
    }
  }

  /// Simpan pending activity
  Future<void> savePendingActivity(Map<String, dynamic> data) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final pending = await getPendingActivities();
      final clientKey = data['clientKey']?.toString();
      if (clientKey != null && clientKey.isNotEmpty) {
        final exists = pending.any((item) => item['clientKey']?.toString() == clientKey);
        if (exists) {
          debugPrint('[OfflineStorage] Duplicate pending activity ignored ($clientKey)');
          return;
        }
      }
      pending.add({
        ...data,
        'timestamp': DateTime.now().toIso8601String(),
      });
      await prefs.setString(_pendingActivitiesKey, jsonEncode(pending));
      debugPrint('[OfflineStorage] Pending activity saved');
    } catch (e) {
      debugPrint('[OfflineStorage] Error saving pending activity: $e');
    }
  }

  /// Ambil semua pending activities
  Future<List<Map<String, dynamic>>> getPendingActivities() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final data = prefs.getString(_pendingActivitiesKey);
      if (data != null) {
        final list = jsonDecode(data) as List;
        return list.cast<Map<String, dynamic>>();
      }
      return [];
    } catch (e) {
      debugPrint('[OfflineStorage] Error getting pending activities: $e');
      return [];
    }
  }

  /// Hapus pending activity setelah berhasil sync
  Future<void> removePendingActivity(int index) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final pending = await getPendingActivities();
      if (index >= 0 && index < pending.length) {
        pending.removeAt(index);
        await prefs.setString(_pendingActivitiesKey, jsonEncode(pending));
        debugPrint('[OfflineStorage] Pending activity removed');
      }
    } catch (e) {
      debugPrint('[OfflineStorage] Error removing pending activity: $e');
    }
  }

  /// Simpan pending patroli (terpisah dari daily activities)
  Future<void> savePendingPatroli(Map<String, dynamic> data) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final pending = await getPendingPatroli();
      final clientKey = data['clientKey']?.toString();
      if (clientKey != null && clientKey.isNotEmpty) {
        final exists = pending.any((item) => item['clientKey']?.toString() == clientKey);
        if (exists) {
          debugPrint('[OfflineStorage] Duplicate pending patroli ignored ($clientKey)');
          return;
        }
      }
      pending.add({
        ...data,
        'timestamp': DateTime.now().toIso8601String(),
      });
      await prefs.setString(_pendingPatroliKey, jsonEncode(pending));
      debugPrint('[OfflineStorage] Pending patroli saved');
    } catch (e) {
      debugPrint('[OfflineStorage] Error saving pending patroli: $e');
    }
  }

  /// Ambil semua pending patroli
  Future<List<Map<String, dynamic>>> getPendingPatroli() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final data = prefs.getString(_pendingPatroliKey);
      if (data != null) {
        final list = jsonDecode(data) as List;
        return list.cast<Map<String, dynamic>>();
      }
      return [];
    } catch (e) {
      debugPrint('[OfflineStorage] Error getting pending patroli: $e');
      return [];
    }
  }

  /// Hapus pending patroli setelah berhasil sync
  Future<void> removePendingPatroli(int index) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final pending = await getPendingPatroli();
      if (index >= 0 && index < pending.length) {
        pending.removeAt(index);
        await prefs.setString(_pendingPatroliKey, jsonEncode(pending));
        debugPrint('[OfflineStorage] Pending patroli removed');
      }
    } catch (e) {
      debugPrint('[OfflineStorage] Error removing pending patroli: $e');
    }
  }

  /// Simpan pending location log
  Future<void> savePendingLocationLog(Map<String, dynamic> data) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final pending = await getPendingLocationLogs();
      pending.add({
        ...data,
        'timestamp': DateTime.now().toIso8601String(),
      });
      // Batasi antrean (500 titik = ~40 jam pada interval 5 menit): yang paling lama dibuang
      if (pending.length > _maxPendingLocationLogs) {
        pending.removeRange(0, pending.length - _maxPendingLocationLogs);
      }
      await prefs.setString(_pendingLocationLogsKey, jsonEncode(pending));
      debugPrint('[OfflineStorage] Pending location log saved');
    } catch (e) {
      debugPrint('[OfflineStorage] Error saving pending location log: $e');
    }
  }

  /// Jumlah laporan yang masih tertahan di HP (absen, aktivitas, patroli).
  /// Dipakai untuk memperingatkan sebelum logout, karena logout menghapusnya.
  Future<int> countUnsentReports() async {
    final lists = await Future.wait([
      getPendingCheckIns(),
      getPendingCheckOuts(),
      getPendingActivities(),
      getPendingPatroli(),
    ]);
    return lists.fold<int>(0, (total, list) => total + list.length);
  }

  /// Ambil semua pending location logs
  Future<List<Map<String, dynamic>>> getPendingLocationLogs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final data = prefs.getString(_pendingLocationLogsKey);
      if (data != null) {
        final list = jsonDecode(data) as List;
        return list.cast<Map<String, dynamic>>();
      }
      return [];
    } catch (e) {
      debugPrint('[OfflineStorage] Error getting pending location logs: $e');
      return [];
    }
  }

  /// Hapus pending location log setelah berhasil sync
  Future<void> removePendingLocationLog(int index) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final pending = await getPendingLocationLogs();
      if (index >= 0 && index < pending.length) {
        pending.removeAt(index);
        await prefs.setString(_pendingLocationLogsKey, jsonEncode(pending));
        debugPrint('[OfflineStorage] Pending location log removed');
      }
    } catch (e) {
      debugPrint('[OfflineStorage] Error removing pending location log: $e');
    }
  }

  /// Clear semua data offline
  Future<void> clearAll() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_attendanceKey);
      await prefs.remove(_shiftsKey);
      await prefs.remove(_activitiesKey);
      await prefs.remove(_requestsKey);
      await prefs.remove(_pendingCheckInKey);
      await prefs.remove(_pendingCheckOutKey);
      await prefs.remove(_pendingActivitiesKey);
      await prefs.remove(_pendingPatroliKey);
      await prefs.remove(_pendingRequestsKey);
      await prefs.remove(_pendingLocationLogsKey);
      // Salinan foto antrean (lihat ActivityProvider._persistPendingPhotos)
      final photoDir = Directory(p.join((await getApplicationDocumentsDirectory()).path, 'pending_photos'));
      if (await photoDir.exists()) await photoDir.delete(recursive: true);
      debugPrint('[OfflineStorage] All offline data cleared');
    } catch (e) {
      debugPrint('[OfflineStorage] Error clearing data: $e');
    }
  }
}
