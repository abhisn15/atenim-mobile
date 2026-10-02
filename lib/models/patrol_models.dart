// Model Patroli QR. Paket (titik, rute, ronde) diunduh dari server dan disimpan di HP supaya
// patroli tetap jalan tanpa sinyal; scan masuk antrean lalu dikirim saat sinyal kembali.

String? _str(dynamic v) => v is String && v.trim().isNotEmpty ? v : null;
double? _dbl(dynamic v) => v is num ? v.toDouble() : null;
int? _int(dynamic v) => v is num ? v.toInt() : null;
List<String> _strList(dynamic v) => v is List ? v.whereType<String>().toList() : const [];

class PatrolTask {
  final String id;
  final String label;

  const PatrolTask({required this.id, required this.label});

  factory PatrolTask.fromJson(Map<String, dynamic> json) =>
      PatrolTask(id: json['id']?.toString() ?? '', label: json['label']?.toString() ?? '');

  Map<String, dynamic> toJson() => {'id': id, 'label': label};
}

class PatrolPoint {
  final String id;
  final String code;
  final String name;
  final String? area;
  final String? floor;
  final String locationType; // outdoor | indoor | enclosed
  final String gpsMode; // required | if_available | none
  final double? latitude;
  final double? longitude;
  final int? radiusMeters;
  final String photoPolicy; // none | always | random
  final bool isCritical;
  final String? instruction;
  final List<PatrolTask> tasks;
  final List<String> tagHashes;

  const PatrolPoint({
    required this.id,
    required this.code,
    required this.name,
    this.area,
    this.floor,
    required this.locationType,
    required this.gpsMode,
    this.latitude,
    this.longitude,
    this.radiusMeters,
    required this.photoPolicy,
    required this.isCritical,
    this.instruction,
    required this.tasks,
    required this.tagHashes,
  });

  /// "Gedung A · Lantai 2" (kata "Lantai" hanya ditambahkan bila isinya angka, sama seperti web)
  String get placeLabel {
    final f = floor?.trim();
    final floorText = f == null || f.isEmpty ? null : (RegExp(r'^\d+$').hasMatch(f) ? 'Lantai $f' : f);
    return [area, floorText].whereType<String>().where((s) => s.trim().isNotEmpty).join(' · ');
  }

  factory PatrolPoint.fromJson(Map<String, dynamic> json) => PatrolPoint(
        id: json['id'] as String,
        code: json['code']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        area: _str(json['area']),
        floor: _str(json['floor']),
        locationType: json['locationType']?.toString() ?? 'outdoor',
        gpsMode: json['gpsMode']?.toString() ?? 'required',
        latitude: _dbl(json['latitude']),
        longitude: _dbl(json['longitude']),
        radiusMeters: _int(json['radiusMeters']),
        photoPolicy: json['photoPolicy']?.toString() ?? 'random',
        isCritical: json['isCritical'] == true,
        instruction: _str(json['instruction']),
        tasks: (json['tasks'] is List ? json['tasks'] as List : const [])
            .whereType<Map>()
            .map((t) => PatrolTask.fromJson(Map<String, dynamic>.from(t)))
            .where((t) => t.label.isNotEmpty)
            .toList(),
        tagHashes: _strList(json['tagHashes']),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'code': code,
        'name': name,
        'area': area,
        'floor': floor,
        'locationType': locationType,
        'gpsMode': gpsMode,
        'latitude': latitude,
        'longitude': longitude,
        'radiusMeters': radiusMeters,
        'photoPolicy': photoPolicy,
        'isCritical': isCritical,
        'instruction': instruction,
        'tasks': tasks.map((t) => t.toJson()).toList(),
        'tagHashes': tagHashes,
      };
}

class PatrolRoutePoint {
  final String pointId;
  final int order;
  final bool required;

  const PatrolRoutePoint({required this.pointId, required this.order, required this.required});

  factory PatrolRoutePoint.fromJson(Map<String, dynamic> json) => PatrolRoutePoint(
        pointId: json['pointId'] as String,
        order: _int(json['order']) ?? 0,
        required: json['required'] != false,
      );

  Map<String, dynamic> toJson() => {'pointId': pointId, 'order': order, 'required': required};
}

class PatrolRoute {
  final String id;
  final String name;
  final bool isMandatoryOrder;
  final List<PatrolRoutePoint> points;

  const PatrolRoute({required this.id, required this.name, required this.isMandatoryOrder, required this.points});

