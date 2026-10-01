import 'package:flutter/foundation.dart';
import 'dart:io';
import '../models/attendance_model.dart';
import '../models/user_model.dart' show User;
import '../services/attendance_service.dart';
import '../services/realtime_location_service.dart';
import '../services/offline_storage_service.dart';
import '../services/background_tracking_service.dart';
import '../services/tracking_state_service.dart';
import '../services/persistent_notification_service.dart';
import '../services/auth_service.dart';
import '../utils/error_handler.dart';
import 'connectivity_provider.dart';

class AttendanceProvider with ChangeNotifier {
  final AttendanceService _attendanceService = AttendanceService();
  final RealtimeLocationService _realtimeService = RealtimeLocationService();
  final OfflineStorageService _offlineStorage = OfflineStorageService();
  final AuthService _authService = AuthService();
  ConnectivityProvider? _connectivityProvider;
  AttendancePayload? _attendanceData;
  AttendanceBreakState? _breakState;
  bool _isLoading = false;
  String? _error;
  bool _isOfflineMode = false;
  bool _syncPendingInProgress = false;
  bool _isBreakLoading = false;
  bool _breakActionInProgress = false;

  // Flags to prevent double initialization
  bool _realtimeTrackingInitialized = false;
  bool _trackingEnabledByPolicy = false;
  int _trackingIntervalSeconds = TrackingStateService.defaultIntervalSeconds;

  // Callback setelah checkout sukses (untuk rating popup, dll)
  void Function()? _onCheckoutSuccessCallback;
  void setOnCheckoutSuccessCallback(void Function()? cb) {
    _onCheckoutSuccessCallback = cb;
  }

  // Flags to prevent double API calls
  bool _checkInInProgress = false;
  bool _checkOutInProgress = false;
  bool _loadAttendanceInProgress = false;

  AttendancePayload? get attendanceData => _attendanceData;
  List<AttendanceRecord> get todayRecords => _attendanceData?.today ?? [];
  AttendanceRecord? get activeAttendance {
    for (final record in todayRecords) {
      if (record.checkIn != null && record.checkOut == null) {
        return record;
      }
    }
    return null;
  }

  AttendanceRecord? get todayAttendance => activeAttendance;
  List<AttendanceRecord> get recentAttendance => _attendanceData?.recent ?? [];
  AttendanceBreakState? get breakState => _breakState;
  bool get isLoading => _isLoading;
  bool get isBreakLoading => _isBreakLoading;
  bool get isBreakActionInProgress => _breakActionInProgress;
  String? get error => _error;
  bool get isOfflineMode => _isOfflineMode;
  bool get isRealtimeTracking => _realtimeService.isTracking;
  bool get isTrackingEnabledByPolicy => _trackingEnabledByPolicy;
  int get trackingIntervalSeconds => _trackingIntervalSeconds;

  @override
  void dispose() {
    _connectivityProvider?.removeListener(_handleConnectivityChange);
    super.dispose();
  }

  void setConnectivityProvider(ConnectivityProvider provider) {
    if (_connectivityProvider == provider) {
      return;
    }
    _connectivityProvider?.removeListener(_handleConnectivityChange);
    _connectivityProvider = provider;
    _connectivityProvider?.addListener(_handleConnectivityChange);
  }

  void setForegroundActive(bool value) {
    debugPrint('[AttendanceProvider] Foreground status changed: $value');
    try {
      (_realtimeService as dynamic)?.setForegroundActive?.call(value);
    } catch (e) {
      debugPrint('[AttendanceProvider] setForegroundActive not available: $e');
    }
  }

  void _safeCall(Function fn) {
    try {
      fn();
    } catch (e) {
      // Method might not exist yet, ignore for now
      debugPrint('[AttendanceProvider] Method not available: $e');
    }
  }

  Future<void> _safeCallAsync(Function fn) async {
    try {
      await fn();
    } catch (e) {
      // Method might not exist yet, ignore for now
      debugPrint('[AttendanceProvider] Async method not available: $e');
    }
  }

  // Safe method calls using dynamic access
  void _safeSetForegroundActive(bool value) {
    try {
      (_realtimeService as dynamic)?.setForegroundActive?.call(value);
    } catch (e) {
      debugPrint('[AttendanceProvider] setForegroundActive not available: $e');
    }
  }

  void _safeSyncPendingLocationLogs() {
    _realtimeService.syncPendingLocationLogs().catchError((e) {
      debugPrint(
        '[AttendanceProvider] syncPendingLocationLogs not available: $e',
      );
    });
  }

  Future<void> _safeSyncPendingLocationLogsAsync() async {
    try {
      await _realtimeService.syncPendingLocationLogs();
    } catch (e) {
      debugPrint(
        '[AttendanceProvider] syncPendingLocationLogs async not available: $e',
      );
    }
  }

  String _formatDateOnly(DateTime value) {
    final year = value.year.toString().padLeft(4, '0');
    final month = value.month.toString().padLeft(2, '0');
    final day = value.day.toString().padLeft(2, '0');
    return '$year-$month-$day';
  }

  String _normalizeDate(String? raw) {
    if (raw == null || raw.isEmpty) {
      return _formatDateOnly(DateTime.now());
    }
    return raw.contains('T') ? raw.split('T').first : raw;
  }

  String _buildClientKey(String type, String? shiftId, String date) {
    final shiftKey = (shiftId == null || shiftId.isEmpty)
        ? 'no_shift'
        : shiftId;
    return '$type|$shiftKey|$date';
  }

  Future<List<AttendanceRecord>> _getCachedAttendanceRecords() async {
    if (_attendanceData != null) {
      return [..._attendanceData!.today, ..._attendanceData!.recent];
    }
    final offline = await _offlineStorage.getAttendance();
    if (offline != null) {
      final payload = AttendancePayload.fromJson(offline);
      return [...payload.today, ...payload.recent];
    }
    return [];
  }

  Future<bool> _hasAttendanceFor({
    required String type,
    required String date,
    required String? shiftId,
  }) async {
    final records = await _getCachedAttendanceRecords();
    for (final record in records) {
      if (_normalizeDate(record.date) != date) {
        continue;
      }
      final recordShift = record.shiftId ?? '';
      final targetShift = shiftId ?? '';
      if (recordShift != targetShift) {
        continue;
      }
      if (type == 'checkin' && record.checkIn != null) {
        return true;
      }
      if (type == 'checkout' && record.checkOut != null) {
        return true;
      }
    }
    return false;
  }

  void _handleConnectivityChange() {
    final isConnected = _connectivityProvider?.isConnected ?? true;
    if (!isConnected) {
      return;
    }

    Future.microtask(() async {
      await _enforceTrackingPolicy();
      await syncPendingAttendance();
      debugPrint('[AttendanceProvider] Sync pending location logs');
      _realtimeService.syncPendingLocationLogs().catchError((e) {
        debugPrint(
          '[AttendanceProvider] syncPendingLocationLogs not available: $e',
        );
      });
      await syncRealtimeTracking();
      await ensureBackgroundTracking();
    });
  }

