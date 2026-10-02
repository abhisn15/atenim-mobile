import 'package:flutter_test/flutter_test.dart';
import 'package:fms_mobile/models/attendance_model.dart';

AttendanceRecord _rec({
  String? checkIn,
  String? checkOut,
  DateTime? checkInAt,
  DateTime? checkOutAt,
}) =>
    AttendanceRecord(
      id: 't',
      userId: 'u',
      date: '2026-10-01',
      status: 'present',
      checkIn: checkIn,
      checkOut: checkOut,
      checkInAt: checkInAt,
      checkOutAt: checkOutAt,
    );

void main() {
  test('masuk 07:00 kemarin, pulang 10:00 hari ini = 27 jam (bukan 3 jam)', () {
    final r = _rec(
      checkIn: '07:00',
      checkOut: '10:00',
      checkInAt: DateTime.utc(2026, 10, 1, 0, 0),
      checkOutAt: DateTime.utc(2026, 10, 2, 3, 0),
    );
    expect(r.workDurationMinutes(), 27 * 60);
  });

  test('shift malam lewat tengah malam tetap benar', () {
    final r = _rec(
      checkIn: '22:00',
      checkOut: '06:00',
      checkInAt: DateTime.utc(2026, 10, 1, 15, 0),
      checkOutAt: DateTime.utc(2026, 10, 1, 23, 0),
    );
    expect(r.workDurationMinutes(), 8 * 60);
  });

  test('belum pulang: dihitung sampai sekarang dari waktu penuh', () {
    final r = _rec(checkIn: '07:00', checkInAt: DateTime.utc(2026, 10, 1, 0, 0));
    expect(r.workDurationMinutes(now: DateTime.utc(2026, 10, 2, 3, 0)), 27 * 60);
  });

  test('belum pulang dan tanpa now: null', () {
    final r = _rec(checkIn: '07:00', checkInAt: DateTime.utc(2026, 10, 1, 0, 0));
    expect(r.workDurationMinutes(), isNull);
  });

  test('data lama tanpa waktu penuh: cadangan dari HH:mm, lewat tengah malam +24 jam', () {
    expect(_rec(checkIn: '08:00', checkOut: '17:00').workDurationMinutes(), 9 * 60);
    expect(_rec(checkIn: '22:00', checkOut: '06:00').workDurationMinutes(), 8 * 60);
  });

  test('pulang lebih awal dari masuk (jam janggal): null, bukan angka palsu', () {
    final r = _rec(
      checkIn: '07:00',
      checkOut: '06:00',
      checkInAt: DateTime.utc(2026, 10, 2, 0, 0),
      checkOutAt: DateTime.utc(2026, 10, 1, 23, 0),
    );
    expect(r.workDurationMinutes(), isNull);
  });

  test('belum pulang tanpa waktu penuh: null, tidak menebak', () {
    expect(_rec(checkIn: '07:00').workDurationMinutes(now: DateTime.utc(2026, 10, 2, 3, 0)), isNull);
  });
}
