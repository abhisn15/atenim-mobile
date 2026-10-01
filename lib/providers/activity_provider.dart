import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'dart:io';
import 'package:geolocator/geolocator.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../models/activity_model.dart';
import '../services/activity_service.dart';
import '../services/offline_storage_service.dart';
import '../services/auth_service.dart';
import '../utils/error_handler.dart';
import 'connectivity_provider.dart';

class ActivityProvider with ChangeNotifier {
  static const String _pendingPhotoDir = 'pending_photos';
  final ActivityService _activityService = ActivityService();
  final OfflineStorageService _offlineStorage = OfflineStorageService();
  final AuthService _authService = AuthService();
  ConnectivityProvider? _connectivityProvider;
  ActivityPayload? _activityData;
  bool _isLoading = false;
  String? _error;
  String? _successMessage;
  bool _isOfflineMode = false;
  bool _syncPendingInProgress = false;
  bool _isDisposed = false;

  void _safeNotify() {
    if (_isDisposed) return;
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.persistentCallbacks || phase == SchedulerPhase.transientCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (_isDisposed) return;
        notifyListeners();
      });
    } else {
      notifyListeners();
    }
  }

  ActivityPayload? get activityData => _activityData;
  DailyActivity? get todayActivity => _activityData?.today;
  List<DailyActivity> get recentActivities => _activityData?.recent ?? [];
  bool get isLoading => _isLoading;
  String? get error => _error;
  String? get successMessage => _successMessage;
  bool get isOfflineMode => _isOfflineMode;

  // Get all pending activities (both daily and patroli) that haven't been synced yet
  Future<List<DailyActivity>> getPendingActivitiesList() async {
    final pendingDaily = await _offlineStorage.getPendingActivities();
    final pendingPatroli = await _offlineStorage.getPendingPatroli();

    debugPrint('[ActivityProvider] Retrieved ${pendingDaily.length} pending daily, ${pendingPatroli.length} pending patroli from storage');

    final pendingActivities = <DailyActivity>[];

    // Convert pending daily activities to DailyActivity objects
    // IMPORTANT: Daily activities should NOT have location data
    for (final item in pendingDaily) {
      try {
        final activity = DailyActivity(
          id: item['localId']?.toString() ?? 'pending-${DateTime.now().millisecondsSinceEpoch}',
          userId: '', // Will be set when synced
          date: item['date']?.toString() ?? DateTime.now().toIso8601String().split('T')[0],
          summary: item['summary']?.toString() ?? '',
          activityType: item['activityType']?.toString() ?? 'normal',
          sentiment: item['sentiment']?.toString() ?? 'netral',
          focusHours: item['focusHours'] is int ? item['focusHours'] as int : 0,
          blockers: item['blockers'] is List ? (item['blockers'] as List).map((e) => e.toString()).toList() : [],
          highlights: item['highlights'] is List ? (item['highlights'] as List).map((e) => e.toString()).toList() : [],
          plans: item['plans'] is List ? (item['plans'] as List).map((e) => e.toString()).toList() : [],
          notes: item['notes']?.toString(),
          locationName: null, // Daily activities should not have location
          checkpoints: null,
          photoUrls: item['photoPaths'] is List ? (item['photoPaths'] as List).map((path) => 'file://${path.toString()}').toList() : null,
          latitude: null, // Daily activities should not have GPS
          longitude: null, // Daily activities should not have GPS
          createdAt: item['timestamp']?.toString() ?? item['createdAt']?.toString() ?? DateTime.now().toIso8601String(),
          isRead: null,
          viewsCount: null,
          isLocal: true, // Mark as local/pending
        );
        pendingActivities.add(activity);
      } catch (e) {
        debugPrint('[ActivityProvider] Error converting pending daily activity: $e');
      }
    }

    // Convert pending patroli to DailyActivity objects
    for (final item in pendingPatroli) {
      try {
        final activity = DailyActivity(
          id: item['localId']?.toString() ?? 'pending-patroli-${DateTime.now().millisecondsSinceEpoch}',
          userId: '', // Will be set when synced
          date: item['date']?.toString() ?? DateTime.now().toIso8601String().split('T')[0],
          summary: item['summary']?.toString() ?? '',
          sentiment: 'netral',
          focusHours: 0,
          blockers: [],
          highlights: [],
          plans: [],
          notes: item['notes']?.toString(),
          locationName: item['locationName']?.toString(),
          checkpoints: null,
          photoUrls: item['photoPaths'] is List ? (item['photoPaths'] as List).map((path) => 'file://${path.toString()}').toList() : null,
          latitude: item['latitude'] is num ? (item['latitude'] as num).toDouble() : null,
          longitude: item['longitude'] is num ? (item['longitude'] as num).toDouble() : null,
          createdAt: item['timestamp']?.toString() ?? item['createdAt']?.toString() ?? DateTime.now().toIso8601String(),
          isRead: null,
          viewsCount: null,
          isLocal: true, // Mark as local/pending
        );
        pendingActivities.add(activity);
      } catch (e) {
        debugPrint('[ActivityProvider] Error converting pending patroli: $e');
      }
    }

    return pendingActivities;
  }

  void setConnectivityProvider(ConnectivityProvider provider) {
    if (_connectivityProvider == provider) {
      return;
    }
    _connectivityProvider?.removeListener(_handleConnectivityChange);
    _connectivityProvider = provider;
    _connectivityProvider?.addListener(_handleConnectivityChange);
  }

  void _handleConnectivityChange() {
    final isConnected = _connectivityProvider?.isConnected ?? true;
    if (isConnected) {
      syncPendingActivities();
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    _connectivityProvider?.removeListener(_handleConnectivityChange);
    super.dispose();
  }

  Future<void> loadActivities() async {
    _error = null;
    _successMessage = null;

    // Load cached activities first for instant display
    final offlineData = await _offlineStorage.getActivities();
    if (offlineData != null) {
      _activityData = ActivityPayload.fromJson(offlineData);
      await _mergePendingActivities(); // Merge pending activities into cached data
      _isLoading = false;
      _isOfflineMode = false;
      _safeNotify();
      debugPrint('[ActivityProvider] [OK] Activities loaded from offline storage');
    }

    final isConnected = _connectivityProvider?.isConnected ?? true;
    _isOfflineMode = !isConnected;

    if (_activityData == null) {
      _isLoading = true;
      _safeNotify();
    }

    if (!isConnected) {
      _error = 'Mode offline - Data terakhir yang tersimpan';
      _isLoading = false;
      _safeNotify();
      return;
    }

    try {
      debugPrint('[ActivityProvider] Loading activities...');
      _activityData = await _activityService.getActivities();
      _error = null;
      _isOfflineMode = false;
      debugPrint('[ActivityProvider] [OK] Activities loaded: today=${_activityData?.today != null}, recent=${_activityData?.recent.length ?? 0}');
      await _offlineStorage.saveActivities(_buildOfflinePayload(_activityData));
      await _mergePendingActivities(); // Merge pending activities into fresh data
      debugPrint('[ActivityProvider] After merge - today: ${_activityData?.today?.summary}, recent: ${_activityData?.recent.length}');
    } catch (e) {
      _error = ErrorHandler.getErrorMessage(e);
      debugPrint('[ActivityProvider] [WARN] Failed to load activities: $_error');
    } finally {
      _isLoading = false;
      debugPrint('[ActivityProvider] Notifying listeners - isLoading: $_isLoading, error: $_error');
      _safeNotify();
    }
  }

  Future<void> _mergePendingActivities() async {
    if (_activityData == null) return;

    try {
      final pendingActivities = await getPendingActivitiesList();
      debugPrint('[ActivityProvider] Found ${pendingActivities.length} pending activities to merge');

      if (pendingActivities.isEmpty) return;

      final recent = List<DailyActivity>.from(_activityData!.recent);
      final today = _activityData!.today;

      // Add pending activities to recent list (they will appear at the top)
      recent.insertAll(0, pendingActivities);

      _activityData = ActivityPayload(today: today, recent: recent);
      debugPrint('[ActivityProvider] Merged ${pendingActivities.length} pending activities. Total recent: ${recent.length}');

      // Debug: Check what's in the merged data
      final dailyCount = recent.where((a) => a.locationName == null && a.latitude == null).length;
      final patroliCount = recent.where((a) => a.locationName != null || a.latitude != null).length;
      debugPrint('[ActivityProvider] After merge - Daily: $dailyCount, Patroli: $patroliCount');
    } catch (e) {
      debugPrint('[ActivityProvider] Error merging pending activities: $e');
    }
  }

  Future<bool> submitDailyActivity({
    required String summary,
    String activityType = 'normal',
    String? sentiment,
    int? focusHours,
    List<String>? blockers,
    List<String>? highlights,
    List<String>? plans,
    String? notes,
    List<File>? photos,
  }) async {
    _isLoading = true;
    _error = null;
    _successMessage = null;
    _safeNotify();

    final isConnected = _connectivityProvider?.isConnected ?? true;
    final now = DateTime.now();
    final dateOnly = _formatDateOnly(now);

    try {
      // Always queue as pending first for immediate UI feedback
        await _queueOfflineActivity(
          type: 'daily',
          summary: summary,
          activityType: activityType,
          sentiment: sentiment,
          focusHours: focusHours,
          blockers: blockers,
          highlights: highlights,
          plans: plans,
          notes: notes,
          photos: photos ?? [],
          date: dateOnly,
        );

      // Show pending activity immediately in UI
      await loadActivities();

      // Try to sync if connected (background operation)
      if (isConnected) {
        // Start background sync - this will remove the pending status when successful
        syncPendingActivities().then((_) {
          // Reload after sync completes to update UI
          loadActivities();
        }).catchError((error) {
          debugPrint('[ActivityProvider] Background sync failed: $error');
        });
        _successMessage = 'Aktivitas sedang dikirim...';
      } else {
        _successMessage = 'Mode offline - Aktivitas disimpan, akan disinkronkan saat online';
      }

        return true;
    } catch (e) {
      _error = ErrorHandler.getErrorMessage(e);
      return false;
    } finally {
      _isLoading = false;
      _safeNotify();
    }
  }

  Future<bool> submitPatroli({
    required String summary,
    String? notes,
    List<File>? photos,
  }) async {
    _isLoading = true;
    _error = null;
    _successMessage = null;
    _safeNotify();

    final isConnected = _connectivityProvider?.isConnected ?? true;
    final now = DateTime.now();
    final dateOnly = _formatDateOnly(now);
    Map<String, double>? location;

    try {
      // Always queue as pending first for immediate UI feedback
        location = await _getCurrentLocation();
      await _queueOfflinePatroli(
          summary: summary,
          notes: notes,
          photos: photos ?? [],
          date: dateOnly,
          latitude: location?['lat'],
          longitude: location?['lng'],
          locationName: summary,
        );

      // Show pending patroli immediately in UI
      await loadActivities();

      // Try to sync if connected (background operation)
      if (isConnected) {
        // Start background sync - this will remove the pending status when successful
        syncPendingActivities().then((_) {
          // Reload after sync completes to update UI
          loadActivities();
        }).catchError((error) {
          debugPrint('[ActivityProvider] Background sync failed: $error');
        });
        _successMessage = 'Laporan patroli sedang dikirim...';
      } else {
        _successMessage = 'Mode offline - Patroli disimpan, akan disinkronkan saat online';
      }

        return true;
    } catch (e) {
      _error = ErrorHandler.getErrorMessage(e);
      return false;
    } finally {
      _isLoading = false;
      _safeNotify();
    }
  }

  Future<DailyActivity?> getActivityById(String id) async {
    try {
      debugPrint('[ActivityProvider] Getting activity: $id');
      final result = await _activityService.getActivityById(id);
      if (result['success'] == true) {
        final data = result['data'] as Map<String, dynamic>;
        final activity = DailyActivity.fromJson(data);
        debugPrint('[ActivityProvider] [OK] Activity loaded');
        return activity;
      } else {
        debugPrint('[ActivityProvider] Failed to get activity: ${result['message']}');
        return null;
      }
    } catch (e) {
      _error = ErrorHandler.getErrorMessage(e);
      return null;
    } finally {
      _isLoading = false;
      _safeNotify();
    }
  }

  Future<bool> updateActivity({
    required String id,
    required String summary,
    String activityType = 'normal',
    String? sentiment,
    int? focusHours,
    List<String>? blockers,
    List<String>? highlights,
    List<String>? plans,
    String? notes,
    List<File>? newPhotos,
    List<String>? existingPhotoUrls,
  }) async {
    _isLoading = true;
    _error = null;
    _safeNotify();

    try {
      debugPrint('[ActivityProvider] Updating activity: $id');
      final result = await _activityService.updateActivity(
        id: id,
        summary: summary,
        activityType: activityType,
        sentiment: sentiment,
        focusHours: focusHours,
        blockers: blockers,
        highlights: highlights,
        plans: plans,
        notes: notes,
        newPhotos: newPhotos ?? [],
        existingPhotoUrls: existingPhotoUrls ?? [],
      );

      if (result['success'] == true) {
        await loadActivities();
        debugPrint('[ActivityProvider] [OK] Activity updated');
        return true;
      } else {
        _error = result['message'] as String? ?? 'Operasi gagal';
        return false;
      }
    } catch (e) {
      _error = ErrorHandler.getErrorMessage(e);
      return false;
    } finally {
      _isLoading = false;
      _safeNotify();
    }
  }

  Future<bool> deleteActivity(String id) async {
    _isLoading = true;
    _error = null;
    _safeNotify();

    try {
      debugPrint('[ActivityProvider] Deleting activity: $id');
      final result = await _activityService.deleteActivity(id);
      if (result['success'] == true) {
        await loadActivities();
        debugPrint('[ActivityProvider] [OK] Activity deleted');
        return true;
      } else {
        _error = result['message'] as String? ?? 'Operasi gagal';
        return false;
      }
    } catch (e) {
      _error = ErrorHandler.getErrorMessage(e);
      return false;
    } finally {
      _isLoading = false;
      _safeNotify();
    }
  }

  Future<void> syncPendingActivities() async {
    if (_syncPendingInProgress) {
      return;
    }

    final isConnected = _connectivityProvider?.isConnected ?? true;
    if (!isConnected) {
      return;
    }

    _syncPendingInProgress = true;
    try {
      // Sync daily activities
      final pendingActivities = await _offlineStorage.getPendingActivities();
      // Sync patroli
      final pendingPatroli = await _offlineStorage.getPendingPatroli();

      final totalPending = pendingActivities.length + pendingPatroli.length;
      if (totalPending == 0) {
        return;
      }

      debugPrint('[ActivityProvider] Syncing ${pendingActivities.length} daily activities and ${pendingPatroli.length} patroli...');

      // Debug: Log pending items
      if (pendingActivities.isNotEmpty) {
        debugPrint('[ActivityProvider] Pending daily activities:');
        for (var i = 0; i < pendingActivities.length; i++) {
          debugPrint('  [$i] ${pendingActivities[i]['summary']} (${pendingActivities[i]['type']})');
        }
      }

      if (pendingPatroli.isNotEmpty) {
        debugPrint('[ActivityProvider] Pending patroli:');
        for (var i = 0; i < pendingPatroli.length; i++) {
          debugPrint('  [$i] ${pendingPatroli[i]['summary']} (${pendingPatroli[i]['type']}) - Location: ${pendingPatroli[i]['locationName']}');
        }
      }
      var syncedCount = 0;
      var failedCount = 0;

      // Sync daily activities
      for (int i = pendingActivities.length - 1; i >= 0; i--) {
        final item = pendingActivities[i];
        try {
          final success = await _syncSingleActivity(item, i, 'activity');
          if (success) {
            syncedCount++;
          } else {
            failedCount++;
            debugPrint('[ActivityProvider] Failed to sync daily activity at index $i');
          }
        } catch (e) {
          failedCount++;
          debugPrint('[ActivityProvider] Error syncing daily activity at index $i: $e');
        }
      }

      // Sync patroli
      for (int i = pendingPatroli.length - 1; i >= 0; i--) {
        final item = pendingPatroli[i];
        try {
          final success = await _syncSingleActivity(item, i, 'patroli');
          if (success) {
            syncedCount++;
          } else {
            failedCount++;
            debugPrint('[ActivityProvider] Failed to sync patroli at index $i');
          }
        } catch (e) {
          failedCount++;
          debugPrint('[ActivityProvider] Error syncing patroli at index $i: $e');
        }
      }

      debugPrint('[ActivityProvider] Sync completed: $syncedCount synced, $failedCount failed');

      if (syncedCount > 0) {
        debugPrint('[ActivityProvider] Successfully synced $syncedCount activities, reloading UI');
        await loadActivities(); // Reload from server, pending activities already removed during sync
      }
    } finally {
      _syncPendingInProgress = false;
    }
  }

  Future<bool> _syncSingleActivity(Map<String, dynamic> item, int index, String storageType) async {
        final type = (item['type'] ?? 'daily').toString();
        final summary = (item['summary'] ?? '').toString();
        final localId = item['localId']?.toString();
        final date = item['date']?.toString();
        final notes = item['notes']?.toString();
        final locationName = item['locationName']?.toString();
        final latitude = item['latitude'];
        final longitude = item['longitude'];
        final sentiment = item['sentiment']?.toString();
        final activityType = (item['activityType'] ?? 'normal').toString();
        final focusHours = item['focusHours'] is int ? item['focusHours'] as int : null;
        final blockers = item['blockers'] is List ? (item['blockers'] as List).map((e) => e.toString()).toList() : null;
        final highlights = item['highlights'] is List ? (item['highlights'] as List).map((e) => e.toString()).toList() : null;
        final plans = item['plans'] is List ? (item['plans'] as List).map((e) => e.toString()).toList() : null;

        if (summary.trim().isEmpty) {
      if (storageType == 'patroli') {
        await _offlineStorage.removePendingPatroli(index);
      } else {
        await _offlineStorage.removePendingActivity(index);
      }
          if (localId != null) {
            await _removeLocalActivity(localId);
          }
      return true; // Empty activities are considered "successfully handled"
        }

        final photoPaths = item['photoPaths'] is List ? (item['photoPaths'] as List).map((e) => e.toString()).toList() : <String>[];
        final photos = <File>[];
        for (final path in photoPaths) {
          final file = File(path);
          if (await file.exists()) {
            photos.add(file);
          }
        }

        try {
          Map<String, dynamic> result;
          if (type == 'patroli') {
            result = await _activityService.submitPatroli(
              summary: summary,
              notes: notes,
              photos: photos,
              date: date,
              latitude: latitude is num ? latitude.toDouble() : null,
              longitude: longitude is num ? longitude.toDouble() : null,
              locationName: locationName,
            );
          } else {
        // For daily activities, only send fields that exist in DailyActivity schema
        // Remove fields that are now specific to patroli activities
            result = await _activityService.submitDailyActivity(
              summary: summary,
              activityType: activityType,
              sentiment: sentiment,
              focusHours: focusHours,
              blockers: blockers,
              highlights: highlights,
              plans: plans,
              notes: notes,
              photos: photos,
              date: date,
            );
          }

          if (result['success'] == true) {
        if (storageType == 'patroli') {
          await _offlineStorage.removePendingPatroli(index);
        } else {
          await _offlineStorage.removePendingActivity(index);
        }
            await _deletePendingPhotos(photoPaths);
            if (localId != null) {
              await _removeLocalActivity(localId);
            }
        debugPrint('[ActivityProvider] Successfully synced $storageType: $summary');
        return true;
      } else {
        debugPrint('[ActivityProvider] Failed to sync $storageType: ${result['message'] ?? 'Unknown error'}');
        return false;
          }
        } catch (e) {
      debugPrint('[ActivityProvider] Exception syncing $storageType: $e');
      return false;
    }
  }

  Future<Map<String, double>?> _getCurrentLocation() async {
    try {
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
      return {
        'lat': position.latitude,
        'lng': position.longitude,
      };
    } catch (_) {
      return null;
    }
  }

  bool _shouldQueueOffline(String message) {
    final lower = message.toLowerCase();
    return lower.contains('timeout') ||
        lower.contains('koneksi') ||
        lower.contains('terhubung') ||
        lower.contains('offline');
  }

  String _formatDateOnly(DateTime value) {
    final year = value.year.toString().padLeft(4, '0');
    final month = value.month.toString().padLeft(2, '0');
    final day = value.day.toString().padLeft(2, '0');
    return '$year-$month-$day';
  }

  String _toFileUrl(String path) {
    return Uri.file(path).toString();
  }

  /// Kunci antrean untuk menahan tap dobel (detik yang sama), bukan laporan
  /// berikutnya. Dulu tanpa waktu, jadi laporan kedua di lokasi yang sama
  /// pada hari yang sama dibuang diam-diam selama HP masih offline.
  String _buildPendingClientKey(String type, String summary, String date, int photoCount, DateTime now) {
    final second = now.millisecondsSinceEpoch ~/ 1000;
    return '${type.toLowerCase()}|${summary.trim()}|$date|$photoCount|$second';
  }

  /// Salin foto antrean ke folder dokumen aplikasi. Foto dari kamera ada di
  /// folder cache yang bisa dibersihkan Android sebelum sinyal kembali, dan
  /// laporan lalu terkirim tanpa foto. Kalau penyalinan gagal, path asli dipakai.
  Future<List<String>> _persistPendingPhotos(List<File> photos, String localId) async {
    if (photos.isEmpty) return [];
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(docs.path, _pendingPhotoDir));
      await dir.create(recursive: true);
      final paths = <String>[];
      for (var i = 0; i < photos.length; i++) {
        final target = p.join(dir.path, '${localId}_$i${p.extension(photos[i].path)}');
        paths.add((await photos[i].copy(target)).path);
      }
      return paths;
    } catch (e) {
      debugPrint('[ActivityProvider] Gagal menyalin foto antrean, pakai path asli: $e');
      return photos.map((file) => file.path).toList();
    }
  }

  /// Hapus salinan foto antrean setelah laporan berhasil terkirim.
  Future<void> _deletePendingPhotos(List<String> paths) async {
    for (final path in paths) {
      if (!path.contains('${p.separator}$_pendingPhotoDir${p.separator}')) continue;
      try {
        final file = File(path);
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }
  }

  Future<void> _queueOfflineActivity({
    required String type,
    required String summary,
    String activityType = 'normal',
    String? sentiment,
    int? focusHours,
    List<String>? blockers,
    List<String>? highlights,
    List<String>? plans,
    String? notes,
    List<File> photos = const [],
    double? latitude,
    double? longitude,
    String? locationName,
    String? date,
  }) async {
    final now = DateTime.now();
    final localId = 'local-${now.millisecondsSinceEpoch}';
    final photoPaths = await _persistPendingPhotos(photos, localId);
    final photoUrls = photoPaths.map(_toFileUrl).toList();
    final activityDate = date ?? _formatDateOnly(now);
    final user = await _authService.getCurrentUser();
    final clientKey = _buildPendingClientKey(type, summary, activityDate, photoPaths.length, now);

    // Gunakan penyimpanan terpisah berdasarkan tipe
    if (type == 'patroli') {
      await _offlineStorage.savePendingPatroli({
        'type': type,
        'localId': localId,
        'summary': summary,
        'notes': notes,
        'photoPaths': photoPaths,
        'latitude': latitude,
        'longitude': longitude,
        'locationName': locationName,
        'date': activityDate,
        'createdAt': now.toIso8601String(),
        'clientKey': clientKey,
      });
    } else {
      // Daily activities should NOT have location data
    await _offlineStorage.savePendingActivity({
      'type': type,
      'localId': localId,
      'summary': summary,
      'activityType': activityType,
      'sentiment': sentiment,
      'focusHours': focusHours,
      'blockers': blockers,
      'highlights': highlights,
      'plans': plans,
      'notes': notes,
      'photoPaths': photoPaths,
        // Daily activities don't need location data
      'date': activityDate,
      'createdAt': now.toIso8601String(),
      'clientKey': clientKey,
    });
    }

    final localActivity = DailyActivity(
      id: localId,
      userId: user?.id ?? '',
      date: activityDate,
      summary: summary,
      activityType: activityType,
      sentiment: sentiment ?? 'netral',
      focusHours: focusHours ?? 0,
      blockers: blockers ?? [],
      highlights: highlights ?? [],
      plans: plans ?? [],
      notes: notes,
      locationName: locationName,
      checkpoints: null,
      photoUrls: photoUrls.isNotEmpty ? photoUrls : null,
      latitude: latitude,
      longitude: longitude,
      createdAt: now.toIso8601String(),
      isRead: false,
      viewsCount: 0,
      isLocal: true,
    );

    await _mergeLocalActivity(localActivity);

    // Reload activities to merge pending activities from storage
    await loadActivities();
  }

  Future<void> _queueOfflinePatroli({
    required String summary,
    String? notes,
    List<File> photos = const [],
    double? latitude,
    double? longitude,
    String? locationName,
    String? date,
  }) async {
    final now = DateTime.now();
    final localId = 'local-patroli-${now.millisecondsSinceEpoch}';
    final photoPaths = await _persistPendingPhotos(photos, localId);
    final photoUrls = photoPaths.map(_toFileUrl).toList();
    final activityDate = date ?? _formatDateOnly(now);
    final user = await _authService.getCurrentUser();
    final clientKey = _buildPendingClientKey('patroli', summary, activityDate, photoPaths.length, now);

    await _offlineStorage.savePendingPatroli({
      'type': 'patroli',
      'localId': localId,
      'summary': summary,
      'notes': notes,
      'photoPaths': photoPaths,
      'latitude': latitude,
      'longitude': longitude,
      'locationName': locationName,
      'date': activityDate,
      'createdAt': now.toIso8601String(),
      'clientKey': clientKey,
    });

    final localActivity = DailyActivity(
      id: localId,
      userId: user?.id ?? '',
      date: activityDate,
      summary: summary,
      sentiment: 'netral',
      focusHours: 0,
      blockers: [],
      highlights: [],
      plans: [],
      notes: notes,
      locationName: locationName,
      checkpoints: null,
      photoUrls: photoUrls.isNotEmpty ? photoUrls : null,
      latitude: latitude,
      longitude: longitude,
      createdAt: now.toIso8601String(),
      isRead: false,
      viewsCount: 0,
      isLocal: true,
    );

    await _mergeLocalActivity(localActivity);

    // Reload activities to merge pending activities from storage
    await loadActivities();
  }

  Future<void> _mergeLocalActivity(DailyActivity localActivity) async {
    final current = _activityData;
    final recent = List<DailyActivity>.from(current?.recent ?? []);
    DailyActivity? today = current?.today;
    final todayDate = _formatDateOnly(DateTime.now());

    if (localActivity.date == todayDate && today == null) {
      today = localActivity;
    } else {
      recent.insert(0, localActivity);
    }

    _activityData = ActivityPayload(today: today, recent: recent);
    await _offlineStorage.saveActivities(_buildOfflinePayload(_activityData));
    _safeNotify();
  }

  Future<void> _removeLocalActivity(String localId) async {
    final current = _activityData;
    if (current == null) {
      return;
    }

    final recent = current.recent.where((item) => item.id != localId).toList();
    DailyActivity? today = current.today;
    if (today?.id == localId) {
      today = null;
    }

    _activityData = ActivityPayload(today: today, recent: recent);
    await _offlineStorage.saveActivities(_buildOfflinePayload(_activityData));
    _safeNotify();
  }

  Map<String, dynamic> _buildOfflinePayload(ActivityPayload? payload) {
    final entries = <Map<String, dynamic>>[];
    if (payload?.today != null) {
      entries.add(payload!.today!.toJson());
    }
    for (final activity in payload?.recent ?? []) {
      entries.add(activity.toJson());
    }
    return {'entries': entries};
  }
}
