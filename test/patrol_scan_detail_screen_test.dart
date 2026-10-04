import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fms_mobile/models/patrol_models.dart';
import 'package:fms_mobile/screens/patroli/patrol_scan_detail_screen.dart';
import 'package:intl/date_symbol_data_local.dart';

PatrolHistoryItem _item(String kind, {List<String> reasons = const [], List<String> notes = const [], bool manual = false}) {
  return PatrolHistoryItem(
    clientScanId: 'x-$kind',
    pointCode: 'DTF-01',
    pointName: 'Pintu belakang gedung utama lantai dasar sisi timur',
    area: 'Area parkir timur',
    floor: 'Lantai dasar',
    scannedAt: DateTime(2026, 10, 3, 21, 5),
    method: manual ? 'manual' : 'qr',
    condition: 'temuan',
    note: 'Lampu koridor mati dan pintu samping tidak terkunci rapat, sudah saya laporkan ke SPV lewat telepon.',
    reason: manual ? 'Stiker rusak terkena air hujan' : null,
    tasks: const [
      PatrolHistoryTask(label: 'Pastikan pintu samping terkunci dan tidak ada barang tertinggal', done: true, photoPath: '/tidak/ada.jpg'),
      PatrolHistoryTask(label: 'Cek lampu koridor', done: false, note: 'Mati sejak sore'),
    ],
    geoLine: 'Lokasi di luar batas: 85 m dari titik (batas 30 m).',
    reviewStatus: kind.endsWith('_by_spv') ? 'accepted' : 'none',
    reviewedBy: kind.endsWith('_by_spv') ? 'Budi Santoso' : null,
    reviewedAt: kind.endsWith('_by_spv') ? DateTime(2026, 10, 3, 22, 10) : null,
    reviewNote: kind.endsWith('_by_spv') ? 'Sudah dicek CCTV, benar ada di titik' : null,
    roundStart: DateTime(2026, 10, 3, 21),
    roundEnd: DateTime(2026, 10, 3, 22),
    outcome: PatrolOutcomeInfo(
      kind: kind,
      title: 'Judul hasil penilaian yang cukup panjang untuk memeriksa pemotongan baris',
      explanation:
          'Penjelasan panjang: SPV Budi Santoso sudah memeriksa scan ini dan menerimanya. Titik dihitung selesai. Catatan SPV: Sudah dicek CCTV, benar ada di titik.',
      reasons: reasons,
      notes: notes,
    ),
    fromServer: true,
  );
}

void main() {
  setUpAll(() async {
    await initializeDateFormatting('id_ID');
  });

  const kinds = [
    'auto_accepted',
    'extra',
    'pending_review',
    'accepted_by_spv',
    'rejected_by_spv',
    'duplicate',
    'skipped',
    'unsent',
    'rejected_server',
  ];

  for (final scale in [1.0, 1.8]) {
    testWidgets('detail tidak meluap di layar 320 px, teks ${scale}x, semua jenis hasil', (tester) async {
      tester.view.physicalSize = const Size(320 * 2, 640 * 2);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);

      for (final kind in kinds) {
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: PatrolScanDetailScreen(
              item: _item(
                kind,
                reasons: const ['Lokasi scan 85 m dari titik (radius 30 m)', 'Jam scan jauh sebelum data tiba (lebih dari batas sinkron)'],
                notes: const ['GPS lemah (akurasi 40 m)'],
                manual: kind == 'rejected_by_spv',
              ),
            ),
          ),
        );
        expect(tester.takeException(), isNull, reason: 'jenis $kind pada skala $scale');
        expect(find.text('Detail scan'), findsOneWidget);
        // Gulir pelan-pelan sampai bagian Lokasi (paling bawah) supaya seluruh isi daftar terbangun dan diperiksa
        await tester.scrollUntilVisible(find.text('Lokasi'), 300);
        expect(tester.takeException(), isNull, reason: 'saat menggulir, jenis $kind pada skala $scale');
        expect(find.text('Lokasi'), findsOneWidget);
      }
    });
  }

  testWidgets('alasan, keterangan peninjau, dan tugas tampil di layar', (tester) async {
    tester.view.physicalSize = const Size(400 * 2, 900 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: PatrolScanDetailScreen(
          item: _item('accepted_by_spv', reasons: const ['Lokasi scan 85 m dari titik (radius 30 m)'], notes: const ['GPS lemah (akurasi 40 m)']),
        ),
      ),
    );
    expect(find.text('Ditandai karena'), findsOneWidget);
    expect(find.text('Lokasi scan 85 m dari titik (radius 30 m)'), findsOneWidget);
    expect(find.text('Catatan sistem'), findsOneWidget);
    expect(find.textContaining('Ditinjau oleh Budi Santoso'), findsOneWidget);
    expect(find.textContaining('Ronde 21.00-22.00'), findsOneWidget);
    await tester.scrollUntilVisible(find.textContaining('Cek lampu koridor (tidak dikerjakan)'), 200);
    expect(find.textContaining('Cek lampu koridor (tidak dikerjakan)'), findsOneWidget);
  });
}
