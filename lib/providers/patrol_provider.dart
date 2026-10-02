import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../models/patrol_models.dart';
import '../services/patrol_service.dart';

/// Keadaan satu titik di satu ronde, dilihat dari HP petugas.
enum PatrolPointState {
  /// Belum ada scan
  todo,

  /// Tersimpan di HP, belum terkirim
  queued,

  /// Sah (oleh petugas ini atau rekan satu shift)
  done,

  /// Terkirim tetapi menunggu keputusan SPV
  review,

  /// Dilewati dengan alasan
  skipped,

  /// Ditolak server (mis. stiker palsu)
  rejected,
}

class PatrolPointProgress {
  final PatrolPointState state;

  /// Scan terakhir petugas ini untuk titik itu di ronde itu (null bila hanya dari data server)
  final PatrolQueuedScan? scan;

  const PatrolPointProgress(this.state, [this.scan]);
}

/// Scan boleh sedikit di luar jendela ronde dan tetap masuk ronde itu (sama dengan server).
const _roundSlack = Duration(minutes: 10);

class PatrolProvider extends ChangeNotifier {
  final PatrolService _service = PatrolService();
  StreamSubscription<List<ConnectivityResult>>? _connSub;
  Timer? _retryTimer;

  String? _userId;
  PatrolPack? _pack;
  List<PatrolQueuedScan> _queue = [];
  bool _initializing = false;
  bool _loadingPack = false;
  bool _syncing = false;
  String? _packError;
  String? _syncError;
  String? _forbiddenMessage;
  DateTime? _lastSyncAt;
  String? _appVersion;

  PatrolPack? get pack => _pack;
  bool get initializing => _initializing;
  bool get loadingPack => _loadingPack;
  bool get syncing => _syncing;
  String? get packError => _packError;
  String? get syncError => _syncError;
  String? get forbiddenMessage => _forbiddenMessage;
  DateTime? get lastSyncAt => _lastSyncAt;
  bool get isQrEnabled => _pack?.enabled == true && _forbiddenMessage == null;
  List<PatrolQueuedScan> get queue => List.unmodifiable(_queue);
  int get pendingCount => _queue.where((q) => q.needsSending).length;

  PatrolProvider() {
    _connSub = Connectivity().onConnectivityChanged.listen((results) {
      final online = results.any((r) => r != ConnectivityResult.none);
      if (online && _userId != null && pendingCount > 0) unawaited(syncNow());
    });
  }

  @override
  void dispose() {
    _connSub?.cancel();
    _retryTimer?.cancel();
    super.dispose();
  }

  /// Muat data akun ini (paket & antrean tersimpan), lalu perbarui dari server. Aman dipanggil berkali-kali.
  Future<void> ensureUser(String userId) async {
    if (_userId == userId) return;
    _userId = userId;
    _pack = null;
    _queue = [];
    _packError = null;
    _syncError = null;
    _forbiddenMessage = null;
    _initializing = true;
    notifyListeners();
    try {
      _appVersion ??= (await PackageInfo.fromPlatform()).version;
    } catch (_) {}
    _pack = await _service.loadCachedPack(userId);
    _queue = await _service.loadQueue(userId);
    _pruneQueue();
    _initializing = false;
    notifyListeners();
    await refresh();
  }

  void clear() {
    _userId = null;
    _pack = null;
    _queue = [];
    _retryTimer?.cancel();
    notifyListeners();
  }

  /// Unduh paket terbaru lalu kirim antrean.
  Future<void> refresh() async {
    await _fetchPack();
    await syncNow();
  }

  Future<void> _fetchPack() async {
    final userId = _userId;
    if (userId == null || _loadingPack) return;
    _loadingPack = true;
    notifyListeners();
    try {
      final fresh = await _service.fetchPack();
      if (_userId != userId) return;
      _pack = fresh;
      _packError = null;
      _forbiddenMessage = null;
      await _service.saveCachedPack(userId, fresh);
      await _applyReviews(userId, fresh.reviews);
    } on PatrolForbiddenException catch (e) {
      _forbiddenMessage = e.message;
    } catch (e) {
      _packError = e.toString();
    } finally {
      _loadingPack = false;
      notifyListeners();
    }
  }