  Future<void> _enforceTrackingPolicy() async {
    final today = todayAttendance;
    final hasActiveAttendance =
        today != null && today.checkIn != null && today.checkOut == null;

    final trackingSettings = await _getEffectiveTrackingSettings();
    final isEnabled = trackingSettings['isEnabled'] as bool? ?? false;
    // Pengaturan tidak terbaca (tanpa sinyal dan belum ada cache): jangan hentikan
    // pelacakan yang sedang jalan, justru di area tanpa sinyal rute perlu tetap terekam.
    final isKnown = trackingSettings['isKnown'] as bool? ?? false;
    final disabledByServer = isKnown && !isEnabled;
    final sessionEnded =
        hasActiveAttendance && await _isEndedAttendance(today.id);

    if (disabledByServer || sessionEnded || !hasActiveAttendance) {
      if (_realtimeService.isTracking) {
        try {
          await _realtimeService.stopRealtimeTracking();
        } catch (e) {
          debugPrint(
            '[AttendanceProvider] Failed to stop realtime tracking during policy enforce: $e',
          );
        }
      }

      // Layanan latar belakang hanya dimatikan kalau monitoring dinonaktifkan atau sesinya
      // sudah selesai. Kalau data absen di HP sekadar tidak memuat sesi aktif (mis. rentang
      // tanggal mulai tanggal 1 memotong shift malam), layanan tetap jalan dan berhenti
      // sendiri begitu server menyatakan sesi selesai; check-out dan logout menghentikannya langsung.
      if (disabledByServer || sessionEnded) {
        try {
          await TrackingStateService.clearTrackingState();
          await BackgroundTrackingService.stop();
        } catch (e) {
          debugPrint(
            '[AttendanceProvider] Failed to stop background tracking during policy enforce: $e',
          );
        }
      }

      _realtimeTrackingInitialized = false;

      if (disabledByServer) {
        debugPrint(
          '[AttendanceProvider] Tracking policy: disabled by site/global feature flags',
        );
      }
    }
  }

  Future<void> _ensureRealtimeTracking() async {
    if (_realtimeTrackingInitialized || _realtimeService.isTracking) {
      return;
    }

    final today = todayAttendance;
    if (today == null || today.checkIn == null || today.checkOut != null) {
      return;
    }

    if (today.id.isEmpty) {
      debugPrint(
        '[AttendanceProvider] Cannot start tracking: attendanceId kosong',
      );
      return;
    }

    if (await _isEndedAttendance(today.id)) {
      return;
    }

    User? user;
    try {
      user = await _authService.getCurrentUser();
    } catch (_) {
      user = null;
    }
    if (user == null) {
      debugPrint('[AttendanceProvider] Cannot start tracking: user null');
      return;
    }

    DateTime checkInDate;
    try {
      checkInDate = DateTime.parse(today.date);
    } catch (_) {
      checkInDate = DateTime.now();
    }

    final trackingSettings = await _getEffectiveTrackingSettings();
    final intervalSeconds = trackingSettings['intervalSeconds'] as int? ??
        TrackingStateService.defaultIntervalSeconds;
    final isEnabled = trackingSettings['isEnabled'] as bool? ?? false;

    if (!isEnabled) {
      debugPrint(
        '[AttendanceProvider] Realtime tracking disabled for this site/user, skipping auto-start',
      );
      try {
        await _realtimeService.stopRealtimeTracking();
      } catch (_) {}
      _realtimeTrackingInitialized = false;
      return;
    }

    try {
      await _realtimeService.startRealtimeTracking(
        user: user,
        attendanceId: today.id,
        checkInDate: checkInDate,
        intervalSeconds: intervalSeconds,
      );
      _realtimeTrackingInitialized = true;
      debugPrint('[AttendanceProvider] Realtime tracking started (auto sync)');
    } catch (e) {
      debugPrint('[AttendanceProvider] Failed to auto-start tracking: $e');
    }
  }

  Future<void> loadBreakState({bool notify = true}) async {
    final today = todayAttendance;
    if (today == null || today.checkIn == null || today.checkOut != null) {
      _breakState = null;
      _isBreakLoading = false;
      if (notify) {
        notifyListeners();
      }
      return;
    }

    final isConnected = _connectivityProvider?.isConnected ?? true;
    if (!isConnected) {
      if (notify) {
        notifyListeners();
      }
      return;
    }

    if (_isBreakLoading) {
      return;
    }

    _isBreakLoading = true;
    if (notify) {
      notifyListeners();
    }

    try {
      _breakState = await _attendanceService.getAttendanceBreakState();
    } catch (e) {
      debugPrint('[AttendanceProvider] Failed to load break state: $e');
    } finally {
      _isBreakLoading = false;
      if (notify) {
        notifyListeners();
      }
    }
  }

