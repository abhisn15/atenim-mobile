import 'package:flutter_test/flutter_test.dart';
import 'package:fms_mobile/models/attendance_model.dart';
import 'package:fms_mobile/utils/today_records.dart';

AttendanceRecord _rec(String id, String date, {String? checkIn = '08:00', String? checkOut, String? shiftId}) =>
    AttendanceRecord(
      id: id,
      userId: 'u',
      date: date,
      status: 'present',
      checkIn: checkIn,
      checkOut: checkOut,
      shiftId: shiftId,
    );

void main() {
  final now = DateTime(2026, 10, 7, 8, 30);

  test('cache kemarin: absen tanpa shift yang sudah pulang tidak dihitung hari ini', () {
    final cached = [_rec('a', '2026-10-06', checkOut: '17:00')];
    final result = recordsForToday(cached, fetchedAt: DateTime(2026, 10, 6, 17, 5), now: now);
    expect(result, isEmpty);
  });

  test('cache kemarin: absen yang masih terbuka tetap ikut (shift malam atau lupa pulang)', () {
    final cached = [_rec('a', '2026-10-06', shiftId: 's-malam')];
    final result = recordsForToday(cached, fetchedAt: DateTime(2026, 10, 6, 21, 5), now: DateTime(2026, 10, 7, 3, 0));
    expect(result.map((r) => r.id), ['a']);
  });

  test('cache lama tanpa penanda waktu dianggap basi', () {
    final cached = [_rec('a', '2026-10-06', checkOut: '17:00'), _rec('b', '2026-10-07', checkOut: '09:00')];
    final result = recordsForToday(cached, fetchedAt: null, now: now);
    expect(result.map((r) => r.id), ['b']);
  });

  test('data diambil dari server hari ini dipercaya apa adanya (zona waktu perangkat tidak ikut menyaring)', () {
    // Server menaruh absen terbuka kemarin di "today" dengan tanggal ditulis ulang; satu lagi sudah pulang.
    final fresh = [_rec('a', '2026-10-06', checkOut: '23:50'), _rec('b', '2026-10-07')];
    final result = recordsForToday(fresh, fetchedAt: DateTime(2026, 10, 7, 8, 0), now: now);
    expect(result.map((r) => r.id), ['a', 'b']);
  });

  test('cache hari ini yang sama tidak diubah: absen tanpa shift hari ini tetap ada (sekali per hari berlaku)', () {
    final cached = [_rec('a', '2026-10-07', checkOut: '12:00')];
    final result = recordsForToday(cached, fetchedAt: DateTime(2026, 10, 7, 12, 1), now: DateTime(2026, 10, 7, 14, 0));
    expect(result.map((r) => r.id), ['a']);
  });

  test('cache dari hari sebelumnya tetapi baris bertanggal hari ini tetap ikut', () {
    final cached = [_rec('a', '2026-10-07', checkOut: '07:00')];
    final result = recordsForToday(cached, fetchedAt: DateTime(2026, 10, 6, 23, 59), now: now);
    expect(result.map((r) => r.id), ['a']);
  });
}
