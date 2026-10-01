import 'dart:async';
import 'dart:ui';

import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'providers/auth_provider.dart';
import 'providers/attendance_provider.dart';
import 'providers/shift_provider.dart';
import 'providers/activity_provider.dart';
import 'providers/request_provider.dart';
import 'providers/connectivity_provider.dart';
import 'providers/developer_options_provider.dart';
import 'providers/checkpoint_provider.dart';
import 'providers/patrol_provider.dart';
import 'widgets/developer_options_warning_dialog.dart';
import 'services/background_tracking_service.dart';
import 'services/push_notification_service.dart';
import 'services/tracking_state_service.dart';
import 'screens/auth/login_screen.dart';
import 'screens/home/home_screen.dart';
import 'screens/attendance/attendance_screen.dart';
import 'screens/profile/force_password_screen.dart';
import 'screens/team/team_monitoring_detail_screen.dart';
import 'screens/incident_report/incident_report_screen.dart';
import 'screens/activity/activity_screen.dart';
import 'screens/payroll/payroll_slips_screen.dart';
import 'services/api_service.dart';
import 'services/persistent_notification_service.dart';
import 'widgets/update_dialog.dart';
import 'widgets/ui_kit.dart';
import 'models/version_model.dart';
import 'services/error_reporting_service.dart';
import 'services/global_update_checker.dart';
import 'app_keys.dart';

Future<void> main() async {
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();

      FlutterError.onError = (details) {
        FlutterError.presentError(details);
        ErrorReportingService().reportFlutterError(details);
      };

      PlatformDispatcher.instance.onError = (error, stack) {
        ErrorReportingService().reportError(error, stack, isFatal: true);
        return true;
      };

      // Load environment variables
      try {
        await dotenv.load(fileName: ".env");
      } catch (e) {
        // Silently use default configuration
      }

      // Initialize Indonesian locale data for DateFormat
      await initializeDateFormatting('id_ID', null);

      runApp(const MyApp());

      // Initialize heavy background services after first frame
      unawaited(_initBackgroundServices());
    },
    (error, stack) {
      ErrorReportingService().reportError(error, stack, isFatal: true);
    },
  );
}