  Future<void> loadAttendance({
    DateTime? startDate,
    DateTime? endDate,
    bool forceRefresh = false,
  }) async {
    // Prevent double load calls
    if (_loadAttendanceInProgress) {
      debugPrint(
        '[AttendanceProvider] Load attendance already in progress, ignoring duplicate call',
      );
      return;
    }

    debugPrint(
      '[AttendanceProvider] Loading attendance... (forceRefresh: $forceRefresh)',
    );
    _loadAttendanceInProgress = true;

    // Load from local storage first (instant display)
    if (!forceRefresh) {
      final offlineData = await _offlineStorage.getAttendance();
      if (offlineData != null) {
        _attendanceData = AttendancePayload.fromJson(offlineData);
        _isOfflineMode = false;
        _error = null;
        _isLoading = false;
        notifyListeners();
        debugPrint(
          '[AttendanceProvider] ✓ Attendance loaded instantly from offline storage',
        );
      }
    }

    // Check connectivity
    final isConnected = _connectivityProvider?.isConnected ?? true;
    _isOfflineMode = !isConnected;

    // Set loading only if we don't have cached data
    if (_attendanceData == null || forceRefresh) {
      _isLoading = true;
      _error = null;
      notifyListeners();
    }

    try {
      if (isConnected) {
        // Try to load from API in background
        try {
          final freshData = await _attendanceService.getAttendance(
            startDate: startDate,
            endDate: endDate,
          );
          // Save to offline storage
          await _offlineStorage.saveAttendance({
            'today': freshData.today.map((e) => e.toJson()).toList(),
            'recent': freshData.recent.map((e) => e.toJson()).toList(),
          });
          _attendanceData = freshData;
          _error = null;
          _isOfflineMode = false;
          debugPrint('[AttendanceProvider] ✓ Attendance refreshed from API');
        } catch (e) {
          // If API fails, keep using cached data if available
          if (_attendanceData == null) {
            debugPrint(
              '[AttendanceProvider] ⚠ API failed, trying offline storage...',
            );
            final offlineData = await _offlineStorage.getAttendance();
            if (offlineData != null && offlineData.isNotEmpty) {
              _attendanceData = AttendancePayload.fromJson(offlineData);
              _isOfflineMode = true;
              _error = 'Mode offline - Data terakhir yang tersimpan';
              debugPrint(
                '[AttendanceProvider] ✓ Attendance loaded from offline storage',
              );
            } else {
              throw e;
            }
          } else {
            // Keep using cached data, just mark as offline
            _isOfflineMode = true;
            _error = 'Mode offline - Data terakhir yang tersimpan';
            debugPrint('[AttendanceProvider] ⚠ API failed, using cached data');
          }
        }
      } else {
        // Offline mode - use cached data if available
        if (_attendanceData == null) {
          final offlineData = await _offlineStorage.getAttendance();
          if (offlineData != null) {
            _attendanceData = AttendancePayload.fromJson(offlineData);
            _isOfflineMode = true;
            _error = 'Mode offline - Data terakhir yang tersimpan';
            debugPrint(
              '[AttendanceProvider] ✓ Attendance loaded from offline storage',
            );
          } else {
            throw Exception('Tidak ada data offline tersedia');
          }
        } else {
          _isOfflineMode = true;
          _error = 'Mode offline - Data terakhir yang tersimpan';
        }
      }

      if (todayAttendance != null) {
        debugPrint(
          '[AttendanceProvider] Active today: ${todayAttendance!.checkIn} - ${todayAttendance!.checkOut}',
        );

        // Restore persistent notification if check-in is active
        final today = todayAttendance!;
        if (today.checkIn != null && today.checkOut == null) {
          try {
            await PersistentNotificationService.showCheckInNotification(today);
            PersistentNotificationService.startPeriodicUpdates(today);
            debugPrint(
              '[AttendanceProvider] ??? Persistent notification restored for active check-in',
            );
          } catch (e) {
            debugPrint(
              '[AttendanceProvider] Failed to restore persistent notification: $e',
            );
          }
        }
      }
    } catch (e) {
      if (_attendanceData == null) {
        _error = ErrorHandler.getErrorMessage(e);
        _attendanceData = null;
        debugPrint('[AttendanceProvider] ✗ Error loading attendance: $_error');
      } else {
        // Keep cached data even if refresh fails
        debugPrint(
          '[AttendanceProvider] ⚠ Refresh failed, keeping cached data: $e',
        );
      }
    } finally {
      _isLoading = false;
      _loadAttendanceInProgress = false;

      await _enforceTrackingPolicy();

      // Only initialize tracking services if we don't have attendance data yet
      // This prevents double initialization on every loadAttendance call
      if (todayAttendance != null) {
        await loadBreakState(notify: false);
        await _ensureRealtimeTracking();
        await ensureBackgroundTracking();
      } else {
        _breakState = null;
        _isBreakLoading = false;
      }

      notifyListeners();
    }
  }

  double? _parseCoordinate(dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }

  // Setting lokasi jarang berubah, tapi dulu diambil 1-3x setiap loadAttendance
  // (enforce policy, realtime, background) -> ~18 ribu request/hari di prod.
  static const Duration _locationSettingsTtl = Duration(minutes: 5);
  Map<String, dynamic>? _locationSettingsCache;
  String? _locationSettingsCacheUserId;
  DateTime? _locationSettingsCachedAt;
  Future<Map<String, dynamic>>? _locationSettingsInFlight;

  Future<Map<String, dynamic>> getLocationSettings({
    bool forceRefresh = false,
  }) async {
    final userId = (await _authService.getCachedUserOnly())?.id;
    final cachedAt = _locationSettingsCachedAt;
    if (!forceRefresh &&
        _locationSettingsCache != null &&
        cachedAt != null &&
        _locationSettingsCacheUserId == userId &&
        DateTime.now().difference(cachedAt) < _locationSettingsTtl) {
      return _locationSettingsCache!;
    }

    final inFlight = _locationSettingsInFlight;
    if (inFlight != null) return inFlight;

    final request = _attendanceService.getLocationSettings();
    _locationSettingsInFlight = request;
    try {
      final result = await request;
      if (result['isFallback'] == true &&
          _locationSettingsCache != null &&
          _locationSettingsCacheUserId == userId) {
        // Tanpa sinyal: pakai pengaturan terakhir yang berhasil dimuat
        return _locationSettingsCache!;
      }
      // Cache hanya respons sukses: bukan fallback klien, bukan respons error server.
      if (result['isFallback'] != true &&
          result['message'] == null &&
          result['data'] is Map) {
        _locationSettingsCache = result;
        _locationSettingsCacheUserId = userId;
        _locationSettingsCachedAt = DateTime.now();
      }
      return result;
    } finally {
      _locationSettingsInFlight = null;
    }
  }

  Future<Map<String, dynamic>> _getEffectiveTrackingSettings({
    bool forceRefresh = false,
  }) async {
    int intervalSeconds = TrackingStateService.defaultIntervalSeconds;
    bool isEnabled = false;
    bool isKnown = false;

    try {
      final locationSettings = await getLocationSettings(
        forceRefresh: forceRefresh,
      );
      final settingsData = locationSettings['data'];
      isKnown = locationSettings['isFallback'] != true &&
          locationSettings['message'] == null &&
          settingsData is Map;
      if (settingsData is Map) {
        final intervalRaw = settingsData['intervalSeconds'];
        final enabledRaw = settingsData['isEnabled'];

        if (intervalRaw is num && intervalRaw > 0) {
          intervalSeconds = intervalRaw.toInt();
        }
        if (enabledRaw is bool) {
          isEnabled = enabledRaw;
        }
      }
    } catch (e) {
      debugPrint(
        '[AttendanceProvider] Failed to load effective tracking settings: $e',
      );
    }

    final shouldNotify =
        _trackingEnabledByPolicy != isEnabled ||
        _trackingIntervalSeconds != intervalSeconds;
    _trackingEnabledByPolicy = isEnabled;
    _trackingIntervalSeconds = intervalSeconds;
    if (shouldNotify) {
      notifyListeners();
    }

    return {
      'intervalSeconds': intervalSeconds,
      'isEnabled': isEnabled,
      'isKnown': isKnown,
    };
  }

