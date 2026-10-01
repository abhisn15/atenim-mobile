import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:geolocator/geolocator.dart';
import '../config/api_config.dart';
import '../models/attendance_model.dart';
import '../models/user_model.dart' show Site;
import '../models/shift_model.dart';
import '../utils/error_handler.dart';
import 'api_service.dart';

class AttendanceService {
  final ApiService _apiService = ApiService();
  static final DeviceInfoPlugin _deviceInfoPlugin = DeviceInfoPlugin();
  Map<String, dynamic>? _deviceInfoCache;
  Map<String, dynamic>? _appInfoCache;
  bool _isClientInfoLoading = false;

  void _validateGeofence({
    required Site? site,
    required double? latitude,
    required double? longitude,
    required String actionLabel,
  }) {
    final siteLat = site?.latitude;
    final siteLng = site?.longitude;
    final maxRadiusMeters = site?.maxRadiusMeters;
    if (siteLat == null || siteLng == null || maxRadiusMeters == null) {
      return;
    }
    final placementName = site?.name.trim();
    final locationLabel = (placementName != null && placementName.isNotEmpty)
        ? placementName
        : 'lokasi penempatan';
    final requirementLabel =
        'dalam radius ${maxRadiusMeters}m dari $locationLabel';
    if (latitude == null || longitude == null) {
      throw Exception(
        'GPS wajib aktif untuk $actionLabel. Pastikan berada $requirementLabel.',
      );
    }
    final distance = Geolocator.distanceBetween(
      siteLat,
      siteLng,
      latitude,
      longitude,
    );
    if (distance > maxRadiusMeters.toDouble()) {
      throw Exception(
        'Lokasi di luar radius (${distance.round()}m > ${maxRadiusMeters}m) dari $locationLabel. '
        'Pindah ke area penempatan untuk $actionLabel.',
      );
    }
  }

  Future<Map<String, dynamic>> _getClientMeta() async {
    if (_deviceInfoCache != null && _appInfoCache != null) {
      return {'device': _deviceInfoCache, 'app': _appInfoCache};
    }
    if (_isClientInfoLoading) {
      return {'device': _deviceInfoCache, 'app': _appInfoCache};
    }
    _isClientInfoLoading = true;
    try {
      _deviceInfoCache ??= await _loadDeviceInfo();
      _appInfoCache ??= await _loadAppInfo();
    } catch (e) {
      debugPrint('[AttendanceService] Failed to load client meta: $e');
    } finally {
      _isClientInfoLoading = false;
    }
    return {'device': _deviceInfoCache, 'app': _appInfoCache};
  }

  Future<Map<String, dynamic>> _loadDeviceInfo() async {
    if (Platform.isAndroid) {
      final info = await _deviceInfoPlugin.androidInfo;
      return {
        'platform': 'android',
        'brand': info.brand,
        'model': info.model,
        'device': info.device,
        'manufacturer': info.manufacturer,
        'version': info.version.release,
        'sdkInt': info.version.sdkInt,
        'isPhysicalDevice': info.isPhysicalDevice,
      };
    }
    if (Platform.isIOS) {
      final info = await _deviceInfoPlugin.iosInfo;
      return {
        'platform': 'ios',
        'name': info.name,
        'model': info.model,
        'systemName': info.systemName,
        'systemVersion': info.systemVersion,
        'isPhysicalDevice': info.isPhysicalDevice,
      };
    }
    return {
      'platform': Platform.operatingSystem,
      'version': Platform.operatingSystemVersion,
    };
  }

  Future<Map<String, dynamic>> _loadAppInfo() async {
    final info = await PackageInfo.fromPlatform();
    return {
      'name': info.appName,
      'package': info.packageName,
      'version': info.version,
      'buildNumber': info.buildNumber,
    };
  }

  Future<Map<String, double>> getRequiredLocation({
    required String actionLabel,
  }) async {
    debugPrint('[AttendanceService] Checking location permission...');
    var permission = await Geolocator.checkPermission();

    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.denied) {
      throw Exception('Izin lokasi ditolak. Aktifkan GPS untuk $actionLabel.');
    }

