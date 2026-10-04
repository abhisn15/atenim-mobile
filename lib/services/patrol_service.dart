import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../config/api_config.dart';
import '../models/patrol_models.dart';
import 'api_service.dart';

/// Hasil sinkron satu scan dari server.
class PatrolSyncResult {
  final String clientScanId;
  final PatrolScanStatus status;
  final String message;

  const PatrolSyncResult(this.clientScanId, this.status, this.message);
}

/// Galat jaringan / server sementara: antrean tetap disimpan dan dikirim ulang nanti.
class PatrolOfflineException implements Exception {
  final String message;
  const PatrolOfflineException(this.message);
  @override
  String toString() => message;
}

/// Server menolak seluruh permintaan (mis. akun bukan petugas security). Tidak diulang otomatis.
class PatrolForbiddenException implements Exception {
  final String message;
  const PatrolForbiddenException(this.message);
  @override
  String toString() => message;
}

const _qrPrefix = 'MMSP1:';

/// Isi QR ("MMSP1:...") atau token saja -> token; null bila bukan stiker patroli (aturan sama dengan server).
String? normalizePatrolToken(String raw) {
  final trimmed = raw.trim();
  final token = trimmed.startsWith(_qrPrefix) ? trimmed.substring(_qrPrefix.length) : trimmed;
  return RegExp(r'^[A-Z2-7]{16,64}$').hasMatch(token) ? token : null;
}

/// Hash SHA-256 token (hex), sama dengan yang dikirim server di paket (tagHashes).
String hashPatrolToken(String token) => sha256.convert(utf8.encode(token)).toString();

class PatrolService {
  final ApiService _api = ApiService();

  // ---------- penyimpanan lokal per akun ----------