  Future<bool> checkIn({
    required File photo,
    String? shiftId,
    double? latitude,
    double? longitude,
    String? checkInReason,
  }) async {
    // Prevent double check-in calls
    if (_checkInInProgress) {
      debugPrint(
        '[AttendanceProvider] Check-in already in progress, ignoring duplicate call',
      );
      return false;
    }

    debugPrint('[AttendanceProvider] Check-in initiated');
    debugPrint(
      '[AttendanceProvider] Shift ID: ${shiftId ?? "null (no shift)"}',
    );
    _isLoading = true;
    _error = null;
    _checkInInProgress = true;
    notifyListeners();

    final isConnected = _connectivityProvider?.isConnected ?? true;
    User? sessionUser;
    double? resolvedLatitude = latitude;
    double? resolvedLongitude = longitude;

    try {
      if (resolvedLatitude == null || resolvedLongitude == null) {
        final location = await _attendanceService.getRequiredLocation(
          actionLabel: 'check-in',
        );
        resolvedLatitude = location['latitude'];
        resolvedLongitude = location['longitude'];
      }

      if (resolvedLatitude == null || resolvedLongitude == null) {
        throw Exception('GPS wajib aktif untuk check-in.');
      }

      if (isConnected) {
        // Try to check-in online
        try {
          try {
            sessionUser = await _authService.getCurrentUser();
          } catch (_) {
            sessionUser = null;
          }

          final result = await _attendanceService.checkIn(
            photo: photo,
            shiftId: shiftId, // Opsional - bisa null
            latitude: resolvedLatitude,
            longitude: resolvedLongitude,
            site: sessionUser?.site,
            checkInReason: checkInReason,
          );

          if (result['success'] == true) {
            debugPrint(
              '[AttendanceProvider] ✓ Check-in successful, reloading attendance...',
            );

            // Load attendance dengan forceRefresh untuk mendapatkan data terbaru
            final now = DateTime.now();
            final responseData = result['data'];
            String? responseAttendanceId;
            DateTime? responseCheckInDate;
            if (responseData is Map) {
              final rawId = responseData['id'];
              if (rawId is String && rawId.isNotEmpty) {
                responseAttendanceId = rawId;
              }
              final rawDate = responseData['date'];
              if (rawDate is String && rawDate.isNotEmpty) {
                try {
                  responseCheckInDate = DateTime.parse(rawDate);
                } catch (_) {}
              }
            }
            bool trackingStarted = false;
            bool checkInTrackingEnabled = false;
            int checkInIntervalSeconds =
                TrackingStateService.defaultIntervalSeconds;
            final startDate = DateTime(now.year, now.month, 1);
            await loadAttendance(
              startDate: startDate,
              endDate: now,
              forceRefresh: true,
            );

            // Start realtime location tracking setelah check-in berhasil
            final user = sessionUser ?? await _authService.getCurrentUser();
            debugPrint(
              '[AttendanceProvider] Current user: ${user?.name} (${user?.id})',
            );

            try {
              debugPrint(
                '[AttendanceProvider] Starting realtime location tracking...',
              );

              // Saat check-in selalu ambil setting terbaru dari server.
              final trackingSettings = await _getEffectiveTrackingSettings(
                forceRefresh: true,
              );
              final intervalSeconds =
                  trackingSettings['intervalSeconds'] as int? ??
                  TrackingStateService.defaultIntervalSeconds;
              final isEnabled = trackingSettings['isEnabled'] as bool? ?? false;
              checkInTrackingEnabled = isEnabled;
              checkInIntervalSeconds = intervalSeconds;

              debugPrint(
                '[AttendanceProvider] Effective tracking settings: interval=$intervalSeconds, enabled=$isEnabled',
              );

              if (!isEnabled) {
                debugPrint(
                  '[AttendanceProvider] Realtime tracking disabled by site/global settings',
                );
                await _realtimeService.stopRealtimeTracking();
              } else {
                if (user != null && responseAttendanceId != null) {
                  debugPrint(
                    '[AttendanceProvider] Using attendance ID from response: $responseAttendanceId',
                  );

                  try {
                    await _realtimeService.startRealtimeTracking(
                      user: user,
                      attendanceId: responseAttendanceId,
                      checkInDate: responseCheckInDate ?? now,
                      intervalSeconds: intervalSeconds,
                    );
                    debugPrint(
                      '[AttendanceProvider] Realtime tracking started with interval: $intervalSeconds seconds',
                    );
                    trackingStarted = true;
                    debugPrint(
                      '[AttendanceProvider] Realtime tracking started (response record)',
                    );
                  } catch (e) {
                    debugPrint(
                      '[AttendanceProvider] Failed to start realtime tracking: $e',
                    );

                    if (e.toString().contains('izin') ||
                        e.toString().contains('permission')) {
                      debugPrint(
                        '[AttendanceProvider] Permission error detected',
                      );
                      rethrow;
                    }
                  }
                }

                if (!trackingStarted) {
                  await Future.delayed(const Duration(milliseconds: 500));

                  final todayRecord = todayAttendance;
                  debugPrint(
                    '[AttendanceProvider] Today attendance: ${todayRecord?.checkIn} - ${todayRecord?.checkOut}, ID: ${todayRecord?.id}',
                  );

                  if (user != null && todayRecord != null) {
                    debugPrint(
                      '[AttendanceProvider] User and attendance record available',
                    );

                    final attendanceId = todayRecord.id.isNotEmpty
                        ? todayRecord.id
                        : 'temp-${user.id}-${now.millisecondsSinceEpoch}';
                    debugPrint(
                      '[AttendanceProvider] Using attendance ID: $attendanceId',
                    );

                    await _realtimeService.startRealtimeTracking(
                      user: user,
                      attendanceId: attendanceId,
                      checkInDate: now,
                      intervalSeconds: intervalSeconds,
                    );
                    debugPrint(
                      '[AttendanceProvider] Realtime tracking started successfully',
                    );
                  } else {
                    debugPrint(
                      '[AttendanceProvider] Cannot start tracking: user=${user != null}, todayRecord=${todayRecord != null}',
                    );
                  }
                }
              }
            } catch (e) {
              debugPrint(
                '[AttendanceProvider] Failed to start realtime tracking: $e',
              );
              debugPrint('[AttendanceProvider] Stack trace: ${e.toString()}');
            }

            // Pastikan background tracking service juga running. Pakai ID absen dari respons
            // check-in, tidak menunggu muat ulang data absen (yang bisa gagal atau tertahan).
            try {
              if (checkInTrackingEnabled &&
                  user != null &&
                  responseAttendanceId != null) {
                await _runBackgroundTracking(
                  userId: user.id,
                  attendanceId: responseAttendanceId,
                  checkInDate: responseCheckInDate ?? now,
                  intervalSeconds: checkInIntervalSeconds,
                );
              } else {
                await ensureBackgroundTracking();
              }
            } catch (e) {
              debugPrint(
                '[AttendanceProvider] Failed to ensure background tracking after check-in: $e',
              );
            }

            // Show persistent notification for active check-in
            try {
              if (todayAttendance != null) {
                await PersistentNotificationService.showCheckInNotification(
                  todayAttendance!,
                );
                PersistentNotificationService.startPeriodicUpdates(
                  todayAttendance!,
                );
              }
            } catch (e) {
              debugPrint(
                '[AttendanceProvider] Failed to show persistent notification: $e',
              );
            }

            return true;
          } else {
            _error = result['message'] as String? ?? 'Check-in gagal';
            debugPrint('[AttendanceProvider] ✗ Check-in failed: $_error');
            return false;
          }
        } catch (e) {
          // Check if it's a memory-related error
          final errorStr = e.toString().toLowerCase();
          if (errorStr.contains('memory') ||
              errorStr.contains('outofmemory') ||
              errorStr.contains('terlalu besar') ||
              errorStr.contains('timeout')) {
            // Don't save to pending for memory/timeout errors - user needs to retry with smaller photo
            _error = ErrorHandler.getErrorMessage(e);
            debugPrint(
              '[AttendanceProvider] ✗ Check-in failed due to memory/timeout: $_error',
            );
            return false;
          }

          // If online check-in fails for other reasons, save to pending
          debugPrint(
            '[AttendanceProvider] ⚠ Online check-in failed, saving to pending...',
          );
          try {
            final pendingDate = _normalizeDate(
              DateTime.now().toIso8601String(),
            );
            final clientKey = _buildClientKey('checkin', shiftId, pendingDate);
            final alreadySaved = await _hasAttendanceFor(
              type: 'checkin',
              date: pendingDate,
              shiftId: shiftId,
            );
            if (alreadySaved) {
              _error = 'Check-in sudah tercatat, tidak perlu disinkronkan lagi';
              debugPrint(
                '[AttendanceProvider] Duplicate check-in detected, skipping pending save',
              );
              return false;
            }
            await _offlineStorage.savePendingCheckIn({
              'photo': photo.path,
              'shiftId': shiftId,
              'latitude': resolvedLatitude,
              'longitude': resolvedLongitude,
              'date': pendingDate,
              'checkInReason': checkInReason,
              'clientKey': clientKey,
            });
            _error = 'Check-in disimpan untuk sync nanti';
            debugPrint('[AttendanceProvider] ✓ Check-in saved to pending');
            return true;
          } catch (saveError) {
            debugPrint(
              '[AttendanceProvider] ✗ Failed to save to pending: $saveError',
            );
            _error = ErrorHandler.getErrorMessage(e);
            return false;
          }
        }
      } else {
        // Save to pending for offline mode
        debugPrint(
          '[AttendanceProvider] ⚠ Offline mode, saving check-in to pending...',
        );
        final pendingDate = _normalizeDate(DateTime.now().toIso8601String());
        final clientKey = _buildClientKey('checkin', shiftId, pendingDate);
        final alreadySaved = await _hasAttendanceFor(
          type: 'checkin',
          date: pendingDate,
          shiftId: shiftId,
        );
        if (alreadySaved) {
          _error = 'Check-in sudah tercatat, tidak perlu disimpan ulang';
          debugPrint(
            '[AttendanceProvider] Duplicate check-in detected, skipping pending save',
          );
          return false;
        }
        await _offlineStorage.savePendingCheckIn({
          'photo': photo.path,
          'shiftId': shiftId,
          'latitude': resolvedLatitude,
          'longitude': resolvedLongitude,
          'date': pendingDate,
          'checkInReason': checkInReason,
          'clientKey': clientKey,
        });
        _error = 'Mode offline - Check-in akan disinkronkan saat online';
        debugPrint('[AttendanceProvider] ✓ Check-in saved to pending');
        return true;
      }
    } catch (e) {
      _error = ErrorHandler.getErrorMessage(e);
      debugPrint('[AttendanceProvider] ✗ Check-in exception: $e');
      debugPrint('[AttendanceProvider] User-friendly error: $_error');
      return false;
    } finally {
      _isLoading = false;
      _checkInInProgress = false;
      notifyListeners();
    }
  }