Future<void> _initBackgroundServices() async {
  try {
    await BackgroundTrackingService.initialize();
  } catch (e) {
    debugPrint('[App] ⚠️ Failed to initialize background tracking: $e');
  }

  try {
    await PersistentNotificationService.initialize();
  } catch (e) {
    debugPrint('[App] ⚠️ Failed to initialize notifications: $e');
  }

  try {
    await PushNotificationService.initialize();
  } catch (e) {
    debugPrint('[App] ⚠️ Failed to initialize push notifications: $e');
  }
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  @override
  void initState() {
    super.initState();
    // Setup auto logout callback setelah widget tree siap
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ApiService().setSessionExpiredCallback(() {
        debugPrint('[App] Session expired - Auto logout triggered');
        _handleAutoLogout();
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ConnectivityProvider()),
        ChangeNotifierProvider(create: (_) => AuthProvider()),
        ChangeNotifierProvider(create: (_) => AttendanceProvider()),
        ChangeNotifierProvider(create: (_) => ShiftProvider()),
        ChangeNotifierProvider(create: (_) => ActivityProvider()),
        ChangeNotifierProvider(create: (_) => RequestProvider()),
        ChangeNotifierProvider(create: (_) => DeveloperOptionsProvider()),
        ChangeNotifierProvider(create: (_) => CheckpointProvider()),
        ChangeNotifierProvider(create: (_) => PatrolProvider()),
      ],
      child: AppLifecycleHandler(
        child: MaterialApp(
          title: 'Atenim Workforce',
          debugShowCheckedModeBanner: false,
          navigatorKey: navigatorKey, // Global navigator key untuk auto logout
          scaffoldMessengerKey: scaffoldMessengerKey,
          navigatorObservers: const [],
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: const [Locale('id', 'ID'), Locale('en', 'US')],
          locale: const Locale('id', 'ID'),
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
            useMaterial3: true,
            // Latar halaman dan bilah atas seragam (DESIGN.md): abu sangat terang, tanpa tint dan bayangan.
            scaffoldBackgroundColor: AtenimUi.pageBg,
            appBarTheme: AppBarTheme(
              backgroundColor: AtenimUi.pageBg,
              foregroundColor: AtenimUi.ink,
              surfaceTintColor: Colors.transparent,
              elevation: 0,
              scrolledUnderElevation: 0,
              centerTitle: false,
              titleTextStyle: TextStyle(
                color: AtenimUi.ink,
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
            ),
            // Pindah layar: memudar sambil maju sedikit, lebih halus dari zoom bawaan Android.
            pageTransitionsTheme: const PageTransitionsTheme(
              builders: {
                TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
                TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
              },
            ),
          ),
          home: const DeveloperOptionsWrapper(child: AuthWrapper()),
          routes: {
            '/login': (context) => const LoginScreen(),
            '/home': (context) => const HomeScreen(),
            '/attendance': (context) => const AttendanceScreen(),
            '/team_monitoring_detail': (context) {
              final args = ModalRoute.of(context)?.settings.arguments;
              if (args is Map) {
                return TeamMonitoringDetailScreen(
                  teamId: args['teamId'] as String? ?? '',
                  teamName: args['teamName'] as String? ?? '',
                );
              }
              return const TeamMonitoringDetailScreen(teamId: '', teamName: '');
            },
            '/incident_report': (context) => const IncidentReportScreen(),
            '/activity': (context) => const ActivityScreen(),
            '/payroll-slips': (context) => const PayrollSlipsScreen(),
          },
        ),
      ),
    );
  }

  void _handleAutoLogout() {
    debugPrint('[App] ===== AUTO LOGOUT TRIGGERED =====');

    // Use navigator key context untuk akses provider
    final context = navigatorKey.currentContext;
    if (context == null) {
      debugPrint(
        '[App] ⚠ Navigator context not available, retrying in 500ms...',
      );
      // Retry setelah navigator siap
      Future.delayed(const Duration(milliseconds: 500), () {
        _handleAutoLogout();
      });
      return;
    }

    debugPrint('[App] Executing auto logout...');
    try {
      final authProvider = Provider.of<AuthProvider>(context, listen: false);
      authProvider
          .logout()
          .then((_) {
            debugPrint('[App] Logout completed, redirecting to login...');
            ApiService().resetSessionExpiredState();
            // Wait a bit untuk memastikan state sudah update
            Future.delayed(const Duration(milliseconds: 200), () {
              final navContext = navigatorKey.currentContext;
              if (navContext != null) {
                Navigator.of(
                  navContext,
                ).pushNamedAndRemoveUntil('/login', (route) => false);
                // Show notification
                ScaffoldMessenger.of(navContext).showSnackBar(
                  const SnackBar(
                    content: Text(
                      'Sesi Anda telah berakhir. Silakan login kembali.',
                    ),
                    backgroundColor: Colors.orange,
                    duration: Duration(seconds: 3),
                  ),
                );
                debugPrint('[App] ✓ Redirected to login screen');
              } else {
                debugPrint('[App] ⚠ Navigator context lost during redirect');
              }
            });
          })
          .catchError((error) {
            debugPrint('[App] ✗ Error during auto logout: $error');
          });
    } catch (e) {
      debugPrint('[App] ✗ Exception during auto logout: $e');
    }
  }
}

class AppLifecycleHandler extends StatefulWidget {
  const AppLifecycleHandler({super.key, required this.child});

  final Widget child;

  @override
  State<AppLifecycleHandler> createState() => _AppLifecycleHandlerState();
}

