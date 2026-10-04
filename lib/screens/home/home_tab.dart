import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:geolocator/geolocator.dart' as geolocator;
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../../providers/attendance_provider.dart';
import '../../utils/checkin_gate.dart';
import '../../providers/shift_provider.dart';
import '../../providers/request_provider.dart';
import '../../providers/auth_provider.dart';
import '../../providers/activity_provider.dart';
import '../../providers/connectivity_provider.dart';
import '../../models/shift_model.dart';
import '../../models/attendance_model.dart';
import '../../models/request_model.dart';
import '../../models/team_model.dart';
import '../camera/camera_screen.dart';
import '../profile/profile_screen.dart';
import '../../widgets/shimmer_loading.dart';
import '../../widgets/password_setup_banner.dart';
import '../../widgets/leave_request_banner.dart';
import '../../widgets/permission_guidance_dialog.dart';
import '../../widgets/permission_status_card.dart';
import '../../config/api_config.dart';
import '../../services/push_notification_service.dart';
import '../../utils/toast_helper.dart';
import '../../services/team_service.dart';
import '../../services/persistent_notification_service.dart';
import '../../services/api_service.dart';
import '../../providers/checkpoint_provider.dart';
import '../../widgets/app_rating_dialog.dart';
import '../notifications/notification_screen.dart';
import '../../models/checkpoint_model.dart';
import '../activity/activity_form_screen.dart';
import '../shifts/my_shift_screen.dart';
import 'home_insights.dart';
import '../../utils/clock.dart';
import '../attendance/attendance_qr_scanner_screen.dart';
import '../patroli/patroli_screen.dart';
import '../../utils/security_position.dart';
import 'dart:io';
import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

class HomeTab extends StatefulWidget {
  const HomeTab({super.key});

  @override
  State<HomeTab> createState() => _HomeTabState();
}

class _ShiftStatusItem {
  final DailyShift? shift;
  final AttendanceRecord? record;
  final String title;
  final String range;
  final String checkIn;
  final String checkOut;
  final String status;

  const _ShiftStatusItem({
    required this.shift,
    required this.record,
    required this.title,
    required this.range,
    required this.checkIn,
    required this.checkOut,
    required this.status,
  });
}

class _ShiftTimelineStage {
  final String label;
  final String range;
  final String status;
  final Color color;
  final IconData icon;

  const _ShiftTimelineStage({
    required this.label,
    required this.range,
    required this.status,
    required this.color,
    required this.icon,
  });
}

class _ShiftBreakWindowConfig {
  final int shiftStartMinutes;
  final int shiftEndMinutes;
  final int breakStartMinutes;
  final int breakEndMinutes;
  final bool overnight;

  const _ShiftBreakWindowConfig({
    required this.shiftStartMinutes,
    required this.shiftEndMinutes,
    required this.breakStartMinutes,
    required this.breakEndMinutes,
    required this.overnight,
  });
}