  bool _qrAttendanceEnabled = false;

  /// QR absen tersedia di site karyawan (supervisor sudah memasang layar absen).
  bool get qrAttendanceEnabled => _qrAttendanceEnabled;

  Future<void> loadQrAttendanceFlag() async {
    final enabled = await _attendanceService.isQrAttendanceEnabled();
    if (enabled != _qrAttendanceEnabled) {
      _qrAttendanceEnabled = enabled;
      notifyListeners();
    }
  }

  /// Absen dengan QR dari layar absen: ambil GPS, kirim isi QR, lalu muat ulang absen hari ini.
  /// Tidak disimpan offline: QR hanya berlaku sekitar satu menit, jadi antrean offline pasti ditolak.
  Future<Map<String, dynamic>> submitQrAttendance({
    required bool checkOut,
    required String qrData,
  }) async {
    if (_checkInInProgress || _checkOutInProgress) {
      return {'success': false, 'message': 'Absen sedang diproses. Tunggu sebentar.'};
    }
    if (checkOut) {
      _checkOutInProgress = true;
    } else {
      _checkInInProgress = true;
    }
    _error = null;
    notifyListeners();
    try {
      final location = await _attendanceService.getRequiredLocation(
        actionLabel: checkOut ? 'check-out' : 'check-in',
      );
      final result = await _attendanceService.submitQrAttendance(
        checkOut: checkOut,
        qrData: qrData,
        latitude: location['latitude']!,
        longitude: location['longitude']!,
        shiftId: checkOut ? todayAttendance?.shiftId : null,
      );
      if (result['success'] != true) return result;

      if (checkOut) {
        await _stopTrackingForQueuedCheckout();
      }
      final now = DateTime.now();
      await loadAttendance(
        startDate: DateTime(now.year, now.month, 1),
        endDate: now,
        forceRefresh: true,
      );
      if (!checkOut) {
        try {
          await ensureBackgroundTracking();
          if (todayAttendance != null) {
            await PersistentNotificationService.showCheckInNotification(todayAttendance!);
            PersistentNotificationService.startPeriodicUpdates(todayAttendance!);
          }
        } catch (e) {
          debugPrint('[AttendanceProvider] Tracking setelah check-in QR gagal: $e');
        }
      }
      return result;
    } catch (e) {
      return {'success': false, 'message': ErrorHandler.getErrorMessage(e)};
    } finally {
      _checkInInProgress = false;
      _checkOutInProgress = false;
      notifyListeners();
    }
  }