  Future<Directory> _dir(String userId) async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(base.path, 'patrol', userId));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<File> _file(String userId, String name) async => File(p.join((await _dir(userId)).path, name));

  /// Tulis lewat file sementara lalu rename, supaya file tidak setengah jadi bila app mati saat menulis.
  Future<void> _writeAtomic(File file, String content) async {
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(content, flush: true);
    await tmp.rename(file.path);
  }

  Future<PatrolPack?> loadCachedPack(String userId) async {
    try {
      final file = await _file(userId, 'pack.json');
      if (!await file.exists()) return null;
      return PatrolPack.fromJson(jsonDecode(await file.readAsString()) as Map<String, dynamic>);
    } catch (e) {
      debugPrint('[Patrol] Paket lokal tidak terbaca: $e');
      return null;
    }
  }

  Future<void> saveCachedPack(String userId, PatrolPack pack) async {
    await _writeAtomic(await _file(userId, 'pack.json'), jsonEncode(pack.toJson()));
  }

  Future<List<PatrolHistoryItem>> loadCachedHistory(String userId) async {
    try {
      final file = await _file(userId, 'history.json');
      if (!await file.exists()) return [];
      final list = jsonDecode(await file.readAsString());
      if (list is! List) return [];
      return list.whereType<Map>().map((m) => PatrolHistoryItem.fromJson(Map<String, dynamic>.from(m))).toList();
    } catch (e) {
      debugPrint('[Patrol] Riwayat lokal tidak terbaca: $e');
      return [];
    }
  }

  Future<void> saveCachedHistory(String userId, List<Map<String, dynamic>> raw) async {
    await _writeAtomic(await _file(userId, 'history.json'), jsonEncode(raw));
  }

  Future<List<PatrolQueuedScan>> loadQueue(String userId) async {
    try {
      final file = await _file(userId, 'queue.json');
      if (!await file.exists()) return [];
      final list = jsonDecode(await file.readAsString());
      if (list is! List) return [];
      return list.whereType<Map>().map((m) => PatrolQueuedScan.fromJson(Map<String, dynamic>.from(m))).toList();
    } catch (e) {
      debugPrint('[Patrol] Antrean lokal tidak terbaca: $e');
      return [];
    }
  }

  Future<void> saveQueue(String userId, List<PatrolQueuedScan> queue) async {
    await _writeAtomic(await _file(userId, 'queue.json'), jsonEncode(queue.map((q) => q.toJson()).toList()));
  }

  /// Salin foto dari kamera ke folder patroli (folder cache kamera bisa dibersihkan sistem).
  Future<String> keepPhoto(String userId, File photo, String clientScanId, int index) async {
    final dir = Directory(p.join((await _dir(userId)).path, 'photos'));
    if (!await dir.exists()) await dir.create(recursive: true);
    final ext = p.extension(photo.path).isEmpty ? '.jpg' : p.extension(photo.path);
    final target = p.join(dir.path, '$clientScanId-$index$ext');
    await photo.copy(target);
    return target;
  }

  Future<void> deletePhotos(List<String> paths) async {
    for (final path in paths) {
      try {
        final f = File(path);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
  }

  // ---------- server ----------

  Future<PatrolPack> fetchPack() async {
    final Response res;
    try {
      res = await _api.get(ApiConfig.essPatrolPack);
    } on DioException catch (e) {
      throw PatrolOfflineException(e.error?.toString() ?? 'Tidak dapat terhubung ke server.');
    }
    if (res.statusCode != 200 || res.data is! Map) {
      throw PatrolOfflineException('Paket patroli belum bisa diunduh (kode ${res.statusCode}).');
    }
    final data = (res.data as Map)['data'];
    if (data is! Map) throw const PatrolOfflineException('Jawaban server tidak dikenali.');
    return PatrolPack.fromJson(Map<String, dynamic>.from(data), fetchedAt: DateTime.now());
  }

  /// Riwayat scan milik petugas dari server (14 hari terakhir), sudah lengkap dengan foto dan alasan.
  Future<List<Map<String, dynamic>>> fetchHistoryRaw() async {
    final Response res;
    try {
      res = await _api.get(ApiConfig.essPatrolHistory, queryParameters: {'days': 14, 'limit': 60});
    } on DioException catch (e) {
      throw PatrolOfflineException(e.error?.toString() ?? 'Tidak dapat terhubung ke server.');
    }
    final data = res.data is Map ? (res.data as Map)['data'] : null;
    if (res.statusCode != 200 || data is! List) {
      throw PatrolOfflineException('Riwayat patroli belum bisa dimuat (kode ${res.statusCode}).');
    }
    return data.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList();
  }

  Future<String> uploadPhoto(String path) async {
    final Response res;
    try {
      final form = FormData.fromMap({'photo': await MultipartFile.fromFile(path, filename: p.basename(path))});
      res = await _api.postFormData(ApiConfig.essPatrolPhoto, form);
    } on DioException catch (e) {
      throw PatrolOfflineException(e.error?.toString() ?? 'Tidak dapat terhubung ke server.');
    }
    final body = res.data is Map ? res.data as Map : const {};
    if (res.statusCode == 403) throw PatrolForbiddenException(body['message']?.toString() ?? 'Akses ditolak');
    final url = body['data'] is Map ? (body['data'] as Map)['photoUrl']?.toString() : null;
    if (res.statusCode != 200 || url == null) {
      throw PatrolOfflineException(body['message']?.toString() ?? 'Foto belum terunggah (kode ${res.statusCode}).');
    }
    return url;
  }

  Future<List<PatrolSyncResult>> sync(List<PatrolQueuedScan> items) async {
    final Response res;
    try {
      res = await _api.post(ApiConfig.essPatrolSync, data: {'items': items.map((i) => i.toSyncItem()).toList()});
    } on DioException catch (e) {
      throw PatrolOfflineException(e.error?.toString() ?? 'Tidak dapat terhubung ke server.');
    }
    final body = res.data is Map ? res.data as Map : const {};
    if (res.statusCode == 401 || res.statusCode == 403) {
      throw PatrolForbiddenException(body['message']?.toString() ?? 'Akses ditolak');
    }
    if (res.statusCode != 200 || body['data'] is! List) {
      throw PatrolOfflineException(body['message']?.toString() ?? 'Server belum bisa menerima scan (kode ${res.statusCode}).');
    }
    return (body['data'] as List).whereType<Map>().map((m) {
      final status = m['status']?.toString();
      return PatrolSyncResult(
        m['clientScanId']?.toString() ?? '',
        PatrolScanStatus.values.firstWhere((s) => s.name == status, orElse: () => PatrolScanStatus.retry),
        m['message']?.toString() ?? '',
      );
    }).toList();
  }
}