  factory PatrolRoute.fromJson(Map<String, dynamic> json) {
    final points = (json['points'] is List ? json['points'] as List : const [])
        .whereType<Map>()
        .map((p) => PatrolRoutePoint.fromJson(Map<String, dynamic>.from(p)))
        .toList()
      ..sort((a, b) => a.order.compareTo(b.order));
    return PatrolRoute(
      id: json['id'] as String,
      name: json['name']?.toString() ?? '',
      isMandatoryOrder: json['isMandatoryOrder'] == true,
      points: points,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'isMandatoryOrder': isMandatoryOrder,
        'points': points.map((p) => p.toJson()).toList(),
      };
}

class PatrolRound {
  final String id;
  final String routeId;
  final DateTime windowStart;
  final DateTime windowEnd;
  final String status;
  final int requiredCount;
  final List<String> requiredPointIds;
  final List<String> donePointIds;
  final List<String> reviewPointIds;
  final List<String> skippedPointIds;

  const PatrolRound({
    required this.id,
    required this.routeId,
    required this.windowStart,
    required this.windowEnd,
    required this.status,
    required this.requiredCount,
    required this.requiredPointIds,
    required this.donePointIds,
    required this.reviewPointIds,
    this.skippedPointIds = const [],
  });

  factory PatrolRound.fromJson(Map<String, dynamic> json) => PatrolRound(
        id: json['id'] as String,
        routeId: json['routeId'] as String,
        windowStart: DateTime.parse(json['windowStart'] as String).toLocal(),
        windowEnd: DateTime.parse(json['windowEnd'] as String).toLocal(),
        status: json['status']?.toString() ?? 'scheduled',
        requiredCount: _int(json['requiredCount']) ?? 0,
        requiredPointIds: _strList(json['requiredPointIds']),
        donePointIds: _strList(json['donePointIds']),
        reviewPointIds: _strList(json['reviewPointIds']),
        skippedPointIds: _strList(json['skippedPointIds']),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'routeId': routeId,
        'windowStart': windowStart.toUtc().toIso8601String(),
        'windowEnd': windowEnd.toUtc().toIso8601String(),
        'status': status,
        'requiredCount': requiredCount,
        'requiredPointIds': requiredPointIds,
        'donePointIds': donePointIds,
        'reviewPointIds': reviewPointIds,
        'skippedPointIds': skippedPointIds,
      };
}

/// Hasil tinjauan SPV atas scan milik petugas ini, dikirim server di paket patroli.
class PatrolReview {
  final String clientScanId;
  final String reviewStatus; // none | pending | accepted | rejected
  final String? note;

  const PatrolReview({required this.clientScanId, required this.reviewStatus, this.note});

  factory PatrolReview.fromJson(Map<String, dynamic> json) => PatrolReview(
        clientScanId: json['clientScanId']?.toString() ?? '',
        reviewStatus: json['reviewStatus']?.toString() ?? 'none',
        note: _str(json['reviewNote']),
      );
}

class PatrolPack {
  final bool enabled;
  final String? siteId;
  final String? siteName;
  final String? packVersion;
  final List<PatrolPoint> points;
  final List<PatrolRoute> routes;
  final List<PatrolRound> rounds;

  /// Hasil tinjauan scan milik petugas (clientScanId -> hasil). Tidak ikut disimpan di cache paket.
  final Map<String, PatrolReview> reviews;

  /// Kapan paket ini diunduh (jam HP), untuk keterangan "paket diperbarui ...".
  final DateTime fetchedAt;

  const PatrolPack({
    required this.enabled,
    this.siteId,
    this.siteName,
    this.packVersion,
    required this.points,
    required this.routes,
    required this.rounds,
    required this.fetchedAt,
    this.reviews = const {},
  });

  factory PatrolPack.fromJson(Map<String, dynamic> json, {DateTime? fetchedAt}) {
    final site = json['site'] is Map ? Map<String, dynamic>.from(json['site'] as Map) : const <String, dynamic>{};
    List<Map<String, dynamic>> maps(String key) =>
        (json[key] is List ? json[key] as List : const []).whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList();
    return PatrolPack(
      enabled: json['enabled'] == true,
      siteId: _str(site['id']),
      siteName: _str(site['name']),
      packVersion: _str(json['packVersion']),
      points: maps('points').map(PatrolPoint.fromJson).toList(),
      routes: maps('routes').map(PatrolRoute.fromJson).toList(),
      rounds: maps('rounds').map(PatrolRound.fromJson).toList()..sort((a, b) => a.windowStart.compareTo(b.windowStart)),
      fetchedAt: fetchedAt ?? DateTime.tryParse(json['fetchedAt']?.toString() ?? '')?.toLocal() ?? DateTime.now(),
      reviews: {
        for (final r in maps('reviews').map(PatrolReview.fromJson))
          if (r.clientScanId.isNotEmpty) r.clientScanId: r,
      },
    );
  }

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'site': {'id': siteId, 'name': siteName},
        'packVersion': packVersion,
        'points': points.map((p) => p.toJson()).toList(),
        'routes': routes.map((r) => r.toJson()).toList(),
        'rounds': rounds.map((r) => r.toJson()).toList(),
        'fetchedAt': fetchedAt.toUtc().toIso8601String(),
      };