  /// Perbarui status scan lokal yang tadinya "ditinjau SPV" bila SPV sudah menerima atau menolaknya.
  Future<void> _applyReviews(String userId, Map<String, PatrolReview> reviews) async {
    if (reviews.isEmpty) return;
    var changed = false;
    for (final q in List<PatrolQueuedScan>.from(_queue)) {
      final review = reviews[q.clientScanId];
      if (review == null || q.status != PatrolScanStatus.flagged) continue;
      if (review.reviewStatus == 'accepted') {
        _replace(q.copyWith(status: PatrolScanStatus.accepted, message: 'Diterima SPV'));
        changed = true;
      } else if (review.reviewStatus == 'rejected') {
        final note = (review.note ?? '').trim();
        _replace(q.copyWith(status: PatrolScanStatus.rejected, message: note.isEmpty ? 'SPV menolak scan ini' : 'SPV: $note'));
        changed = true;
      }
    }
    if (changed) await _service.saveQueue(userId, _queue);
  }

  // ---------- stiker & titik ----------

  /// Titik untuk isi QR, dicari lewat hash token di paket (bisa tanpa sinyal). null bila tidak dikenal.
  PatrolPoint? pointForToken(String token) {
    final pack = _pack;
    if (pack == null) return null;
    final hash = hashPatrolToken(token);
    for (final point in pack.points) {
      if (point.tagHashes.contains(hash)) return point;
    }
    return null;
  }

  // ---------- ronde ----------

  List<PatrolRound> get rounds => _pack?.rounds ?? const [];

  /// Ronde yang sedang berjalan (dengan kelonggaran), paling awal lebih dulu.
  List<PatrolRound> activeRounds(DateTime now) => rounds
      .where((r) => !now.isBefore(r.windowStart.subtract(_roundSlack)) && !now.isAfter(r.windowEnd.add(_roundSlack)))
      .toList();

  PatrolRound? nextRound(DateTime now) {
    for (final r in rounds) {
      if (r.windowStart.isAfter(now)) return r;
    }
    return null;
  }

  /// Titik rute ronde itu, urut sesuai rute; titik yang tidak ada di paket dilewati.
  List<PatrolPoint> pointsOfRound(PatrolRound round) {
    final pack = _pack;
    final route = pack?.routeById(round.routeId);
    if (pack == null || route == null) return const [];
    return route.points.map((rp) => pack.pointById(rp.pointId)).whereType<PatrolPoint>().toList();
  }

  bool isRequiredIn(PatrolRound round, String pointId) =>
      round.requiredPointIds.isEmpty || round.requiredPointIds.contains(pointId);

  bool _inWindow(PatrolRound round, DateTime at) =>
      !at.isBefore(round.windowStart.subtract(_roundSlack)) && !at.isAfter(round.windowEnd.add(_roundSlack));

  /// Scan yang sudah dijawab server mengikuti data ronde di paket (server yang menentukan rondenya),
  /// asalkan paket diunduh setelah scan itu. Tebakan jendela di HP hanya untuk scan yang belum terkirim.
  bool _useLocal(PatrolQueuedScan q) {
    final fetchedAt = _pack?.fetchedAt;
    return q.needsSending || fetchedAt == null || !fetchedAt.isAfter(q.scannedAt);
  }

