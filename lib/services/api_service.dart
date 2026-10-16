import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../config/api_config.dart';
import 'device_id_service.dart';

/// Callback untuk handle session expired
typedef SessionExpiredCallback = void Function();

class ApiService {
  late Dio _dio;
  static final ApiService _instance = ApiService._internal();
  SessionExpiredCallback? _onSessionExpired;
  bool _isLoggingOut = false; // Prevent multiple logout calls

  factory ApiService() => _instance;

  /// Set callback untuk handle session expired
  void setSessionExpiredCallback(SessionExpiredCallback callback) {
    _onSessionExpired = callback;
  }

  /// Reset state setelah logout selesai, agar auto-logout bisa trigger lagi jika session expired di login berikutnya
  void resetSessionExpiredState() {
    _isLoggingOut = false;
  }

  ApiService._internal() {
    _dio = Dio(
      BaseOptions(
        baseUrl: ApiConfig.baseUrl,
        connectTimeout: const Duration(
          seconds: 60,
        ), // Increase timeout untuk development
        receiveTimeout: const Duration(seconds: 60),
        headers: {'Content-Type': 'application/json'},
      ),
    );

    // Add interceptor untuk menambahkan cookies
    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          // Ambil cookies dari shared preferences
          final prefs = await SharedPreferences.getInstance();
          final cookies = prefs.getString('cookies');
          if (cookies != null && cookies.isNotEmpty) {
            options.headers['Cookie'] = cookies;
          }

          if (options.headers['x-device-id'] == null) {
            final deviceId = await DeviceIdService.getOrCreateDeviceId();
            options.headers['x-device-id'] = deviceId;
          }
          // Nama HP & sistem ikut di setiap permintaan supaya jejak perangkat Face ID (pendaftaran/absen) terisi di server.
          if (options.headers['x-device-name'] == null) {
            final info = await DeviceIdService.getNameAndPlatform();
            options.headers['x-device-name'] = info['name'];
            options.headers['x-device-platform'] = info['platform'];
          }

          handler.next(options);
        },
        onResponse: (response, handler) async {
          // Check for session expired in response (401/403)
          if (response.statusCode == 401 || response.statusCode == 403) {
            final path = response.requestOptions.path;
            if (path == ApiConfig.session) {
              // Trigger auto logout callback (only once)
              if (_onSessionExpired != null && !_isLoggingOut) {
                _isLoggingOut = true;
                _onSessionExpired!();
              }
            }
          }

          // Simpan cookies dari response
          final cookies = response.headers.value('set-cookie');
          if (cookies != null) {
            final prefs = await SharedPreferences.getInstance();
            await prefs.setString('cookies', cookies);
          }
          handler.next(response);
        },
        onError: (error, handler) {
          if (error.response != null) {
            final statusCode = error.response?.statusCode;

            // Handle session expired (401 Unauthorized atau 403 Forbidden)
            if (statusCode == 401 || statusCode == 403) {
              final path = error.requestOptions.path;
              if (path == ApiConfig.session) {
                // Trigger auto logout callback (only once)
                if (_onSessionExpired != null && !_isLoggingOut) {
                  _isLoggingOut = true;
                  _onSessionExpired!();
                }
              }
            }
          }
          // Handle connection timeout dengan pesan yang lebih jelas
          if (error.type == DioExceptionType.connectionTimeout ||
              error.type == DioExceptionType.receiveTimeout ||
              error.type == DioExceptionType.sendTimeout) {
            error = DioException(
              requestOptions: error.requestOptions,
              response: error.response,
              type: error.type,
              error: 'Koneksi timeout.',
            );
          } else if (error.type == DioExceptionType.connectionError) {
            error = DioException(
              requestOptions: error.requestOptions,
              response: error.response,
              type: error.type,
              error: 'Tidak dapat terhubung ke server.',
            );
          }
          handler.next(error);
        },
      ),
    );
  }

  // GET request
  Future<Response> get(
    String endpoint, {
    Map<String, dynamic>? queryParameters,
    Map<String, dynamic>? headers,
    ResponseType responseType = ResponseType.json,
  }) async {
    try {
      final response = await _dio.get(
        endpoint,
        queryParameters: queryParameters,
        options: Options(
          headers: headers,
          responseType: responseType,
          followRedirects: false,
          validateStatus: (status) =>
              status! < 600, // Allow 500-level errors for custom handling
        ),
      );
      return response;
    } catch (e) {
      rethrow;
    }
  }

  // POST request dengan JSON
  Future<Response> post(
    String endpoint, {
    Map<String, dynamic>? data,
    Map<String, dynamic>? headers,
  }) async {
    try {
      final response = await _dio.post(
        endpoint,
        data: data,
        options: Options(
          headers: headers,
          followRedirects: false,
          validateStatus: (status) =>
              status! < 600, // Allow 500-level errors for custom handling
        ),
      );
      return response;
    } catch (e) {
      rethrow;
    }
  }

  // POST request dengan FormData (untuk upload file)
  Future<Response> postFormData(
    String endpoint,
    FormData formData, {
    Map<String, dynamic>? headers,
  }) async {
    try {
      final response = await _dio.post(
        endpoint,
        data: formData,
        options: Options(
          headers: headers,
          contentType: 'multipart/form-data',
          followRedirects: false,
          validateStatus: (status) =>
              status! < 600, // Allow 500-level errors for custom handling
        ),
      );
      return response;
    } catch (e) {
      rethrow;
    }
  }

  // PUT request dengan JSON
  Future<Response> put(String endpoint, {Map<String, dynamic>? data}) async {
    try {
      final response = await _dio.put(
        endpoint,
        data: data,
        options: Options(
          followRedirects: false,
          validateStatus: (status) => status! < 600,
        ),
      );
      return response;
    } catch (e) {
      rethrow;
    }
  }

  // PUT request dengan FormData (untuk update dengan file)
  Future<Response> putFormData(String endpoint, FormData formData) async {
    try {
      final response = await _dio.put(
        endpoint,
        data: formData,
        options: Options(
          contentType: 'multipart/form-data',
          followRedirects: false,
          validateStatus: (status) => status! < 600,
        ),
      );
      return response;
    } catch (e) {
      rethrow;
    }
  }

  // PATCH request dengan JSON
  Future<Response> patch(String endpoint, {Map<String, dynamic>? data}) async {
    try {
      final response = await _dio.patch(
        endpoint,
        data: data,
        options: Options(
          followRedirects: false,
          validateStatus: (status) => status! < 600,
        ),
      );
      return response;
    } catch (e) {
      rethrow;
    }
  }

  // DELETE request
  Future<Response> delete(String endpoint, {Map<String, dynamic>? data}) async {
    try {
      final response = await _dio.delete(
        endpoint,
        data: data,
        options: Options(
          followRedirects: false,
          validateStatus: (status) => status! < 600,
        ),
      );
      return response;
    } catch (e) {
      rethrow;
    }
  }
}
