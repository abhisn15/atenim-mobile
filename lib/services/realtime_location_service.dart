import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:geolocator/geolocator.dart' as geolocator;
import '../models/user_model.dart';
import '../services/persistent_notification_service.dart';
import 'api_service.dart';
import 'tracking_state_service.dart';

// Area monitoring settings
class AreaMonitoringSettings {
  final bool enabled;
  final int warningMinutes;
  final int criticalMinutes;

  AreaMonitoringSettings({
    required this.enabled,
    required this.warningMinutes,
    required this.criticalMinutes,
  });

  factory AreaMonitoringSettings.fromJson(Map<String, dynamic> json) {
    return AreaMonitoringSettings(
      enabled: json['enabled'] ?? true,
      warningMinutes: json['warningMinutes'] ?? 60,
      criticalMinutes: json['criticalMinutes'] ?? 120,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'enabled': enabled,
      'warningMinutes': warningMinutes,
      'criticalMinutes': criticalMinutes,
    };
  }
}

class RealtimeLocationService {
  static const int DEFAULT_WARNING_MINUTES = 60;
  static const int DEFAULT_CRITICAL_MINUTES = 120;

  // Location tracking state
  bool _isTracking = false;
  Timer? _trackingTimer;
  int _intervalSeconds = 60;
  double _movementThreshold = 1.0; // meters
  static const double RADIUS_THRESHOLD = 25.0; // meters - threshold untuk reset timer (20-25 meter)

  // User and attendance info
  String? _currentUserId;
  String? _currentAttendanceId;

  // Location duration tracking (simplified)
  // Hanya track satu lokasi aktif saat ini
  DateTime? _currentLocationEntryTime; // Waktu masuk lokasi saat ini
  double? _currentLocationEntryLat; // Koordinat entry point lokasi saat ini
  double? _currentLocationEntryLng; // Koordinat entry point lokasi saat ini
  int _currentLocationDurationMinutes = 0; // Durasi di lokasi saat ini (dalam menit)
  
  // Store previous location data untuk dikirim saat pindah lokasi
  double? _previousLocationEntryLat;
  double? _previousLocationEntryLng;
  int _previousLocationDurationMinutes = 0;
  DateTime? _previousLocationEntryTime;
  bool _previousLocationConsumed = false; // Flag untuk memastikan previous location hanya dikirim sekali

  // Latest known position for subscribers (mini map)
  final ValueNotifier<geolocator.Position?> latestPosition = ValueNotifier(null);

  // Area monitoring settings
  AreaMonitoringSettings? _areaSettings;

  // Singleton pattern
  static final RealtimeLocationService _instance = RealtimeLocationService._internal();
  factory RealtimeLocationService() => _instance;
  RealtimeLocationService._internal();

  // Getters
  bool get isTracking => _isTracking;
  int get intervalSeconds => _intervalSeconds;
  double get movementThreshold => _movementThreshold;

  // Initialize area monitoring settings
  Future<void> loadAreaMonitoringSettings() async {
    try {
      final response = await ApiService().get('/api/ess/location-settings');
      if (response.statusCode == 200) {
        final data = jsonDecode(response.data);
        _areaSettings = AreaMonitoringSettings.fromJson(data['data']);
        debugPrint('[RealtimeLocationService] Area monitoring settings loaded: warning=${_areaSettings!.warningMinutes}m, critical=${_areaSettings!.criticalMinutes}m');
      }
    } catch (e) {
      debugPrint('[RealtimeLocationService] Failed to load area settings: $e');
      // Use defaults
      _areaSettings = AreaMonitoringSettings(
        enabled: true,
        warningMinutes: DEFAULT_WARNING_MINUTES,
        criticalMinutes: DEFAULT_CRITICAL_MINUTES,
      );
    }
  }