  PatrolPointProgress progressOf(PatrolRound round, String pointId) {
    final inWindow = _queue.where((q) => q.pointId == pointId && _inWindow(round, q.scannedAt)).toList()
      ..sort((a, b) => b.scannedAt.compareTo(a.scannedAt));
    final mine = inWindow.where(_useLocal).toList();
    PatrolQueuedScan? pickIn(List<PatrolQueuedScan> list, bool Function(PatrolQueuedScan) test) {
      for (final q in list) {
        if (test(q)) return q;
      }
      return null;
    }

    PatrolQueuedScan? pick(bool Function(PatrolQueuedScan) test) => pickIn(mine, test);
    bool isAccepted(PatrolQueuedScan q) =>
        q.method != 'skip' && (q.status == PatrolScanStatus.accepted || q.status == PatrolScanStatus.duplicate);

    final accepted = pick(isAccepted);
    if (accepted != null) return PatrolPointProgress(PatrolPointState.done, accepted);
    // Sah menurut server: tampilkan scan petugas ini bila ada, selain itu berarti rekan satu shift
    if (round.donePointIds.contains(pointId)) return PatrolPointProgress(PatrolPointState.done, pickIn(inWindow, isAccepted));
    final queued = pick((q) => q.method != 'skip' && q.needsSending);
    if (queued != null) return PatrolPointProgress(PatrolPointState.queued, queued);
    final flagged = pick((q) => q.status == PatrolScanStatus.flagged);
    if (flagged != null) return PatrolPointProgress(PatrolPointState.review, flagged);
    if (round.reviewPointIds.contains(pointId)) {
      return PatrolPointProgress(PatrolPointState.review, pickIn(inWindow, (q) => q.status == PatrolScanStatus.flagged));
    }
    final skipped = pick((q) => q.method == 'skip');
    if (skipped != null) return PatrolPointProgress(PatrolPointState.skipped, skipped);
    if (round.skippedPointIds.contains(pointId)) return const PatrolPointProgress(PatrolPointState.skipped);
    final rejected = pick((q) => q.status == PatrolScanStatus.rejected);
    if (rejected != null) return PatrolPointProgress(PatrolPointState.rejected, rejected);
    return const PatrolPointProgress(PatrolPointState.todo);
  }

  /// (sudah sah atau tersimpan di HP, jumlah titik wajib)
  (int, int) countOf(PatrolRound round) {
    final required = pointsOfRound(round).where((p) => isRequiredIn(round, p.id)).toList();
    final done = required.where((p) {
      final s = progressOf(round, p.id).state;
      return s == PatrolPointState.done || s == PatrolPointState.queued;
    }).length;
    return (done, required.length);
  }

  // ---------- simpan & kirim ----------