  PatrolPoint? pointById(String id) {
    for (final p in points) {
      if (p.id == id) return p;
    }
    return null;
  }

  PatrolRoute? routeById(String id) {
    for (final r in routes) {
      if (r.id == id) return r;
    }
    return null;
  }
}

/// Status scan di antrean HP.
/// - pending: belum terkirim (tanpa sinyal atau belum dicoba)
/// - accepted / flagged / duplicate / rejected: jawaban server (final)
/// - retry: server belum bisa memproses, dikirim ulang nanti
enum PatrolScanStatus { pending, accepted, flagged, duplicate, rejected, retry }

PatrolScanStatus _statusFrom(String? value) {
  for (final s in PatrolScanStatus.values) {
    if (s.name == value) return s;
  }
  return PatrolScanStatus.pending;
}

class PatrolTaskResult {
  final String id;
  final String label;
  final bool done;
  final String? note;

  /// Foto bukti tugas ini (opsional). [photoPath] = berkas di HP selama menunggu terkirim;
  /// [photoUrl] = alamat setelah terunggah, dan hanya itu yang dikirim ke server.
  final String? photoPath;
  final String? photoUrl;

  const PatrolTaskResult({
    required this.id,
    required this.label,
    required this.done,
    this.note,
    this.photoPath,
    this.photoUrl,
  });

  PatrolTaskResult copyWith({String? photoPath, String? photoUrl}) => PatrolTaskResult(
        id: id,
        label: label,
        done: done,
        note: note,
        photoPath: photoPath ?? this.photoPath,
        photoUrl: photoUrl ?? this.photoUrl,
      );

  factory PatrolTaskResult.fromJson(Map<String, dynamic> json) => PatrolTaskResult(
        id: json['id']?.toString() ?? '',
        label: json['label']?.toString() ?? '',
        done: json['done'] == true,
        note: _str(json['note']),
        photoPath: _str(json['photoPath']),
        photoUrl: _str(json['photoUrl']),
      );

  /// Bentuk yang dikirim ke server (kontrak taskResults di scanItemSchema): tanpa jalur berkas lokal.
  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'done': done,
        if (note != null && note!.trim().isNotEmpty) 'note': note!.trim(),
        if (photoUrl != null && photoUrl!.isNotEmpty) 'photoUrl': photoUrl,
      };

  /// Bentuk yang disimpan di antrean HP: ditambah jalur berkas supaya foto tidak hilang saat offline.
  Map<String, dynamic> toLocalJson() => {
        ...toJson(),
        if (photoPath != null && photoPath!.isNotEmpty) 'photoPath': photoPath,
      };
}

/// Satu scan di antrean HP. Jam scan disimpan dalam UTC (ISO dengan "Z") supaya server bisa
/// membacanya tanpa menebak zona waktu.
class PatrolQueuedScan {
  final String clientScanId;
  final String method; // qr | manual | skip
  final String? token;
  final String pointId;
  final String pointCode;
  final String? reason;
  final DateTime scannedAt;
  final double? latitude;
  final double? longitude;
  final double? accuracy;
  final int? fixAgeMs;
  final bool isMocked;
  final String condition; // aman | temuan
  final String? note;
  final List<PatrolTaskResult> taskResults;
  final List<String> localPhotoPaths;
  final List<String> uploadedPhotoUrls;
  final PatrolScanStatus status;
  final String? message;
  final int attempts;
  final String? packVersion;
  final String? appVersion;

  const PatrolQueuedScan({
    required this.clientScanId,
    required this.method,
    this.token,
    required this.pointId,
    required this.pointCode,
    this.reason,
    required this.scannedAt,
    this.latitude,
    this.longitude,
    this.accuracy,
    this.fixAgeMs,
    this.isMocked = false,
    required this.condition,
    this.note,
    required this.taskResults,
    required this.localPhotoPaths,
    this.uploadedPhotoUrls = const [],
    this.status = PatrolScanStatus.pending,
    this.message,
    this.attempts = 0,
    this.packVersion,
    this.appVersion,
  });

  /// Berkas foto tugas yang masih ada di HP (dihapus setelah scan terkirim).
  List<String> get taskPhotoPaths =>
      taskResults.map((t) => t.photoPath).whereType<String>().where((p) => p.isNotEmpty).toList();