class _AppLifecycleHandlerState extends State<AppLifecycleHandler>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    TrackingStateService.setAppForeground(true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _setForeground(true);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    TrackingStateService.setAppForeground(false);
    super.dispose();
  }

  void _setForeground(bool isForeground) {
    if (!mounted) return;

    try {
      TrackingStateService.setAppForeground(isForeground);

      // Safety check: pastikan mounted sebelum akses Provider
      if (mounted) {
        try {
          final attendanceProvider = Provider.of<AttendanceProvider>(
            context,
            listen: false,
          );
          attendanceProvider.setForegroundActive(isForeground);
        } catch (e) {
          debugPrint(
            '[AppLifecycleHandler] ⚠️ Failed to set foreground active: $e',
          );
        }
      }
    } catch (e) {
      debugPrint('[AppLifecycleHandler] ⚠️ Error in _setForeground: $e');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final isForeground = state == AppLifecycleState.resumed;
    _setForeground(isForeground);

    // Recover services when app comes back from background/force close
    if (state == AppLifecycleState.resumed) {
      _recoverServicesAfterForceClose();
    }
  }

  Future<void> _recoverServicesAfterForceClose() async {
    if (!mounted) return;

    debugPrint(
      '[AppLifecycleHandler] 🔄 Recovering services after app resume...',
    );

    // Delay sedikit untuk memastikan Flutter engine sudah siap
    await Future.delayed(const Duration(milliseconds: 300));

    if (!mounted) return;

    try {
      if (!mounted) {
        debugPrint(
          '[AppLifecycleHandler] ⚠️ Widget not mounted, skipping recovery',
        );
        return;
      }

      // 1. Re-initialize persistent notification if needed
      try {
        final attendanceProvider = Provider.of<AttendanceProvider>(
          context,
          listen: false,
        );
        await attendanceProvider
            .loadAttendance(); // This will restore persistent notification
      } catch (e) {
        debugPrint('[AppLifecycleHandler] ⚠️ Failed to load attendance: $e');
      }

      // 2. Re-check background tracking status
      try {
        final trackingState = await TrackingStateService.getTrackingState();
        if (trackingState != null && mounted) {
          debugPrint(
            '[AppLifecycleHandler] 🔄 Background tracking was active, restarting...',
          );
          await BackgroundTrackingService.ensureRunning();
        }
      } catch (e) {
        debugPrint(
          '[AppLifecycleHandler] ⚠️ Failed to restart background tracking: $e',
        );
      }

      // 3. Re-sync any pending data
      if (mounted) {
        await _syncPendingData();
      }

      if (mounted) {
        debugPrint('[AppLifecycleHandler] ✅ Services recovered successfully');
      }
    } catch (e) {
      debugPrint('[AppLifecycleHandler] ❌ Failed to recover services: $e');
    }
  }

  Future<void> _syncPendingData() async {
    if (!mounted) return;

    try {
      if (!mounted) {
        debugPrint('[AppLifecycleHandler] ⚠️ Widget not mounted for sync');
        return;
      }

      // Sync pending activities
      try {
        final activityProvider = Provider.of<ActivityProvider>(
          context,
          listen: false,
        );
        await activityProvider.syncPendingActivities();
      } catch (e) {
        debugPrint('[AppLifecycleHandler] ⚠️ Failed to sync activities: $e');
      }

      // Location logs will be synced automatically by AttendanceProvider when needed
      if (mounted) {
        debugPrint('[AppLifecycleHandler] ✅ Pending data synced');
      }
    } catch (e) {
      debugPrint('[AppLifecycleHandler] ❌ Failed to sync pending data: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}

class DeveloperOptionsWrapper extends StatefulWidget {
  final Widget child;

  const DeveloperOptionsWrapper({super.key, required this.child});

  @override
  State<DeveloperOptionsWrapper> createState() =>
      _DeveloperOptionsWrapperState();
}

class _DeveloperOptionsWrapperState extends State<DeveloperOptionsWrapper>
    with WidgetsBindingObserver {
  bool _dialogShown = false;
  Timer? _periodicCheckTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // Cek mock location saat widget pertama kali dibuat
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkDeveloperOptions();
      _startPeriodicCheck();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _periodicCheckTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Cek mock location setiap kali app kembali ke foreground
    if (state == AppLifecycleState.resumed) {
      _checkDeveloperOptions();
    }
  }

  void _startPeriodicCheck() {
    // Cek mock location setiap 5 detik untuk memastikan modal muncul terus jika fake GPS aktif
    _periodicCheckTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      if (mounted) {
        _checkDeveloperOptions();
      }
    });
  }

  void _checkDeveloperOptions() async {
    if (!mounted) return;

    try {
      final developerProvider = Provider.of<DeveloperOptionsProvider>(
        context,
        listen: false,
      );

      // Refresh status dari native Android
      try {
        await developerProvider.refreshStatus();
      } catch (e) {
        debugPrint('[DeveloperOptionsWrapper] ⚠️ Failed to refresh status: $e');
        return;
      }

      if (!mounted) return;

      // Cek status setelah refresh
      final isSecurityRisk = developerProvider.isSecurityRisk;

      debugPrint(
        '[DeveloperOptionsWrapper] Security risk: $isSecurityRisk, Dialog shown: $_dialogShown',
      );

      // Jika sudah tidak ada security risk, pastikan flag di-reset dan tidak ada dialog
      if (!isSecurityRisk) {
        if (_dialogShown) {
          debugPrint(
            '[DeveloperOptionsWrapper] Security risk cleared, resetting dialog flag',
          );
          _dialogShown = false;
          // Tutup dialog jika masih terbuka
          if (mounted) {
            try {
              if (Navigator.of(context).canPop()) {
                Navigator.of(context).pop();
              }
            } catch (e) {
              debugPrint(
                '[DeveloperOptionsWrapper] ⚠️ Failed to pop dialog: $e',
              );
            }
          }
        }
        return; // Tidak perlu tampilkan dialog jika tidak ada security risk
      }

      // Jika ada security risk dan dialog belum ditampilkan, tampilkan dialog
      if (isSecurityRisk && !_dialogShown && mounted) {
        debugPrint('[DeveloperOptionsWrapper] Showing security warning dialog');
        _dialogShown = true;

        // Tampilkan dialog dengan informasi lengkap (hanya untuk mock location)
        try {
          DeveloperOptionsWarningDialog.show(
                context,
                isDeveloperOptionsEnabled:
                    false, // Tidak perlu check developer options
                isMockLocationEnabled: developerProvider.isMockLocationEnabled,
              )
              .then((_) {
                // Dialog ditutup, reset flag
                debugPrint(
                  '[DeveloperOptionsWrapper] Dialog closed, resetting flag',
                );
                _dialogShown = false;

                // Cek ulang setelah dialog ditutup untuk memastikan status terbaru
                Future.delayed(const Duration(milliseconds: 500), () {
                  if (mounted) {
                    _checkDeveloperOptions(); // Re-check immediately
                  }
                });
              })
              .catchError((e) {
                debugPrint(
                  '[DeveloperOptionsWrapper] ⚠️ Error showing dialog: $e',
                );
                _dialogShown = false;
              });
        } catch (e) {
          debugPrint(
            '[DeveloperOptionsWrapper] ⚠️ Exception showing dialog: $e',
          );
          _dialogShown = false;
        }
      }
    } catch (e) {
      debugPrint(
        '[DeveloperOptionsWrapper] ⚠️ Error in _checkDeveloperOptions: $e',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<DeveloperOptionsProvider>(
      builder: (context, developerProvider, child) {
        // Cek security risk (mock location) setiap kali provider berubah
        if (developerProvider.isSecurityRisk && !_dialogShown) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _checkDeveloperOptions();
          });
        }

        return widget.child;
      },
      child: widget.child,
    );
  }
}

