import 'package:flutter_test/flutter_test.dart';
import 'package:fms_mobile/models/patrol_models.dart';
import 'package:fms_mobile/screens/home/home_insights.dart';
import 'package:fms_mobile/widgets/ui_kit.dart';

PatrolHistoryItem _scan({
  String method = 'qr',
  String condition = 'aman',
  String kind = 'auto_accepted',
  String title = 'Diterima otomatis oleh sistem',
  List<PatrolHistoryTask> tasks = const [],
}) {
  return PatrolHistoryItem(
    clientScanId: 'x',
    pointCode: 'DTF-01',
    scannedAt: DateTime(2026, 10, 5, 9, 15),
    method: method,
    condition: condition,
    tasks: tasks,
    outcome: PatrolOutcomeInfo(kind: kind, title: title, explanation: ''),
  );
}

void main() {
  test('warna baris timeline mengikuti hasil penilaian', () {
    expect(patrolTimelineTone('auto_accepted'), Tone.success);
    expect(patrolTimelineTone('accepted_by_spv'), Tone.success);
    expect(patrolTimelineTone('pending_review'), Tone.warning);
    expect(patrolTimelineTone('rejected_by_spv'), Tone.danger);
    expect(patrolTimelineTone('rejected_server'), Tone.danger);
    expect(patrolTimelineTone('unsent'), Tone.info);
    expect(patrolTimelineTone('extra'), Tone.neutral);
    expect(patrolTimelineTone('duplicate'), Tone.neutral);
    expect(patrolTimelineTone('jenis-baru-yang-belum-dikenal'), Tone.neutral);
  });

  test('keterangan: hasil saja bila scan aman tanpa tugas', () {
    expect(patrolTimelineDetail(_scan()), 'Diterima otomatis oleh sistem');
  });

  test('keterangan: temuan dan jumlah tugas yang selesai', () {
    final detail = patrolTimelineDetail(_scan(
      condition: 'temuan',
      kind: 'pending_review',
      title: 'Menunggu ditinjau SPV',
      tasks: const [
        PatrolHistoryTask(label: 'Cek pintu', done: true),
        PatrolHistoryTask(label: 'Cek lampu', done: false),
        PatrolHistoryTask(label: 'Cek jendela', done: true),
      ],
    ));
    expect(detail, 'Ada temuan · Menunggu ditinjau SPV · 2 dari 3 tugas');
  });

  test('keterangan: tanpa scan QR dan dilewati disebut jelas', () {
    expect(patrolTimelineDetail(_scan(method: 'manual', kind: 'pending_review', title: 'Menunggu ditinjau SPV')),
        'Tanpa scan QR · Menunggu ditinjau SPV');
    expect(patrolTimelineDetail(_scan(method: 'skip', kind: 'skipped', title: 'Titik dilewati')), 'Dilewati · Titik dilewati');
  });

  group('jendela timeline untuk shift malam', () {
    final now = DateTime(2026, 10, 5, 1, 0); // 01.00, sudah lewat tengah malam

    test('check-in kemarin malam yang masih terbuka memulai jendela dari check-in itu', () {
      final start = timelineWindowStart(now, [DateTime(2026, 10, 4, 22, 0)]);
      expect(start, DateTime(2026, 10, 4, 22, 0));
    });

    test('check-in hari ini tidak memajukan jendela ke belakang tengah malam', () {
      expect(timelineWindowStart(now, [DateTime(2026, 10, 5, 0, 30)]), DateTime(2026, 10, 5));
      expect(timelineWindowStart(now, const []), DateTime(2026, 10, 5));
      expect(timelineWindowStart(now, [null]), DateTime(2026, 10, 5));
    });

    test('check-in yang lebih tua dari 36 jam (lupa check-out) diabaikan', () {
      expect(timelineWindowStart(now, [DateTime(2026, 10, 3, 8, 0)]), DateTime(2026, 10, 5));
    });

    test('check-in di masa depan (jam HP salah) diabaikan', () {
      expect(timelineWindowStart(now, [DateTime(2026, 10, 5, 9, 0)]), DateTime(2026, 10, 5));
    });

    test('dari beberapa check-in dipakai yang paling awal', () {
      final start = timelineWindowStart(now, [DateTime(2026, 10, 4, 23, 0), DateTime(2026, 10, 4, 21, 30)]);
      expect(start, DateTime(2026, 10, 4, 21, 30));
    });
  });

  group('jam HH:mm yang jatuh setelah tengah malam', () {
    final checkIn = DateTime(2026, 10, 4, 22, 0);

    test('jam yang masih sama hari dengan check-in tetap hari itu', () {
      expect(clockOnOrAfter(checkIn, 23 * 60 + 30), DateTime(2026, 10, 4, 23, 30));
    });

    test('jam yang lebih awal dari check-in jatuh pada hari berikutnya (istirahat 01.00, pulang 06.00)', () {
      expect(clockOnOrAfter(checkIn, 60), DateTime(2026, 10, 5, 1, 0));
      expect(clockOnOrAfter(checkIn, 6 * 60), DateTime(2026, 10, 5, 6, 0));
    });

    test('jam yang sama persis dengan check-in dianggap saat itu juga', () {
      expect(clockOnOrAfter(checkIn, 22 * 60), checkIn);
    });

    test('akhir bulan dan akhir tahun berganti dengan benar', () {
      expect(clockOnOrAfter(DateTime(2026, 12, 31, 22, 0), 6 * 60), DateTime(2027, 1, 1, 6, 0));
      expect(clockOnOrAfter(DateTime(2026, 2, 28, 22, 0), 5 * 60), DateTime(2026, 3, 1, 5, 0));
    });

    test('urutan akhir shift malam benar: check-in 22.00, patroli 23.30, istirahat 01.00, pulang 06.00', () {
      final times = [
        clockOnOrAfter(checkIn, 6 * 60),
        checkIn,
        clockOnOrAfter(checkIn, 60),
        clockOnOrAfter(checkIn, 23 * 60 + 30),
      ]..sort();
      expect(times.map((t) => '${t.day}/${t.hour}').toList(), ['4/22', '4/23', '5/1', '5/6']);
    });
  });
}