    if (permission == LocationPermission.deniedForever) {
      await Geolocator.openAppSettings();
      throw Exception(
        'Izin lokasi ditolak permanen. Aktifkan dari pengaturan untuk $actionLabel.',
      );
    }

    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      await Geolocator.openLocationSettings();
      throw Exception('GPS belum aktif. Aktifkan lokasi untuk $actionLabel.');
    }

    debugPrint('[AttendanceService] Getting GPS location...');

    Position? lastKnown;
    try {
      lastKnown = await Geolocator.getLastKnownPosition();
      if (lastKnown != null) {
        final now = DateTime.now();
        final positionTime = lastKnown.timestamp;
        final ageSeconds = now.difference(positionTime).inSeconds;
        final isFresh = ageSeconds <= 180;
        final isAccurate = lastKnown.accuracy <= 150;
        if (isFresh && isAccurate) {
          debugPrint(
            '[AttendanceService] Using fresh last-known GPS: ${lastKnown.latitude}, ${lastKnown.longitude} (accuracy=${lastKnown.accuracy.toStringAsFixed(0)}m, age=${ageSeconds}s)',
          );
          return {
            'latitude': lastKnown.latitude,
            'longitude': lastKnown.longitude,
          };
        }
      }
    } catch (e) {
      debugPrint('[AttendanceService] Failed to read last-known GPS: $e');
    }

    try {
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 12),
      );
      debugPrint(
        '[AttendanceService] GPS obtained: ${position.latitude}, ${position.longitude}',
      );
      return {'latitude': position.latitude, 'longitude': position.longitude};
    } on TimeoutException {
      try {
        final fallbackPosition = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.medium,
          timeLimit: const Duration(seconds: 8),
        );
        debugPrint(
          '[AttendanceService] GPS obtained with fallback accuracy: ${fallbackPosition.latitude}, ${fallbackPosition.longitude}',
        );
        return {
          'latitude': fallbackPosition.latitude,
          'longitude': fallbackPosition.longitude,
        };
      } catch (_) {
        if (lastKnown != null) {
          debugPrint(
            '[AttendanceService] Using stale last-known GPS fallback: ${lastKnown.latitude}, ${lastKnown.longitude}',
          );
          return {
            'latitude': lastKnown.latitude,
            'longitude': lastKnown.longitude,
          };
        }
        throw Exception(
          'Gagal mendapatkan lokasi GPS. Pastikan sinyal GPS bagus lalu coba lagi.',
        );
      }
    } catch (e) {
      if (lastKnown != null) {
        debugPrint(
          '[AttendanceService] Current GPS failed, fallback last-known: ${lastKnown.latitude}, ${lastKnown.longitude}',
        );
        return {
          'latitude': lastKnown.latitude,
          'longitude': lastKnown.longitude,
        };
      }
      throw Exception('Gagal mendapatkan lokasi GPS. ${e.toString()}');
    }
  }

  Future<AttendancePayload> getAttendance({
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    debugPrint('[AttendanceService] Loading attendance data...');
    try {
      String url = ApiConfig.attendance;
      if (startDate != null && endDate != null) {
        final startDateStr = startDate.toIso8601String().split('T')[0];
        final endDateStr = endDate.toIso8601String().split('T')[0];
        url =
            '${ApiConfig.attendance}?startDate=$startDateStr&endDate=$endDateStr';
        debugPrint(
          '[AttendanceService] Using date range: $startDateStr to $endDateStr',
        );
      }

      final response = await _apiService.get(url);
      if (response.statusCode == 200) {
        debugPrint('[AttendanceService] ✓ Attendance data loaded successfully');
        final normalizedResponse = _normalizeApiResponse(response.data);
        final payloadJson = _extractAttendancePayload(normalizedResponse);
        final payload = AttendancePayload.fromJson(payloadJson);
        debugPrint(
          '[AttendanceService] Today count: ${payload.today.length}, History count: ${payload.recent.length}',
        );
        // Log semua status untuk debugging
        for (var record in payload.recent) {
          debugPrint(
            '[AttendanceService] - ${record.date}: ${record.status} (${record.checkIn ?? '-'} - ${record.checkOut ?? '-'})',
          );
        }
        return payload;
      }
      // Handle non-200 responses
      if (response.statusCode != null && response.statusCode! >= 400) {
        final errorMessage =
            response.data?['message'] ??
            response.data?['error'] ??
            'Gagal memuat data attendance';
        debugPrint(
          '[AttendanceService] ✗ Error ${response.statusCode}: $errorMessage',
        );
        throw DioException(
          requestOptions: RequestOptions(path: ApiConfig.attendance),
          response: response,
          type: DioExceptionType.badResponse,
          error: errorMessage,
        );
      }
      throw Exception('Gagal memuat data attendance');
    } catch (e) {
      debugPrint('[AttendanceService] ✗ Exception: $e');
      rethrow;
    }
  }

  Future<AttendanceBreakState> getAttendanceBreakState() async {
    try {
      final response = await _apiService.get(ApiConfig.attendanceSessionCurrent);
      if (response.statusCode == 200) {
        final data = response.data;
        final payload = (data is Map && data['data'] is Map<String, dynamic>)
            ? data['data'] as Map<String, dynamic>
            : <String, dynamic>{};
        return AttendanceBreakState.fromJson(payload);
      }

      // Backward compatibility fallback.
      final legacyResponse = await _apiService.get(ApiConfig.attendanceBreakStatus);
      if (legacyResponse.statusCode == 200) {
        final data = legacyResponse.data;
        final payload = (data is Map && data['data'] is Map<String, dynamic>)
            ? data['data'] as Map<String, dynamic>
            : <String, dynamic>{};
        return AttendanceBreakState.fromJson(payload);
      }

      throw Exception(
        (response.data is Map && response.data['message'] != null)
            ? response.data['message'].toString()
            : 'Gagal memuat status istirahat',
      );
    } catch (e) {
      debugPrint('[AttendanceService] getAttendanceBreakState error: $e');
      rethrow;
    }
  }

  Future<Map<String, dynamic>> startAttendanceBreak() async {
    try {
      final idempotencyKey =
          'mobile-break-start-${DateTime.now().microsecondsSinceEpoch}';
      final response = await _apiService.post(
        ApiConfig.attendanceBreakStart,
        headers: {'Idempotency-Key': idempotencyKey},
      );
      if (response.statusCode == 200 || response.statusCode == 201) {
        return {
          'success': true,
          'data': response.data is Map ? response.data['data'] : null,
          'message': response.data is Map
              ? (response.data['message'] ?? 'Istirahat dimulai')
              : 'Istirahat dimulai',
        };
      }
      return {
        'success': false,
        'message': response.data is Map
            ? (response.data['message'] ?? 'Gagal memulai istirahat')
            : 'Gagal memulai istirahat',
      };
    } catch (e) {
      debugPrint('[AttendanceService] startAttendanceBreak error: $e');
      return {'success': false, 'message': ErrorHandler.getErrorMessage(e)};
    }
  }

  Future<Map<String, dynamic>> endAttendanceBreak({String? reason}) async {
    try {
      final idempotencyKey =
          'mobile-break-end-${DateTime.now().microsecondsSinceEpoch}';
      final response = await _apiService.post(
        ApiConfig.attendanceBreakEnd,
        data: {
          if (reason != null && reason.trim().isNotEmpty)
            'reason': reason.trim(),
        },
        headers: {'Idempotency-Key': idempotencyKey},
      );
      if (response.statusCode == 200 || response.statusCode == 201) {
        return {
          'success': true,
          'data': response.data is Map ? response.data['data'] : null,
          'message': response.data is Map
              ? (response.data['message'] ?? 'Istirahat selesai')
              : 'Istirahat selesai',
        };
      }
      return {
        'success': false,
        'message': response.data is Map
            ? (response.data['message'] ?? 'Gagal menyelesaikan istirahat')
            : 'Gagal menyelesaikan istirahat',
      };
    } catch (e) {
      debugPrint('[AttendanceService] endAttendanceBreak error: $e');
      return {'success': false, 'message': ErrorHandler.getErrorMessage(e)};
    }
  }

  dynamic _normalizeApiResponse(dynamic data) {
    if (data is String) {
      final trimmed = data.trim();
      if (trimmed.isEmpty) {
        return <String, dynamic>{};
      }
      try {
        return jsonDecode(trimmed);
      } catch (e) {
        debugPrint('[AttendanceService] Gagal decode response string: $e');
        return data;
      }
    }
    return data;
  }

  Map<String, dynamic> _extractAttendancePayload(dynamic data) {
    if (data is Map<String, dynamic>) {
      final extracted = _tryExtractDataField(data['data']);
      if (extracted != null) {
        return extracted;
      }
      return data;
    }
    if (data is Map) {
      return _extractAttendancePayload(Map<String, dynamic>.from(data));
    }
    if (data is List) {
      debugPrint(
        '[AttendanceService] Attendance response provided as list, wrapping as history',
      );
      return _wrapHistory(data);
    }
    throw Exception(
      'Unexpected attendance response format: ${data.runtimeType}',
    );
  }

  Map<String, dynamic>? _tryExtractDataField(dynamic candidate) {
    if (candidate == null) {
      return null;
    }
    if (candidate is Map || candidate is Map<String, dynamic>) {
      try {
        return _mapFrom(candidate);
      } catch (e) {
        debugPrint('[AttendanceService] Failed to normalize data field: $e');
        return null;
      }
    }
    if (candidate is List) {
      debugPrint(
        '[AttendanceService] Data field is a list, wrapping as history',
      );
      return _wrapHistory(candidate);
    }
    if (candidate is String) {
      return _tryDecodeStringPayload(candidate);
    }
    return null;
  }

  Map<String, dynamic>? _tryDecodeStringPayload(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map || decoded is Map<String, dynamic>) {
        return _mapFrom(decoded);
      }
      if (decoded is List) {
        debugPrint(
          '[AttendanceService] Decoded string payload into list, wrapping as history',
        );
        return _wrapHistory(decoded);
      }
    } catch (e) {
      debugPrint('[AttendanceService] Gagal decode nested string payload: $e');
    }
    return null;
  }

  Map<String, dynamic> _wrapHistory(List<dynamic> history) {
    return {'today': [], 'history': history};
  }

  Map<String, dynamic> _mapFrom(dynamic value) {
    if (value is Map<String, dynamic>) {
      return value;
    }
    if (value is Map) {
      return Map<String, dynamic>.from(value);
    }
    throw Exception(
      'Tidak bisa mengonversi ${value.runtimeType} menjadi Map<String, dynamic>',
    );
  }

  Future<ShiftSchedulePayload> getShiftSchedule() async {
    debugPrint('[AttendanceService] Loading shift schedule...');
    try {
      final response = await _apiService.get(ApiConfig.shifts);
      if (response.statusCode == 200) {
        debugPrint('[AttendanceService] ✓ Shift schedule loaded successfully');
        return ShiftSchedulePayload.fromJson(response.data['data']);
      }
      // Handle non-200 responses
      if (response.statusCode != null && response.statusCode! >= 400) {
        final errorMessage =
            response.data?['message'] ??
            response.data?['error'] ??
            'Gagal memuat shift schedule';
        debugPrint(
          '[AttendanceService] ✗ Error ${response.statusCode}: $errorMessage',
        );
        throw DioException(
          requestOptions: RequestOptions(path: ApiConfig.shifts),
          response: response,
          type: DioExceptionType.badResponse,
          error: errorMessage,
        );
      }
      throw Exception('Gagal memuat shift schedule');
    } catch (e) {
      debugPrint('[AttendanceService] ✗ Exception: $e');
      rethrow;
    }
  }

  Future<Map<String, dynamic>> getLocationSettings() async {
    try {
      final response = await _apiService.get(ApiConfig.locationSettings);
      return response.data;
    } catch (e) {
      debugPrint('[AttendanceService] Failed to get location settings: $e');
      // Return defaults if API fails
      return {
        'data': {
          'intervalSeconds': 60, // 1 minute default
          'isEnabled': false,
        },
        'isFallback': true, // jangan di-cache, supaya request berikutnya coba server lagi
      };
    }
  }

  Future<Map<String, dynamic>> checkIn({
    required File photo,
    String?
    shiftId, // Opsional - jika tidak ada, gunakan shift yang di-assign atau absen tanpa shift
    double? latitude,
    double? longitude,
    Site? site,
    String? checkInReason,
  }) async {
    debugPrint('[AttendanceService] Starting check-in...');
    debugPrint('[AttendanceService] Shift ID: ${shiftId ?? "null (no shift)"}');
    debugPrint('[AttendanceService] Photo path: ${photo.path}');
    try {
      if (latitude == null || longitude == null) {
        final location = await getRequiredLocation(actionLabel: 'check-in');
        latitude = location['latitude'];
        longitude = location['longitude'];
      } else {
        debugPrint(
          '[AttendanceService] Using provided GPS: $latitude, $longitude',
        );
      }

      _validateGeofence(
        site: site,
        latitude: latitude,
        longitude: longitude,
        actionLabel: 'check-in',
      );

      // Validasi file sebelum upload untuk mencegah OOM di device low-end
      try {
        final fileStat = await photo.stat();
        final fileSizeMB = fileStat.size / (1024 * 1024);
        debugPrint(
          '[AttendanceService] Photo size: ${fileSizeMB.toStringAsFixed(2)} MB',
        );

        // Jika file terlalu besar (>10MB), bisa menyebabkan OOM di device low-end
        if (fileSizeMB > 10) {
          throw Exception(
            'Foto terlalu besar (${fileSizeMB.toStringAsFixed(2)} MB). Maksimal 10 MB.',
          );
        }
      } catch (e) {
        if (e.toString().contains('terlalu besar')) {
          rethrow;
        }
        debugPrint('[AttendanceService] ⚠ Could not check file size: $e');
        // Continue anyway if we can't check size
      }

      // Buat MultipartFile dengan error handling untuk mencegah OOM
      MultipartFile? photoFile;
      try {
        photoFile = await MultipartFile.fromFile(photo.path).timeout(
          const Duration(seconds: 10),
          onTimeout: () {
            throw Exception(
              'Timeout saat membaca file foto. File mungkin terlalu besar.',
            );
          },
        );
      } catch (e) {
        if (e.toString().contains('OutOfMemory') ||
            e.toString().contains('out of memory') ||
            e.toString().contains('Memory')) {
          throw Exception(
            'Memori tidak cukup untuk memproses foto. Coba ambil foto dengan resolusi lebih kecil.',
          );
        }
        rethrow;
      }

      final clientMeta = await _getClientMeta();
      final deviceMeta = clientMeta['device'] as Map<String, dynamic>?;
      final appMeta = clientMeta['app'] as Map<String, dynamic>?;
      final formData = FormData.fromMap({
        'photo': photoFile,
        if (shiftId != null)
          'shiftId': shiftId, // Opsional - hanya kirim jika ada
        if (latitude != null) 'latitude': latitude.toString(),
        if (longitude != null) 'longitude': longitude.toString(),
        if (checkInReason != null && checkInReason.trim().isNotEmpty)
          'checkInReason': checkInReason.trim(),
        if (deviceMeta != null) 'deviceInfo': jsonEncode(deviceMeta),
        if (appMeta != null) 'appInfo': jsonEncode(appMeta),
        if (deviceMeta?['model'] != null)
          'deviceModel': deviceMeta!['model'].toString(),
        if (deviceMeta?['brand'] != null)
          'deviceBrand': deviceMeta!['brand'].toString(),
        if (deviceMeta?['version'] != null)
          'osVersion': deviceMeta!['version'].toString(),
        if (deviceMeta?['sdkInt'] != null)
          'sdkInt': deviceMeta!['sdkInt'].toString(),
        if (appMeta?['version'] != null)
          'appVersion': appMeta!['version'].toString(),
        if (appMeta?['buildNumber'] != null)
          'buildNumber': appMeta!['buildNumber'].toString(),
      });

      debugPrint('[AttendanceService] Sending check-in request...');
      final response = await _apiService
          .postFormData(ApiConfig.checkIn, formData)
          .timeout(
            const Duration(seconds: 60), // Timeout 60 detik untuk upload
            onTimeout: () {
              throw Exception(
                'Upload timeout. Koneksi mungkin lambat atau file terlalu besar.',
              );
            },
          );

      if (response.statusCode == 200 || response.statusCode == 201) {
        debugPrint('[AttendanceService] ✓ Check-in successful');
        // Safely parse response data
        final responseData = response.data;
        final data = (responseData is Map && responseData.containsKey('data'))
            ? responseData['data']
            : responseData;
        final message =
            (responseData is Map && responseData.containsKey('message'))
            ? (responseData['message'] as String?)
            : 'Check-in berhasil';

        return {
          'success': true,
          'data': data,
          'message': message ?? 'Check-in berhasil',
        };
      } else {
        // Handle error response
        final responseData = response.data;
        final errorMessage = (responseData is Map)
            ? (responseData['message'] ??
                  responseData['error'] ??
                  'Check-in gagal')
            : 'Check-in gagal';
        debugPrint(
          '[AttendanceService] ✗ Check-in failed: $errorMessage (Status: ${response.statusCode})',
        );
        throw DioException(
          requestOptions: RequestOptions(path: ApiConfig.checkIn),
          response: response,
          type: DioExceptionType.badResponse,
          error: errorMessage,
        );
      }
    } catch (e) {
      final errorMsg = ErrorHandler.getErrorMessage(e);
      debugPrint('[AttendanceService] ✗ Check-in exception: $e');
      debugPrint('[AttendanceService] User-friendly error: $errorMsg');
      return {'success': false, 'message': errorMsg};
    }
  }

  Future<Map<String, dynamic>> checkOut({
    required File photo,
    String? shiftId,
    double? latitude,
    double? longitude,
    Site? site,
    String? earlyCheckoutReason,
  }) async {
    debugPrint('[AttendanceService] Starting check-out...');
    debugPrint('[AttendanceService] Shift ID: ${shiftId ?? "null (no shift)"}');
    debugPrint('[AttendanceService] Photo path: ${photo.path}');
    try {
      if (latitude == null || longitude == null) {
        final location = await getRequiredLocation(actionLabel: 'check-out');
        latitude = location['latitude'];
        longitude = location['longitude'];
      } else {
        debugPrint(
          '[AttendanceService] Using provided GPS: $latitude, $longitude',
        );
      }

      _validateGeofence(
        site: site,
        latitude: latitude,
        longitude: longitude,
        actionLabel: 'check-out',
      );

      // Validasi file sebelum upload untuk mencegah OOM di device low-end
      try {
        final fileStat = await photo.stat();
        final fileSizeMB = fileStat.size / (1024 * 1024);
        debugPrint(
          '[AttendanceService] Photo size: ${fileSizeMB.toStringAsFixed(2)} MB',
        );

        // Jika file terlalu besar (>10MB), bisa menyebabkan OOM di device low-end
        if (fileSizeMB > 10) {
          throw Exception(
            'Foto terlalu besar (${fileSizeMB.toStringAsFixed(2)} MB). Maksimal 10 MB.',
          );
        }
      } catch (e) {
        if (e.toString().contains('terlalu besar')) {
          rethrow;
        }
        debugPrint('[AttendanceService] ⚠ Could not check file size: $e');
        // Continue anyway if we can't check size
      }

      // Buat MultipartFile dengan error handling untuk mencegah OOM
      MultipartFile? photoFile;
      try {
        photoFile = await MultipartFile.fromFile(photo.path).timeout(
          const Duration(seconds: 10),
          onTimeout: () {
            throw Exception(
              'Timeout saat membaca file foto. File mungkin terlalu besar.',
            );
          },
        );
      } catch (e) {
        if (e.toString().contains('OutOfMemory') ||
            e.toString().contains('out of memory') ||
            e.toString().contains('Memory')) {
          throw Exception(
            'Memori tidak cukup untuk memproses foto. Coba ambil foto dengan resolusi lebih kecil.',
          );
        }
        rethrow;
      }

      final clientMeta = await _getClientMeta();
      final deviceMeta = clientMeta['device'] as Map<String, dynamic>?;
      final appMeta = clientMeta['app'] as Map<String, dynamic>?;
      final formData = FormData.fromMap({
        'photo': photoFile,
        if (shiftId != null) 'shiftId': shiftId,
        if (latitude != null) 'latitude': latitude.toString(),
        if (longitude != null) 'longitude': longitude.toString(),
        if (earlyCheckoutReason != null &&
            earlyCheckoutReason.trim().isNotEmpty)
          'earlyCheckoutReason': earlyCheckoutReason.trim(),
        if (deviceMeta != null) 'deviceInfo': jsonEncode(deviceMeta),
        if (appMeta != null) 'appInfo': jsonEncode(appMeta),
        if (deviceMeta?['model'] != null)
          'deviceModel': deviceMeta!['model'].toString(),
        if (deviceMeta?['brand'] != null)
          'deviceBrand': deviceMeta!['brand'].toString(),
        if (deviceMeta?['version'] != null)
          'osVersion': deviceMeta!['version'].toString(),
        if (deviceMeta?['sdkInt'] != null)
          'sdkInt': deviceMeta!['sdkInt'].toString(),
        if (appMeta?['version'] != null)
          'appVersion': appMeta!['version'].toString(),
        if (appMeta?['buildNumber'] != null)
          'buildNumber': appMeta!['buildNumber'].toString(),
      });

      debugPrint('[AttendanceService] Sending check-out request...');
      final response = await _apiService
          .postFormData(ApiConfig.checkOut, formData)
          .timeout(
            const Duration(seconds: 60), // Timeout 60 detik untuk upload
            onTimeout: () {
              throw Exception(
                'Upload timeout. Koneksi mungkin lambat atau file terlalu besar.',
              );
            },
          );

      if (response.statusCode == 200 || response.statusCode == 201) {
        debugPrint('[AttendanceService] ✓ Check-out successful');
        // Safely parse response data
        final responseData = response.data;
        final data = (responseData is Map && responseData.containsKey('data'))
            ? responseData['data']
            : responseData;
        final message =
            (responseData is Map && responseData.containsKey('message'))
            ? (responseData['message'] as String?)
            : 'Check-out berhasil';

        return {
          'success': true,
          'data': data,
          'message': message ?? 'Check-out berhasil',
        };
      } else {
        // Handle error response
        final responseData = response.data;
        final errorMessage = (responseData is Map)
            ? (responseData['message'] ??
                  responseData['error'] ??
                  'Check-out gagal')
            : 'Check-out gagal';
        debugPrint(
          '[AttendanceService] ✗ Check-out failed: $errorMessage (Status: ${response.statusCode})',
        );
        throw DioException(
          requestOptions: RequestOptions(path: ApiConfig.checkOut),
          response: response,
          type: DioExceptionType.badResponse,
          error: errorMessage,
        );
      }
    } catch (e) {
      final errorMsg = ErrorHandler.getErrorMessage(e);
      debugPrint('[AttendanceService] ✗ Check-out exception: $e');
      debugPrint('[AttendanceService] User-friendly error: $errorMsg');
      return {'success': false, 'message': errorMsg};
    }
  }

  /// QR absen aktif di site karyawan bila supervisor sudah memasang layar absen.
  Future<bool> isQrAttendanceEnabled() async {
    try {
      final response = await _apiService.get(ApiConfig.essSiteFlags);
      final body = response.data;
      if (response.statusCode == 200 && body is Map && body['data'] is Map) {
        return body['data']['qrAttendanceEnabled'] == true;
      }
    } catch (e) {
      debugPrint('[AttendanceService] Gagal memuat status QR absen: $e');
    }
    return false;
  }

  /// Absen dengan QR dari layar absen. Server memeriksa QR (berganti tiap 30 detik) dan lokasi GPS.
  /// Hasil: success, message, dan reason dari server (expired/signature/format) bila QR ditolak.
  Future<Map<String, dynamic>> submitQrAttendance({
    required bool checkOut,
    required String qrData,
    required double latitude,
    required double longitude,
    String? shiftId,
  }) async {
    final endpoint = checkOut ? ApiConfig.checkOutQr : ApiConfig.checkInQr;
    try {
      final response = await _apiService
          .post(
            endpoint,
            data: {
              'qrData': qrData,
              'latitude': latitude,
              'longitude': longitude,
              if (checkOut && shiftId != null) 'shiftId': shiftId,
            },
          )
          .timeout(const Duration(seconds: 30));
      final body = response.data;
      final message = body is Map ? body['message']?.toString() : null;
      if (response.statusCode == 200 || response.statusCode == 201) {
        return {
          'success': true,
          'message': message ?? (checkOut ? 'Check-out berhasil' : 'Check-in berhasil'),
        };
      }
      return {
        'success': false,
        'status': response.statusCode,
        'reason': body is Map ? body['reason']?.toString() : null,
        'message': message ?? (checkOut ? 'Check-out gagal' : 'Check-in gagal'),
      };
    } catch (e) {
      return {'success': false, 'message': ErrorHandler.getErrorMessage(e)};
    }
  }
}
