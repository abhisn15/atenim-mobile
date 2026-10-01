import 'dart:async';

import 'package:flutter/foundation.dart';
import '../models/user_model.dart';
import '../models/version_model.dart';
import '../services/auth_service.dart';
import '../services/background_tracking_service.dart';
import '../services/realtime_location_service.dart';
import '../services/push_notification_service.dart';
import '../services/tracking_state_service.dart';
import '../services/version_service.dart';
import '../services/persistent_notification_service.dart';
import '../services/offline_storage_service.dart';
import '../utils/error_handler.dart';

class AuthProvider with ChangeNotifier {
  final AuthService _authService = AuthService();
  final VersionService _versionService = VersionService();
  User? _user;
  bool _isLoading = false;
  String? _error;
  bool _isRefreshingSession = false;

  // Version check callback
  Function(bool updateAvailable, bool updateRequired, VersionData? versionData)?
  _onVersionCheck;

  User? get user => _user;
  bool get isLoading => _isLoading;
  String? get error => _error;
  bool get isAuthenticated => _user != null;

  // Set callback for version check results
  void setVersionCheckCallback(
    Function(
      bool updateAvailable,
      bool updateRequired,
      VersionData? versionData,
    )
    callback,
  ) {
    _onVersionCheck = callback;
  }

  AuthProvider() {
    _checkAuthStatus();
  }