class AuthWrapper extends StatelessWidget {
  const AuthWrapper({super.key});

  void _showUpdateDialog(
    BuildContext context,
    VersionData versionData,
    bool isRequired,
  ) {
    UpdateDialog.show(
      context: context,
      versionData: versionData,
      isRequired: isRequired,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AuthProvider>(
      builder: (context, authProvider, _) {
        // Version check handled on dashboard (HomeScreen) only
        authProvider.setVersionCheckCallback((_, __, ___) {});

        // Auto redirect ke login jika tidak authenticated
        if (!authProvider.isLoading && !authProvider.isAuthenticated) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            // Clear check-in notification jika user tidak authenticated
            try {
              PersistentNotificationService.hideCheckInNotification();
              PersistentNotificationService.stopPeriodicUpdates();
              debugPrint(
                '[AuthWrapper] ✓ Check-in notification cleared (user not authenticated)',
              );
            } catch (e) {
              debugPrint(
                '[AuthWrapper] ⚠️ Failed to clear check-in notification: $e',
              );
            }

            try {
              final navContext = navigatorKey.currentContext;
              if (navContext != null) {
                Navigator.of(
                  navContext,
                ).pushNamedAndRemoveUntil('/login', (route) => false);
              }
            } catch (e) {
              debugPrint('[AuthWrapper] ⚠️ Failed to navigate to login: $e');
            }
          });
        }

        if (authProvider.isLoading) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        if (authProvider.isAuthenticated) {
          final user = authProvider.user;
          final needsPasswordSetup =
              (user?.hasPassword == false) ||
              (user?.needsPasswordChange == true);
          if (needsPasswordSetup) {
            return const ForcePasswordScreen();
          }

          // Pastikan background tracking service running jika ada attendance aktif
          WidgetsBinding.instance.addPostFrameCallback((_) {
            try {
              final navContext = navigatorKey.currentContext;
              if (navContext != null) {
                try {
                  final attendanceProvider = Provider.of<AttendanceProvider>(
                    navContext,
                    listen: false,
                  );
                  attendanceProvider.ensureBackgroundTracking();
                } catch (e) {
                  debugPrint(
                    '[AuthWrapper] ⚠️ Failed to ensure background tracking: $e',
                  );
                }
              }
            } catch (e) {
              debugPrint(
                '[AuthWrapper] ⚠️ Error in background tracking callback: $e',
              );
            }
          });

          return const HomeScreen();
        }

        return const LoginScreen();
      },
    );
  }
}
