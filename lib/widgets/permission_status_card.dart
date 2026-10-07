import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart' as geolocator;
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import '../providers/attendance_provider.dart';

class PermissionStatusCard extends StatefulWidget {
  const PermissionStatusCard({super.key});

  @override
  State<PermissionStatusCard> createState() => _PermissionStatusCardState();
}

class _PermissionStatusCardState extends State<PermissionStatusCard> {
  static bool _sessionPermissionRequested = false;
  PermissionStatus _locationStatus = PermissionStatus.denied;
  PermissionStatus _notificationStatus = PermissionStatus.denied;
  geolocator.LocationPermission _locationPermission =
      geolocator.LocationPermission.denied;

  @override
  void initState() {
    super.initState();
    debugPrint(
      '[PermissionStatusCard] 🎯 Widget initialized, checking permissions...',
    );

    // Only request permissions once per app session to avoid conflicts
    if (!_sessionPermissionRequested) {
      _sessionPermissionRequested = true;
      debugPrint(
        '[PermissionStatusCard] 🔄 Requesting permissions for this session...',
      );
      _checkAndRequestPermissions();
    } else {
      debugPrint(
        '[PermissionStatusCard] ℹ️ Permissions already requested this session, just checking status...',
      );
      _checkPermissions();
    }
  }

  Future<void> _checkAndRequestPermissions() async {
    try {
      // Small delay to ensure UI is rendered before showing dialogs
      await Future.delayed(Duration(milliseconds: 500));

      // Check current location permission
      final locationPermission = await geolocator.Geolocator.checkPermission();
      final notificationStatus = await Permission.notification.status;

      debugPrint(
        '[PermissionStatusCard] 📍 Current location permission: $locationPermission',
      );
      debugPrint(
        '[PermissionStatusCard] 🔔 Current notification permission: $notificationStatus',
      );

      // If location is denied or whileInUse, try to request it
      if (locationPermission == geolocator.LocationPermission.denied ||
          locationPermission == geolocator.LocationPermission.deniedForever) {
        debugPrint(
          '[PermissionStatusCard] 🚨 Location permission denied, requesting immediately...',
        );

        // Request location permission first - this will show system dialog
        final requestedLocation =
            await geolocator.Geolocator.requestPermission();
        debugPrint(
          '[PermissionStatusCard] ✅ Location permission request result: $requestedLocation',
        );

        // If still denied after request, check notification
        if (requestedLocation == geolocator.LocationPermission.denied ||
            requestedLocation == geolocator.LocationPermission.deniedForever) {
          // Request notification permission if location failed
          if (notificationStatus.isDenied) {
            debugPrint(
              '[PermissionStatusCard] 🔔 Requesting notification permission...',
            );
            final requestedNotification = await Permission.notification
                .request();
            debugPrint(
              '[PermissionStatusCard] ✅ Notification permission request result: $requestedNotification',
            );
          }
        }
      } else if (notificationStatus.isDenied) {
        // Location OK, but notification denied - request notification
        debugPrint(
          '[PermissionStatusCard] 🔔 Location OK but notification denied, requesting notification...',
        );
        final requestedNotification = await Permission.notification.request();
        debugPrint(
          '[PermissionStatusCard] ✅ Notification permission request result: $requestedNotification',
        );
      } else {
        debugPrint('[PermissionStatusCard] ✅ All permissions already granted');
      }

      // Re-check all permissions after requests
      await _checkPermissions();
    } catch (e) {
      debugPrint('[PermissionStatusCard] ❌ Error requesting permissions: $e');
      // Fall back to just checking permissions
      await _checkPermissions();
    }
  }

  Future<void> _checkPermissions() async {
    try {
      // Check location permission
      final locationStatus = await Permission.location.status;
      final locationPermission = await geolocator.Geolocator.checkPermission();

      // Check notification permission
      final notificationStatus = await Permission.notification.status;

      if (mounted) {
        setState(() {
          _locationStatus = locationStatus;
          _notificationStatus = notificationStatus;
          _locationPermission = locationPermission;
        });
      }
    } catch (e) {
      debugPrint('[PermissionStatusCard] Error checking permissions: $e');
    }
  }

  bool get _hasAllPermissions {
    return _locationPermission == geolocator.LocationPermission.always &&
        _notificationStatus.isGranted;
  }

  // Check if card should be shown (only if permissions are permanently denied)
  bool get _shouldShowCard {
    final locationPermanentlyDenied =
        _locationPermission == geolocator.LocationPermission.deniedForever;
    final locationStatusDenied = _locationStatus.isPermanentlyDenied;
    final notificationPermanentlyDenied =
        _notificationStatus.isPermanentlyDenied;

    // Show card only if permissions are permanently denied (user chose "Don't ask again")
    return locationPermanentlyDenied ||
        locationStatusDenied ||
        notificationPermanentlyDenied;
  }