  Future<void> _checkAuthStatus() async {
    _isLoading = true;
    notifyListeners();

    // Fast path: use cached user to avoid long loading screen
    final cachedUser = await _authService.getCachedUserOnly();
    if (cachedUser != null) {
      _user = cachedUser;
      _error = null;
      _isLoading = false;
      notifyListeners();

      // Refresh session in background without blocking UI
      _refreshSessionInBackground();
      return;
    }

    try {
      _user = await _authService.getCurrentUser().timeout(
        const Duration(seconds: 8),
      );
      if (_user == null) {
        final cachedUser = await _authService.getCachedUserOnly();
        if (cachedUser != null) {
          debugPrint('[AuthProvider] Using cached user (offline mode).');
          _user = cachedUser;
        } else {
          // Session expired atau tidak valid
          debugPrint('[AuthProvider] Session expired or invalid');
          await logout();
        }
      }
      _error = null;
    } catch (e) {
      debugPrint('[AuthProvider] Error checking auth status: $e');
      _error = ErrorHandler.getErrorMessage(e);
      final cachedUser = await _authService.getCachedUserOnly();
      if (cachedUser != null) {
        debugPrint('[AuthProvider] Using cached user after error.');
        _user = cachedUser;
      } else {
        _user = null;
        // Jika error karena session expired, logout
        if (e.toString().contains('401') || e.toString().contains('403')) {
          await logout();
        }
      }
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> _refreshSessionInBackground() async {
    if (_isRefreshingSession) return;
    _isRefreshingSession = true;

    try {
      final user = await _authService.getCurrentUser().timeout(
        const Duration(seconds: 8),
      );
      if (user != null) {
        _user = user;
        _error = null;
        notifyListeners();
      } else {
        await logout();
      }
    } on TimeoutException {
      debugPrint('[AuthProvider] Session check timeout, using cached user.');
    } catch (e) {
      debugPrint('[AuthProvider] Session refresh error: $e');
    } finally {
      _isRefreshingSession = false;
    }
  }

  Future<bool> login(String email, String password) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final result = await _authService.login(email, password);
      if (result['success'] == true) {
        _user = result['user'] as User;

        unawaited(PushNotificationService.syncCurrentToken());

        // Check for app updates after successful login
        try {
          final updateCheck = await _versionService.checkUpdateAvailability();
          if (_onVersionCheck != null) {
            _onVersionCheck!(
              updateCheck.updateAvailable,
              updateCheck.updateRequired,
              updateCheck.serverVersion,
            );
          }
        } catch (e) {
          debugPrint('[AuthProvider] Version check failed: $e');
          // Don't fail login just because version check failed
        }

        _error = null;
        _isLoading = false;
        notifyListeners();
        return true;
      } else {
        _error = result['message'] as String? ?? 'Login gagal';
        _isLoading = false;
        notifyListeners();
        return false;
      }
    } catch (e) {
      _error = ErrorHandler.getErrorMessage(e);
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  Future<void> logout() async {
    debugPrint('[AuthProvider] Logging out...');

    // Unregister push token before logout
    await PushNotificationService.unregisterCurrentToken();

    // Stop all tracking services
    await TrackingStateService.clearTrackingState();
    await BackgroundTrackingService.stop();
    try {
      await RealtimeLocationService().stopRealtimeTracking();
    } catch (_) {}

    // Hide check-in notification and stop periodic updates
    try {
      await PersistentNotificationService.hideCheckInNotification();
      PersistentNotificationService.stopPeriodicUpdates();
      debugPrint('[AuthProvider] ✓ Check-in notification cleared');
    } catch (e) {
      debugPrint('[AuthProvider] ⚠️ Failed to clear check-in notification: $e');
      // Don't fail logout just because notification clear failed
    }

    // Clear semua data offline (cache + pending) agar tidak tersisa untuk user lain / sesi berikutnya
    try {
      await OfflineStorageService().clearAll();
      debugPrint('[AuthProvider] ✓ Offline & pending data cleared');
    } catch (e) {
      debugPrint('[AuthProvider] ⚠️ Failed to clear offline data: $e');
    }

    await _authService.logout();
    _user = null;
    _error = null;
    notifyListeners();
    debugPrint('[AuthProvider] ✓ Logout completed, user cleared');
  }

  void updateUserPhoto(String photoUrl) {
    if (_user != null) {
      _user = User(
        id: _user!.id,
        externalId: _user!.externalId,
        name: _user!.name,
        email: _user!.email,
        role: _user!.role,
        photoUrl: photoUrl,
        team: _user!.team,
        title: _user!.title,
        phone: _user!.phone,
        bpjsKesehatan: _user!.bpjsKesehatan,
        bpjsKetenagakerjaan: _user!.bpjsKetenagakerjaan,
        tempatLahir: _user!.tempatLahir,
        tanggalLahir: _user!.tanggalLahir,
        namaRekening: _user!.namaRekening,
        noRekening: _user!.noRekening,
        pemilikRekening: _user!.pemilikRekening,
        avatarColor: _user!.avatarColor,
        positionId: _user!.positionId,
        siteId: _user!.siteId,
        checkpointEnabled: _user!.checkpointEnabled,
        effectiveCheckpointEnabled: _user!.effectiveCheckpointEnabled,
        position: _user!.position,
        site: _user!.site,
        hasPassword: _user!.hasPassword,
        needsPasswordChange: _user!.needsPasswordChange,
      );
      notifyListeners();
    }
  }

  Future<void> refreshUser() async {
    await _checkAuthStatus();
  }

  /// Request password reset - kirim OTP ke email
  /// Returns Map dengan 'success' dan 'email' (email dari backend, bukan input user)
  Future<Map<String, dynamic>> requestPasswordReset(String email) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final result = await _authService.requestPasswordReset(email);
      if (result['success'] == true) {
        _error = null;
        _isLoading = false;
        notifyListeners();
        return {
          'success': true,
          'email':
              result['email']
                  as String?, // ✅ Email dari backend (jika input NIK, ini adalah email user)
        };
      } else {
        _error = result['message'] as String? ?? 'Gagal mengirim OTP';
        _isLoading = false;
        notifyListeners();
        return {'success': false, 'email': null};
      }
    } catch (e) {
      _error = ErrorHandler.getErrorMessage(e);
      _isLoading = false;
      notifyListeners();
      return {'success': false, 'email': null};
    }
  }

  /// Verify OTP code
  Future<bool> verifyOTP(String email, String otpCode) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final result = await _authService.verifyOTP(email, otpCode);
      if (result['success'] == true) {
        _error = null;
        _isLoading = false;
        notifyListeners();
        return true;
      } else {
        _error = result['message'] as String? ?? 'OTP tidak valid';
        _isLoading = false;
        notifyListeners();
        return false;
      }
    } catch (e) {
      _error = ErrorHandler.getErrorMessage(e);
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  /// Reset password dengan OTP yang sudah diverifikasi
  Future<bool> resetPassword(
    String email,
    String otpCode,
    String newPassword,
  ) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final result = await _authService.resetPassword(
        email,
        otpCode,
        newPassword,
      );
      if (result['success'] == true) {
        _error = null;
        _isLoading = false;
        notifyListeners();
        return true;
      } else {
        _error = result['message'] as String? ?? 'Gagal mereset password';
        _isLoading = false;
        notifyListeners();
        return false;
      }
    } catch (e) {
      _error = ErrorHandler.getErrorMessage(e);
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }
}