  Future<bool> checkOut({
    required File photo,
    String? shiftId,
    double? latitude,
    double? longitude,
    String? earlyCheckoutReason,
  }) async {
    // Prevent double check-out calls
    if (_checkOutInProgress) {
      debugPrint(
        '[AttendanceProvider] Check-out already in progress, ignoring duplicate call',
      );
      return false;
    }

    debugPrint('[AttendanceProvider] Check-out initiated');
    final resolvedShiftId = shiftId ?? todayAttendance?.shiftId;
    _isLoading = true;
    _error = null;
    _checkOutInProgress = true;
    notifyListeners();

    final isConnected = _connectivityProvider?.isConnected ?? true;
    double? resolvedLatitude = latitude;
    double? resolvedLongitude = longitude;

    try {
      if (resolvedLatitude == null || resolvedLongitude == null) {
        final location = await _attendanceService.getRequiredLocation(
          actionLabel: 'check-out',
        );
        resolvedLatitude = location['latitude'];
        resolvedLongitude = location['longitude'];
      }

      if (resolvedLatitude == null || resolvedLongitude == null) {
        throw Exception('GPS wajib aktif untuk check-out.');
      }

      if (isConnected) {
        // Try to check-out online
        try {
          User? sessionUser;
          try {
            sessionUser = await _authService.getCurrentUser();
          } catch (_) {
            sessionUser = null;
          }

          final result = await _attendanceService.checkOut(
            photo: photo,
            shiftId: resolvedShiftId,
            latitude: resolvedLatitude,
            longitude: resolvedLongitude,
            site: sessionUser?.site,
            earlyCheckoutReason: earlyCheckoutReason,
          );

          if (result['success'] == true) {
            debugPrint(
              '[AttendanceProvider] ✓ Check-out successful, reloading attendance...',
            );
            // Reset loading sebelum loadAttendance untuk menghindari loading state yang stuck
            _isLoading = false;
            notifyListeners();

            // Stop realtime location tracking setelah check-out berhasil
            try {
              debugPrint(
                '[AttendanceProvider] Stopping realtime location tracking...',
              );
              await _realtimeService.stopRealtimeTracking();
              debugPrint('[AttendanceProvider] ✓ Realtime tracking stopped');
            } catch (e) {
              debugPrint(
                '[AttendanceProvider] Failed to stop realtime tracking: $e',
              );
              // Don't fail check-out just because tracking stop failed
            }

            // Rute berhenti tepat saat check-out, termasuk layanan latar belakang. Sesi ditandai
            // selesai supaya muat ulang yang gagal (cache lama) tidak menyalakannya lagi.
            try {
              final endedId = todayAttendance?.id;
              if (endedId != null && endedId.isNotEmpty) {
                await TrackingStateService.markAttendanceEnded(endedId);
              }
              await TrackingStateService.clearTrackingState();
              await BackgroundTrackingService.stop();
            } catch (e) {
              debugPrint(
                '[AttendanceProvider] Failed to stop background tracking after check-out: $e',
              );
            }

            // Hide persistent notification after successful check-out
            try {
              await PersistentNotificationService.hideCheckInNotification();
              PersistentNotificationService.stopPeriodicUpdates();
              debugPrint(
                '[AttendanceProvider] ✓ Persistent notification hidden',
              );
            } catch (e) {
              debugPrint(
                '[AttendanceProvider] Failed to hide persistent notification: $e',
              );
            }

            // Reset initialization flags for next check-in
            _realtimeTrackingInitialized = false;

            // Load attendance dengan forceRefresh untuk mendapatkan data terbaru
            final now = DateTime.now();
            final startDate = DateTime(now.year, now.month, 1);
            await loadAttendance(
              startDate: startDate,
              endDate: now,
              forceRefresh: true,
            );

            // Trigger rating popup (hanya sekali, di checkout pertama)
            _onCheckoutSuccessCallback?.call();

            return true;
          } else {
            _error = result['message'] as String? ?? 'Check-out gagal';
            debugPrint('[AttendanceProvider] ✗ Check-out failed: $_error');
            return false;
          }
        } catch (e) {
          // Check if it's a memory-related error
          final errorStr = e.toString().toLowerCase();
          if (errorStr.contains('memory') ||
              errorStr.contains('outofmemory') ||
              errorStr.contains('terlalu besar') ||
              errorStr.contains('timeout')) {
            // Don't save to pending for memory/timeout errors - user needs to retry with smaller photo
            _error = ErrorHandler.getErrorMessage(e);
            debugPrint(
              '[AttendanceProvider] ✗ Check-out failed due to memory/timeout: $_error',
            );
            return false;
          }

          // If online check-out fails for other reasons, save to pending
          debugPrint(
            '[AttendanceProvider] ⚠ Online check-out failed, saving to pending...',
          );
          try {
            final pendingDate = _normalizeDate(
              todayAttendance?.date ?? DateTime.now().toIso8601String(),
            );
            final clientKey = _buildClientKey(
              'checkout',
              resolvedShiftId,
              pendingDate,
            );
            final alreadySaved = await _hasAttendanceFor(
              type: 'checkout',
              date: pendingDate,
              shiftId: resolvedShiftId,
            );
            if (alreadySaved) {
              _error =
                  'Check-out sudah tercatat, tidak perlu disinkronkan lagi';
              debugPrint(
                '[AttendanceProvider] Duplicate check-out detected, skipping pending save',
              );
              return false;
            }
            await _offlineStorage.savePendingCheckOut({
              'photo': photo.path,
              'shiftId': resolvedShiftId,
              'latitude': resolvedLatitude,
              'longitude': resolvedLongitude,
              'date': pendingDate,
              'clientKey': clientKey,
              if (earlyCheckoutReason != null)
                'earlyCheckoutReason': earlyCheckoutReason,
            });
            _error = 'Check-out disimpan untuk sync nanti';
            debugPrint('[AttendanceProvider] ✓ Check-out saved to pending');
            await _stopTrackingForQueuedCheckout();
            return true;
          } catch (saveError) {
            debugPrint(
              '[AttendanceProvider] ✗ Failed to save to pending: $saveError',
            );
            _error = ErrorHandler.getErrorMessage(e);
            return false;
          }
        }
      } else {
        // Save to pending for offline mode
        debugPrint(
          '[AttendanceProvider] ⚠ Offline mode, saving check-out to pending...',
        );
        final pendingDate = _normalizeDate(
          todayAttendance?.date ?? DateTime.now().toIso8601String(),
        );
        final clientKey = _buildClientKey(
          'checkout',
          resolvedShiftId,
          pendingDate,
        );
        final alreadySaved = await _hasAttendanceFor(
          type: 'checkout',
          date: pendingDate,
          shiftId: resolvedShiftId,
        );
        if (alreadySaved) {
          _error = 'Check-out sudah tercatat, tidak perlu disimpan ulang';
          debugPrint(
            '[AttendanceProvider] Duplicate check-out detected, skipping pending save',
          );
          return false;
        }
        await _offlineStorage.savePendingCheckOut({
          'photo': photo.path,
          'shiftId': resolvedShiftId,
          'latitude': resolvedLatitude,
          'longitude': resolvedLongitude,
          'date': pendingDate,
          'clientKey': clientKey,
          if (earlyCheckoutReason != null)
            'earlyCheckoutReason': earlyCheckoutReason,
        });
        _error = 'Mode offline - Check-out akan disinkronkan saat online';
        debugPrint('[AttendanceProvider] ✓ Check-out saved to pending');
        await _stopTrackingForQueuedCheckout();
        return true;
      }
    } catch (e) {
      _error = ErrorHandler.getErrorMessage(e);
      debugPrint('[AttendanceProvider] ✗ Check-out exception: $e');
      debugPrint('[AttendanceProvider] User-friendly error: $_error');
      return false;
    } finally {
      _isLoading = false;
      _checkOutInProgress = false;
      notifyListeners();
    }
  }

  Future<Map<String, dynamic>> startBreak() async {
    if (_breakActionInProgress) {
      return {
        'success': false,
        'message': 'Permintaan istirahat sedang diproses',
      };
    }

    final isConnected = _connectivityProvider?.isConnected ?? true;
    if (!isConnected) {
      return {
        'success': false,
        'message': 'Mulai istirahat hanya bisa dilakukan saat online',
      };
    }

    _error = null;
    _breakActionInProgress = true;
    notifyListeners();

    try {
      final result = await _attendanceService.startAttendanceBreak();
      if (result['success'] == true) {
        final now = DateTime.now();
        final startDate = DateTime(now.year, now.month, 1);
        await loadAttendance(
          startDate: startDate,
          endDate: now,
          forceRefresh: true,
        );
      } else {
        _error = result['message'] as String?;
      }
      return result;
    } catch (e) {
      _error = ErrorHandler.getErrorMessage(e);
      return {'success': false, 'message': _error};
    } finally {
      _breakActionInProgress = false;
      notifyListeners();
    }
  }

