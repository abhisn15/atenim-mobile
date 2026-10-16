import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_service.dart';

const _faceIdPath = '/api/ess/face-id';
const _kEnforceCache = 'face_id_enforce_cached';

/// Status Face ID karyawan dari server (sumber tunggal, termasuk teks persetujuan).
class FaceIdState {
  final bool enabled;
  final bool enforce;
  final bool enrolled;

  /// none | pending | approved | rejected
  final String reviewStatus;
  final bool declined;
  final bool needsEnrollment;
  final String consentVersion;
  final List<String> consentText;

  const FaceIdState({
    required this.enabled,
    required this.enforce,
    required this.enrolled,
    required this.reviewStatus,
    required this.declined,
    required this.needsEnrollment,
    required this.consentVersion,
    required this.consentText,
  });

  /// Wajah sudah terdaftar (menunggu atau disetujui): absen memakai kamera Face ID.
  bool get usesFaceCapture => enabled && enrolled;

  factory FaceIdState.fromJson(Map<String, dynamic> j) => FaceIdState(
    enabled: j['enabled'] == true,
    enforce: j['enforce'] == true,
    enrolled: j['enrolled'] == true,
    reviewStatus: (j['reviewStatus'] as String?) ?? 'none',
    declined: j['declined'] == true,
    needsEnrollment: j['needsEnrollment'] == true,
    consentVersion: (j['consentVersion'] as String?) ?? '',
    consentText: ((j['consentText'] as List?) ?? const []).map((e) => '$e').toList(),
  );
}

/// Tantangan gerak dari server untuk satu absen: langkah dipilih server, token sekali pakai.
class FaceChallenge {
  final String token;
  final List<String> steps; // turn | smile | blink
  const FaceChallenge(this.token, this.steps);
}

/// Foto langkah gerakan yang ikut dikirim bersama absen.
class FaceLiveData {
  final String token;
  final List<String> kinds;
  final List<File> photos;
  const FaceLiveData({required this.token, required this.kinds, required this.photos});
}

class FaceEnrollResult {
  final bool ok;
  final String message;

  /// Kode penolakan kualitas dari server (NO_FACE, TOO_DARK, INCONSISTENT, ...), bila ada.
  final String? code;

  /// Foto ke berapa (mulai 0) yang bermasalah, bila server menyebutkannya.
  final int? photoIndex;

  const FaceEnrollResult({required this.ok, required this.message, this.code, this.photoIndex});
}

class FaceIdService {
  final ApiService _api = ApiService();

  /// Null bila gagal dibaca (jaringan/server): pemanggil harus jatuh ke alur foto biasa, bukan memblokir absen.
  Future<FaceIdState?> getState() async {
    try {
      final res = await _api.get(_faceIdPath);
      final body = res.data;
      if (res.statusCode == 200 && body is Map && body['data'] is Map) {
        final state = FaceIdState.fromJson(Map<String, dynamic>.from(body['data'] as Map));
        // Diingat untuk penjagaan offline: di site ber-Mode Wajib, absen butuh internet.
        unawaited(_rememberEnforce(state.enabled && state.enforce));
        return state;
      }
    } catch (e) {
      debugPrint('[FaceIdService] getState gagal: $e');
    }
    return null;
  }

  /// Null bila site tidak meminta gerakan untuk absen ini, atau gagal dibaca (jangan memblokir absen).
  Future<FaceChallenge?> getChallenge(String kind) async {
    try {
      final res = await _api.get('$_faceIdPath/challenge', queryParameters: {'kind': kind});
      final body = res.data;
      if (res.statusCode == 200 && body is Map && body['data'] is Map) {
        final d = body['data'] as Map;
        if (d['required'] == true && d['token'] is String && d['steps'] is List) {
          final steps = (d['steps'] as List).map((e) => '$e').toList();
          if (steps.isNotEmpty) return FaceChallenge(d['token'] as String, steps);
        }
      }
    } catch (e) {
      debugPrint('[FaceIdService] getChallenge gagal: $e');
    }
    return null;
  }

  Future<void> _rememberEnforce(bool value) async {
    try {
      (await SharedPreferences.getInstance()).setBool(_kEnforceCache, value);
    } catch (_) {}
  }

  /// Status Mode Wajib terakhir yang diketahui (untuk saat status tidak bisa dimuat karena offline).
  Future<bool> cachedEnforce() async {
    try {
      return (await SharedPreferences.getInstance()).getBool(_kEnforceCache) ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<FaceEnrollResult> enroll({
    required List<File> photos,
    required String consentVersion,
  }) async {
    try {
      final form = FormData();
      form.fields
        ..add(const MapEntry('consent', 'true'))
        ..add(MapEntry('consentVersion', consentVersion));
      for (final p in photos) {
        form.files.add(MapEntry('photos', await MultipartFile.fromFile(p.path, filename: 'wajah.jpg')));
      }
      final res = await _api
          .postFormData('$_faceIdPath/enroll', form)
          .timeout(const Duration(seconds: 90));
      final body = res.data;
      final message = body is Map ? (body['message'] as String? ?? '') : '';
      if (res.statusCode == 200) {
        return FaceEnrollResult(ok: true, message: message);
      }
      return FaceEnrollResult(
        ok: false,
        message: message.isNotEmpty ? message : 'Gagal mendaftarkan Face ID.',
        code: body is Map ? body['code'] as String? : null,
        photoIndex: body is Map ? (body['photoIndex'] as num?)?.toInt() : null,
      );
    } catch (e) {
      debugPrint('[FaceIdService] enroll gagal: $e');
      return const FaceEnrollResult(ok: false, message: 'Koneksi bermasalah. Coba lagi.');
    }
  }

  /// Menolak: absensi tetap memakai foto biasa. Mengembalikan false bila gagal.
  Future<bool> decline() async {
    try {
      final res = await _api.post('$_faceIdPath/decline');
      return res.statusCode == 200;
    } catch (e) {
      debugPrint('[FaceIdService] decline gagal: $e');
      return false;
    }
  }

  /// Menarik persetujuan: seluruh data wajah dihapus.
  Future<bool> remove() async {
    try {
      final res = await _api.delete(_faceIdPath);
      return res.statusCode == 200;
    } catch (e) {
      debugPrint('[FaceIdService] remove gagal: $e');
      return false;
    }
  }
}