  // Start realtime location tracking
  Future<void> startRealtimeTracking({
    required User user,
    required String attendanceId,
    required DateTime checkInDate,
    int intervalSeconds = 60,
  }) async {
    if (_isTracking) {
      debugPrint('[RealtimeLocationService] Already tracking, stopping first...');
      await stopRealtimeTracking();
    }

    _currentUserId = user.id;
    _currentAttendanceId = attendanceId;
    _intervalSeconds = intervalSeconds;
    _movementThreshold = 1.0;

    // Load area monitoring settings
    await loadAreaMonitoringSettings();

    // Reset location tracking untuk fresh start
    _currentLocationEntryTime = null;
    _currentLocationEntryLat = null;
    _currentLocationEntryLng = null;
    _currentLocationDurationMinutes = 0;
    
    // Clear previous location data
    _previousLocationEntryLat = null;
    _previousLocationEntryLng = null;
    _previousLocationDurationMinutes = 0;
    _previousLocationEntryTime = null;
    _previousLocationConsumed = false;

    // Start tracking
    debugPrint('[RealtimeLocationService] Starting realtime location tracking...');
    debugPrint('[RealtimeLocationService] User: ${user.name} (${user.id})');
    debugPrint('[RealtimeLocationService] Interval: $_intervalSeconds seconds');
    debugPrint('[RealtimeLocationService] Movement threshold: $_movementThreshold meters');
    debugPrint('[RealtimeLocationService] Area monitoring: ${_areaSettings?.enabled ?? true}');

    _isTracking = true;
    await _startLocationTracking();
  }

  // Stop realtime location tracking
  Future<void> stopRealtimeTracking() async {
    debugPrint('[RealtimeLocationService] Stopping realtime location tracking...');

    _isTracking = false;
    _trackingTimer?.cancel();
    _trackingTimer = null;

    // Clear current session data
    _currentUserId = null;
    _currentAttendanceId = null;
    
    // Reset location tracking
    _currentLocationEntryTime = null;
    _currentLocationEntryLat = null;
    _currentLocationEntryLng = null;
    _currentLocationDurationMinutes = 0;
    
    // Clear previous location data
    _previousLocationEntryLat = null;
    _previousLocationEntryLng = null;
    _previousLocationDurationMinutes = 0;
    _previousLocationEntryTime = null;
    _previousLocationConsumed = false;

    debugPrint('[RealtimeLocationService] Realtime tracking stopped');
  }

  // Internal method to start location tracking
  Future<void> _startLocationTracking() async {
    // Check permissions
    final permission = await geolocator.Geolocator.checkPermission();
    if (permission == geolocator.LocationPermission.denied ||
        permission == geolocator.LocationPermission.deniedForever) {
      debugPrint('[RealtimeLocationService] Location permission denied');
      // Belum benar-benar melacak: biarkan syncRealtimeTracking mencoba lagi nanti
      _isTracking = false;
      return;
    }

    final serviceEnabled = await geolocator.Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      debugPrint('[RealtimeLocationService] Location service not enabled');
      _isTracking = false;
      return;
    }

    // Start timer for periodic location tracking
    debugPrint('[RealtimeLocationService] Starting location tracking timer with interval: $_intervalSeconds seconds');
    _trackingTimer = Timer.periodic(
      Duration(seconds: _intervalSeconds),
      (timer) => _trackAndSendLocation(),
    );