class _HomeTabState extends State<HomeTab>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  Timer? _durationTimer;
  Timer? _shiftUiTimer;
  DateTime? _checkInDateTime; // Store parsed check-in datetime
  String? _notificationKey;
  final ValueNotifier<String> _durationNotifier = ValueNotifier<String>(
    '00 : 00 : 00',
  );
  final ValueNotifier<DateTime> _shiftClockNotifier = ValueNotifier<DateTime>(
    DateTime.now(),
  );
  bool _isDisposed = false;
  int _unreadNotifCount = 0;

  Future<void> _fetchUnreadCount() async {
    try {
      final response = await ApiService().get(
        ApiConfig.notificationUnreadCount,
      );
      final count = response.data['unreadCount'] as int? ?? 0;
      if (mounted && !_isDisposed) {
        setState(() => _unreadNotifCount = count);
      }
    } catch (_) {}
  }

  bool _gpsCheckInProgress = false;
  bool _gpsPrompted = false;
  bool _shouldRetryCheckInAfterGpsPrompt = false;
  bool _checkInActionInProgress = false;
  bool _checkOutActionInProgress = false;
  LatLng? _currentMapPosition;
  LatLng? _geofenceSitePosition;
  int? _geofenceRadiusMeters;
  GoogleMapController? _geofenceMapController;
  bool _isFetchingMapPosition = false;
  bool _isAutoFittingMap = false;
  bool _mapUserInteracted = false;
  BitmapDescriptor? _userMarkerIcon;
  String? _userMarkerKey;
  bool _isBuildingUserMarker = false;
  bool _isMapDisposed = false;
  AppLifecycleState _appLifecycleState = AppLifecycleState.resumed;
  geolocator.Position? _latestGpsPosition;
  DateTime? _latestGpsFetchedAt;
  DailyShift? _selectedShift;
  final TeamService _teamService = TeamService();
  bool _isLeader = false;
  bool _leaderChecked = false;
  bool _leaderLoading = false;
  List<TeamSummary> _leaderTeams = [];
  bool _teamInfoLoading = false;
  bool _teamInfoLoaded = false;
  List<String> _teamLeaderNames = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startShiftUiTimer();
    _fetchUnreadCount();
    PushNotificationService.incomingMessageTick.addListener(_fetchUnreadCount);

    debugPrint('[HomeTab] Initializing...');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Register rating callback setelah checkout sukses
      final attendanceProv = Provider.of<AttendanceProvider>(
        context,
        listen: false,
      );
      attendanceProv.setOnCheckoutSuccessCallback(() {
        if (mounted) {
          AppRatingDialog.maybeShowAfterCheckout(context);
        }
      });

      debugPrint('[HomeTab] Loading initial data...');
      // Set connectivity provider untuk attendance provider
      final attendanceProvider = Provider.of<AttendanceProvider>(
        context,
        listen: false,
      );
      final connectivityProvider = Provider.of<ConnectivityProvider>(
        context,
        listen: false,
      );
      attendanceProvider.setConnectivityProvider(connectivityProvider);
      Provider.of<ActivityProvider>(
        context,
        listen: false,
      ).setConnectivityProvider(connectivityProvider);
      attendanceProvider.syncPendingAttendance();
      Provider.of<ActivityProvider>(
        context,
        listen: false,
      ).syncPendingActivities();

      // Load leader status for quick actions
      _loadLeaderStatus();
      _loadMyTeamInfo();

      // Only refresh user data if we don't have it yet
      final authProvider = Provider.of<AuthProvider>(context, listen: false);
      if (authProvider.user == null) {
        authProvider.refreshUser();
      }
      // Load attendance dengan default bulan ini
      // Load dari cache dulu untuk instant display, lalu refresh dari API
      final now = DateTime.now();
      // Mundur 2 hari dari awal bulan agar shift malam akhir bulan lalu
      // yang melewati tengah malam/pergantian bulan tetap ikut di-fetch
      // sehingga tombol checkout muncul di hari pertama bulan baru.
      final startDate = DateTime(
        now.year,
        now.month,
        1,
      ).subtract(const Duration(days: 2));
      attendanceProvider
          .loadAttendance(
            startDate: startDate,
            endDate: now,
            forceRefresh: false, // Load dari cache dulu untuk instant display
          )
          .then((_) {
            // Setelah data di-load (baik dari cache atau API), start timer
            if (mounted) {
              debugPrint(
                '[HomeTab] Attendance loaded, checking and starting timer...',
              );
              _checkAndStartTimer(attendanceProvider);

              // Refresh dari API di background untuk mendapatkan data terbaru
              attendanceProvider
                  .loadAttendance(
                    startDate: startDate,
                    endDate: now,
                    forceRefresh: true, // Force refresh dari API
                  )
                  .then((_) {
                    // Setelah refresh dari API, update timer dengan data terbaru
                    if (mounted) {
                      debugPrint(
                        '[HomeTab] Attendance refreshed from API, updating timer...',
                      );
                      _checkAndStartTimer(attendanceProvider);
                    }
                  });
            }
          });

      Provider.of<ShiftProvider>(context, listen: false).loadShifts();
      Provider.of<RequestProvider>(context, listen: false).loadRequests();
      _ensureGpsActive(promptSettings: false);
      attendanceProvider.loadQrAttendanceFlag();
    });
  }

  Future<void> _loadLeaderStatus() async {
    if (_leaderLoading || _leaderChecked) {
      return;
    }
    _leaderLoading = true;
    try {
      final teams = await _teamService.getLeaderTeams();
      if (!mounted) return;
      setState(() {
        _leaderTeams = teams;
        _isLeader = teams.isNotEmpty;
        _leaderChecked = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLeader = false;
        _leaderChecked = true;
      });
    } finally {
      _leaderLoading = false;
    }
  }

  Future<void> _loadMyTeamInfo() async {
    if (_teamInfoLoading || _teamInfoLoaded) {
      return;
    }
    _teamInfoLoading = true;
    try {
      final teams = await _teamService.getMyTeamsWithMembers();
      if (!mounted) return;
      final leaderNames =
          teams
              .map((team) => team.leaderName.trim())
              .where(
                (name) =>
                    name.isNotEmpty && name.toLowerCase() != 'tanpa leader',
              )
              .toSet()
              .toList()
            ..sort();
      setState(() {
        _teamLeaderNames = leaderNames;
        _teamInfoLoaded = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _teamLeaderNames = [];
        _teamInfoLoaded = true;
      });
    } finally {
      _teamInfoLoading = false;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    PushNotificationService.incomingMessageTick.removeListener(_fetchUnreadCount);
    _isDisposed = true;
    _isMapDisposed = true;
    _geofenceMapController?.dispose();
    _geofenceMapController = null;
    _durationTimer?.cancel();
    _shiftUiTimer?.cancel();
    _durationNotifier.dispose();
    _shiftClockNotifier.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    _appLifecycleState = state;
    if (!mounted || _isDisposed) {
      return;
    }
    // Saat app kembali ke foreground, hitung durasi langsung dari database (tidak perlu timer di background)
    if (state == AppLifecycleState.resumed) {
      _startShiftUiTimer();
      _fetchUnreadCount();
      debugPrint('[HomeTab] App resumed - calculating duration from database');
      _ensureGpsActive(promptSettings: false);
      final attendanceProvider = Provider.of<AttendanceProvider>(
        context,
        listen: false,
      );
      final today = attendanceProvider.todayAttendance;

      // Langsung hitung durasi dari database tanpa perlu reload (lebih cepat)
      if (today != null && today.checkIn != null && today.checkOut == null) {
        final checkInDateTime = _parseCheckInDateTime(today);
        if (checkInDateTime != null) {
          // Update duration langsung dari perhitungan waktu check-in sampai sekarang
          final currentDuration = _formatDuration(checkInDateTime);
          _setDuration(currentDuration);
          _checkInDateTime = checkInDateTime;
          // Restart timer untuk update real-time selanjutnya
          _startDurationTimer();
        }
      } else if (today != null && today.checkOut != null) {
        // Sudah check-out, hitung total durasi
        final checkInDateTime = _parseCheckInDateTime(today);
        if (checkInDateTime != null) {
          final checkOutDateTime = _parseCheckOutDateTime(today);
          final totalDuration = _formatDuration(
            checkInDateTime,
            checkOutDateTime: checkOutDateTime,
          );
          _setDuration(totalDuration);
          _durationTimer?.cancel();
        }
      }

      // Refresh data dari API di background (tidak blocking)
      final now = DateTime.now();
      final startDate = DateTime(
        now.year,
        now.month,
        1,
      ).subtract(const Duration(days: 2));
      attendanceProvider
          .loadAttendance(
            startDate: startDate,
            endDate: now,
            forceRefresh: true,
          )
          .then((_) {
            if (mounted && !_isDisposed) {
              _checkAndStartTimer(attendanceProvider);
            }
          });
      Provider.of<ShiftProvider>(context, listen: false).loadShifts();
      Provider.of<RequestProvider>(context, listen: false).loadRequests();
      Provider.of<CheckpointProvider>(
        context,
        listen: false,
      ).loadCheckpoint(force: true);
      if (_shouldRetryCheckInAfterGpsPrompt) {
        final attendanceProvider = Provider.of<AttendanceProvider>(
          context,
          listen: false,
        );
        if (attendanceProvider.activeAttendance == null &&
            !_checkInActionInProgress) {
          _shouldRetryCheckInAfterGpsPrompt = false;
          Future.delayed(const Duration(milliseconds: 250), () {
            if (!mounted) return;
            debugPrint(
              '[HomeTab] Retrying check-in after GPS prompt user interaction',
            );
            _handleCheckIn();
          });
        }
      }
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      // App di background - stop timer untuk hemat baterai
      // Timer tidak perlu berjalan di background karena durasi akan dihitung ulang saat app resume
      debugPrint(
        '[HomeTab] App paused/inactive - stopping timer to save battery',
      );
      _durationTimer?.cancel();
      _shiftUiTimer?.cancel();
    }
  }

  void _startShiftUiTimer() {
    _shiftUiTimer?.cancel();
    if (!mounted || _isDisposed) {
      return;
    }
    _shiftClockNotifier.value = DateTime.now();
    _shiftUiTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!mounted || _isDisposed) {
        _shiftUiTimer?.cancel();
        return;
      }
      _shiftClockNotifier.value = DateTime.now();
    });
  }

  Future<void> _loadCurrentLocationForMap({bool force = false}) async {
    if (_isMapDisposed ||
        _isFetchingMapPosition ||
        (!force && _currentMapPosition != null)) {
      return;
    }
    if (_appLifecycleState != AppLifecycleState.resumed) {
      return;
    }
    _isFetchingMapPosition = true;
    try {
      geolocator.Position? position =
          await geolocator.Geolocator.getLastKnownPosition();
      position ??= await geolocator.Geolocator.getCurrentPosition(
        desiredAccuracy: geolocator.LocationAccuracy.low,
        timeLimit: const Duration(seconds: 8),
      );
      if (position == null) {
        return;
      }
      if (!mounted || _isDisposed || _isMapDisposed) {
        return;
      }
      _cacheGpsPosition(position!);
      _tryFitGeofenceCamera();
    } catch (e) {
      debugPrint('[HomeTab] Failed to load map location: $e');
    } finally {
      _isFetchingMapPosition = false;
    }
  }

  LatLngBounds _buildBounds(LatLng a, LatLng b) {
    final southWest = LatLng(
      a.latitude < b.latitude ? a.latitude : b.latitude,
      a.longitude < b.longitude ? a.longitude : b.longitude,
    );
    final northEast = LatLng(
      a.latitude > b.latitude ? a.latitude : b.latitude,
      a.longitude > b.longitude ? a.longitude : b.longitude,
    );
    return LatLngBounds(southwest: southWest, northeast: northEast);
  }

  void _tryFitGeofenceCamera() {
    final controller = _geofenceMapController;
    final sitePosition = _geofenceSitePosition;
    final userPosition = _currentMapPosition;
    if (_isMapDisposed || _appLifecycleState != AppLifecycleState.resumed) {
      return;
    }
    if (controller == null || sitePosition == null || userPosition == null) {
      return;
    }
    if (_mapUserInteracted) {
      return;
    }
    final samePoint =
        sitePosition.latitude == userPosition.latitude &&
        sitePosition.longitude == userPosition.longitude;
    if (samePoint) {
      _animateMapToPosition(
        controller,
        sitePosition,
        _zoomForRadius(_geofenceRadiusMeters),
      );
      return;
    }
    final bounds = _buildBounds(sitePosition, userPosition);
    _animateMapToBounds(controller, bounds);
  }

  Future<void> _animateMapToBounds(
    GoogleMapController controller,
    LatLngBounds bounds,
  ) async {
    if (_isMapDisposed || _appLifecycleState != AppLifecycleState.resumed) {
      return;
    }
    _isAutoFittingMap = true;
    try {
      await controller.animateCamera(CameraUpdate.newLatLngBounds(bounds, 60));
    } catch (_) {
      // Ignore camera errors when map is not ready.
    } finally {
      _isAutoFittingMap = false;
    }
  }

  Future<void> _animateMapToPosition(
    GoogleMapController controller,
    LatLng target,
    double zoom,
  ) async {
    if (_isMapDisposed || _appLifecycleState != AppLifecycleState.resumed) {
      return;
    }
    _isAutoFittingMap = true;
    try {
      await controller.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(target: target, zoom: zoom),
        ),
      );
    } catch (_) {
      // Ignore camera errors when map is not ready.
    } finally {
      _isAutoFittingMap = false;
    }
  }

  String _getUserInitials(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      return 'U';
    }
    final parts = trimmed
        .split(RegExp(r'\\s+'))
        .where((part) => part.isNotEmpty)
        .toList();
    if (parts.isEmpty) {
      return trimmed.substring(0, 1).toUpperCase();
    }
    if (parts.length == 1) {
      return parts.first.substring(0, 1).toUpperCase();
    }
    final first = parts.first.substring(0, 1).toUpperCase();
    final last = parts.last.substring(0, 1).toUpperCase();
    return '$first$last';
  }

  Color _colorForUser(String seed) {
    final palette = [
      Colors.blue,
      Colors.teal,
      Colors.indigo,
      Colors.green,
      Colors.orange,
      Colors.deepPurple,
    ];
    final hash = seed.codeUnits.fold<int>(0, (sum, item) => sum + item);
    return palette[hash % palette.length];
  }

  Future<ui.Image?> _loadNetworkMarkerImage(String url) async {
    try {
      final imageProvider = NetworkImage(url);
      final completer = Completer<ui.Image>();
      final stream = imageProvider.resolve(const ImageConfiguration());
      late ImageStreamListener listener;
      listener = ImageStreamListener(
        (ImageInfo info, bool _) {
          completer.complete(info.image);
          stream.removeListener(listener);
        },
        onError: (error, stackTrace) {
          completer.completeError(error, stackTrace);
          stream.removeListener(listener);
        },
      );
      stream.addListener(listener);
      return await completer.future;
    } catch (_) {
      return null;
    }
  }

  Future<BitmapDescriptor> _createUserMarkerIcon({
    required String initials,
    required Color backgroundColor,
    String? photoUrl,
  }) async {
    const size = 120.0;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final center = const Offset(size / 2, size / 2);
    final radius = size / 2;

    final backgroundPaint = Paint()..color = backgroundColor;
    canvas.drawCircle(center, radius, backgroundPaint);

    ui.Image? profileImage;
    if (photoUrl != null && photoUrl.trim().isNotEmpty) {
      profileImage = await _loadNetworkMarkerImage(photoUrl.trim());
    }

    final innerRadius = radius * 0.86;
    final innerRect = Rect.fromCircle(center: center, radius: innerRadius);

    if (profileImage != null) {
      canvas.save();
      canvas.clipPath(Path()..addOval(innerRect));
      paintImage(
        canvas: canvas,
        rect: innerRect,
        image: profileImage,
        fit: BoxFit.cover,
        filterQuality: FilterQuality.high,
      );
      canvas.restore();
    } else {
      final textPainter = TextPainter(
        text: TextSpan(
          text: initials,
          style: TextStyle(
            color: Colors.white,
            fontSize: size * 0.36,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.2,
          ),
        ),
        textDirection: ui.TextDirection.ltr,
      );
      textPainter.layout();
      final offset = Offset(
        center.dx - textPainter.width / 2,
        center.dy - textPainter.height / 2,
      );
      textPainter.paint(canvas, offset);
    }

    final borderPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = size * 0.06
      ..color = Colors.white;
    canvas.drawCircle(center, innerRadius, borderPaint);

    final picture = recorder.endRecording();
    final image = await picture.toImage(size.toInt(), size.toInt());
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    if (byteData == null) {
      return BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure);
    }
    return BitmapDescriptor.fromBytes(byteData.buffer.asUint8List());
  }

  Future<void> _updateUserMarkerIcon({
    required String displayName,
    String? photoUrl,
  }) async {
    if (_isMapDisposed || _appLifecycleState != AppLifecycleState.resumed) {
      return;
    }
    final initials = _getUserInitials(displayName);
    final trimmedPhotoUrl = photoUrl?.trim();
    final markerKey = (trimmedPhotoUrl != null && trimmedPhotoUrl.isNotEmpty)
        ? 'photo:$trimmedPhotoUrl'
        : 'initials:$initials';
    if (_userMarkerKey == markerKey && _userMarkerIcon != null) {
      return;
    }
    if (_isBuildingUserMarker) {
      return;
    }
    _isBuildingUserMarker = true;
    try {
      if (!mounted || _isDisposed || _isMapDisposed) {
        return;
      }
      final icon = await _createUserMarkerIcon(
        initials: initials,
        backgroundColor: _colorForUser(displayName),
        photoUrl: trimmedPhotoUrl,
      );
      if (!mounted || _isDisposed || _isMapDisposed) {
        return;
      }
      setState(() {
        _userMarkerIcon = icon;
        _userMarkerKey = markerKey;
      });
    } finally {
      _isBuildingUserMarker = false;
    }
  }

  Future<bool> _ensureGpsActive({required bool promptSettings}) async {
    if (_gpsCheckInProgress) {
      if (!promptSettings) {
        return false;
      }
      debugPrint('[HomeTab] GPS check already in progress, waiting...');
      var waitedMs = 0;
      while (_gpsCheckInProgress && waitedMs < 6000) {
        await Future.delayed(const Duration(milliseconds: 200));
        waitedMs += 200;
      }
      if (_gpsCheckInProgress) {
        if (mounted && promptSettings) {
          ToastHelper.showWarning(
            context,
            'Sedang memeriksa GPS. Coba lagi sebentar.',
          );
        }
        return false;
      }
    }
    _gpsCheckInProgress = true;

    try {
      debugPrint('[HomeTab] Checking location permission...');
      var permission = await geolocator.Geolocator.checkPermission();
      if (permission == geolocator.LocationPermission.denied) {
        if (!promptSettings) {
          debugPrint('[HomeTab] Location permission still denied (pre-check)');
          return false;
        }
        debugPrint('[HomeTab] Requesting location permission...');
        permission = await geolocator.Geolocator.requestPermission();
      }

      if (permission == geolocator.LocationPermission.denied) {
        debugPrint('[HomeTab] Location permission denied');
        if (mounted && promptSettings) {
          ToastHelper.showWarning(
            context,
            'Izin lokasi ditolak. Aktifkan GPS untuk absensi.',
          );
        }
        return false;
      }

      if (permission == geolocator.LocationPermission.deniedForever) {
        debugPrint('[HomeTab] Location permission denied forever');
        if (promptSettings && !_gpsPrompted) {
          _gpsPrompted = true;
          await geolocator.Geolocator.openAppSettings();
        }
        if (mounted && promptSettings) {
          ToastHelper.showWarning(
            context,
            'Izin lokasi ditolak permanen. Aktifkan dari pengaturan.',
          );
        }
        return false;
      }

      debugPrint('[HomeTab] Checking if location service is enabled...');
      final serviceEnabled =
          await geolocator.Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        debugPrint('[HomeTab] Location service not enabled');
        if (promptSettings && !_gpsPrompted) {
          _gpsPrompted = true;
          await geolocator.Geolocator.openLocationSettings();
        }
        if (mounted && promptSettings) {
          ToastHelper.showWarning(
            context,
            'GPS belum aktif. Aktifkan lokasi untuk absensi.',
          );
        }
        return false;
      }

      final position = await _resolveCurrentPosition();
      if (position == null) {
        debugPrint('[HomeTab] GPS service ready but fix is unavailable');
        if (promptSettings && mounted) {
          ToastHelper.showWarning(
            context,
            'GPS aktif, tetapi lokasi belum terbaca. Coba lagi sebentar.',
          );
        }
        return !promptSettings;
      }

      _cacheGpsPosition(position);
      debugPrint(
        '[HomeTab] GPS is ready: ${position.latitude}, ${position.longitude} (accuracy=${position.accuracy.toStringAsFixed(0)}m)',
      );
      _loadCurrentLocationForMap(force: true);
      _gpsPrompted = false;
      return true;
    } finally {
      _gpsCheckInProgress = false;
    }
  }

  void _cacheGpsPosition(geolocator.Position position) {
    _latestGpsPosition = position;
    _latestGpsFetchedAt = DateTime.now();
    if (!mounted || _isDisposed || _isMapDisposed) {
      return;
    }
    setState(() {
      _currentMapPosition = LatLng(position.latitude, position.longitude);
    });
  }

  Map<String, double>? _consumeRecentGpsCoordinates({int maxAgeSeconds = 45}) {
    final position = _latestGpsPosition;
    final fetchedAt = _latestGpsFetchedAt;
    if (position == null || fetchedAt == null) {
      return null;
    }
    final age = DateTime.now().difference(fetchedAt).inSeconds;
    if (age > maxAgeSeconds) {
      return null;
    }
    return {'lat': position.latitude, 'lng': position.longitude};
  }

  Future<geolocator.Position?> _resolveCurrentPosition() async {
    geolocator.Position? lastKnown;
    try {
      lastKnown = await geolocator.Geolocator.getLastKnownPosition();
    } catch (e) {
      debugPrint('[HomeTab] Failed to read last known position: $e');
    }

    final now = DateTime.now();
    if (lastKnown != null) {
      final positionTime = lastKnown.timestamp ?? now;
      final ageMinutes = now.difference(positionTime).inMinutes;
      if (ageMinutes <= 5 && lastKnown.accuracy <= 120) {
        return lastKnown;
      }
    }

    try {
      return await geolocator.Geolocator.getCurrentPosition(
        desiredAccuracy: geolocator.LocationAccuracy.high,
        timeLimit: const Duration(seconds: 12),
      );
    } catch (e) {
      debugPrint('[HomeTab] High-accuracy GPS fetch failed: $e');
    }

    try {
      return await geolocator.Geolocator.getCurrentPosition(
        desiredAccuracy: geolocator.LocationAccuracy.medium,
        timeLimit: const Duration(seconds: 8),
      );
    } catch (e) {
      debugPrint('[HomeTab] Medium-accuracy GPS fetch failed: $e');
    }

    return lastKnown;
  }

  DateTime? _parseCheckInDateTime(AttendanceRecord? today) {
    if (today == null || today.checkIn == null || today.checkIn!.isEmpty) {
      return null;
    }

    try {
      final now = DateTime.now();
      final checkInTime = today.checkIn!;

      // Try parsing as ISO 8601 datetime first (e.g., "2024-01-15T08:30:00Z")
      try {
        final parsed = DateTime.parse(checkInTime);
        // If parsed successfully and has date info, use it
        if (parsed.year > 2000) {
          return parsed;
        }
      } catch (e) {
        // Not ISO format, continue to time-only parsing
      }

      // Parse waktu check-in (format: HH:mm atau HH:mm:ss)
      final parts = checkInTime.split(':');
      if (parts.length < 2) return null;

      final checkInHour = int.parse(parts[0]);
      final checkInMinute = int.parse(parts[1]);
      final checkInSecond = parts.length > 2 ? int.parse(parts[2]) : 0;
      final checkInTimeMinutes = checkInHour * 60 + checkInMinute;
      final nowTimeMinutes = now.hour * 60 + now.minute;
      final todayDateOnly = DateTime(now.year, now.month, now.day);

      // Use original check-in date when record is carried over from previous day.
      DateTime baseDate;
      try {
        final baseDateRaw =
            (today.originalCheckInDate != null &&
                today.originalCheckInDate!.trim().isNotEmpty)
            ? today.originalCheckInDate!
            : today.date;
        baseDate = DateTime.parse(baseDateRaw);
      } catch (e) {
        baseDate = now;
      }

      var checkInDate = DateTime(
        baseDate.year,
        baseDate.month,
        baseDate.day,
        checkInHour,
        checkInMinute,
        checkInSecond,
      );

      final baseDateOnly = DateTime(
        baseDate.year,
        baseDate.month,
        baseDate.day,
      );

      // Adjust only for true overnight shift (early morning + late check-in time)
      if (baseDateOnly.isAtSameMomentAs(todayDateOnly)) {
        final isEarlyMorning = nowTimeMinutes < 360; // before 06:00
        final isLateEveningCheckIn = checkInTimeMinutes > 720; // after 12:00
        if (isEarlyMorning && isLateEveningCheckIn) {
          checkInDate = checkInDate.subtract(const Duration(days: 1));
          debugPrint(
            '[HomeTab] Overnight shift: early morning + late check-in, using yesterday date',
          );
        }
      } else if (baseDateOnly.isAfter(todayDateOnly)) {
        // Guard against future date due to timezone drift: clamp to today
        checkInDate = DateTime(
          todayDateOnly.year,
          todayDateOnly.month,
          todayDateOnly.day,
          checkInHour,
          checkInMinute,
          checkInSecond,
        );
        debugPrint(
          '[HomeTab] Future record date detected, clamping check-in date to today',
        );
      }

      return checkInDate;
    } catch (e) {
      debugPrint('[HomeTab] Error parsing check-in time: $e');
      return null;
    }
  }

  bool _isSameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  int? _parseTimeToMinutes(String time) {
    final trimmed = time.trim();
    if (trimmed.isEmpty) return null;
    final parts = trimmed.split(':');
    if (parts.length < 2) return null;
    final hour = int.tryParse(parts[0]);
    final minute = int.tryParse(parts[1]);
    if (hour == null || minute == null) return null;
    return (hour * 60) + minute;
  }

  int _effectiveStartMinutes(DailyShift shift, int referenceMinutes) {
    final start = _parseTimeToMinutes(shift.startTime) ?? 0;
    final end = _parseTimeToMinutes(shift.endTime) ?? 0;
    if (end <= start && referenceMinutes < start) {
      return start - 1440;
    }
    return start;
  }

  bool _isTimeWithinShift(int timeMinutes, DailyShift shift) {
    final start = _parseTimeToMinutes(shift.startTime);
    final end = _parseTimeToMinutes(shift.endTime);
    if (start == null || end == null) return false;
    var compareTime = timeMinutes;
    var compareEnd = end;
    if (compareEnd <= start) {
      compareEnd += 1440;
      if (compareTime < start) {
        compareTime += 1440;
      }
    }
    return compareTime >= start && compareTime <= compareEnd;
  }

  DailyShift? _inferShiftFromRecord(
    AttendanceRecord record,
    List<DailyShift> shifts,
  ) {
    final checkIn = record.checkIn;
    if (checkIn == null || checkIn.isEmpty) return null;
    final checkInMinutes = _parseTimeToMinutes(checkIn);
    if (checkInMinutes == null) return null;

    DailyShift? matched;
    int? matchedStart;
    for (final shift in shifts) {
      if (!_isTimeWithinShift(checkInMinutes, shift)) {
        continue;
      }
      final start = _effectiveStartMinutes(shift, checkInMinutes);
      if (matched == null || start > (matchedStart ?? -99999)) {
        matched = shift;
        matchedStart = start;
      }
    }
    return matched;
  }

  List<DailyShift> _getRemainingShifts(
    List<DailyShift> todayShifts,
    List<AttendanceRecord> todayRecords,
  ) {
    if (todayShifts.isEmpty) {
      return [];
    }

    final completedShiftIds = <String>{};
    for (final record in todayRecords) {
      if (record.checkOut == null) {
        continue;
      }
      final recordShiftId = record.shiftId;
      if (recordShiftId != null && recordShiftId.isNotEmpty) {
        completedShiftIds.add(recordShiftId);
        continue;
      }
      final inferred = _inferShiftFromRecord(record, todayShifts);
      if (inferred != null && inferred.id.isNotEmpty) {
        completedShiftIds.add(inferred.id);
      }
    }

    return todayShifts
        .where(
          (shift) =>
              shift.id.isNotEmpty && !completedShiftIds.contains(shift.id),
        )
        .toList();
  }

  bool _isOffShift(DailyShift shift) {
    final code = shift.code.trim().toLowerCase();
    final name = shift.name.trim().toLowerCase();
    if (code == 'off' || name == 'off') {
      return true;
    }
    if (code.startsWith('off') || name.startsWith('off')) {
      return true;
    }
    return false;
  }

  bool _isOffDay(List<DailyShift> todayShifts) {
    if (todayShifts.isEmpty) return false;
    return todayShifts.every(_isOffShift);
  }

  AttendanceRecord? _findOpenAttendanceFromHistory(
    AttendanceProvider attendanceProvider,
  ) {
    final todayDate = DateFormat('yyyy-MM-dd').format(DateTime.now());
    AttendanceRecord? openRecord;

    for (final record in attendanceProvider.todayRecords) {
      if (record.checkIn != null && record.checkOut == null) {
        openRecord = record;
        break;
      }
    }

    if (openRecord == null) {
      for (final record in attendanceProvider.recentAttendance) {
        if (record.checkIn != null && record.checkOut == null) {
          openRecord = record;
          break;
        }
      }
    }

    if (openRecord == null) {
      return null;
    }

    if (openRecord.date == todayDate) {
      return null;
    }

    return openRecord;
  }

  String _buildOffShiftMessage() {
    if (_teamLeaderNames.isEmpty) {
      return 'Hari ini OFF. Jika ada kebutuhan masuk, hubungi supervisor atau Team Leader Anda.';
    }
    final leaders = _teamLeaderNames.join(', ');
    return 'Hari ini OFF. Jika ada kebutuhan masuk, hubungi supervisor atau Team Leader Anda: $leaders.';
  }

  DailyShift? _selectShiftForCheckIn(
    List<DailyShift> todayShifts,
    List<AttendanceRecord> todayRecords,
  ) {
    if (todayShifts.isEmpty) {
      return null;
    }

    final availableShifts = _getRemainingShifts(
      todayShifts,
      todayRecords,
    ).where((shift) => !_isOffShift(shift)).toList();
    if (availableShifts.isEmpty) {
      return null;
    }

    final now = DateTime.now();
    final nowMinutes = (now.hour * 60) + now.minute;

    DailyShift? activeShift;
    int? activeStart;
    for (final shift in availableShifts) {
      if (_isTimeWithinShift(nowMinutes, shift)) {
        final start = _effectiveStartMinutes(shift, nowMinutes);
        if (activeShift == null || start > (activeStart ?? -99999)) {
          activeShift = shift;
          activeStart = start;
        }
      }
    }
    if (activeShift != null) {
      return activeShift;
    }

    DailyShift? upcomingShift;
    int? upcomingStart;
    for (final shift in availableShifts) {
      final start = _parseTimeToMinutes(shift.startTime);
      if (start == null || start <= nowMinutes) {
        continue;
      }
      if (upcomingShift == null || start < (upcomingStart ?? 99999)) {
        upcomingShift = shift;
        upcomingStart = start;
      }
    }
    if (upcomingShift != null) {
      return upcomingShift;
    }

    availableShifts.sort(
      (a, b) => _effectiveStartMinutes(
        a,
        nowMinutes,
      ).compareTo(_effectiveStartMinutes(b, nowMinutes)),
    );
    return availableShifts.last;
  }

  /// Format duration dari check-in sampai sekarang (jika belum check-out) atau sampai check-out (jika sudah check-out)
  String _formatDuration(
    DateTime? checkInDateTime, {
    DateTime? checkOutDateTime,
  }) {
    if (checkInDateTime == null) return '00 : 00 : 00';

    try {
      // Jika sudah check-out, hitung dari check-in sampai check-out
      // Jika belum check-out, hitung dari check-in sampai sekarang
      final endTime = checkOutDateTime ?? DateTime.now();
      final diff = endTime.difference(checkInDateTime);

      // Handle negative duration (shouldn't happen, but just in case)
      if (diff.isNegative) return '00 : 00 : 00';

      final hours = diff.inHours.toString().padLeft(2, '0');
      final minutes = (diff.inMinutes % 60).toString().padLeft(2, '0');
      final seconds = (diff.inSeconds % 60).toString().padLeft(2, '0');

      return '$hours : $minutes : $seconds';
    } catch (e) {
      return '00 : 00 : 00';
    }
  }

  String _formatTimeHHmm(DateTime value) {
    final hour = value.hour.toString().padLeft(2, '0');
    final minute = value.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  DateTime? _calculateExpectedShiftStart(DailyShift? shift) {
    if (shift == null) return null;
    final startMinutes = _parseTimeToMinutes(shift.startTime);
    final endMinutes = _parseTimeToMinutes(shift.endTime);
    if (startMinutes == null || endMinutes == null) return null;

    final now = DateTime.now();
    var baseDate = DateTime(now.year, now.month, now.day);
    final overnight = endMinutes <= startMinutes;
    if (overnight) {
      final nowMinutes = now.hour * 60 + now.minute;
      if (nowMinutes < endMinutes) {
        baseDate = baseDate.subtract(const Duration(days: 1));
      }
    }

    return baseDate.add(
      Duration(hours: startMinutes ~/ 60, minutes: startMinutes % 60),
    );
  }

  DateTime? _calculateExpectedShiftEnd(
    AttendanceRecord? record,
    DailyShift? shift,
  ) {
    if (record == null || shift == null) return null;
    final startMinutes = _parseTimeToMinutes(shift.startTime);
    final endMinutes = _parseTimeToMinutes(shift.endTime);
    if (startMinutes == null || endMinutes == null) return null;

    DateTime baseDate;
    final checkInDateTime = _parseCheckInDateTime(record);
    if (checkInDateTime != null) {
      baseDate = DateTime(
        checkInDateTime.year,
        checkInDateTime.month,
        checkInDateTime.day,
      );
    } else {
      try {
        final parsed = DateTime.parse(record.date);
        baseDate = DateTime(parsed.year, parsed.month, parsed.day);
      } catch (_) {
        final now = DateTime.now();
        baseDate = DateTime(now.year, now.month, now.day);
      }
    }

    final overnight = endMinutes <= startMinutes;
    if (overnight && checkInDateTime != null) {
      final checkInMinutes = checkInDateTime.hour * 60 + checkInDateTime.minute;
      if (checkInMinutes < endMinutes) {
        baseDate = baseDate.subtract(const Duration(days: 1));
      }
    }

    final startDateTime = baseDate.add(
      Duration(hours: startMinutes ~/ 60, minutes: startMinutes % 60),
    );
    final endDateTime = overnight
        ? startDateTime
              .add(const Duration(days: 1))
              .add(Duration(hours: endMinutes ~/ 60, minutes: endMinutes % 60))
        : baseDate.add(
            Duration(hours: endMinutes ~/ 60, minutes: endMinutes % 60),
          );
    return endDateTime;
  }

  Future<String?> _showCheckoutReasonDialog({
    required BuildContext context,
    required String title,
    required String message,
  }) async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return AlertDialog(
          title: Text(title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(message),
              const SizedBox(height: 12),
              const Text(
                'Harap beritahu supervisor atau team leader.',
                style: TextStyle(fontSize: 12, color: Colors.black54),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Keterangan',
                  hintText: 'Isi keterangan checkout tidak sesuai jadwal',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(null),
              child: const Text('Batal'),
            ),
            ElevatedButton(
              onPressed: () {
                final reason = controller.text.trim();
                if (reason.isEmpty) return;
                Navigator.of(context).pop(reason);
              },
              child: const Text('Konfirmasi'),
            ),
          ],
        );
      },
    );
    return result;
  }

  Future<String?> _showCheckInReasonDialog({
    required BuildContext context,
    required String title,
    required String message,
  }) async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return AlertDialog(
          title: Text(title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(message),
              const SizedBox(height: 12),
              const Text(
                'Harap beritahu supervisor atau team leader.',
                style: TextStyle(fontSize: 12, color: Colors.black54),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Keterangan',
                  hintText: 'Isi keterangan check-in tidak sesuai jadwal',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(null),
              child: const Text('Batal'),
            ),
            ElevatedButton(
              onPressed: () {
                final reason = controller.text.trim();
                if (reason.isEmpty) return;
                Navigator.of(context).pop(reason);
              },
              child: const Text('Konfirmasi'),
            ),
          ],
        );
      },
    );
    return result;
  }

  Future<String?> _showBreakReasonDialog({
    required BuildContext context,
    required String title,
    required String message,
  }) async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return AlertDialog(
          title: Text(title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(message),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Keterangan Istirahat',
                  hintText: 'Isi alasan keterlambatan selesai istirahat',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(null),
              child: const Text('Batal'),
            ),
            ElevatedButton(
              onPressed: () {
                final reason = controller.text.trim();
                if (reason.isEmpty) return;
                Navigator.of(context).pop(reason);
              },
              child: const Text('Simpan'),
            ),
          ],
        );
      },
    );
    return result;
  }

  Future<bool> _showCheckoutConfirmationDialog(BuildContext context) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return AlertDialog(
          title: const Text('Konfirmasi Check-out'),
          content: const Text(
            'Apakah Anda yakin ingin melanjutkan check-out sekarang?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Batal'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Ya, Lanjutkan'),
            ),
          ],
        );
      },
    );

    return result ?? false;
  }

  int? _calculateMinutesWorked(AttendanceRecord? today) {
    if (today == null) return null;

    final parsed = _parseCheckInDateTime(today);
    if (parsed != null) {
      final diff = DateTime.now().difference(parsed);
      return diff.isNegative ? null : diff.inMinutes;
    }

    final checkInTime = today.checkIn;
    if (checkInTime == null || checkInTime.isEmpty) return null;

    try {
      DateTime checkInDateTime;

      try {
        final parsedIso = DateTime.parse(checkInTime);
        if (parsedIso.year > 2000) {
          checkInDateTime = parsedIso;
        } else {
          throw const FormatException('Not ISO');
        }
      } catch (_) {
        final parts = checkInTime.split(':');
        if (parts.length < 2) return null;
        final hour = int.tryParse(parts[0]) ?? 0;
        final minute = int.tryParse(parts[1]) ?? 0;
        final second = parts.length > 2 ? int.tryParse(parts[2]) ?? 0 : 0;

        DateTime baseDate;
        try {
          baseDate = DateTime.parse(today.date);
        } catch (_) {
          final now = DateTime.now();
          baseDate = DateTime(now.year, now.month, now.day);
        }

        checkInDateTime = DateTime(
          baseDate.year,
          baseDate.month,
          baseDate.day,
          hour,
          minute,
          second,
        );

        final now = DateTime.now();
        final nowMinutes = now.hour * 60 + now.minute;
        final checkInMinutes = hour * 60 + minute;
        final isEarlyMorning = nowMinutes < 360; // before 06:00
        final isLateEveningCheckIn = checkInMinutes > 720; // after 12:00
        if (isEarlyMorning && isLateEveningCheckIn) {
          checkInDateTime = checkInDateTime.subtract(const Duration(days: 1));
        }
      }

      final diff = DateTime.now().difference(checkInDateTime);
      return diff.isNegative ? null : diff.inMinutes;
    } catch (_) {
      return null;
    }
  }

  String _formatTimeLabel(String? value) {
    if (value == null || value.isEmpty) return "-";

    try {
      if (value.contains('T') || value.contains('-')) {
        final parsed = DateTime.parse(value);
        if (parsed.year > 2000) {
          final hour = parsed.hour.toString().padLeft(2, '0');
          final minute = parsed.minute.toString().padLeft(2, '0');
          return "$hour:$minute";
        }
      }
    } catch (_) {}

    if (value.contains(':')) {
      final parts = value.split(':');
      if (parts.length >= 2) {
        final hour = parts[0].padLeft(2, '0');
        final minute = parts[1].padLeft(2, '0');
        return "$hour:$minute";
      }
    }

    return value;
  }

  Duration _calculateTotalWorkDuration(List<AttendanceRecord> records) {
    var total = Duration.zero;

    for (final record in records) {
      if (record.checkIn == null || record.checkIn!.isEmpty) {
        continue;
      }

      final checkInDateTime = _parseCheckInDateTime(record);
      if (checkInDateTime == null) {
        continue;
      }

      DateTime endTime;
      if (record.checkOut != null && record.checkOut!.isNotEmpty) {
        endTime = _parseCheckOutDateTime(record) ?? DateTime.now();
      } else {
        endTime = DateTime.now();
      }

      if (endTime.isBefore(checkInDateTime)) {
        continue;
      }

      total += endTime.difference(checkInDateTime);
    }

    return total;
  }

  String _formatTotalDuration(Duration duration) {
    if (duration.inSeconds <= 0) return "00 : 00";
    final hours = duration.inHours.toString().padLeft(2, '0');
    final minutes = (duration.inMinutes % 60).toString().padLeft(2, '0');
    return "$hours : $minutes";
  }

  _ShiftBreakWindowConfig? _resolveBreakWindowConfig(DailyShift? shift) {
    if (shift == null ||
        shift.hasBreak != true ||
        shift.breakStartTime == null ||
        shift.breakEndTime == null) {
      return null;
    }
    final shiftStart = _parseTimeToMinutes(shift.startTime);
    final shiftEnd = _parseTimeToMinutes(shift.endTime);
    final breakStart = _parseTimeToMinutes(shift.breakStartTime!);
    final breakEnd = _parseTimeToMinutes(shift.breakEndTime!);
    if (shiftStart == null ||
        shiftEnd == null ||
        breakStart == null ||
        breakEnd == null) {
      return null;
    }

    final overnight = shiftEnd <= shiftStart;
    final normalizedShiftEnd = overnight ? shiftEnd + 1440 : shiftEnd;
    var normalizedBreakStart = breakStart;
    var normalizedBreakEnd = breakEnd;

    if (overnight && normalizedBreakStart < shiftStart) {
      normalizedBreakStart += 1440;
    }
    if (overnight && normalizedBreakEnd < shiftStart) {
      normalizedBreakEnd += 1440;
    }
    if (normalizedBreakEnd <= normalizedBreakStart) {
      normalizedBreakEnd += 1440;
    }

    if (normalizedBreakStart < shiftStart ||
        normalizedBreakEnd > normalizedShiftEnd ||
        normalizedBreakEnd <= normalizedBreakStart) {
      return null;
    }

    return _ShiftBreakWindowConfig(
      shiftStartMinutes: shiftStart,
      shiftEndMinutes: normalizedShiftEnd,
      breakStartMinutes: normalizedBreakStart,
      breakEndMinutes: normalizedBreakEnd,
      overnight: overnight,
    );
  }

  int _normalizeShiftMinuteForNow(
    DateTime now,
    _ShiftBreakWindowConfig config,
  ) {
    var minutes = now.hour * 60 + now.minute;
    if (config.overnight && minutes < config.shiftStartMinutes) {
      minutes += 1440;
    }
    return minutes;
  }

  _ShiftTimelineStage _buildWorkStage({
    required String label,
    required String range,
    required int currentMinutes,
    required int startMinutes,
    required int endMinutes,
    required bool hasRecord,
    required bool isCompletedShift,
  }) {
    if (!hasRecord) {
      if (currentMinutes < startMinutes) {
        return _ShiftTimelineStage(
          label: label,
          range: range,
          status: 'Berikutnya',
          color: Colors.orange.shade700,
          icon: Icons.upcoming_outlined,
        );
      }
      return _ShiftTimelineStage(
        label: label,
        range: range,
        status: 'Menunggu check-in',
        color: Colors.orange.shade700,
        icon: Icons.login_outlined,
      );
    }

    if (isCompletedShift || currentMinutes >= endMinutes) {
      return _ShiftTimelineStage(
        label: label,
        range: range,
        status: 'Selesai',
        color: Colors.green.shade700,
        icon: Icons.check_circle_outline,
      );
    }

    if (currentMinutes < startMinutes) {
      return _ShiftTimelineStage(
        label: label,
        range: range,
        status: 'Berikutnya',
        color: Colors.orange.shade700,
        icon: Icons.upcoming_outlined,
      );
    }

    return _ShiftTimelineStage(
      label: label,
      range: range,
      status: 'Sedang berjalan',
      color: Colors.blue.shade700,
      icon: Icons.timelapse_outlined,
    );
  }

  _ShiftTimelineStage _buildBreakStage({
    required DailyShift shift,
    required AttendanceRecord? record,
    required int currentMinutes,
    required _ShiftBreakWindowConfig config,
    required bool hasRecord,
    required bool isCompletedShift,
  }) {
    final range = '${shift.breakStartTime} - ${shift.breakEndTime}';
    final breakStatus = record?.breakStatus?.toLowerCase();

    if (breakStatus == 'active') {
      return _ShiftTimelineStage(
        label: 'Istirahat',
        range: range,
        status: 'Sedang istirahat',
        color: Colors.deepOrange.shade700,
        icon: Icons.free_breakfast_outlined,
      );
    }
    if (breakStatus == 'over_duration') {
      return _ShiftTimelineStage(
        label: 'Istirahat',
        range: range,
        status: 'Over durasi',
        color: Colors.red.shade700,
        icon: Icons.warning_amber_rounded,
      );
    }
    if (breakStatus == 'on_duration') {
      return _ShiftTimelineStage(
        label: 'Istirahat',
        range: range,
        status: 'Tercatat',
        color: Colors.green.shade700,
        icon: Icons.check_circle_outline,
      );
    }
    if (breakStatus == 'no_tagging') {
      return _ShiftTimelineStage(
        label: 'Istirahat',
        range: range,
        status: 'Tidak tagging',
        color: Colors.red.shade700,
        icon: Icons.report_problem_outlined,
      );
    }

    if (!hasRecord) {
      if (currentMinutes < config.breakStartMinutes) {
        return _ShiftTimelineStage(
          label: 'Istirahat',
          range: range,
          status: 'Berikutnya',
          color: Colors.orange.shade700,
          icon: Icons.upcoming_outlined,
        );
      }
      return _ShiftTimelineStage(
        label: 'Istirahat',
        range: range,
        status: 'Belum dimulai',
        color: Colors.orange.shade700,
        icon: Icons.free_breakfast_outlined,
      );
    }

    if (isCompletedShift || currentMinutes >= config.breakEndMinutes) {
      return _ShiftTimelineStage(
        label: 'Istirahat',
        range: range,
        status: 'Selesai',
        color: Colors.green.shade700,
        icon: Icons.check_circle_outline,
      );
    }

    if (currentMinutes < config.breakStartMinutes) {
      return _ShiftTimelineStage(
        label: 'Istirahat',
        range: range,
        status: 'Berikutnya',
        color: Colors.orange.shade700,
        icon: Icons.upcoming_outlined,
      );
    }

    return _ShiftTimelineStage(
      label: 'Istirahat',
      range: range,
      status: 'Waktunya istirahat',
      color: Colors.deepOrange.shade700,
      icon: Icons.free_breakfast_outlined,
    );
  }

  List<_ShiftTimelineStage> _buildShiftTimelineStages(
    DailyShift? shift,
    AttendanceRecord? record,
    DateTime now,
  ) {
    final config = _resolveBreakWindowConfig(shift);
    if (shift == null || config == null) {
      return const [];
    }

    final currentMinutes = _normalizeShiftMinuteForNow(now, config);
    final hasRecord =
        record != null &&
        (record.id.isNotEmpty ||
            record.checkIn != null ||
            record.checkOut != null);
    final isCompletedShift =
        record?.checkOut != null && record!.checkOut!.trim().isNotEmpty;

    return [
      _buildWorkStage(
        label: 'Kerja 1',
        range: '${shift.startTime} - ${shift.breakStartTime}',
        currentMinutes: currentMinutes,
        startMinutes: config.shiftStartMinutes,
        endMinutes: config.breakStartMinutes,
        hasRecord: hasRecord,
        isCompletedShift: isCompletedShift,
      ),
      _buildBreakStage(
        shift: shift,
        record: record,
        currentMinutes: currentMinutes,
        config: config,
        hasRecord: hasRecord,
        isCompletedShift: isCompletedShift,
      ),
      _buildWorkStage(
        label: 'Kerja 2',
        range: '${shift.breakEndTime} - ${shift.endTime}',
        currentMinutes: currentMinutes,
        startMinutes: config.breakEndMinutes,
        endMinutes: config.shiftEndMinutes,
        hasRecord: hasRecord,
        isCompletedShift: isCompletedShift,
      ),
    ];
  }

  DailyShift? _resolveActiveShiftForAttendance(
    List<DailyShift> todayShifts,
    AttendanceRecord? activeRecord,
  ) {
    final shiftId = activeRecord?.shiftId;
    if (shiftId != null && shiftId.isNotEmpty) {
      for (final shift in todayShifts) {
        if (shift.id == shiftId) {
          return shift;
        }
      }
    }
    return null;
  }

  bool _isWithinBreakWindow(DailyShift? shift, DateTime now) {
    final config = _resolveBreakWindowConfig(shift);
    if (config == null) {
      return false;
    }
    final currentMinutes = _normalizeShiftMinuteForNow(now, config);
    return currentMinutes >= config.breakStartMinutes &&
        currentMinutes < config.breakEndMinutes;
  }

  bool _hasBreakWindowPassed(DailyShift? shift, DateTime now) {
    final config = _resolveBreakWindowConfig(shift);
    if (config == null) {
      return false;
    }
    final currentMinutes = _normalizeShiftMinuteForNow(now, config);
    return currentMinutes >= config.breakEndMinutes;
  }

  bool _needsBreakEndReason(AttendanceBreakState? breakState) {
    if (breakState == null || !breakState.strict) {
      return false;
    }

    final activeSession = breakState.activeSession;
    if (activeSession == null) {
      return false;
    }

    if ((activeSession.overByMinutes ?? 0) > 0) {
      return true;
    }

    try {
      final startedAt = DateTime.parse(activeSession.startAt).toLocal();
      final elapsedMinutes = DateTime.now().difference(startedAt).inMinutes;
      return elapsedMinutes > breakState.maxMinutes;
    } catch (_) {
      return false;
    }
  }

  bool _shouldPromptBreakReasonFromMessage(String? message) {
    final normalized = (message ?? '').toLowerCase();
    return normalized.contains('alasan') ||
        normalized.contains('reason') ||
        normalized.contains('keterangan');
  }

  List<_ShiftStatusItem> _buildShiftStatusList(
    List<DailyShift> shifts,
    List<AttendanceRecord> records,
  ) {
    final items = <_ShiftStatusItem>[];

    if (shifts.isNotEmpty) {
      final sorted = [...shifts];
      sorted.sort((a, b) {
        final aStart = _parseTimeToMinutes(a.startTime) ?? 0;
        final bStart = _parseTimeToMinutes(b.startTime) ?? 0;
        return aStart.compareTo(bStart);
      });

      for (var i = 0; i < sorted.length; i++) {
        final shift = sorted[i];
        final record = records.firstWhere(
          (r) => r.shiftId == shift.id,
          orElse: () =>
              AttendanceRecord(id: '', userId: '', date: '', status: 'absent'),
        );
        final hasRecord =
            record.id.isNotEmpty ||
            record.checkIn != null ||
            record.checkOut != null;
        final checkIn = hasRecord ? _formatTimeLabel(record.checkIn) : "-";
        final checkOut = hasRecord ? _formatTimeLabel(record.checkOut) : "-";
        String status;
        if (!hasRecord || record.checkIn == null || record.checkIn!.isEmpty) {
          status = "Belum check-in";
        } else if (record.checkOut == null || record.checkOut!.isEmpty) {
          status = "Sedang bekerja";
        } else {
          status = "Selesai";
        }

        final shiftLabel = shift.name.isNotEmpty
            ? shift.name
            : (shift.code.isNotEmpty ? shift.code : "Shift");
        items.add(
          _ShiftStatusItem(
            shift: shift,
            record: hasRecord ? record : null,
            title: "Shift ${i + 1}: $shiftLabel",
            range: "${shift.startTime} - ${shift.endTime}",
            checkIn: checkIn,
            checkOut: checkOut,
            status: status,
          ),
        );
      }

      return items;
    }

    final shiftlessRecords = records
        .where((r) => r.shiftId == null || r.shiftId!.isEmpty)
        .toList();
    if (shiftlessRecords.isEmpty) {
      items.add(
        const _ShiftStatusItem(
          shift: null,
          record: null,
          title: "Tanpa Shift",
          range: "-",
          checkIn: "-",
          checkOut: "-",
          status: "Belum check-in",
        ),
      );
      return items;
    }

    for (var i = 0; i < shiftlessRecords.length; i++) {
      final record = shiftlessRecords[i];
      final checkIn = _formatTimeLabel(record.checkIn);
      final checkOut = _formatTimeLabel(record.checkOut);
      String status;
      if (record.checkIn == null || record.checkIn!.isEmpty) {
        status = "Belum check-in";
      } else if (record.checkOut == null || record.checkOut!.isEmpty) {
        status = "Sedang bekerja";
      } else {
        status = "Selesai";
      }

      items.add(
        _ShiftStatusItem(
          shift: null,
          record: record,
          title: shiftlessRecords.length > 1
              ? "Tanpa Shift #${i + 1}"
              : "Tanpa Shift",
          range: "-",
          checkIn: checkIn,
          checkOut: checkOut,
          status: status,
        ),
      );
    }

    return items;
  }

  void _setDuration(String value) {
    if (!mounted || _isDisposed) {
      return;
    }
    _durationNotifier.value = value;
  }

  /// Parse check-out datetime dari attendance record
  DateTime? _parseCheckOutDateTime(AttendanceRecord? today) {
    if (today == null || today.checkOut == null || today.checkOut!.isEmpty) {
      return null;
    }

    try {
      final now = DateTime.now();
      final checkOutTime = today.checkOut!;

      // Try parsing as ISO 8601 datetime first
      try {
        final parsed = DateTime.parse(checkOutTime);
        if (parsed.year > 2000) {
          return parsed;
        }
      } catch (e) {
        // Not ISO format, continue to time-only parsing
      }

      // Parse waktu check-out (format: HH:mm atau HH:mm:ss)
      final parts = checkOutTime.split(':');
      if (parts.length < 2) return null;

      final checkOutHour = int.parse(parts[0]);
      final checkOutMinute = int.parse(parts[1]);
      final checkOutSecond = parts.length > 2 ? int.parse(parts[2]) : 0;

      // Use original check-in date when available (carry-over record).
      DateTime checkOutDate;
      try {
        final baseDateRaw =
            (today.originalCheckInDate != null &&
                today.originalCheckInDate!.trim().isNotEmpty)
            ? today.originalCheckInDate!
            : today.date;
        final recordDate = DateTime.parse(baseDateRaw);
        checkOutDate = DateTime(
          recordDate.year,
          recordDate.month,
          recordDate.day,
          checkOutHour,
          checkOutMinute,
          checkOutSecond,
        );

        final checkInDate = _parseCheckInDateTime(today);
        if (checkInDate != null && checkOutDate.isBefore(checkInDate)) {
          checkOutDate = checkOutDate.add(const Duration(days: 1));
        }
      } catch (e) {
        // Fallback to current date
        checkOutDate = DateTime(
          now.year,
          now.month,
          now.day,
          checkOutHour,
          checkOutMinute,
          checkOutSecond,
        );
      }

      return checkOutDate;
    } catch (e) {
      debugPrint('[HomeTab] Error parsing check-out time: $e');
      return null;
    }
  }

  void _checkAndStartTimer(AttendanceProvider attendanceProvider) {
    if (!mounted || _isDisposed) {
      return;
    }
    final today = attendanceProvider.todayAttendance;

    // Priority: Check if check-out exists first - stop timer immediately
    // Jika sudah check-out, tidak perlu timer real-time, cukup hitung total durasi dari database
    if (today != null && today.checkOut != null) {
      if (_durationTimer != null && _durationTimer!.isActive) {
        debugPrint(
          '[HomeTab] Stopping timer - check-out detected, showing total duration from database',
        );
        _durationTimer?.cancel();
      }
      // Parse check-in untuk menghitung total durasi (tidak perlu timer, cukup hitung sekali)
      final checkInDateTime = _parseCheckInDateTime(today);
      _checkInDateTime = checkInDateTime;
      _notificationKey = null;
      // Update duration notifier dengan total durasi (fixed, tidak real-time)
      if (mounted && checkInDateTime != null) {
        final checkOutDateTime = _parseCheckOutDateTime(today);
        final totalDuration = _formatDuration(
          checkInDateTime,
          checkOutDateTime: checkOutDateTime,
        );
        _setDuration(totalDuration);
      }
      return; // Don't start timer if checked out
    }

    // Only start timer if checked in and NOT checked out
    if (today != null && today.checkIn != null && today.checkOut == null) {
      // Parse check-in datetime dari database (selalu baca fresh dari database)
      final newCheckInDateTime = _parseCheckInDateTime(today);
      if (newCheckInDateTime != null) {
        // Selalu restart timer dengan data terbaru dari database
        // Ini memastikan timer selalu menghitung dari waktu check-in yang benar
        // bahkan setelah app di-close dan dibuka lagi
        final shouldRestart =
            _checkInDateTime != newCheckInDateTime ||
            _durationTimer == null ||
            !_durationTimer!.isActive;

        if (shouldRestart) {
          _checkInDateTime = newCheckInDateTime;
          debugPrint(
            '[HomeTab] Starting/restarting duration timer from check-in: $_checkInDateTime',
          );
          // Initialize duration notifier dengan durasi yang benar dari database
          // Durasi dihitung dari waktu check-in sampai sekarang (real-time)
          if (_checkInDateTime != null) {
            final currentDuration = _formatDuration(_checkInDateTime);
            _setDuration(currentDuration);
          }
          _startDurationTimer();
        }
      }

      final shiftProvider = Provider.of<ShiftProvider>(context, listen: false);
      _syncPersistentNotification(today, shiftProvider);
    } else {
      // No check-in detected
      if (_durationTimer != null && _durationTimer!.isActive) {
        debugPrint('[HomeTab] Stopping timer - no check-in detected');
        _durationTimer?.cancel();
      }
      _checkInDateTime = null;
      _notificationKey = null;
      _setDuration('00 : 00 : 00');
    }
  }

  DailyShift? _resolveShiftForNotification(
    AttendanceRecord record,
    ShiftProvider shiftProvider,
  ) {
    final shiftId = record.shiftId;
    if (shiftId != null && shiftId.isNotEmpty) {
      for (final shift in shiftProvider.todayShifts) {
        if (shift.id == shiftId) {
          return shift;
        }
      }
      for (final shift in shiftProvider.shifts) {
        if (shift.id == shiftId) {
          return shift;
        }
      }
    }

    if (shiftProvider.todayShifts.length == 1) {
      return shiftProvider.todayShifts.first;
    }
    return null;
  }

  void _syncPersistentNotification(
    AttendanceRecord record,
    ShiftProvider shiftProvider, {
    DailyShift? fallbackShift,
  }) {
    if (record.checkIn == null || record.checkOut != null) return;
    final resolvedShift =
        _resolveShiftForNotification(record, shiftProvider) ?? fallbackShift;
    final key =
        '${record.id}|${record.checkIn ?? ''}|${resolvedShift?.id ?? ''}';
    if (_notificationKey == key) return;
    _notificationKey = key;
    PersistentNotificationService.updateCheckInNotification(
      record,
      shift: resolvedShift,
    );
    PersistentNotificationService.updateStoredRecord(
      record,
      shift: resolvedShift,
    );
  }

  Map<String, int> _calculateAttendanceStats(List<AttendanceRecord> recent) {
    int present = 0;
    int late = 0;
    int absent = 0;

    final now = DateTime.now();
    final currentMonth = now.month;
    final currentYear = now.year;

    for (var record in recent) {
      try {
        final recordDate = DateTime.parse(record.date);
        if (recordDate.month == currentMonth &&
            recordDate.year == currentYear) {
          final status = record.status.toLowerCase();
          if (status == 'present') {
            present++;
          } else if (status == 'late') {
            late++;
          } else if (status == 'absent') {
            absent++;
          }
        }
      } catch (e) {
        // Skip invalid dates
        continue;
      }
    }

    return {'present': present, 'late': late, 'absent': absent};
  }

  Future<void> _handleCheckIn() async {
    if (_checkInActionInProgress) {
      debugPrint(
        '[HomeTab] Check-in already in progress, ignoring duplicate tap',
      );
      return;
    }
    _checkInActionInProgress = true;
    debugPrint(
      '[HomeTab] Check-in button pressed - starting GPS check and camera',
    );

    try {
      final shiftProvider = Provider.of<ShiftProvider>(context, listen: false);
      if (shiftProvider.shiftData == null) {
        try {
          await shiftProvider.loadShifts();
        } catch (e) {
          debugPrint('[HomeTab] Failed to load shifts before check-in: $e');
        }
      }

      final isBlocked = shiftProvider.shiftData?.blocked ?? false;
      if (isBlocked) {
        final message =
            shiftProvider.shiftData?.blockedMessage ??
            'Anda tidak dapat melakukan absensi hari ini.';
        if (mounted) {
          ToastHelper.showWarning(context, message);
        }
        return;
      }

      if (_isOffDay(shiftProvider.todayShifts)) {
        if (mounted) {
          ToastHelper.showWarning(context, _buildOffShiftMessage());
        }
        return;
      }

      // Check if user has active leave request
      final requestProvider = Provider.of<RequestProvider>(
        context,
        listen: false,
      );
      final requests = requestProvider.requests;
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);

      LeaveRequest? activeRequest;
      for (final request in requests) {
        final status = request.status.toLowerCase();
        if (status == 'approved' || status == 'berlangsung') {
          try {
            final startDate = DateTime.parse(request.startDate);
            final endDate = DateTime.parse(request.endDate);
            final start = DateTime(
              startDate.year,
              startDate.month,
              startDate.day,
            );
            final end = DateTime(endDate.year, endDate.month, endDate.day);

            if (today.isAfter(start.subtract(const Duration(days: 1))) &&
                today.isBefore(end.add(const Duration(days: 1)))) {
              activeRequest = request;
              break;
            }
          } catch (_) {
            continue;
          }
        }
      }

      if (activeRequest != null) {
        String getTypeLabel(String type) {
          switch (type.toLowerCase()) {
            case 'izin':
              return 'Izin';
            case 'cuti':
              return 'Cuti';
            case 'sakit':
            case 'sick':
              return 'Sakit';
            default:
              return type;
          }
        }

        if (mounted) {
          ToastHelper.showWarning(
            context,
            'Anda sedang dalam ${getTypeLabel(activeRequest.type).toLowerCase()} yang berlangsung. Tidak dapat melakukan check-in saat ini.',
          );
        }
        return;
      }

      final gpsReady = await _ensureGpsActive(promptSettings: true);
      if (!gpsReady) {
        debugPrint('[HomeTab] GPS not ready, will retry after prompt');
        _shouldRetryCheckInAfterGpsPrompt = _gpsPrompted;
        return;
      }
      debugPrint('[HomeTab] GPS ready for check-in');
      _shouldRetryCheckInAfterGpsPrompt = false;

      final attendanceProvider = Provider.of<AttendanceProvider>(
        context,
        listen: false,
      );
      if (attendanceProvider.activeAttendance != null) {
        if (mounted) {
          ToastHelper.showWarning(
            context,
            'Masih ada check-in aktif. Silakan check-out terlebih dahulu.',
          );
        }
        return;
      }

      var todayShifts = shiftProvider.todayShifts;
      var selectedShift = _selectShiftForCheckIn(
        todayShifts,
        attendanceProvider.todayRecords,
      );

      if (todayShifts.isNotEmpty && selectedShift == null) {
        try {
          await shiftProvider.loadShifts();
        } catch (e) {
          debugPrint('[HomeTab] Failed to refresh shifts before check-in: $e');
        }
        todayShifts = shiftProvider.todayShifts;
        selectedShift = _selectShiftForCheckIn(
          todayShifts,
          attendanceProvider.todayRecords,
        );
      }

      if (todayShifts.isEmpty) {
        try {
          await shiftProvider.loadShifts();
        } catch (e) {
          debugPrint(
            '[HomeTab] Failed to refresh shifts (empty) before check-in: $e',
          );
        }
        todayShifts = shiftProvider.todayShifts;
        selectedShift = _selectShiftForCheckIn(
          todayShifts,
          attendanceProvider.todayRecords,
        );
      }

      if (todayShifts.isNotEmpty && selectedShift == null) {
        if (mounted) {
          ToastHelper.showWarning(
            context,
            _isOffDay(todayShifts)
                ? _buildOffShiftMessage()
                : 'Semua shift hari ini sudah selesai.',
          );
        }
        return;
      }

      if (todayShifts.isEmpty) {
        final hasShiftlessRecord = attendanceProvider.todayRecords.any(
          (record) => (record.shiftId == null || record.shiftId!.isEmpty),
        );
        if (hasShiftlessRecord) {
          if (mounted) {
            ToastHelper.showWarning(
              context,
              'Absensi tanpa shift hanya bisa sekali per hari.',
            );
          }
          return;
        }
      }

      if (selectedShift != null) {
        debugPrint(
          '[HomeTab] Using selected shift: ${selectedShift.name} (${selectedShift.id})',
        );
      } else {
        debugPrint('[HomeTab] No shift assigned, will check-in without shift');
      }

      String? checkInReason;
      if (selectedShift != null && mounted) {
        final expectedStart = _calculateExpectedShiftStart(selectedShift);
        if (expectedStart != null) {
          final authProvider = Provider.of<AuthProvider>(
            context,
            listen: false,
          );
          final toleranceMinutes =
              authProvider.user?.site?.lateToleranceMinutes ?? 0;
          final now = DateTime.now();
          final diffMinutes = now.difference(expectedStart).inMinutes;
          if (diffMinutes > toleranceMinutes) {
            final absMinutes = diffMinutes;
            final hours = absMinutes ~/ 60;
            final minutes = absMinutes % 60;
            final durationLabel = hours == 0
                ? '$minutes menit'
                : minutes == 0
                ? '$hours jam'
                : '$hours jam $minutes menit';
            final expectedLabel = _formatTimeHHmm(expectedStart);
            final toleranceLabel = toleranceMinutes > 0
                ? 'melewati toleransi $toleranceMinutes menit'
                : 'melewati jadwal';
            final reason = await _showCheckInReasonDialog(
              context: context,
              title: 'Check-in Terlambat',
              message:
                  'Check-in $toleranceLabel dari jadwal ($expectedLabel). Selisih $durationLabel. Mohon isi keterangan.',
            );
            if (reason == null) {
              return;
            }
            checkInReason = reason;
          }
        }
      }

      debugPrint('[HomeTab] Opening camera for check-in selfie...');

      final photo = await Navigator.push<File>(
        context,
        MaterialPageRoute(
          builder: (_) => const CameraScreen(
            title: 'Ambil Selfie untuk Check-In',
            allowGallery: false,
            preferLowResolution: true,
          ),
        ),
      );

      if (photo != null && mounted) {
        debugPrint('[HomeTab] Photo captured: ${photo.path}');
        debugPrint('[HomeTab] Submitting check-in...');
        try {
          final refreshedPosition = await _resolveCurrentPosition();
          if (refreshedPosition != null) {
            _cacheGpsPosition(refreshedPosition);
          }
          final gpsCoordinates = _consumeRecentGpsCoordinates();
          final success = await attendanceProvider.checkIn(
            photo: photo,
            shiftId: selectedShift?.id,
            checkInReason: checkInReason,
            latitude: gpsCoordinates?['lat'],
            longitude: gpsCoordinates?['lng'],
          );

          if (mounted) {
            debugPrint('[HomeTab] Check-in result: $success');
            if (success) {
              await Future.delayed(const Duration(milliseconds: 100));

              if (mounted) {
                ToastHelper.showSuccess(context, 'Check-in berhasil!');
                debugPrint('[HomeTab] Starting duration timer...');
                final today = attendanceProvider.todayAttendance;
                final shiftProvider = Provider.of<ShiftProvider>(
                  context,
                  listen: false,
                );
                _checkInDateTime = _parseCheckInDateTime(today);
                _startDurationTimer();
                if (today != null) {
                  _syncPersistentNotification(
                    today,
                    shiftProvider,
                    fallbackShift: selectedShift,
                  );
                }
                if (mounted) {
                  setState(() => _selectedShift = null);
                }
              }
            } else {
              if (mounted) {
                ToastHelper.showError(
                  context,
                  attendanceProvider.error ?? 'Check-in gagal',
                );
              }
            }
          }
        } catch (e) {
          debugPrint('[HomeTab] Error during check-in: $e');
          if (mounted) {
            if (e.toString().contains('izin') ||
                e.toString().contains('permission') ||
                e.toString().contains('lokasi') ||
                e.toString().contains('Location')) {
              debugPrint(
                '[HomeTab] Permission error detected, showing guidance dialog',
              );
              await PermissionGuidanceDialog.show(
                context,
                title: 'Izin Lokasi Diperlukan',
                message: e.toString().replaceAll('Exception: ', ''),
              );
            } else {
              ToastHelper.showError(
                context,
                'Terjadi kesalahan saat check-in: $e',
              );
            }
          }
        }
      } else {
        debugPrint('[HomeTab] Photo capture cancelled or widget unmounted');
      }
    } finally {
      _checkInActionInProgress = false;
    }
  }

  Future<void> _handleCheckOut() async {
    if (_checkOutActionInProgress) {
      debugPrint(
        '[HomeTab] Check-out already in progress, ignoring duplicate tap',
      );
      return;
    }
    _checkOutActionInProgress = true;
    debugPrint('[HomeTab] Check-out button pressed');
    try {
      final shouldContinue = await _showCheckoutConfirmationDialog(context);
      if (!shouldContinue) {
        debugPrint('[HomeTab] Check-out cancelled by user confirmation');
        return;
      }

      final gpsReady = await _ensureGpsActive(promptSettings: true);
      if (!gpsReady) {
        return;
      }
      final attendanceProvider = Provider.of<AttendanceProvider>(
        context,
        listen: false,
      );
      final today = attendanceProvider.todayAttendance;
      final checkInDateTime = _parseCheckInDateTime(today);
      if (today != null && (today.shiftId == null || today.shiftId!.isEmpty)) {
        DateTime? recordDate;
        try {
          recordDate = DateTime.parse(today.date);
        } catch (_) {
          recordDate = checkInDateTime != null
              ? DateTime(
                  checkInDateTime.year,
                  checkInDateTime.month,
                  checkInDateTime.day,
                )
              : null;
        }
        if (recordDate != null && !_isSameDay(recordDate, DateTime.now())) {
          if (mounted) {
            ToastHelper.showWarning(
              context,
              'Absensi tanpa shift harus check-out di hari yang sama. Silakan hubungi supervisor jika lewat hari.',
            );
          }
          return;
        }
      }

      // Checkout lebih awal dibiarkan saja (tidak wajib keterangan).
      // Catatan khusus hanya untuk checkout telat (> 2 jam dari jam shift), ditambah otomatis di backend.
      String? earlyCheckoutReason;

      debugPrint('[HomeTab] Opening camera for check-out selfie...');
      final wasTracking = await attendanceProvider.pauseRealtimeTracking();

      // Buka kamera untuk selfie (hanya kamera, tidak boleh galeri)
      final photo = await Navigator.push<File>(
        context,
        MaterialPageRoute(
          builder: (_) => const CameraScreen(
            title: 'Ambil Selfie untuk Check-Out',
            allowGallery: false, // Check-out hanya boleh kamera
            preferLowResolution: true,
          ),
        ),
      );

      if (photo != null && mounted) {
        debugPrint('[HomeTab] Photo captured: ${photo.path}');
        debugPrint('[HomeTab] Submitting check-out...');

        try {
          final refreshedPosition = await _resolveCurrentPosition();
          if (refreshedPosition != null) {
            _cacheGpsPosition(refreshedPosition);
          }
          final gpsCoordinates = _consumeRecentGpsCoordinates();
          final success = await attendanceProvider.checkOut(
            photo: photo,
            shiftId: today?.shiftId,
            earlyCheckoutReason: earlyCheckoutReason,
            latitude: gpsCoordinates?['lat'],
            longitude: gpsCoordinates?['lng'],
          );

          if (mounted) {
            debugPrint('[HomeTab] Check-out result: $success');
            if (success) {
              // loadAttendance sudah dipanggil di checkOut() method, tidak perlu dipanggil lagi
              // Tunggu sebentar untuk memastikan loading state sudah di-reset
              await Future.delayed(const Duration(milliseconds: 100));

              if (mounted) {
                ToastHelper.showSuccess(context, 'Check-out berhasil!');
                // Stop timer immediately after successful check-out
                debugPrint('[HomeTab] Stopping duration timer after check-out');
                _durationTimer?.cancel();
                // Parse check-in untuk menghitung total durasi (tidak perlu timer lagi)
                final updatedToday = attendanceProvider.todayAttendance;
                _checkInDateTime = updatedToday != null
                    ? _parseCheckInDateTime(updatedToday)
                    : null;
                // Update duration notifier dengan total durasi (fixed)
                if (_checkInDateTime != null && updatedToday != null) {
                  final checkOutDateTime = _parseCheckOutDateTime(updatedToday);
                  final totalDuration = _formatDuration(
                    _checkInDateTime,
                    checkOutDateTime: checkOutDateTime,
                  );
                  _setDuration(totalDuration);
                }
                try {
                  await Provider.of<ShiftProvider>(
                    context,
                    listen: false,
                  ).loadShifts();
                } catch (e) {
                  debugPrint(
                    '[HomeTab] Failed to refresh shifts after check-out: $e',
                  );
                }
                if (mounted) {
                  setState(() => _selectedShift = null);
                }
              }
            } else {
              if (mounted) {
                ToastHelper.showError(
                  context,
                  attendanceProvider.error ?? 'Check-out gagal',
                );
              }
              if (wasTracking) {
                await attendanceProvider.syncRealtimeTracking();
              }
            }
          }
        } catch (e) {
          debugPrint('[HomeTab] Error during check-out: $e');
          if (mounted) {
            ToastHelper.showError(
              context,
              'Terjadi kesalahan saat check-out: $e',
            );
          }
          if (wasTracking) {
            await attendanceProvider.syncRealtimeTracking();
          }
        }
      } else {
        debugPrint('[HomeTab] Photo capture cancelled or widget unmounted');
        if (wasTracking) {
          await attendanceProvider.syncRealtimeTracking();
        }
      }
    } finally {
      _checkOutActionInProgress = false;
    }
  }

  Future<void> _handleStartBreak() async {
    final attendanceProvider = Provider.of<AttendanceProvider>(
      context,
      listen: false,
    );
    final result = await attendanceProvider.startBreak();
    if (!mounted) {
      return;
    }

    final message =
        result['message']?.toString() ??
        attendanceProvider.error ??
        'Gagal memulai istirahat';

    if (result['success'] == true) {
      ToastHelper.showSuccess(context, message);
      return;
    }

    ToastHelper.showError(context, message);
  }

  Future<void> _handleEndBreak() async {
    final attendanceProvider = Provider.of<AttendanceProvider>(
      context,
      listen: false,
    );

    String? reason;
    if (_needsBreakEndReason(attendanceProvider.breakState)) {
      reason = await _showBreakReasonDialog(
        context: context,
        title: 'Selesaikan Istirahat',
        message:
            'Durasi istirahat melewati batas. Mohon isi keterangan sebelum melanjutkan kerja.',
      );
      if (reason == null) {
        return;
      }
    }

    var result = await attendanceProvider.endBreak(reason: reason);
    var message =
        result['message']?.toString() ??
        attendanceProvider.error ??
        'Gagal menyelesaikan istirahat';

    if (result['success'] != true &&
        reason == null &&
        _shouldPromptBreakReasonFromMessage(message)) {
      reason = await _showBreakReasonDialog(
        context: context,
        title: 'Keterangan Istirahat Diperlukan',
        message: message,
      );
      if (reason == null) {
        return;
      }

      result = await attendanceProvider.endBreak(reason: reason);
      message =
          result['message']?.toString() ??
          attendanceProvider.error ??
          'Gagal menyelesaikan istirahat';
    }

    if (!mounted) {
      return;
    }

    if (result['success'] == true) {
      ToastHelper.showSuccess(context, message);
      return;
    }

    ToastHelper.showError(context, message);
  }

  void _startDurationTimer() {
    _durationTimer?.cancel();
    if (_checkInDateTime == null) {
      debugPrint('[HomeTab] Cannot start timer: _checkInDateTime is null');
      return;
    }

    debugPrint('[HomeTab] Starting duration timer from: $_checkInDateTime');
    // Timer hanya berjalan saat app aktif (foreground)
    // Saat app di background, timer akan di-stop dan durasi akan dihitung ulang saat resume
    debugPrint('[HomeTab] ⏰ Starting duration timer');
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }

      // Optimasi: hanya cek database setiap 5 detik untuk mengurangi beban
      // Tapi update UI setiap detik untuk smooth animation
      final shouldCheckDatabase = timer.tick % 5 == 0;

      if (shouldCheckDatabase) {
        // Cek data dari database setiap 5 detik (lebih efisien)
        final attendanceProvider = Provider.of<AttendanceProvider>(
          context,
          listen: false,
        );
        final today = attendanceProvider.todayAttendance;

        // Check if still checked in
        if (today == null || today.checkIn == null || today.checkOut != null) {
          // Check-out detected, stop timer
          debugPrint('[HomeTab] Check-out detected, stopping timer');
          _checkInDateTime = null;
          timer.cancel();
          if (mounted) {
            // Update dengan total durasi jika sudah check-out
            if (today != null && today.checkOut != null) {
              final checkInDateTime = _parseCheckInDateTime(today);
              if (checkInDateTime != null) {
                final checkOutDateTime = _parseCheckOutDateTime(today);
                final totalDuration = _formatDuration(
                  checkInDateTime,
                  checkOutDateTime: checkOutDateTime,
                );
                _setDuration(totalDuration);
              }
            } else {
              _setDuration('00 : 00 : 00');
            }
          }
          return;
        }

        // Update check-in datetime jika berubah (jarang terjadi)
        final newCheckInDateTime = _parseCheckInDateTime(today);
        if (newCheckInDateTime != null &&
            newCheckInDateTime != _checkInDateTime) {
          debugPrint(
            '[HomeTab] Check-in datetime updated from database: $newCheckInDateTime',
          );
          _checkInDateTime = newCheckInDateTime;
        }
      }

      // Update UI setiap detik (ringan, hanya perhitungan waktu)
      // Tidak perlu akses database setiap detik, cukup hitung dari _checkInDateTime yang sudah ada
      if (mounted && _checkInDateTime != null) {
        final duration = _formatDuration(_checkInDateTime);
        _setDuration(duration);
      }
    });
  }

  /// Skeleton untuk kartu Kehadiran Hari Ini (saat loading)
  Widget _buildAttendanceCardSkeleton(BuildContext context) {
    // Bentuknya mengikuti kartu absen: judul, baris shift, tombol utama
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey[200]!),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ShimmerLoading(
            width: 160,
            height: 14,
            borderRadius: BorderRadius.circular(6),
          ),
          const SizedBox(height: 8),
          ShimmerLoading(
            width: 140,
            height: 20,
            borderRadius: BorderRadius.circular(6),
          ),
          const SizedBox(height: 16),
          ShimmerLoading(
            width: 220,
            height: 16,
            borderRadius: BorderRadius.circular(6),
          ),
          const SizedBox(height: 16),
          ShimmerLoading(
            width: double.infinity,
            height: 52,
            borderRadius: BorderRadius.circular(12),
          ),
        ],
      ),
    );
  }

  Widget _buildTodaysAttendanceCard(BuildContext context) {
    return Consumer<AttendanceProvider>(
      builder: (context, attendanceProvider, _) {
        final today = attendanceProvider.todayAttendance;

        // Tampilkan skeleton saat loading dan belum ada data hari ini
        if (attendanceProvider.isLoading && today == null) {
          return _buildAttendanceCardSkeleton(context);
        }

        final hasCheckedIn = today?.checkIn != null;
        final hasCheckedOut = today?.checkOut != null;

        final shiftProvider = Provider.of<ShiftProvider>(context);
        final todayShifts = shiftProvider.todayShifts;
        final todayRecords = attendanceProvider.todayRecords;
        final shiftItems = _buildShiftStatusList(todayShifts, todayRecords);
        final totalWorkDuration = _calculateTotalWorkDuration(todayRecords);
        final totalWorkLabel = _formatTotalDuration(totalWorkDuration);
        final completedCount = shiftItems
            .where((item) => item.status == "Selesai")
            .length;
        final inProgressCount = shiftItems
            .where((item) => item.status == "Sedang bekerja")
            .length;
        final totalShiftCount = shiftItems.length;
        final noShiftToday = todayShifts.isEmpty && todayRecords.isEmpty;
        final offDayPendingCheckout =
            _isOffDay(todayShifts) &&
            _findOpenAttendanceFromHistory(attendanceProvider) != null;

        // Check and start timer when attendance data changes
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || _isDisposed) {
            return;
          }
          _checkAndStartTimer(attendanceProvider);
        });

        final isBlocked = shiftProvider.shiftData?.blocked ?? false;
        // todayAttendance hanya berisi absen yang masih terbuka. Hari dianggap selesai bila sudah ada
        // absen yang ditutup dan tidak ada shift tersisa (server menolak check-in ulang: tanpa shift
        // hanya sekali sehari, shift yang sudah check-out tidak bisa check-in lagi).
        final completedToday = todayRecords
            .where((r) => r.checkIn != null && r.checkOut != null)
            .toList();
        final dayComplete =
            !hasCheckedIn &&
            completedToday.isNotEmpty &&
            (todayShifts.isEmpty ||
                _getRemainingShifts(todayShifts, todayRecords).isEmpty);
        final breakOpen =
            attendanceProvider.breakState?.activeSession != null ||
            (today?.breakStatus ?? '').toLowerCase() == 'active';
        // QR ditawarkan bila site punya layar absen; tidak saat istirahat masih terbuka
        final showQrButton =
            attendanceProvider.qrAttendanceEnabled &&
            !offDayPendingCheckout &&
            !isBlocked &&
            !hasCheckedOut &&
            !dayComplete &&
            !(hasCheckedIn && breakOpen);

        // Kartu absen hari ini: status, shift, lalu satu aksi utama (Check-In atau Check-Out)
        return Container(
          margin: const EdgeInsets.only(bottom: 16),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.grey[200]!),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildTodayHeader(
                hasCheckedIn: hasCheckedIn || dayComplete,
                hasCheckedOut: hasCheckedOut || dayComplete,
              ),
              const SizedBox(height: 12),
              if (dayComplete)
                _buildWorkingTimeBlock(
                  attendanceProvider,
                  completedToday.last,
                  hasCheckedOut: true,
                )
              else if (hasCheckedIn)
                _buildWorkingTimeBlock(
                  attendanceProvider,
                  today,
                  hasCheckedOut: hasCheckedOut,
                )
              else if (!offDayPendingCheckout)
                _buildShiftSelectionInCard(context),
              const SizedBox(height: 16),
              if (offDayPendingCheckout)
                _buildDisabledCheckInButton(
                  context,
                  label: 'Check-In',
                  message:
                      'Shift hari ini OFF. Hubungi supervisor untuk koreksi check-out yang tertunda.',
                )
              else if (dayComplete)
                _buildDoneTodayRow()
              else if (!hasCheckedIn)
                _buildCheckInButton(context)
              else if (!hasCheckedOut)
                _buildActiveAttendanceActionSection(
                  context,
                  attendanceProvider: attendanceProvider,
                  todayShifts: todayShifts,
                  today: today,
                )
              else
                _buildDoneTodayRow(),
              if (showQrButton) ...[
                const SizedBox(height: 8),
                _buildQrAttendanceButton(checkOut: hasCheckedIn),
              ],
              if (!hasCheckedOut && !offDayPendingCheckout && !dayComplete) ...[
                const SizedBox(height: 14),
                _buildGeofenceHint(context, forCheckOut: hasCheckedIn),
              ],
              const SizedBox(height: 12),
              const _CheckpointProgressCard(),
              // Rincian shift hanya saat bekerja atau bila shift lebih dari satu (tidak mengulang info)
              if (hasCheckedIn || totalShiftCount > 1) ...[
                const SizedBox(height: 4),
                _buildShiftDetailsSection(
                  shiftItems: shiftItems,
                  completedCount: completedCount,
                  inProgressCount: inProgressCount,
                  totalShiftCount: totalShiftCount,
                  noShiftToday: noShiftToday,
                  totalWorkLabel: totalWorkLabel,
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  /// Judul kartu: tanggal, "Absen hari ini", dan status singkat hari ini.
  Widget _buildTodayHeader({
    required bool hasCheckedIn,
    required bool hasCheckedOut,
  }) {
    final String status;
    final Color statusColor;
    if (!hasCheckedIn) {
      status = 'Belum check-in';
      statusColor = Colors.grey[700]!;
    } else if (!hasCheckedOut) {
      status = 'Sedang bekerja';
      statusColor = Colors.green[900]!;
    } else {
      status = 'Selesai';
      statusColor = Colors.grey[700]!;
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                DateFormat('EEEE, d MMMM yyyy', 'id_ID').format(DateTime.now()),
                style: TextStyle(fontSize: 13, color: Colors.grey[700]),
              ),
              const SizedBox(height: 2),
              Text(
                'Absen hari ini',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: Colors.grey[900],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: statusColor.withOpacity(0.1),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            status,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: statusColor,
            ),
          ),
        ),
      ],
    );
  }

  /// Waktu bekerja berjalan, jam masuk/pulang, dan lokasi yang tercatat saat absen.
  Widget _buildWorkingTimeBlock(
    AttendanceProvider attendanceProvider,
    AttendanceRecord? today, {
    required bool hasCheckedOut,
  }) {
    final checkInLocation =
        today?.checkInLocation ?? (hasCheckedOut ? null : today?.location);
    final checkOutLocation = hasCheckedOut
        ? (today?.checkOutLocation ?? today?.location)
        : null;
    final trackingText = !attendanceProvider.isTrackingEnabledByPolicy
        ? 'Pelacakan lokasi tidak aktif di site ini.'
        : attendanceProvider.isRealtimeTracking
        ? 'Lokasi dikirim berkala selama bekerja.'
        : 'Pelacakan lokasi aktif, menunggu lokasi pertama terkirim.';
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.grey[50],
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey[200]!),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            hasCheckedOut ? 'Total waktu kerja' : 'Waktu bekerja',
            style: TextStyle(fontSize: 13, color: Colors.grey[700]),
          ),
          const SizedBox(height: 2),
          // Hanya angka durasi yang dibangun ulang tiap detik
          ValueListenableBuilder<String>(
            valueListenable: _durationNotifier,
            builder: (context, duration, _) {
              final value = hasCheckedOut
                  ? _formatDuration(
                      _parseCheckInDateTime(today),
                      checkOutDateTime: _parseCheckOutDateTime(today),
                    )
                  : duration;
              return Text(
                value,
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                  color: Colors.grey[900],
                  fontFeatures: const [ui.FontFeature.tabularFigures()],
                ),
              );
            },
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _buildTimeCell('Masuk', today?.checkIn, checkInLocation),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildTimeCell(
                  'Pulang',
                  today?.checkOut,
                  checkOutLocation,
                ),
              ),
            ],
          ),
          if (!hasCheckedOut) ...[
            const SizedBox(height: 10),
            Text(
              trackingText,
              style: TextStyle(fontSize: 12, color: Colors.grey[700]),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildTimeCell(String label, String? time, Location? location) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(fontSize: 12, color: Colors.grey[700])),
        const SizedBox(height: 2),
        Text(
          time ?? '-',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: Colors.grey[900],
          ),
        ),
        if (location != null)
          Text(
            '${location.lat.toStringAsFixed(5)}, ${location.lng.toStringAsFixed(5)}',
            style: TextStyle(fontSize: 11, color: Colors.grey[700]),
          ),
      ],
    );
  }

  Widget _buildDoneTodayRow() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.green[50],
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.check_circle, color: Colors.green[700], size: 20),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              'Absen hari ini selesai',
              style: TextStyle(
                color: Colors.green[900],
                fontWeight: FontWeight.w600,
                fontSize: 15,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Tombol kedua di bawah aksi utama: absen dengan QR dari layar absen.
  Widget _buildQrAttendanceButton({required bool checkOut}) {
    return OutlinedButton.icon(
      onPressed: () => _openQrAttendance(checkOut: checkOut),
      icon: const Icon(Icons.qr_code_scanner, size: 20),
      label: Text(checkOut ? 'Check-out dengan QR' : 'Check-in dengan QR'),
      style: OutlinedButton.styleFrom(
        foregroundColor: Colors.blue[800],
        side: BorderSide(color: Colors.blue[300]!),
        minimumSize: const Size.fromHeight(48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
    );
  }

  Future<void> _openQrAttendance({required bool checkOut}) async {
    final attendanceProvider = Provider.of<AttendanceProvider>(
      context,
      listen: false,
    );
    final shiftProvider = Provider.of<ShiftProvider>(context, listen: false);
    final message = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => AttendanceQrScannerScreen(checkOut: checkOut),
      ),
    );
    if (!mounted || message == null) return;
    ToastHelper.showSuccess(context, message);
    final today = attendanceProvider.todayAttendance;
    if (checkOut) {
      _durationTimer?.cancel();
      _checkInDateTime = today != null ? _parseCheckInDateTime(today) : null;
      if (_checkInDateTime != null && today != null) {
        _setDuration(
          _formatDuration(
            _checkInDateTime,
            checkOutDateTime: _parseCheckOutDateTime(today),
          ),
        );
      }
    } else {
      _checkInDateTime = _parseCheckInDateTime(today);
      _startDurationTimer();
      if (today != null) {
        _syncPersistentNotification(today, shiftProvider);
      }
    }
    try {
      await shiftProvider.loadShifts();
    } catch (e) {
      debugPrint('[HomeTab] Gagal memuat shift setelah absen QR: $e');
    }
  }

  /// Rincian shift hari ini (jam shift, masuk/pulang, istirahat).
  Widget _buildShiftDetailsSection({
    required List<_ShiftStatusItem> shiftItems,
    required int completedCount,
    required int inProgressCount,
    required int totalShiftCount,
    required bool noShiftToday,
    required String totalWorkLabel,
  }) {
    return ValueListenableBuilder<DateTime>(
      valueListenable: _shiftClockNotifier,
      builder: (context, now, _) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.grey[50],
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey[200]!),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Rincian shift hari ini',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: Colors.grey[800],
              ),
            ),
            const SizedBox(height: 10),
            ...shiftItems.map((item) {
              final status = item.status;
              final statusColor = status == 'Selesai'
                  ? Colors.green[600]
                  : status == 'Sedang bekerja'
                  ? Colors.blue[600]
                  : Colors.orange[700];
              final breakStages = _buildShiftTimelineStages(
                item.shift,
                item.record,
                now,
              );
              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.grey[200]!),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            item.title,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: Colors.grey[900],
                            ),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: statusColor?.withOpacity(0.12),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: statusColor ?? Colors.grey,
                            ),
                          ),
                          child: Text(
                            status,
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: statusColor,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      item.range,
                      style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Text(
                          "Masuk: ${item.checkIn}",
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.grey[800],
                            fontFamily: 'monospace',
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          "Pulang: ${item.checkOut}",
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.grey[800],
                            fontFamily: 'monospace',
                          ),
                        ),
                      ],
                    ),
                    if (breakStages.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.blueGrey[50],
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.blueGrey[100]!),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Timeline shift & istirahat',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                color: Colors.blueGrey[700],
                                letterSpacing: 0.2,
                              ),
                            ),
                            const SizedBox(height: 8),
                            ...breakStages.map((stage) {
                              return Container(
                                margin: const EdgeInsets.only(bottom: 6),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 8,
                                ),
                                decoration: BoxDecoration(
                                  color: stage.color.withOpacity(0.08),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: stage.color.withOpacity(0.25),
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      stage.icon,
                                      size: 16,
                                      color: stage.color,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            stage.label,
                                            style: TextStyle(
                                              fontSize: 11,
                                              fontWeight: FontWeight.w700,
                                              color: Colors.grey[900],
                                            ),
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            stage.range,
                                            style: TextStyle(
                                              fontSize: 10,
                                              color: Colors.grey[600],
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 4,
                                      ),
                                      decoration: BoxDecoration(
                                        color: stage.color.withOpacity(0.12),
                                        borderRadius: BorderRadius.circular(20),
                                      ),
                                      child: Text(
                                        stage.status,
                                        style: TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.bold,
                                          color: stage.color,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            }),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              );
            }).toList(),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: completedCount == totalShiftCount && totalShiftCount > 0
                    ? Colors.green[50]
                    : inProgressCount > 0
                    ? Colors.blue[50]
                    : Colors.orange[50],
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color:
                      completedCount == totalShiftCount && totalShiftCount > 0
                      ? Colors.green[200]!
                      : inProgressCount > 0
                      ? Colors.blue[200]!
                      : Colors.orange[200]!,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    completedCount == totalShiftCount && totalShiftCount > 0
                        ? Icons.check_circle
                        : inProgressCount > 0
                        ? Icons.timelapse
                        : Icons.info_outline,
                    size: 16,
                    color:
                        completedCount == totalShiftCount && totalShiftCount > 0
                        ? Colors.green[700]
                        : inProgressCount > 0
                        ? Colors.blue[700]
                        : Colors.orange[700],
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      noShiftToday
                          ? 'Belum ada shift hari ini.'
                          : completedCount == totalShiftCount
                          ? 'Semua shift hari ini selesai.'
                          : 'Selesai $completedCount dari $totalShiftCount shift.',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: Colors.grey[800],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Total jam kerja',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: Colors.grey[700],
                  ),
                ),
                Text(
                  totalWorkLabel,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Colors.blue[800],
                    letterSpacing: 1.0,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAllShiftsCompletedBanner() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.green[50],
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.green[200]!),
      ),
      child: Row(
        children: [
          Icon(Icons.check_circle, color: Colors.green[700], size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Semua shift hari ini sudah selesai',
              style: TextStyle(
                color: Colors.green[900],
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOffShiftBanner() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.red[50],
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.red[200]!),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.block, color: Colors.red[700], size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _buildOffShiftMessage(),
              style: TextStyle(
                color: Colors.red[900],
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildShiftQuickActionsSkeleton() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ShimmerLoading(
            width: 120,
            height: 14,
            borderRadius: BorderRadius.circular(6),
          ),
          const SizedBox(height: 12),
          ShimmerLoading(
            width: double.infinity,
            height: 44,
            borderRadius: BorderRadius.circular(10),
          ),
          const SizedBox(height: 12),
          ShimmerLoading(
            width: double.infinity,
            height: 44,
            borderRadius: BorderRadius.circular(10),
          ),
        ],
      ),
    );
  }

  Widget _buildShiftQuickActions(BuildContext context) {
    return Consumer<ShiftProvider>(
      builder: (context, shiftProvider, _) {
        if (shiftProvider.isLoading) {
          return _buildShiftQuickActionsSkeleton();
        }
        final user = Provider.of<AuthProvider>(context, listen: false).user;
        final showPatrol = isSecurityPosition(user);

        return Material(
          color: Colors.white,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: Colors.grey[200]!),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_isOffDay(shiftProvider.todayShifts))
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                  child: _buildOffShiftBanner(),
                ),
              _buildShortcutRow(
                icon: Icons.calendar_month_outlined,
                label: 'Jadwal shift saya',
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const MyShiftScreen()),
                  );
                },
              ),
              if (showPatrol) ...[
                Divider(height: 1, indent: 56, color: Colors.grey[200]),
                _buildShortcutRow(
                  icon: Icons.qr_code_2,
                  label: 'Patroli',
                  subtitle: 'Scan stiker titik patroli di site',
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const PatroliScreen()),
                    );
                  },
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _buildShortcutRow({
    required IconData icon,
    required String label,
    String? subtitle,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Icon(icon, color: Colors.blue[700], size: 24),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Colors.grey[900],
                      ),
                    ),
                    if (subtitle != null)
                      Text(
                        subtitle,
                        style: TextStyle(fontSize: 12, color: Colors.grey[700]),
                      ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: Colors.grey[600]),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildShiftSelectionInCard(BuildContext context) {
    return Consumer2<ShiftProvider, AttendanceProvider>(
      builder: (context, shiftProvider, attendanceProvider, _) {
        final activeRecord = attendanceProvider.todayAttendance;
        if (activeRecord != null &&
            activeRecord.checkIn != null &&
            activeRecord.checkOut == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            _syncPersistentNotification(activeRecord, shiftProvider);
          });
        }
        final isBlocked = shiftProvider.shiftData?.blocked ?? false;
        final blockedMessage =
            shiftProvider.shiftData?.blockedMessage ??
            'Anda tidak dapat melakukan absensi hari ini.';
        if (isBlocked) {
          return Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.orange[50],
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.orange[200]!, width: 1.5),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.warning_amber_rounded,
                  color: Colors.orange[700],
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    blockedMessage,
                    style: TextStyle(color: Colors.orange[900], fontSize: 12),
                  ),
                ),
              ],
            ),
          );
        }
        final todayShifts = shiftProvider.todayShifts;
        final remainingShifts = _getRemainingShifts(
          todayShifts,
          attendanceProvider.todayRecords,
        );
        final allCompleted = todayShifts.isNotEmpty && remainingShifts.isEmpty;

        if (todayShifts.isEmpty) {
          // Tidak ada shift yang di-assign dan tidak ada shift template
          // Tampilkan info bahwa absen bisa dilakukan tanpa shift
          return Row(
            children: [
              Icon(Icons.schedule, size: 18, color: Colors.grey[700]),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Tidak ada shift terjadwal hari ini. Absen tetap bisa tanpa shift.',
                  style: TextStyle(fontSize: 14, color: Colors.grey[800]),
                ),
              ),
            ],
          );
        }

        if (todayShifts.length == 1) {
          final todayShift = todayShifts.first;
          final shiftCard = Row(
            children: [
              Icon(Icons.schedule, size: 18, color: Colors.grey[700]),
              const SizedBox(width: 8),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: todayShift.name,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: Colors.grey[900],
                        ),
                      ),
                      TextSpan(
                        text:
                            '  ${todayShift.startTime} - ${todayShift.endTime}',
                        style: TextStyle(color: Colors.grey[800]),
                      ),
                    ],
                  ),
                  style: const TextStyle(fontSize: 15),
                ),
              ),
            ],
          );

          if (!allCompleted) {
            return shiftCard;
          }

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildAllShiftsCompletedBanner(),
              const SizedBox(height: 6),
              shiftCard,
            ],
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (allCompleted) _buildAllShiftsCompletedBanner(),
            if (allCompleted) const SizedBox(height: 6),
            ...todayShifts.map((shift) {
              final shiftColor = shift.color != null
                  ? Color(
                      int.parse(
                        'FF${shift.color!.replaceAll('#', '')}',
                        radix: 16,
                      ),
                    )
                  : Colors.blue;
              return Container(
                margin: const EdgeInsets.only(bottom: 6),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.blueGrey[100]!),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: shiftColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${shift.name} (${shift.code})',
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                          Text(
                            '${shift.startTime} - ${shift.endTime}',
                            style: TextStyle(
                              color: Colors.grey[700],
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            }).toList(),
            const SizedBox(height: 6),
            Text(
              'Shift dipilih otomatis berdasarkan jam check-in. Jika ada overlap, hubungi supervisor.',
              style: TextStyle(
                fontSize: 11,
                color: Colors.blueGrey[700],
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        );
      },
    );
  }

  String? _resolvePlacementName(String? siteName) {
    final trimmed = siteName?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      return null;
    }
    return trimmed;
  }

  String _buildUserDetailLine(String? title, String? siteName) {
    final safeTitle = (title != null && title.trim().isNotEmpty)
        ? title.trim()
        : 'Employee';
    final placementName = _resolvePlacementName(siteName);
    if (placementName == null) {
      return safeTitle;
    }
    return '$safeTitle \u2022 $placementName';
  }

  String _getGeofenceHintText(
    BuildContext context, {
    required bool forCheckOut,
  }) {
    final user = Provider.of<AuthProvider>(context, listen: false).user;
    final site = user?.site;
    final radius = site?.maxRadiusMeters;
    final hasGeofence =
        site?.latitude != null && site?.longitude != null && radius != null;
    final actionLabel = forCheckOut ? 'check-out' : 'check-in';

    if (hasGeofence) {
      final placementName = _resolvePlacementName(site?.name);
      final locationLabel = placementName ?? 'lokasi penempatan';
      return 'Untuk $actionLabel, Anda harus berada dalam radius $radius\u00A0m dari $locationLabel. GPS harus aktif.';
    }

    return 'Untuk $actionLabel, pastikan Anda berada di lokasi penempatan. GPS harus aktif.';
  }

  Widget _buildGeofenceHint(BuildContext context, {required bool forCheckOut}) {
    final message = _getGeofenceHintText(context, forCheckOut: forCheckOut);
    final user = Provider.of<AuthProvider>(context, listen: false).user;
    final site = user?.site;
    final latitude = site?.latitude;
    final longitude = site?.longitude;
    final radius = site?.maxRadiusMeters;
    final hasCoordinates = latitude != null && longitude != null;
    final rawPhotoUrl = user?.photoUrl;
    final resolvedPhotoUrl =
        (rawPhotoUrl != null && rawPhotoUrl.trim().isNotEmpty)
        ? ApiConfig.getImageUrl(rawPhotoUrl)
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(Icons.gps_fixed, size: 16, color: Colors.grey[700]),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.35,
                  color: Colors.grey[800],
                ),
              ),
            ),
          ],
        ),
        if (hasCoordinates)
          _buildGeofenceMapPreview(
            latitude: latitude!,
            longitude: longitude!,
            radiusMeters: radius,
            siteName: site?.name,
            userName: user?.name,
            userPhotoUrl: resolvedPhotoUrl,
          ),
      ],
    );
  }

  double _zoomForRadius(int? radiusMeters) {
    if (radiusMeters == null) return 16;
    if (radiusMeters >= 2000) return 14;
    if (radiusMeters >= 1000) return 15;
    if (radiusMeters >= 500) return 15.5;
    return 16.5;
  }

  Widget _buildGeofenceMapPreview({
    required double latitude,
    required double longitude,
    int? radiusMeters,
    String? siteName,
    String? userName,
    String? userPhotoUrl,
  }) {
    final target = LatLng(latitude, longitude);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          _isDisposed ||
          _isMapDisposed ||
          _appLifecycleState != AppLifecycleState.resumed) {
        return;
      }
      final previousTarget = _geofenceSitePosition;
      final isSameTarget =
          previousTarget != null &&
          previousTarget.latitude == target.latitude &&
          previousTarget.longitude == target.longitude;
      if (!isSameTarget || _geofenceRadiusMeters != radiusMeters) {
        _mapUserInteracted = false;
      }
      _geofenceSitePosition = target;
      _geofenceRadiusMeters = radiusMeters;
      _loadCurrentLocationForMap();
      final safeUserName = (userName != null && userName.trim().isNotEmpty)
          ? userName.trim()
          : 'User';
      _updateUserMarkerIcon(displayName: safeUserName, photoUrl: userPhotoUrl);
      _tryFitGeofenceCamera();
    });
    final displayName = (siteName != null && siteName.trim().isNotEmpty)
        ? siteName.trim()
        : 'Lokasi Penempatan';
    final circles = <Circle>{};

    if (radiusMeters != null) {
      circles.add(
        Circle(
          circleId: const CircleId('site_radius'),
          center: target,
          radius: radiusMeters.toDouble(),
          strokeWidth: 2,
          strokeColor: Colors.orange[700]!,
          fillColor: Colors.orange[200]!.withOpacity(0.3),
        ),
      );
    }

    final markers = <Marker>{
      Marker(
        markerId: const MarkerId('site_marker'),
        position: target,
        infoWindow: InfoWindow(title: displayName),
      ),
      if (_currentMapPosition != null)
        Marker(
          markerId: const MarkerId('user_marker'),
          position: _currentMapPosition!,
          infoWindow: const InfoWindow(title: 'Lokasi Kamu'),
          icon:
              _userMarkerIcon ??
              BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
          anchor: const Offset(0.5, 0.5),
          zIndex: 2,
        ),
    };

    return Container(
      height: 170,
      margin: const EdgeInsets.only(top: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.grey[300]!),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: GoogleMap(
          initialCameraPosition: CameraPosition(
            target: target,
            zoom: _zoomForRadius(radiusMeters),
          ),
          onMapCreated: (controller) {
            if (_isMapDisposed) {
              controller.dispose();
              return;
            }
            _geofenceMapController = controller;
            _tryFitGeofenceCamera();
          },
          onCameraMoveStarted: () {
            if (_isAutoFittingMap) {
              return;
            }
            _mapUserInteracted = true;
          },
          markers: markers,
          circles: circles,
          mapType: MapType.normal,
          liteModeEnabled: false,
          myLocationEnabled: false,
          myLocationButtonEnabled: false,
          zoomControlsEnabled: false,
          compassEnabled: true,
          rotateGesturesEnabled: true,
          scrollGesturesEnabled: true,
          tiltGesturesEnabled: true,
          zoomGesturesEnabled: true,
          mapToolbarEnabled: false,
          gestureRecognizers: {
            Factory<OneSequenceGestureRecognizer>(
              () => EagerGestureRecognizer(),
            ),
          },
        ),
      ),
    );
  }

  Widget _buildDisabledCheckInButton(
    BuildContext context, {
    required String label,
    String? message,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ElevatedButton(
          onPressed: null,
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.grey[400],
            foregroundColor: Colors.white70,
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            elevation: 0,
            disabledBackgroundColor: Colors.grey[400],
            disabledForegroundColor: Colors.white70,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.login, size: 20),
              const SizedBox(width: 8),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
        if (message != null) ...[
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.red[600],
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildCheckInButton(BuildContext context) {
    return Consumer<ShiftProvider>(
      builder: (context, shiftProvider, _) {
        return Consumer<AttendanceProvider>(
          builder: (context, attendanceProvider, _) {
            final isLoading = attendanceProvider.isLoading;
            final isBlocked = shiftProvider.shiftData?.blocked ?? false;
            final isDisabled = isLoading || isBlocked;

            if (isLoading) {
              return Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 14),
                decoration: BoxDecoration(
                  color: Colors.blue[300],
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Center(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            Colors.white,
                          ),
                        ),
                      ),
                      SizedBox(width: 12),
                      Text(
                        'Memproses Check-In...',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }

            return ElevatedButton(
              onPressed: isDisabled ? null : _handleCheckIn,
              style: ElevatedButton.styleFrom(
                backgroundColor: isDisabled
                    ? Colors.grey[400]
                    : Colors.blue[700],
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                elevation: isDisabled ? 0 : 2,
                disabledBackgroundColor: Colors.grey[400],
                disabledForegroundColor: Colors.white70,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.login,
                    size: 20,
                    color: isDisabled ? Colors.white70 : Colors.white,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    isBlocked ? 'Check-in diblokir' : 'Check-In',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: isDisabled ? Colors.white70 : Colors.white,
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildCheckOutButton(BuildContext context) {
    return Consumer<AttendanceProvider>(
      builder: (context, attendanceProvider, _) {
        final isLoading = attendanceProvider.isLoading;
        final today = attendanceProvider.todayAttendance;
        final hasCheckedOut = today?.checkOut != null;

        // Disable jika sudah check-out atau sedang loading
        final isDisabled = hasCheckedOut || isLoading;

        if (isLoading) {
          return Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 14),
            decoration: BoxDecoration(
              color: Colors.blue[300],
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Center(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                    ),
                  ),
                  SizedBox(width: 12),
                  Text(
                    'Memproses Check-Out...',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        return ElevatedButton(
          onPressed: isDisabled ? null : _handleCheckOut,
          style: ElevatedButton.styleFrom(
            backgroundColor: isDisabled ? Colors.grey[400] : Colors.blue[700],
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            elevation: isDisabled ? 0 : 2,
            disabledBackgroundColor: Colors.grey[400],
            disabledForegroundColor: Colors.white70,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.logout,
                size: 20,
                color: isDisabled ? Colors.white70 : Colors.white,
              ),
              const SizedBox(width: 8),
              Text(
                hasCheckedOut ? 'Sudah Check-Out' : 'Check-Out',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: isDisabled ? Colors.white70 : Colors.white,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildBreakActionButton({
    required String label,
    required IconData icon,
    required Color color,
    required String loadingLabel,
    required VoidCallback? onPressed,
    bool isLoading = false,
  }) {
    if (isLoading) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: color.withOpacity(0.75),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Center(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const SizedBox(
                height: 20,
                width: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                loadingLabel,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return ElevatedButton(
      onPressed: onPressed,
      style: ElevatedButton.styleFrom(
        backgroundColor: onPressed == null ? Colors.grey[400] : color,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        elevation: onPressed == null ? 0 : 2,
        disabledBackgroundColor: Colors.grey[400],
        disabledForegroundColor: Colors.white70,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            icon,
            size: 20,
            color: onPressed == null ? Colors.white70 : Colors.white,
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: onPressed == null ? Colors.white70 : Colors.white,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBreakGuidanceBanner({
    required IconData icon,
    required Color color,
    required String message,
  }) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.25)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: color,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActiveAttendanceActionSection(
    BuildContext context, {
    required AttendanceProvider attendanceProvider,
    required List<DailyShift> todayShifts,
    required AttendanceRecord? today,
  }) {
    return ValueListenableBuilder<DateTime>(
      valueListenable: _shiftClockNotifier,
      builder: (context, now, _) {
        final activeShift = _resolveActiveShiftForAttendance(
          todayShifts,
          today,
        );
        final shiftHasBreak = _resolveBreakWindowConfig(activeShift) != null;
        final breakState = attendanceProvider.breakState;
        final breakEnabled = shiftHasBreak && (breakState?.enabled ?? false);
        final breakStatus = (today?.breakStatus ?? '').toLowerCase();
        final breakWindowActive =
            breakEnabled && _isWithinBreakWindow(activeShift, now);
        final breakWindowPassed =
            breakEnabled && _hasBreakWindowPassed(activeShift, now);
        final hasOpenBreak =
            breakState?.activeSession != null || breakStatus == 'active';
        final hasCompletedBreak =
            breakStatus == 'on_duration' || breakStatus == 'over_duration';
        final canStartBreak =
            breakEnabled &&
            breakWindowActive &&
            !hasOpenBreak &&
            !hasCompletedBreak &&
            (breakState?.canStart ?? false);
        final canEndBreak =
            breakEnabled && hasOpenBreak && (breakState?.canEnd ?? true);

        Widget actionButton = _buildCheckOutButton(context);
        Widget? banner;

        if (attendanceProvider.isBreakLoading && shiftHasBreak) {
          actionButton = _buildBreakActionButton(
            label: 'Memuat Status Istirahat',
            icon: Icons.free_breakfast_outlined,
            color: Colors.orange,
            loadingLabel: 'Memuat status istirahat...',
            onPressed: null,
            isLoading: true,
          );
        } else if (canEndBreak) {
          actionButton = _buildBreakActionButton(
            label: 'Selesai Istirahat',
            icon: Icons.playlist_add_check_circle_outlined,
            color: Colors.deepOrange,
            loadingLabel: 'Menyimpan status istirahat...',
            onPressed: attendanceProvider.isBreakActionInProgress
                ? null
                : _handleEndBreak,
            isLoading: attendanceProvider.isBreakActionInProgress,
          );
          banner = _buildBreakGuidanceBanner(
            icon: Icons.free_breakfast_outlined,
            color: Colors.deepOrange,
            message:
                'Anda sedang dalam sesi istirahat. Selesaikan istirahat terlebih dahulu sebelum melanjutkan pekerjaan.',
          );
        } else if (canStartBreak) {
          actionButton = _buildBreakActionButton(
            label: 'Mulai Istirahat',
            icon: Icons.free_breakfast_outlined,
            color: Colors.orange,
            loadingLabel: 'Memulai istirahat...',
            onPressed: attendanceProvider.isBreakActionInProgress
                ? null
                : _handleStartBreak,
            isLoading: attendanceProvider.isBreakActionInProgress,
          );
          banner = _buildBreakGuidanceBanner(
            icon: Icons.schedule_outlined,
            color: Colors.orange.shade800,
            message:
                'Saat ini masuk jadwal istirahat. Tombol utama berubah menjadi Mulai Istirahat.',
          );
        } else if (breakEnabled &&
            hasCompletedBreak &&
            !attendanceProvider.isBreakActionInProgress) {
          banner = _buildBreakGuidanceBanner(
            icon: Icons.check_circle_outline,
            color: Colors.green.shade700,
            message:
                'Istirahat sudah tercatat. Anda dapat melanjutkan pekerjaan dan melakukan check-out saat selesai shift.',
          );
        } else if (breakEnabled &&
            (breakState?.mandatory ?? false) &&
            breakWindowPassed &&
            !hasOpenBreak &&
            !hasCompletedBreak &&
            breakStatus != 'no_tagging') {
          banner = _buildBreakGuidanceBanner(
            icon: Icons.warning_amber_rounded,
            color: Colors.red.shade700,
            message:
                'Istirahat wajib belum ditagging. Jika langsung check-out, status absensi akan tercatat sebagai no tagging.',
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [if (banner != null) banner, actionButton],
        );
      },
    );
  }

  Widget _buildErrorBanner(
    BuildContext context,
    String errorMessage, {
    VoidCallback? onDismiss,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.red[50],
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.red[300]!, width: 1),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: Colors.red[700], size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              errorMessage,
              style: TextStyle(color: Colors.red[900], fontSize: 13),
            ),
          ),
          if (onDismiss != null)
            IconButton(
              icon: Icon(Icons.close, color: Colors.red[700], size: 18),
              onPressed: onDismiss,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
        ],
      ),
    );
  }

  Widget _buildMonthSummaryCard(
    BuildContext context,
    Map<String, int> stats,
    List<AttendanceRecord> records,
  ) {
    final monthLabel = DateFormat('MMMM yyyy', 'id_ID').format(DateTime.now());
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey[200]!),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Kehadiran $monthLabel',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: Colors.grey[900],
            ),
          ),
          const SizedBox(height: 12),
          // Tinggi sel sama walau label terbungkus dua baris
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: _buildStatCard(
                    context,
                    count: stats['present'] ?? 0,
                    label: 'Hadir',
                    color: _getStatusColor('present'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildStatCard(
                    context,
                    count: stats['late'] ?? 0,
                    label: 'Terlambat',
                    color: _getStatusColor('late'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildStatCard(
                    context,
                    count: stats['absent'] ?? 0,
                    label: 'Tidak hadir',
                    color: _getStatusColor('absent'),
                  ),
                ),
              ],
            ),
          ),
          AttendanceKpiRow(records: records),
        ],
      ),
    );
  }

  Widget _buildRecentHistoryCard(
    BuildContext context,
    AttendanceProvider attendanceProvider,
  ) {
    final recent = attendanceProvider.recentAttendance;
    if (recent.isEmpty) {
      return const SizedBox.shrink();
    }
    final items = recent.take(5).toList();
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey[200]!),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Riwayat absen',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Colors.grey[900],
                  ),
                ),
              ),
              if (recent.length > items.length)
                TextButton(
                  onPressed: () => Navigator.pushNamed(context, '/attendance'),
                  child: const Text('Lihat semua'),
                ),
            ],
          ),
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0) Divider(height: 1, color: Colors.grey[200]),
            _buildHistoryRow(items[i]),
          ],
        ],
      ),
    );
  }

  Widget _buildHistoryRow(AttendanceRecord record) {
    final date = DateTime.tryParse(record.date);
    final dateLabel = date != null
        ? DateFormat('EEE, d MMM', 'id_ID').format(date)
        : record.date;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  dateLabel,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Colors.grey[900],
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _statusLabel(record.status),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: _getStatusColor(record.status),
                  ),
                ),
              ],
            ),
          ),
          Text(
            record.checkOut == null && record.checkIn != null
                ? '${clockLabel(record.checkIn) ?? record.checkIn} · belum pulang'
                : '${clockLabel(record.checkIn) ?? "-"} - ${clockLabel(record.checkOut) ?? "-"}',
            style: TextStyle(
              fontSize: 14,
              color: Colors.grey[800],
              fontFeatures: const [ui.FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  String _statusLabel(String status) {
    switch (status.toLowerCase()) {
      case 'present':
        return 'Hadir';
      case 'late':
        return 'Terlambat';
      case 'absent':
        return 'Tidak hadir';
      case 'leave':
        return 'Izin';
      case 'sick':
        return 'Sakit';
      case 'remote':
        return 'Kerja jarak jauh';
      case 'off':
        return 'Libur';
      default:
        final text = status.replaceAll('_', ' ').trim();
        return text.isEmpty
            ? '-'
            : '${text[0].toUpperCase()}${text.substring(1)}';
    }
  }

  Color _getStatusColor(String status) {
    switch (status.toLowerCase()) {
      // Warna teks status: kontras minimal 4,5:1 di atas putih
      case 'present':
        return Colors.green[800]!;
      case 'late':
        return const Color(0xFFB45309);
      case 'absent':
        return Colors.red[700]!;
      case 'leave':
        return Colors.blue[700]!;
      default:
        return Colors.grey[700]!;
    }
  }

  Widget _buildStatCard(
    BuildContext context, {
    Key? key,
    required int count,
    required String label,
    required Color color,
  }) {
    return Container(
      key: key,
      padding: const EdgeInsets.fromLTRB(10, 10, 8, 10),
      decoration: BoxDecoration(
        color: Colors.grey[50],
        borderRadius: BorderRadius.circular(12),
      ),
      // Titik warna di samping angka, supaya label dapat lebar penuh saat huruf diperbesar
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 6),
              Text(
                '$count',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: Colors.grey[900],
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(label, style: TextStyle(fontSize: 12, color: Colors.grey[800])),
        ],
      ),
    );
  }

  Widget _buildUserHeader(BuildContext context) {
    return Consumer<AuthProvider>(
      builder: (context, authProvider, _) {
        final user = authProvider.user;
        if (user == null) return const SizedBox.shrink();

        // Calculate display name - ensure it's never empty
        // Handle cases where name might be empty or contain only whitespace
        String displayName = user.name.trim();
        if (displayName.isEmpty) {
          // Fallback to email username if name is empty
          if (user.email.isNotEmpty) {
            displayName = user.email.split('@')[0];
          } else {
            // Last resort fallback
            displayName = 'User';
          }
        }

        return Container(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: MediaQuery.of(context).padding.top + 6,
            bottom: 8,
          ),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Colors.blue[700]!, Colors.blue[600]!],
            ),
            borderRadius: const BorderRadius.only(
              bottomLeft: Radius.circular(20),
              bottomRight: Radius.circular(20),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.blue.withOpacity(0.3),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Profile Picture - Clickable
              GestureDetector(
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const ProfileScreen(),
                    ),
                  );
                },
                child: Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2.5),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.2),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: CircleAvatar(
                    radius: 24,
                    backgroundColor: Colors.white,
                    backgroundImage: user.photoUrl != null
                        ? NetworkImage(ApiConfig.getImageUrl(user.photoUrl!))
                        : null,
                    child: user.photoUrl == null
                        ? Text(
                            (user.name.isNotEmpty ? user.name[0] : 'U')
                                .toUpperCase(),
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                              color: Colors.blue[700],
                            ),
                          )
                        : null,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              // User Info
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // Nama user - always show name if available
                    // Jika nama terlalu panjang, akan otomatis dipotong dengan "..." di akhir
                    Text(
                      displayName,
                      key: ValueKey('user-name-${user.id}'),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        height: 1.2,
                        letterSpacing: 0.3,
                        shadows: [
                          Shadow(
                            offset: Offset(0, 1),
                            blurRadius: 2,
                            color: Colors.black26,
                          ),
                        ],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.left,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _buildUserDetailLine(user.title, user.site?.name),
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.9),
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        height: 1.2,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.left,
                    ),
                  ],
                ),
              ),
              // Notification Bell with unread badge
              Stack(
                children: [
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.2),
                      shape: BoxShape.circle,
                    ),
                    child: IconButton(
                      icon: const Icon(
                        Icons.notifications_outlined,
                        color: Colors.white,
                        size: 20,
                      ),
                      onPressed: () async {
                        await Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const NotificationScreen(),
                          ),
                        );
                        _fetchUnreadCount();
                      },
                      padding: const EdgeInsets.all(6),
                      constraints: const BoxConstraints(
                        minWidth: 36,
                        minHeight: 36,
                      ),
                    ),
                  ),
                  if (_unreadNotifCount > 0)
                    Positioned(
                      right: 0,
                      top: 0,
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: const BoxDecoration(
                          color: Colors.red,
                          shape: BoxShape.circle,
                        ),
                        constraints: const BoxConstraints(
                          minWidth: 18,
                          minHeight: 18,
                        ),
                        child: Text(
                          _unreadNotifCount > 99
                              ? '99+'
                              : _unreadNotifCount.toString(),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF6F7F9),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        // Header sapaan berlatar biru: ikon status bar terang
        systemOverlayStyle: SystemUiOverlayStyle.light,
        automaticallyImplyLeading: false,
        // Cukup untuk avatar + nama + jabatan saat ukuran huruf sistem diperbesar
        toolbarHeight: 64,
        flexibleSpace: MediaQuery.withClampedTextScaling(
          maxScaleFactor: 1.4,
          child: _buildUserHeader(context),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          // Ambil semua provider SEBELUM await pertama. Refresh bisa lama di sinyal
          // lapangan; kalau user pindah tab / app ke background, widget ini di-dispose
          // dan `context` tidak valid lagi setelah await.
          final authProvider = Provider.of<AuthProvider>(
            context,
            listen: false,
          );
          final attendanceProvider = Provider.of<AttendanceProvider>(
            context,
            listen: false,
          );
          final shiftProvider = Provider.of<ShiftProvider>(
            context,
            listen: false,
          );
          final requestProvider = Provider.of<RequestProvider>(
            context,
            listen: false,
          );
          final activityProvider = Provider.of<ActivityProvider>(
            context,
            listen: false,
          );

          await authProvider.refreshUser();
          // Load attendance dengan default bulan ini
          final now = DateTime.now();
          final startDate = DateTime(
            now.year,
            now.month,
            1,
          ).subtract(const Duration(days: 2));
          await attendanceProvider.loadAttendance(
            startDate: startDate,
            endDate: now,
          );
          await shiftProvider.loadShifts();
          await requestProvider.loadRequests();
          await activityProvider.loadActivities();
          await attendanceProvider.loadQrAttendanceFlag();
        },
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: [
            // Password Setup Banner (jika user belum punya password atau masih pakai password default)
            Consumer<AuthProvider>(
              builder: (context, authProvider, _) {
                final user = authProvider.user;
                // User perlu ganti password jika:
                // 1. Belum punya password di database (hasPassword === false)
                // 2. Masih menggunakan password default (needsPasswordChange === true)
                final needsPasswordSetup =
                    (user?.hasPassword == false) ||
                    (user?.needsPasswordChange == true);
                if (needsPasswordSetup) {
                  return const PasswordSetupBanner();
                }
                return const SizedBox.shrink();
              },
            ),
            // Leave Request Banner (jika ada izin yang berlangsung)
            const LeaveRequestBanner(),
            // Permission Status Card (check location & notification permissions)
            const PermissionStatusCard(),
            // Today's Attendance Card (check-in/check-out diutamakan, task card di dalamnya di atas tombol)
            _buildTodaysAttendanceCard(context),
            _buildShiftQuickActions(context),
            // Error Banner (jika ada error dari provider)
            Consumer<AttendanceProvider>(
              builder: (context, attendanceProvider, _) {
                if (attendanceProvider.error != null) {
                  return _buildErrorBanner(
                    context,
                    attendanceProvider.error!,
                    onDismiss: () {
                      // Clear error saat dismiss
                      // Note: Provider tidak memiliki method clearError, jadi kita biarkan saja
                      // Error akan hilang saat data berhasil di-load
                    },
                  );
                }
                return const SizedBox.shrink();
              },
            ),
            Consumer<ShiftProvider>(
              builder: (context, shiftProvider, _) {
                if (shiftProvider.error != null) {
                  return _buildErrorBanner(
                    context,
                    shiftProvider.error!,
                    onDismiss: () {},
                  );
                }
                return const SizedBox.shrink();
              },
            ),

            const SizedBox(height: 20),

            // Rekap kehadiran bulan ini
            Consumer<AttendanceProvider>(
              builder: (context, attendanceProvider, _) {
                final recent = attendanceProvider.recentAttendance;
                if (attendanceProvider.isLoading && recent.isEmpty) {
                  return ShimmerLoading(
                    width: double.infinity,
                    height: 112,
                    borderRadius: BorderRadius.circular(16),
                  );
                }
                return _buildMonthSummaryCard(
                  context,
                  _calculateAttendanceStats(recent),
                  recent,
                );
              },
            ),
            const SizedBox(height: 16),
            // Kegiatan hari ini (check-in, istirahat, aktivitas, check-out) tepat di bawah KPI kehadiran
            TodayTimelineCard(
              onSeeActivities: () => Navigator.pushNamed(context, '/activity'),
            ),
            const SizedBox(height: 16),
            Consumer<AttendanceProvider>(
              builder: (context, attendanceProvider, _) =>
                  _buildRecentHistoryCard(context, attendanceProvider),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// Checkpoint Progress Card (tugas hari ini) - uses CheckpointProvider
// ============================================================

class _CheckpointProgressCard extends StatefulWidget {
  const _CheckpointProgressCard();

  @override
  State<_CheckpointProgressCard> createState() =>
      _CheckpointProgressCardState();
}

class _CheckpointProgressCardState extends State<_CheckpointProgressCard> {
  @override
  void initState() {
    super.initState();
    // Pre-fetch checkpoint data melalui provider (akan di-cache)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Provider.of<CheckpointProvider>(context, listen: false).loadCheckpoint();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<CheckpointProvider>(
      builder: (context, cp, _) {
        final hasAssignedCheckpoint =
            cp.hasCheckpoint || cp.templateStates.isNotEmpty;
        if (cp.loading || !hasAssignedCheckpoint) {
          return const SizedBox.shrink();
        }

        final completed = cp.completedCount;
        final total = cp.totalCount;
        final allDone = completed == total && total > 0;
        final nextTask = cp.nextTaskName;
        final todoPreviews = cp.todoPreviews;

        // Kotak kecil full width, klik seluruh komponen, panah > di kanan
        return Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () {
              if (!ensureCheckedIn(context, CheckInPurpose.activity)) return;
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ActivityFormScreen()),
              ).then((_) {
                Provider.of<CheckpointProvider>(
                  context,
                  listen: false,
                ).loadCheckpoint(force: true);
              });
            },
            borderRadius: BorderRadius.circular(12),
            child: Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.06),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
                border: Border.all(
                  color: allDone ? Colors.green.shade100 : Colors.blue.shade100,
                  width: 1,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    allDone
                        ? Icons.check_circle_rounded
                        : Icons.checklist_rounded,
                    color: allDone
                        ? Colors.green.shade600
                        : Colors.blue.shade600,
                    size: 22,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Tugas Checkpoint Hari Ini',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                            color: Colors.grey.shade800,
                          ),
                        ),
                        const SizedBox(height: 4),
                        if (allDone)
                          Text(
                            'Semua checkpoint selesai',
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.green.shade700,
                              fontWeight: FontWeight.w600,
                            ),
                          )
                        else if (todoPreviews.isEmpty)
                          Text(
                            nextTask != null
                                ? 'Selanjutnya: $nextTask'
                                : '${cp.template?.name ?? 'Checkpoint'} - $completed/$total',
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.grey.shade600,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          )
                        else ...[
                          ...todoPreviews.take(2).map((preview) {
                            final pendingCount = preview.pendingItems.length;
                            final nextItem = pendingCount > 0
                                ? preview.pendingItems.first.name
                                : 'Selesai';
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 2),
                              child: Text(
                                '${preview.templateName}: ${preview.completedCount}/${preview.totalCount} - $nextItem',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.grey.shade700,
                                  fontWeight: FontWeight.w500,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            );
                          }),
                          if (todoPreviews.length > 2)
                            Text(
                              '+${todoPreviews.length - 2} template lain',
                              style: TextStyle(
                                fontSize: 10,
                                color: Colors.grey.shade600,
                              ),
                            ),
                        ],
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: allDone
                          ? Colors.green.shade50
                          : Colors.blue.shade50,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '$completed/$total',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: allDone
                            ? Colors.green.shade700
                            : Colors.blue.shade700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    Icons.chevron_right,
                    color: Colors.grey.shade400,
                    size: 22,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