  Future<Map<String, dynamic>> endBreak({String? reason}) async {
    if (_breakActionInProgress) {
      return {
        'success': false,
        'message': 'Permintaan istirahat sedang diproses',
      };
    }

    final isConnected = _connectivityProvider?.isConnected ?? true;
    if (!isConnected) {
      return {
        'success': false,
        'message': 'Selesai istirahat hanya bisa dilakukan saat online',
      };
    }

    _error = null;
    _breakActionInProgress = true;
    notifyListeners();

    try {
      final result = await _attendanceService.endAttendanceBreak(
        reason: reason,
      );
      if (result['success'] == true) {
        final now = DateTime.now();
        final startDate = DateTime(now.year, now.month, 1);
        await loadAttendance(
          startDate: startDate,
          endDate: now,
          forceRefresh: true,
        );
      } else {
        _error = result['message'] as String?;
      }
      return result;
    } catch (e) {
      _error = ErrorHandler.getErrorMessage(e);
      return {'success': false, 'message': _error};
    } finally {
      _breakActionInProgress = false;
      notifyListeners();
    }
  }

  Future<void> syncPendingAttendance() async {
    if (_syncPendingInProgress) {
      return;
    }

    final isConnected = _connectivityProvider?.isConnected ?? true;
    if (!isConnected) {
      return;
    }

    _syncPendingInProgress = true;
    try {
      final checkInSynced = await _syncPendingCheckIns();
      final checkOutSynced = await _syncPendingCheckOuts();
      try {
        await _realtimeService.syncPendingLocationLogs();
      } catch (e) {
        debugPrint(
          '[AttendanceProvider] syncPendingLocationLogs async not available: $e',
        );
      }
      if (checkInSynced || checkOutSynced) {
        final now = DateTime.now();
        final startDate = DateTime(now.year, now.month, 1);
        await loadAttendance(
          startDate: startDate,
          endDate: now,
          forceRefresh: true,
        );
      }
    } finally {
      _syncPendingInProgress = false;
    }
  }

  Future<bool> _syncPendingCheckIns() async {
    final pending = await _offlineStorage.getPendingCheckIns();
    if (pending.isEmpty) {
      return false;
    }

    User? sessionUser;
    try {
      sessionUser = await _authService.getCurrentUser();
    } catch (_) {
      sessionUser = null;
    }

    var synced = false;
    for (int i = pending.length - 1; i >= 0; i--) {
      final item = pending[i];
      final pendingDate = _normalizeDate(
        item['date']?.toString() ?? item['timestamp']?.toString(),
      );
      final photoPath = item['photo']?.toString();
      if (photoPath == null || photoPath.isEmpty) {
        await _offlineStorage.removePendingCheckIn(i);
        continue;
      }

      final file = File(photoPath);
      if (!await file.exists()) {
        await _offlineStorage.removePendingCheckIn(i);
        continue;
      }

      final shiftId = item['shiftId']?.toString();
      final checkInReason = item['checkInReason']?.toString();
      final alreadySynced = await _hasAttendanceFor(
        type: 'checkin',
        date: pendingDate,
        shiftId: shiftId,
      );
      if (alreadySynced) {
        await _offlineStorage.removePendingCheckIn(i);
        continue;
      }
      final latitude = _parseCoordinate(item['latitude']);
      final longitude = _parseCoordinate(item['longitude']);
      final result = await _attendanceService.checkIn(
        photo: file,
        shiftId: shiftId,
        latitude: latitude,
        longitude: longitude,
        site: sessionUser?.site,
        checkInReason: checkInReason,
      );

      if (result['success'] == true) {
        await _offlineStorage.removePendingCheckIn(i);
        synced = true;
      } else {
        final message = (result['message'] ?? '').toString().toLowerCase();
        if (message.contains('sudah check-in') || message.contains('already')) {
          await _offlineStorage.removePendingCheckIn(i);
        }
      }
    }

    return synced;
  }

  Future<bool> _syncPendingCheckOuts() async {
    final pending = await _offlineStorage.getPendingCheckOuts();
    if (pending.isEmpty) {
      return false;
    }

    User? sessionUser;
    try {
      sessionUser = await _authService.getCurrentUser();
    } catch (_) {
      sessionUser = null;
    }

    var synced = false;
    for (int i = pending.length - 1; i >= 0; i--) {
      final item = pending[i];
      final pendingDate = _normalizeDate(
        item['date']?.toString() ?? item['timestamp']?.toString(),
      );
      final photoPath = item['photo']?.toString();
      if (photoPath == null || photoPath.isEmpty) {
        await _offlineStorage.removePendingCheckOut(i);
        continue;
      }

      final file = File(photoPath);
      if (!await file.exists()) {
        await _offlineStorage.removePendingCheckOut(i);
        continue;
      }

      final latitude = _parseCoordinate(item['latitude']);
      final longitude = _parseCoordinate(item['longitude']);
      final shiftId = item['shiftId']?.toString();
      final earlyCheckoutReason = item['earlyCheckoutReason']?.toString();
      final alreadySynced = await _hasAttendanceFor(
        type: 'checkout',
        date: pendingDate,
        shiftId: shiftId,
      );
      if (alreadySynced) {
        await _offlineStorage.removePendingCheckOut(i);
        continue;
      }
      final result = await _attendanceService.checkOut(
        photo: file,
        shiftId: shiftId,
        latitude: latitude,
        longitude: longitude,
        site: sessionUser?.site,
        earlyCheckoutReason: earlyCheckoutReason,
      );

      if (result['success'] == true) {
        await _offlineStorage.removePendingCheckOut(i);
        synced = true;
      } else {
        final message = (result['message'] ?? '').toString().toLowerCase();
        if (message.contains('sudah check-out') ||
            message.contains('already')) {
          await _offlineStorage.removePendingCheckOut(i);
        }
      }
    }

    return synced;
  }

  Future<bool> pauseRealtimeTracking() async {
    if (!_realtimeService.isTracking) {
      return false;
    }
    try {
      await _realtimeService.stopRealtimeTracking();
      return true;
    } catch (e) {
      debugPrint('[AttendanceProvider] Failed to pause tracking: $e');
      return false;
    }
  }