    debugPrint('[RealtimeLocationService] Location tracking timer started successfully');
  }

  // Track and send location
  Future<void> _trackAndSendLocation() async {
    if (!_isTracking || _currentUserId == null || _currentAttendanceId == null) {
      return;
    }

    try {
      final position = await geolocator.Geolocator.getCurrentPosition(
        desiredAccuracy: geolocator.LocationAccuracy.high,
      );

      // Track location duration for monitoring
      // Mengembalikan true jika user pindah lokasi (jarak > 25m)
      bool hasLocationChanged = await _trackLocationDuration(position.latitude, position.longitude);

      // Check location alerts
      await _checkLocationAlerts(position.latitude, position.longitude);

      // HANYA kirim log jika:
      // 1. User pindah lokasi (jarak > 25m) - kirim log dengan durasi stay yang sudah terkumpul
      // 2. Atau ini adalah lokasi pertama (belum ada entry point)
    if (hasLocationChanged || _currentLocationEntryTime == null) {
        // Jika pindah lokasi, kirim log dengan durasi stay dari lokasi sebelumnya
        // HANYA kirim jika belum pernah dikirim sebelumnya (flag _previousLocationConsumed = false)
        if (hasLocationChanged && 
            !_previousLocationConsumed && // Pastikan hanya dikirim sekali
            _previousLocationEntryLat != null && 
            _previousLocationEntryLng != null && 
            _previousLocationEntryTime != null &&
            _previousLocationDurationMinutes > 0) { // Hanya kirim jika durasi > 0
          debugPrint('[RealtimeLocationService] 📤 Sending previous location log: $_previousLocationDurationMinutes min');
          // Kirim log untuk lokasi sebelumnya dengan durasi stay yang sudah terkumpul
          final success = await _sendLocationToServer(
            geolocator.Position(
              latitude: _previousLocationEntryLat!,
              longitude: _previousLocationEntryLng!,
              timestamp: DateTime.now(),
              accuracy: position.accuracy,
              altitude: position.altitude,
              heading: position.heading,
              speed: position.speed,
              speedAccuracy: position.speedAccuracy,
              altitudeAccuracy: position.altitudeAccuracy,
              headingAccuracy: position.headingAccuracy,
            ),
            durationMinutes: _previousLocationDurationMinutes,
            entryLat: _previousLocationEntryLat!,
            entryLng: _previousLocationEntryLng!,
            entryTime: _previousLocationEntryTime!, // Entry time dari lokasi sebelumnya
          );
          
          // Setelah berhasil mengirim, clear previous location data dan set flag
          // Ini memastikan log untuk previous location hanya dikirim sekali
          if (success) {
            _previousLocationEntryLat = null;
            _previousLocationEntryLng = null;
            _previousLocationDurationMinutes = 0;
            _previousLocationEntryTime = null;
            _previousLocationConsumed = true;
          } else {
            // Data tidak di-clear, akan dicoba lagi pada interval berikutnya
          }
        } else if (hasLocationChanged && _previousLocationDurationMinutes == 0) {
          // Clear data meskipun durasi 0 (tidak perlu kirim log untuk durasi 0)
          _previousLocationEntryLat = null;
          _previousLocationEntryLng = null;
          _previousLocationDurationMinutes = 0;
          _previousLocationEntryTime = null;
          _previousLocationConsumed = true;
        }
        
        // Kirim log untuk lokasi baru (entry point baru)
        await _sendLocationToServer(position);
      }

    } catch (e) {
      debugPrint('[RealtimeLocationService] Error getting location: $e');
    }
  }

  // Track durasi di lokasi tertentu untuk monitoring
  // Logic: Timer terus bertambah saat dalam radius 25m, reset saat jarak > 25m dari entry point
  // Returns: true jika user pindah lokasi (jarak > 25m), false jika masih dalam radius
  Future<bool> _trackLocationDuration(double latitude, double longitude) async {
    DateTime now = DateTime.now();

    // Jika belum ada lokasi yang di-track, mulai tracking lokasi baru
    if (_currentLocationEntryTime == null || _currentLocationEntryLat == null || _currentLocationEntryLng == null) {
      _currentLocationEntryTime = now;
      _currentLocationEntryLat = latitude;
      _currentLocationEntryLng = longitude;
      _currentLocationDurationMinutes = 0;
      return true; // Lokasi pertama, kirim log
    }

    // Hitung jarak dari entry point lokasi saat ini
        double distance = geolocator.Geolocator.distanceBetween(
      _currentLocationEntryLat!,
      _currentLocationEntryLng!,
      latitude,
      longitude,
        );
        
    // Jika jarak > 25m dari entry point, reset timer dan mulai lokasi baru
    // SETIAP PINDAH KOORDINAT (jarak > 25m) = RESET TIMER KE 0
    if (distance > RADIUS_THRESHOLD) {
      // Simpan data lokasi sebelumnya untuk dikirim ke server (SEBELUM reset)
      _previousLocationEntryLat = _currentLocationEntryLat;
      _previousLocationEntryLng = _currentLocationEntryLng;
      _previousLocationDurationMinutes = _currentLocationDurationMinutes;
      _previousLocationEntryTime = _currentLocationEntryTime; // Simpan entry time sebelum reset
      _previousLocationConsumed = false; // Reset flag agar log untuk previous location bisa dikirim
      
      debugPrint('[RealtimeLocationService] 🔄 RESET: Moved ${distance.toStringAsFixed(1)}m, previous duration: $_previousLocationDurationMinutes min');
      
      // RESET: Setiap koordinat baru punya timer sendiri yang mulai dari 0
      _currentLocationEntryTime = now;
      _currentLocationEntryLat = latitude;
      _currentLocationEntryLng = longitude;
      _currentLocationDurationMinutes = 0; // RESET KE 0 - Lokasi baru punya timer sendiri
      
      debugPrint('[RealtimeLocationService] 🆕 New location: ${latitude.toStringAsFixed(6)}, ${longitude.toStringAsFixed(6)}');
      return true; // Pindah lokasi, kirim log
    }

    // Masih dalam radius 25m dari entry point, timer terus bertambah
    // Timer ini spesifik untuk lokasi saat ini (entry point: $_currentLocationEntryLat, $_currentLocationEntryLng)
    Duration duration = now.difference(_currentLocationEntryTime!);
    int minutesInLocation = duration.inMinutes;

    // Update durasi dengan batas maksimal (8 jam untuk work scenarios)
    const int maxDurationMinutes = 8 * 60; // 8 hours
    if (minutesInLocation > maxDurationMinutes) {
      debugPrint('[RealtimeLocationService] Duration capped at $maxDurationMinutes minutes');
      minutesInLocation = maxDurationMinutes;
    }

    _currentLocationDurationMinutes = minutesInLocation;

    // Debug log durasi saat ini (setiap 5 menit untuk mengurangi logging di device low-end)
    if (minutesInLocation > 0 && minutesInLocation % 5 == 0) {
      debugPrint('[RealtimeLocationService] ⏱️ Timer: $minutesInLocation min (distance: ${distance.toStringAsFixed(1)}m)');
    }

    return false; // Masih dalam radius, tidak kirim log
  }

  // Check for location alerts (WARNING only - critical removed)
  Future<void> _checkLocationAlerts(double latitude, double longitude) async {
    // Gunakan durasi saat ini dari lokasi yang sedang di-track
    int minutesInLocation = _currentLocationDurationMinutes;

    // Gunakan settings dari server atau default
    int warningMinutes = _areaSettings?.warningMinutes ?? DEFAULT_WARNING_MINUTES;
    bool monitoringEnabled = _areaSettings?.enabled ?? true;

    if (monitoringEnabled) {
      // Check untuk warning alert (setiap kelipatan 30 menit) - Critical alert dihapus karena terlalu mengganggu
      if (minutesInLocation >= warningMinutes && minutesInLocation % 30 == 0) {
        debugPrint('[RealtimeLocationService] WARNING ALERT: User at same location for $minutesInLocation minutes');
        debugPrint('[RealtimeLocationService] Location: $latitude, $longitude');
        await _showLocationAlert('WARNING', minutesInLocation, latitude, longitude);
      }
    }
  }

  // Send location to server
  // Optional parameters untuk lokasi sebelumnya (saat pindah lokasi)
  // Returns: true jika berhasil, false jika gagal
  Future<bool> _sendLocationToServer(
    geolocator.Position position, {
    int? durationMinutes,
    double? entryLat,
    double? entryLng,
    DateTime? entryTime,
  }) async {
    try {
      // Get current date for the API
      DateTime now = DateTime.now();
      String dateStr = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      
      // Jika ada parameter untuk lokasi sebelumnya, gunakan itu
      // Jika tidak, gunakan lokasi saat ini
      Map<String, dynamic> locationInfo;
      
      if (durationMinutes != null && entryLat != null && entryLng != null && entryTime != null) {
        // Kirim log untuk lokasi sebelumnya dengan durasi stay yang sudah terkumpul
        locationInfo = {
          'currentLocation': {
            'latitude': entryLat,
            'longitude': entryLng,
            'durationMinutes': durationMinutes,
            'entryTime': entryTime.toIso8601String(),
            'entryLatitude': entryLat,
            'entryLongitude': entryLng,
          },
        };
      } else {
        // Kirim log untuk lokasi saat ini (entry point baru)
        locationInfo = _getLocationDurationInfo(position.latitude, position.longitude);
      }
      
      final locationData = {
        'userId': _currentUserId, // ✅ Required by API
        'attendanceId': _currentAttendanceId,
        'date': dateStr,
        'latitude': position.latitude,
        'longitude': position.longitude,
        'accuracy': position.accuracy,
        'speed': position.speed,
        'heading': position.heading,
        'timestamp': position.timestamp.toIso8601String(),
        'locationInfo': locationInfo, // ✅ Complete locationInfo with stayDurations
      };

      latestPosition.value = position;
      // Layanan latar belakang yang mengirim titik rute selama check-in. Aplikasi hanya mengirim
      // kalau layanan itu tidak berjalan, supaya tidak ada titik ganda atau rute yang melompat balik.
      try {
        if (await FlutterBackgroundService().isRunning()) {
          return true;
        }
      } catch (_) {}
      final response = await ApiService().post('/api/supervisor/attendance/realtime/log', data: locationData);

      if (response.statusCode == 200) {
        // Layanan latar belakang membaca penanda ini supaya tidak mengirim titik ganda
        await TrackingStateService.markLocationSent(DateTime.now());
        return true;
      } else if (response.statusCode == 404 || response.statusCode == 409) {
        // Sesi sudah selesai di server: jangan terus mengirim sampai aplikasi memuat ulang data absen
        debugPrint('[RealtimeLocationService] Session ended on server (${response.statusCode})');
        final endedId = _currentAttendanceId;
        if (endedId != null) {
          await TrackingStateService.markAttendanceEnded(endedId);
        }
        await stopRealtimeTracking();
        return false;
      } else if (response.statusCode == 403) {
        debugPrint('[RealtimeLocationService] ⚠️ Session expired (403)');
        return false;
      } else {
        debugPrint('[RealtimeLocationService] ⚠️ Failed: ${response.statusCode}');
        return false;
      }
    } catch (e) {
      debugPrint('[RealtimeLocationService] ⚠️ Error: $e');
      return false;
    }
  }

  // Get location duration info untuk dikirim ke server
  // Hanya kirim currentLocation dengan durationMinutes yang terus bertambah
  Map<String, dynamic> _getLocationDurationInfo(double latitude, double longitude) {
    // Pastikan durationMinutes selalu integer (bukan null)
    int durationMinutes = _currentLocationDurationMinutes;
    
    latestPosition.value = geolocator.Position(
      latitude: latitude,
      longitude: longitude,
      timestamp: DateTime.now(),
      accuracy: 0,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
    );

    return {
      'currentLocation': {
        'latitude': latitude,
        'longitude': longitude,
        'durationMinutes': durationMinutes, // Durasi saat ini (timer terus bertambah selama dalam radius) - SELALU INTEGER
        'entryTime': _currentLocationEntryTime?.toIso8601String() ?? DateTime.now().toIso8601String(),
        'entryLatitude': _currentLocationEntryLat,
        'entryLongitude': _currentLocationEntryLng,
      },
    };
    }


  // Sync pending location logs
  Future<void> syncPendingLocationLogs() async {
    debugPrint('[RealtimeLocationService] Sync pending location logs - no pending logs to sync');
    // For now, just log that there's nothing to sync
  }

  // Show local notification for location alerts
  Future<void> _showLocationAlert(String alertType, int minutes, double latitude, double longitude) async {
    try {
      // Format coordinates untuk display
      String coords = '${latitude.toStringAsFixed(4)}, ${longitude.toStringAsFixed(4)}';

      // Create notification content
      String title = '$alertType Alert - Lokasi';
      String body = 'Anda telah di lokasi yang sama selama $minutes menit\nKoordinat: $coords';

      // Show actual notification to user
      debugPrint('[RealtimeLocationService] ALERT NOTIFICATION: $title');
      debugPrint('[RealtimeLocationService] $body');

      // Integrate with notification service
      await PersistentNotificationService.showLocationAlert(title, body);

    } catch (e) {
      debugPrint('[RealtimeLocationService] Error showing location alert: $e');
    }
  }

  // Helper method untuk membuka app settings
  Future<void> openAppSettings() async {
    debugPrint('[RealtimeLocationService] Opening app settings...');
    try {
      await geolocator.Geolocator.openAppSettings();
      debugPrint('[RealtimeLocationService] App settings opened');
    } catch (e) {
      debugPrint('[RealtimeLocationService] Failed to open app settings: $e');
    }
  }
}
