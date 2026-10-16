import 'dart:io';
import 'dart:math';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

class DeviceIdService {
  static const String _deviceIdKey = 'device_id';
  static final Random _random = Random.secure();
  static String? _cachedDeviceId;

  static Future<String> getOrCreateDeviceId() async {
    final cached = _cachedDeviceId;
    if (cached != null && cached.isNotEmpty) {
      return cached;
    }

    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_deviceIdKey)?.trim();
    if (saved != null && saved.isNotEmpty) {
      _cachedDeviceId = saved;
      return saved;
    }

    final generated = _generateDeviceId();
    await prefs.setString(_deviceIdKey, generated);
    _cachedDeviceId = generated;
    return generated;
  }

  static Map<String, String>? _cachedInfo;

  /// Nama HP (merek + model) dan sistem operasinya, untuk header x-device-name / x-device-platform.
  /// Hanya karakter ASCII tercetak: header HTTP menolak karakter lain (mis. nama iPhone dengan tanda kutip tipografis).
  static Future<Map<String, String>> getNameAndPlatform() async {
    final cached = _cachedInfo;
    if (cached != null) return cached;
    String name = '';
    String platform = Platform.operatingSystem;
    try {
      final plugin = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final info = await plugin.androidInfo;
        name = [info.brand.trim(), info.model.trim()].where((v) => v.isNotEmpty).join(' ');
        platform = 'android';
      } else if (Platform.isIOS) {
        final info = await plugin.iosInfo;
        name = [info.name.trim(), info.model.trim()].where((v) => v.isNotEmpty).join(' ');
        platform = 'ios';
      }
    } catch (_) {}
    final safe = name.replaceAll(RegExp(r'[^\x20-\x7E]'), '').trim();
    final result = {'name': safe.isNotEmpty ? safe : 'Unknown Device', 'platform': platform};
    _cachedInfo = result;
    return result;
  }

  static String _generateDeviceId() {
    final timestamp = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final suffix = List.generate(
      3,
      (_) => _random.nextInt(0x7fffffff).toRadixString(36),
    ).join();

    final tsPart = timestamp.length > 10
        ? timestamp.substring(timestamp.length - 10)
        : timestamp;
    final randomPart = suffix.length > 12 ? suffix.substring(0, 12) : suffix;

    return 'mms-$tsPart-$randomPart';
  }
}