  Future<void> testLocationTracking() async {
    debugPrint('[AttendanceProvider] 🧪 Testing location tracking manually...');

    try {
      // Force restart tracking
      await _realtimeService.stopRealtimeTracking();
      await Future.delayed(Duration(seconds: 1));

      final user = await _authService.getCurrentUser();
      if (user != null && todayAttendance != null) {
        final today = todayAttendance!;
        if (today.checkIn != null && today.checkOut == null) {
          debugPrint(
            '[AttendanceProvider] 🔄 Force restarting location tracking...',
          );
          final trackingSettings = await _getEffectiveTrackingSettings();
          final intervalSeconds =
              trackingSettings['intervalSeconds'] as int? ??
              TrackingStateService.defaultIntervalSeconds;
          final isEnabled = trackingSettings['isEnabled'] as bool? ?? false;

          if (!isEnabled) {
            debugPrint(
              '[AttendanceProvider] Tracking disabled by site/global settings, test skipped',
            );
            return;
          }

          await _realtimeService.startRealtimeTracking(
            user: user,
            attendanceId: today.id,
            checkInDate: DateTime.parse(today.checkIn!),
            intervalSeconds: intervalSeconds,
          ); // Use server setting
          debugPrint(
            '[AttendanceProvider] ✅ Location tracking restarted for testing',
          );
        } else {
          debugPrint(
            '[AttendanceProvider] ❌ No active check-in found for testing',
          );
        }
      } else {
        debugPrint(
          '[AttendanceProvider] ❌ No user or attendance data for testing',
        );
      }
    } catch (e) {
      debugPrint('[AttendanceProvider] ❌ Failed to test location tracking: $e');
    }
  }

  Future<void> syncRealtimeTracking() async {
    if (_realtimeService.isTracking) {
      return;
    }

    final today = todayAttendance;
    if (today == null || today.checkIn == null || today.checkOut != null) {
      return;
    }

    if (await _isEndedAttendance(today.id)) {
      return;
    }

    final user = await _authService.getCurrentUser();
    if (user == null) {
      return;
    }

    DateTime checkInDate;
    try {
      checkInDate = DateTime.parse(today.date);
    } catch (_) {
      checkInDate = DateTime.now();
    }

    final trackingSettings = await _getEffectiveTrackingSettings();
    final intervalSeconds = trackingSettings['intervalSeconds'] as int? ??
        TrackingStateService.defaultIntervalSeconds;
    final isEnabled = trackingSettings['isEnabled'] as bool? ?? false;

    if (!isEnabled) {
      try {
        await _realtimeService.stopRealtimeTracking();
      } catch (_) {}
      debugPrint(
        '[AttendanceProvider] Tracking disabled by site/global settings, skip resume',
      );
      return;
    }

    final attendanceId = today.id.isNotEmpty
        ? today.id
        : 'temp-${user.id}-${DateTime.now().millisecondsSinceEpoch}';

    try {
      await _realtimeService.startRealtimeTracking(
        user: user,
        attendanceId: attendanceId,
        checkInDate: checkInDate,
        intervalSeconds: intervalSeconds,
      );
    } catch (e) {
      debugPrint('[AttendanceProvider] Failed to resume tracking: $e');
    }
  }

  /// Pastikan background service tetap running untuk location tracking.
  /// Layanan ini yang mengirim titik rute tiap interval selama check-in, juga saat
  /// aplikasi ditutup, dan berhenti sendiri kalau state dihapus (check-out/logout).
  Future<void> ensureBackgroundTracking() async {
    final today = todayAttendance;
    if (today == null || today.checkIn == null || today.checkOut != null) {
      debugPrint(
        '[AttendanceProvider] No active attendance, skipping background tracking',
      );
      return;
    }

    // Check-in offline yang belum tersinkron belum punya ID dari server
    if (today.id.isEmpty || today.id.startsWith('temp-')) {
      debugPrint(
        '[AttendanceProvider] Background tracking waits for synced attendance id',
      );
      return;
    }

    if (await _isEndedAttendance(today.id)) {
      debugPrint(
        '[AttendanceProvider] Background tracking skipped: session already ended',
      );
      return;
    }

    final trackingSettings = await _getEffectiveTrackingSettings();
    final isEnabled = trackingSettings['isEnabled'] as bool? ?? false;
    final isKnown = trackingSettings['isKnown'] as bool? ?? false;
    final intervalSeconds = trackingSettings['intervalSeconds'] as int? ??
        TrackingStateService.defaultIntervalSeconds;
    if (!isKnown) {
      // Tanpa sinyal: layanan yang sudah jalan tetap melacak dengan state terakhir
      return;
    }
    if (!isEnabled) {
      debugPrint(
        '[AttendanceProvider] Background tracking skipped: disabled by site/global settings',
      );
      return;
    }

    User? user;
    try {
      user = await _authService.getCurrentUser();
    } catch (_) {
      user = null;
    }
    if (user == null) {
      debugPrint('[AttendanceProvider] Background tracking skipped: user null');
      return;
    }

    await _runBackgroundTracking(
      userId: user.id,
      attendanceId: today.id,
      checkInDate: DateTime.tryParse(today.date) ?? DateTime.now(),
      intervalSeconds: intervalSeconds,
    );
  }

  /// Simpan state yang dibaca layanan latar belakang lalu pastikan layanannya berjalan.
  Future<void> _runBackgroundTracking({
    required String userId,
    required String attendanceId,
    required DateTime checkInDate,
    required int intervalSeconds,
  }) async {
    try {
      final existing = await TrackingStateService.getTrackingState();
      if (existing == null ||
          existing.userId != userId ||
          existing.attendanceId != attendanceId ||
          existing.intervalSeconds != intervalSeconds) {
        await TrackingStateService.saveTrackingState(
          TrackingState(
            userId: userId,
            attendanceId: attendanceId,
            checkInDate: checkInDate,
            intervalSeconds: intervalSeconds,
          ),
        );
      }
      await BackgroundTrackingService.ensureRunning();
      debugPrint(
        '[AttendanceProvider] Background tracking running (interval ${intervalSeconds}s)',
      );
    } catch (e) {
      debugPrint(
        '[AttendanceProvider] Failed to ensure background tracking: $e',
      );
    }
  }

  Future<bool> _isEndedAttendance(String attendanceId) async {
    try {
      return await TrackingStateService.getEndedAttendanceId() == attendanceId;
    } catch (_) {
      return false;
    }
  }

  /// Check-out yang masih antre (offline) tetap berarti karyawan sudah pulang:
  /// hentikan rute sekarang juga, jangan menunggu check-out tersinkron.
  Future<void> _stopTrackingForQueuedCheckout() async {
    final endedId = todayAttendance?.id;
    try {
      if (endedId != null && endedId.isNotEmpty) {
        await TrackingStateService.markAttendanceEnded(endedId);
      }
      await _realtimeService.stopRealtimeTracking();
      await TrackingStateService.clearTrackingState();
      await BackgroundTrackingService.stop();
      _realtimeTrackingInitialized = false;
    } catch (e) {
      debugPrint(
        '[AttendanceProvider] Failed to stop tracking after queued check-out: $e',
      );
    }
    try {
      await PersistentNotificationService.hideCheckInNotification();
      PersistentNotificationService.stopPeriodicUpdates();
    } catch (_) {}
  }
}