  bool get isSent =>
      status == PatrolScanStatus.accepted ||
      status == PatrolScanStatus.flagged ||
      status == PatrolScanStatus.duplicate ||
      status == PatrolScanStatus.rejected;

  bool get needsSending => status == PatrolScanStatus.pending || status == PatrolScanStatus.retry;

  PatrolQueuedScan copyWith({
    List<PatrolTaskResult>? taskResults,
    List<String>? uploadedPhotoUrls,
    List<String>? localPhotoPaths,
    PatrolScanStatus? status,
    String? message,
    int? attempts,
  }) =>
      PatrolQueuedScan(
        clientScanId: clientScanId,
        method: method,
        token: token,
        pointId: pointId,
        pointCode: pointCode,
        reason: reason,
        scannedAt: scannedAt,
        latitude: latitude,
        longitude: longitude,
        accuracy: accuracy,
        fixAgeMs: fixAgeMs,
        isMocked: isMocked,
        condition: condition,
        note: note,
        taskResults: taskResults ?? this.taskResults,
        localPhotoPaths: localPhotoPaths ?? this.localPhotoPaths,
        uploadedPhotoUrls: uploadedPhotoUrls ?? this.uploadedPhotoUrls,
        status: status ?? this.status,
        message: message ?? this.message,
        attempts: attempts ?? this.attempts,
        packVersion: packVersion,
        appVersion: appVersion,
      );

  /// Isi yang dikirim ke POST /api/ess/patrol/sync (kontrak scanItemSchema di server).
  Map<String, dynamic> toSyncItem() => {
        'clientScanId': clientScanId,
        'method': method,
        if (method == 'qr' && token != null) 'token': token,
        if (method != 'qr') 'pointCode': pointCode,
        if (reason != null && reason!.trim().isNotEmpty) 'reason': reason!.trim(),
        'deviceTime': scannedAt.toUtc().toIso8601String(),
        if (latitude != null) 'latitude': latitude,
        if (longitude != null) 'longitude': longitude,
        if (accuracy != null) 'accuracy': accuracy,
        if (fixAgeMs != null) 'fixAgeMs': fixAgeMs,
        'isMocked': isMocked,
        'condition': condition,
        if (note != null && note!.trim().isNotEmpty) 'note': note!.trim(),
        'taskResults': taskResults.map((t) => t.toJson()).toList(),
        'photoUrls': uploadedPhotoUrls,
        if (packVersion != null) 'packVersion': packVersion,
        if (appVersion != null) 'appVersion': appVersion,
      };

  factory PatrolQueuedScan.fromJson(Map<String, dynamic> json) => PatrolQueuedScan(
        clientScanId: json['clientScanId'] as String,
        method: json['method']?.toString() ?? 'qr',
        token: _str(json['token']),
        pointId: json['pointId']?.toString() ?? '',
        pointCode: json['pointCode']?.toString() ?? '',
        reason: _str(json['reason']),
        scannedAt: DateTime.parse(json['scannedAt'] as String).toLocal(),
        latitude: _dbl(json['latitude']),
        longitude: _dbl(json['longitude']),
        accuracy: _dbl(json['accuracy']),
        fixAgeMs: _int(json['fixAgeMs']),
        isMocked: json['isMocked'] == true,
        condition: json['condition']?.toString() ?? 'aman',
        note: _str(json['note']),
        taskResults: (json['taskResults'] is List ? json['taskResults'] as List : const [])
            .whereType<Map>()
            .map((t) => PatrolTaskResult.fromJson(Map<String, dynamic>.from(t)))
            .toList(),
        localPhotoPaths: _strList(json['localPhotoPaths']),
        uploadedPhotoUrls: _strList(json['uploadedPhotoUrls']),
        status: _statusFrom(json['status']?.toString()),
        message: _str(json['message']),
        attempts: _int(json['attempts']) ?? 0,
        packVersion: _str(json['packVersion']),
        appVersion: _str(json['appVersion']),
      );

  Map<String, dynamic> toJson() => {
        'clientScanId': clientScanId,
        'method': method,
        'token': token,
        'pointId': pointId,
        'pointCode': pointCode,
        'reason': reason,
        'scannedAt': scannedAt.toUtc().toIso8601String(),
        'latitude': latitude,
        'longitude': longitude,
        'accuracy': accuracy,
        'fixAgeMs': fixAgeMs,
        'isMocked': isMocked,
        'condition': condition,
        'note': note,
        'taskResults': taskResults.map((t) => t.toLocalJson()).toList(),
        'localPhotoPaths': localPhotoPaths,
        'uploadedPhotoUrls': uploadedPhotoUrls,
        'status': status.name,
        'message': message,
        'attempts': attempts,
        'packVersion': packVersion,
        'appVersion': appVersion,
      };
}
