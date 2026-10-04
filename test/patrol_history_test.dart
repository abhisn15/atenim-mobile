import 'package:flutter_test/flutter_test.dart';
import 'package:fms_mobile/models/patrol_models.dart';

PatrolQueuedScan _local(String id, DateTime at, {PatrolScanStatus status = PatrolScanStatus.pending, String? message}) {
  return PatrolQueuedScan(
    clientScanId: id,
    method: 'qr',
    pointId: 'p1',
    pointCode: 'TPM-01',
    scannedAt: at,
    condition: 'aman',
    taskResults: const [PatrolTaskResult(id: 't1', label: 'Cek pintu', done: true, photoPath: '/tmp/x.jpg')],
    localPhotoPaths: const ['/tmp/titik.jpg'],
    status: status,
    message: message,
  );
}

Map<String, dynamic> _serverJson(String id, String trustedTime, {String reviewStatus = 'pending'}) => {
      'clientScanId': id,
      'point': {'code': 'TPM-01', 'name': 'Ruangan IT', 'area': 'Lantai 2', 'floor': null},
      'trustedTime': trustedTime,
      'method': 'qr',
      'condition': 'temuan',
      'note': 'Lampu mati',
      'reason': null,
      'taskResults': [
        {'id': 't1', 'label': 'Cek pintu', 'done': true, 'note': null, 'photoUrl': 'https://storage.googleapis.com/b/p.webp'},
        {'id': 't2', 'label': 'Cek lampu', 'done': false, 'note': 'Mati', 'photoUrl': null},
      ],
      'photoUrls': ['https://storage.googleapis.com/b/titik.webp'],
      'geoLine': 'Lokasi di luar batas: 85 m dari titik (batas 30 m).',
      'reviewStatus': reviewStatus,
      'reviewedBy': reviewStatus == 'pending' ? null : 'Budi',
      'reviewedAt': reviewStatus == 'pending' ? null : '2026-10-03T07:30:00.000Z',
      'reviewNote': reviewStatus == 'rejected' ? 'Foto bukan di titik' : null,
      'round': {'windowStart': '2026-10-03T06:00:00.000Z', 'windowEnd': '2026-10-03T07:00:00.000Z'},
      'outcome': {
        'kind': reviewStatus == 'rejected' ? 'rejected_by_spv' : 'pending_review',
        'title': reviewStatus == 'rejected' ? 'Ditolak SPV' : 'Menunggu ditinjau SPV',
        'explanation': 'penjelasan',
        'reasons': ['Lokasi scan 85 m dari titik (radius 30 m)'],
        'notes': ['GPS lemah (akurasi 40 m)'],
      },
    };