  String newClientScanId() {
    final rnd = Random.secure();
    return List.generate(16, (_) => rnd.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  /// Simpan hasil cek ke antrean (langsung aman di HP), lalu coba kirim.
  Future<PatrolQueuedScan> submit({
    required String clientScanId,
    required String method,
    String? token,
    required PatrolPoint point,
    String? reason,
    required DateTime scannedAt,
    double? latitude,
    double? longitude,
    double? accuracy,
    int? fixAgeMs,
    bool isMocked = false,
    required String condition,
    String? note,
    required List<PatrolTaskResult> taskResults,
    required List<File> photos,
    Map<String, File> taskPhotos = const {},
  }) async {
    final userId = _userId;
    if (userId == null) throw StateError('Belum masuk');
    final kept = <String>[];
    for (var i = 0; i < photos.length; i++) {
      kept.add(await _service.keepPhoto(userId, photos[i], clientScanId, i));
    }
    // Foto per tugas: hanya untuk tugas yang dicentang. Indeks 100+ supaya nama berkas tidak bentrok
    // dengan foto titik.
    var taskPhotoIndex = 100;
    final resultsWithPhotos = <PatrolTaskResult>[];
    for (final t in taskResults) {
      final file = t.done ? taskPhotos[t.id] : null;
      if (file == null) {
        resultsWithPhotos.add(t);
        continue;
      }
      final path = await _service.keepPhoto(userId, file, clientScanId, taskPhotoIndex++);
      resultsWithPhotos.add(t.copyWith(photoPath: path));
    }
    final scan = PatrolQueuedScan(
      clientScanId: clientScanId,
      method: method,
      token: token,
      pointId: point.id,
      pointCode: point.code,
      reason: reason,
      scannedAt: scannedAt,
      latitude: latitude,
      longitude: longitude,
      accuracy: accuracy,
      fixAgeMs: fixAgeMs,
      isMocked: isMocked,
      condition: condition,
      note: note,
      taskResults: resultsWithPhotos,
      localPhotoPaths: kept,
      packVersion: _pack?.packVersion,
      appVersion: _appVersion,
    );
    _queue.add(scan);
    await _service.saveQueue(userId, _queue);
    notifyListeners();
    // Tunggu kiriman sebentar saja; sinyal lemah tidak boleh menahan petugas di layar ini.
    // Bila belum selesai, kiriman berlanjut di latar dan statusnya muncul di daftar.
    await Future.any([syncNow(), Future<void>.delayed(const Duration(seconds: 8))]);
    return _queue.firstWhere((q) => q.clientScanId == clientScanId, orElse: () => scan);
  }

  PatrolQueuedScan? scanById(String clientScanId) {
    for (final q in _queue) {
      if (q.clientScanId == clientScanId) return q;
    }
    return null;
  }

  void _replace(PatrolQueuedScan updated) {
    final i = _queue.indexWhere((q) => q.clientScanId == updated.clientScanId);
    if (i >= 0) _queue[i] = updated;
  }

  /// Kirim antrean: unggah foto yang belum terunggah, lalu kirim scan per 50.
  /// Tanpa sinyal: berhenti diam-diam, antrean tetap tersimpan dan dicoba lagi nanti.
  Future<void> syncNow() async {
    final userId = _userId;
    if (userId == null || _syncing || _forbiddenMessage != null) return;
    final pending = _queue.where((q) => q.needsSending).toList()..sort((a, b) => a.scannedAt.compareTo(b.scannedAt));
    if (pending.isEmpty) return;
    _syncing = true;
    _syncError = null;
    notifyListeners();
    var anyFinal = false;
    try {
      final ready = <PatrolQueuedScan>[];
      for (final item in pending) {
        var current = item;
        final urls = [...current.uploadedPhotoUrls];
        for (var i = urls.length; i < current.localPhotoPaths.length; i++) {
          final path = current.localPhotoPaths[i];
          if (!await File(path).exists()) continue; // foto terhapus sistem: kirim tanpa foto itu
          urls.add(await _service.uploadPhoto(path));
          current = current.copyWith(uploadedPhotoUrls: [...urls]);
          _replace(current);
          await _service.saveQueue(userId, _queue);
        }
        // Foto per tugas: unggah satu per satu dan simpan alamatnya di antrean supaya tidak terunggah ulang.
        for (var i = 0; i < current.taskResults.length; i++) {
          final task = current.taskResults[i];
          final path = task.photoPath;
          if (path == null || path.isEmpty || task.photoUrl != null) continue;
          if (!await File(path).exists()) continue; // foto terhapus sistem: kirim tanpa foto itu
          final url = await _service.uploadPhoto(path);
          final updatedTasks = [...current.taskResults];
          updatedTasks[i] = task.copyWith(photoUrl: url);
          current = current.copyWith(taskResults: updatedTasks);
          _replace(current);
          await _service.saveQueue(userId, _queue);
        }
        ready.add(current);
      }
      for (var start = 0; start < ready.length; start += 50) {
        final batch = ready.sublist(start, min(start + 50, ready.length));
        final results = await _service.sync(batch);
        final byId = {for (final r in results) r.clientScanId: r};
        for (final item in batch) {
          final r = byId[item.clientScanId];
          if (r == null) continue;
          final updated = item.copyWith(status: r.status, message: r.message, attempts: item.attempts + 1);
          _replace(updated);
          if (updated.isSent) {
            anyFinal = true;
            await _service.deletePhotos([...updated.localPhotoPaths, ...updated.taskPhotoPaths]);
          }
        }
        await _service.saveQueue(userId, _queue);
      }
      _lastSyncAt = DateTime.now();
      _retryTimer?.cancel();
      if (pendingCount > 0) _scheduleRetry();
    } on PatrolForbiddenException catch (e) {
      _forbiddenMessage = e.message;
    } catch (e) {
      _syncError = e.toString();
      _scheduleRetry();
    } finally {
      _syncing = false;
      notifyListeners();
    }
    // Perbarui tanda "sudah dicek" dari server (termasuk scan rekan satu shift)
    if (anyFinal) await _fetchPack();
  }

  void _scheduleRetry() {
    _retryTimer?.cancel();
    _retryTimer = Timer(const Duration(minutes: 2), () => unawaited(syncNow()));
  }

  /// Riwayat di HP: scan terkirim disimpan 36 jam untuk ditampilkan, yang belum terkirim tidak pernah dibuang.
  void _pruneQueue() {
    final cutoff = DateTime.now().subtract(const Duration(hours: 36));
    _queue.removeWhere((q) => q.isSent && q.scannedAt.isBefore(cutoff));
  }
}
