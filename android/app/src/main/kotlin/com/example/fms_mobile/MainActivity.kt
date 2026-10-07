package com.atenim

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val DEVELOPER_OPTIONS_CHANNEL = "com.atenim.fms/developer_options"

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        createNotificationChannels()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DEVELOPER_OPTIONS_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "isDeveloperOptionsEnabled" -> {
                    try {
                        val isEnabled = isDeveloperOptionsEnabled()
                        android.util.Log.d("MainActivity", "Developer options check: $isEnabled")
                        result.success(isEnabled)
                    } catch (e: Exception) {
                        android.util.Log.e("MainActivity", "Error checking developer options: ${e.message}")
                        result.error("DEVELOPER_OPTIONS_ERROR", "Failed to check developer options", e.message)
                    }
                }
                "isMockLocationEnabled" -> {
                    try {
                        val isEnabled = isMockLocationEnabled()
                        result.success(isEnabled)
                    } catch (e: Exception) {
                        result.error("MOCK_LOCATION_ERROR", "Failed to check mock location", e.message)
                    }
                }
                "openDeveloperOptions" -> {
                    try {
                        openDeveloperOptions()
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("DEVELOPER_OPTIONS_ERROR", "Failed to open developer options", e.message)
                    }
                }
                else -> {
                    result.notImplemented()
                }
            }
        }
    }

    private fun createNotificationChannels() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

            // Channel untuk location tracking
            val trackingChannel = NotificationChannel(
                "atenim_tracking",
                "MMS Location Tracking",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Pelacakan lokasi absensi karyawan"
                setShowBadge(false)
                enableLights(false)
                enableVibration(false)
            }

            // Channel untuk background service
            val serviceChannel = NotificationChannel(
                "atenim_service",
                "MMS Background Service",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Layanan latar belakang MMS"
                setShowBadge(false)
                enableLights(false)
                enableVibration(false)
            }

            notificationManager.createNotificationChannel(trackingChannel)
            notificationManager.createNotificationChannel(serviceChannel)
        }
    }

    private fun isDeveloperOptionsEnabled(): Boolean {
        return try {
            // Method 1: Check ADB enabled (USB debugging) - most reliable indicator
            // If ADB is enabled, developer options is definitely enabled
            val adbEnabled = Settings.Global.getInt(contentResolver, Settings.Global.ADB_ENABLED, 0) == 1
            android.util.Log.d("MainActivity", "ADB enabled: $adbEnabled")
            
            if (adbEnabled) {
                android.util.Log.d("MainActivity", "Developer options detected via ADB enabled")
                return true
            }
            
            // Method 2: For Android 6.0+, check if we can access mock location setting
            // The ability to access this setting indicates developer options is enabled
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                try {
                    // Try to read mock location setting
                    // If we can read it without SecurityException, developer options is likely enabled
                    val mockLocationValue = Settings.Secure.getInt(contentResolver, Settings.Secure.ALLOW_MOCK_LOCATION, -1)
                    android.util.Log.d("MainActivity", "Can access mock location setting, value: $mockLocationValue")
                    // If we can access this setting, developer options is enabled
                    // (Even if mock location itself is disabled, the setting exists only if dev options is enabled)
                    return true
                } catch (e: SecurityException) {
                    android.util.Log.d("MainActivity", "Cannot access mock location setting (SecurityException)")
                    // Can't access - developer options might not be enabled
                } catch (e: Exception) {
                    android.util.Log.d("MainActivity", "Error accessing mock location: ${e.message}")
                }
            }
            
            // Method 3: Try to check developer-only global settings
            try {
                val stayAwake = Settings.Global.getInt(contentResolver, Settings.Global.STAY_ON_WHILE_PLUGGED_IN, -1)
                android.util.Log.d("MainActivity", "Can access developer settings, stay awake: $stayAwake")
                // If we can access this, it's a good indicator (but not 100% reliable)
            } catch (e: Exception) {
                android.util.Log.d("MainActivity", "Cannot access developer settings: ${e.message}")
            }
            
            android.util.Log.d("MainActivity", "Developer options not detected")
            return false
        } catch (e: Exception) {
            android.util.Log.e("MainActivity", "Exception checking developer options: ${e.message}")
            return false
        }
    }

    private fun isMockLocationEnabled(): Boolean {
        return try {
            // Check if mock location is enabled
            // For Android 6.0 (API 23) and above, check if any app is set as mock location provider
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                // Check if mock location is enabled in developer options
                val mockLocationEnabled = Settings.Secure.getInt(contentResolver, Settings.Secure.ALLOW_MOCK_LOCATION, 0) == 1
                return mockLocationEnabled
            } else {
                // For older Android versions, check the setting directly
                val mockLocationEnabled = Settings.Secure.getInt(contentResolver, Settings.Secure.ALLOW_MOCK_LOCATION, 0) == 1
                return mockLocationEnabled
            }
        } catch (e: Exception) {
            // If we can't check, assume it's not enabled for security
            false
        }
    }

    private fun openDeveloperOptions() {
        try {
            // Try to open developer options directly
            val intent = Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS)
            intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK
            startActivity(intent)
        } catch (e: Exception) {
            // Fallback: open general settings
            try {
                val intent = Intent(Settings.ACTION_SETTINGS)
                intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK
                startActivity(intent)
            } catch (e2: Exception) {
                // If both fail, throw the original exception
                throw e
            }
        }
    }
}