void main() {
  test('JSON server dibaca lengkap: alasan, foto, tugas, ronde, dan keputusan', () {
    final item = PatrolHistoryItem.fromJson(_serverJson('a', '2026-10-03T06:30:00.000Z', reviewStatus: 'rejected'));
    expect(item.fromServer, isTrue);
    expect(item.pointCode, 'TPM-01');
    expect(item.pointName, 'Ruangan IT');
    expect(item.area, 'Lantai 2');
    expect(item.floor, isNull);
    expect(item.outcome.kind, 'rejected_by_spv');
    expect(item.outcome.reasons, ['Lokasi scan 85 m dari titik (radius 30 m)']);
    expect(item.outcome.notes, ['GPS lemah (akurasi 40 m)']);
    expect(item.reviewedBy, 'Budi');
    expect(item.reviewNote, 'Foto bukan di titik');
    expect(item.reviewedAt, isNotNull);
    expect(item.tasks.length, 2);
    expect(item.tasks[0].photoUrl, isNotNull);
    expect(item.tasks[1].done, isFalse);
    expect(item.photoUrls.length, 1);
    expect(item.photoCount, 2, reason: '1 foto titik + 1 foto tugas');
    expect(item.geoLine, contains('85 m'));
    expect(item.roundStart, isNotNull);
    expect(item.roundEnd!.isAfter(item.roundStart!), isTrue);
  });

  test('JSON rusak tidak membuat aplikasi galat', () {
    final item = PatrolHistoryItem.fromJson({'clientScanId': 'x'});
    expect(item.pointCode, '-');
    expect(item.outcome.kind, 'auto_accepted');
    expect(item.tasks, isEmpty);
    expect(item.photoCount, 0);
  });

  test('scan lokal yang belum terkirim dijelaskan jujur, tanpa mengarang alasan', () {
    final unsent = PatrolHistoryItem.fromLocal(_local('u', DateTime(2026, 10, 3, 8)));
    expect(unsent.outcome.kind, 'unsent');
    expect(unsent.outcome.reasons, isEmpty);
    expect(unsent.fromServer, isFalse);
    expect(unsent.photoCount, 2, reason: 'foto titik di HP + foto tugas di HP');

    final retry = PatrolHistoryItem.fromLocal(
      _local('r', DateTime(2026, 10, 3, 8), status: PatrolScanStatus.retry, message: 'Gagal diproses server'),
    );
    expect(retry.outcome.kind, 'unsent');
    expect(retry.outcome.explanation, contains('Gagal diproses server'));
  });

  test('status lokal dipetakan ke penilaian yang sesuai', () {
    PatrolHistoryItem map(PatrolScanStatus s, [String? m]) =>
        PatrolHistoryItem.fromLocal(_local('s', DateTime(2026, 10, 3), status: s, message: m));
    expect(map(PatrolScanStatus.flagged).outcome.kind, 'pending_review');
    expect(map(PatrolScanStatus.duplicate).outcome.kind, 'duplicate');
    expect(map(PatrolScanStatus.accepted, 'Tersimpan').outcome.kind, 'auto_accepted');
    expect(map(PatrolScanStatus.accepted, 'Diterima SPV').outcome.kind, 'accepted_by_spv');
    expect(map(PatrolScanStatus.accepted, 'Tersimpan sebagai patroli tambahan (di luar jadwal ronde)').outcome.kind, 'extra');
    expect(map(PatrolScanStatus.rejected, 'SPV: foto buram').outcome.kind, 'rejected_by_spv');
    expect(map(PatrolScanStatus.rejected, 'Kode titik tidak dikenal').outcome.kind, 'rejected_server');
  });

  test('gabungan: data server menang atas antrean HP, terbaru dulu, scan lokal baru tetap tampil', () {
    final server = [
      PatrolHistoryItem.fromJson(_serverJson('sama', '2026-10-03T06:30:00.000Z')),
      PatrolHistoryItem.fromJson(_serverJson('lama', '2026-10-02T06:30:00.000Z')),
    ];
    final local = [
      _local('sama', DateTime.parse('2026-10-03T06:30:00.000Z'), status: PatrolScanStatus.flagged),
      _local('baru', DateTime.parse('2026-10-03T09:00:00.000Z')),
    ];
    final merged = mergePatrolHistory(server: server, local: local);
    expect(merged.map((e) => e.clientScanId).toList(), ['baru', 'sama', 'lama']);
    final sama = merged.firstWhere((e) => e.clientScanId == 'sama');
    expect(sama.fromServer, isTrue);
    expect(sama.outcome.reasons, isNotEmpty, reason: 'alasan lengkap dari server, bukan kalimat lokal yang umum');
    expect(merged.firstWhere((e) => e.clientScanId == 'baru').fromServer, isFalse);
  });

  test('nama titik untuk scan lokal diambil dari paket bila ada', () {
    const point = PatrolPoint(
      id: 'p1',
      code: 'TPM-01',
      name: 'Ruangan IT',
      locationType: 'indoor',
      gpsMode: 'if_available',
      photoPolicy: 'none',
      isCritical: false,
      tasks: [],
      tagHashes: [],
    );
    final merged = mergePatrolHistory(server: const [], local: [_local('a', DateTime(2026, 10, 3))], pointsById: {'p1': point});
    expect(merged.single.pointName, 'Ruangan IT');
  });
}