  @override
  Widget build(BuildContext context) {
    final attendanceProvider = Provider.of<AttendanceProvider>(context);
    final hasActiveCheckIn =
        attendanceProvider.todayAttendance != null &&
        attendanceProvider.todayAttendance!.checkIn != null &&
        attendanceProvider.todayAttendance!.checkOut == null;

    // Only show card if permissions are permanently denied
    // (system permission dialogs will handle initial requests)
    if (!_shouldShowCard) {
      return SizedBox.shrink();
    }

    return Card(
      margin: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              children: [
                Icon(
                  _hasAllPermissions ? Icons.check_circle : Icons.warning,
                  color: _hasAllPermissions ? Colors.green : Colors.orange,
                  size: 24,
                ),
                SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _hasAllPermissions
                        ? 'Status Izin: Lengkap ✓'
                        : 'Izin Ditolak Permanen',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: _hasAllPermissions
                          ? Colors.green.shade700
                          : Colors.red.shade700,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: _checkPermissions,
                  icon: Icon(Icons.refresh, size: 20),
                  tooltip: 'Periksa ulang izin',
                ),
              ],
            ),

            SizedBox(height: 16),

            // Permission status
            _buildPermissionRow(
              icon: Icons.location_on,
              title: 'Lokasi Latar Belakang',
              subtitle: hasActiveCheckIn
                  ? 'Tracking aktif saat aplikasi tertutup'
                  : 'Diperlukan untuk tracking saat aplikasi tertutup',
              status: _getLocationStatusText(),
              statusColor: _getLocationStatusColor(),
              isRequired: true,
            ),

            SizedBox(height: 12),

            _buildPermissionRow(
              icon: Icons.notifications,
              title: 'Notifikasi',
              subtitle: 'Untuk info check-in dan pengingat',
              status: _getNotificationStatusText(),
              statusColor: _getNotificationStatusColor(),
              isRequired: true,
            ),

            // Action button if permissions not complete
            if (!_hasAllPermissions) ...[
              SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _openAppSettings,
                  icon: Icon(Icons.settings),
                  label: Text('Buka Pengaturan Sistem'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Theme.of(context).primaryColor,
                    foregroundColor: Colors.white,
                    padding: EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ),

              SizedBox(height: 8),

              Text(
                '🔒 Izin telah ditolak permanen. Untuk memberikan izin:\n\n'
                '1. Buka Pengaturan → Aplikasi → MMS\n'
                '2. Pilih "Izin" → "Lokasi" → "Izinkan sepanjang waktu"\n'
                '3. Pilih "Notifikasi" → "Izinkan"\n\n'
                'Atau klik "Buka Pengaturan" di bawah.',
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.grey.shade600,
                  height: 1.4,
                ),
              ),
            ],

            // Success message if all permissions granted
            if (_hasAllPermissions) ...[
              SizedBox(height: 12),
              Container(
                padding: EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.green.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.green.shade200),
                ),
                child: Row(
                  children: [
                    Icon(Icons.check_circle, color: Colors.green, size: 20),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '🎉 Bagus! Semua izin sudah diberikan. '
                        'Tracking lokasi akan berjalan normal.',
                        style: TextStyle(
                          fontSize: 13,
                          color: Colors.green.shade700,
                          height: 1.3,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildPermissionRow({
    required IconData icon,
    required String title,
    required String subtitle,
    required String status,
    required Color statusColor,
    required bool isRequired,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: Colors.grey.shade600),
        SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    title,
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                  ),
                  if (isRequired) ...[
                    SizedBox(width: 4),
                    Text(
                      '*',
                      style: TextStyle(
                        color: Colors.red,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                  Spacer(),
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: statusColor.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: statusColor.withOpacity(0.3)),
                    ),
                    child: Text(
                      status,
                      style: TextStyle(
                        fontSize: 11,
                        color: statusColor,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
              SizedBox(height: 2),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.grey.shade600,
                  height: 1.3,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _getLocationStatusText() {
    switch (_locationPermission) {
      case geolocator.LocationPermission.always:
        return 'Diberikan';
      case geolocator.LocationPermission.whileInUse:
        return 'Hanya Saat Aktif';
      case geolocator.LocationPermission.denied:
        return 'Ditolak';
      case geolocator.LocationPermission.deniedForever:
        return 'Ditolak Permanen';
      default:
        return 'Tidak Diketahui';
    }
  }

  Color _getLocationStatusColor() {
    switch (_locationPermission) {
      case geolocator.LocationPermission.always:
        return Colors.green;
      case geolocator.LocationPermission.whileInUse:
        return Colors.orange;
      case geolocator.LocationPermission.denied:
        return Colors.red;
      case geolocator.LocationPermission.deniedForever:
        return Colors.red;
      default:
        return Colors.grey;
    }
  }

  String _getNotificationStatusText() {
    if (_notificationStatus.isGranted) {
      return 'Diberikan';
    } else if (_notificationStatus.isDenied) {
      return 'Ditolak';
    } else if (_notificationStatus.isPermanentlyDenied) {
      return 'Ditolak Permanen';
    } else {
      return 'Tidak Diketahui';
    }
  }

  Color _getNotificationStatusColor() {
    if (_notificationStatus.isGranted) {
      return Colors.green;
    } else {
      return Colors.red;
    }
  }

  Future<void> _openAppSettings() async {
    try {
      await openAppSettings();
    } catch (e) {
      debugPrint('[PermissionStatusCard] Failed to open app settings: $e');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Tidak dapat membuka pengaturan otomatis. Buka pengaturan aplikasi secara manual.',
            ),
            duration: Duration(seconds: 5),
          ),
        );
      }
    }
  }
}
