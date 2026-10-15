import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'api_service.dart';

const _faceIdPath = '/api/ess/face-id';

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
        return FaceIdState.fromJson(Map<String, dynamic>.from(body['data'] as Map));
      }
    } catch (e) {
      debugPrint('[FaceIdService] getState gagal: $e');
    }
    return null;
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
