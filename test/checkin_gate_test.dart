import 'package:flutter_test/flutter_test.dart';
import 'package:fms_mobile/models/attendance_model.dart';
import 'package:fms_mobile/utils/checkin_gate.dart';

AttendanceRecord _rec({String status = 'present', String? checkIn, String? checkOut}) {
  return AttendanceRecord(id: 'a', userId: 'u', date: '2026-10-05', status: status, checkIn: checkIn, checkOut: checkOut);
}

CheckInGate _gate(List<AttendanceRecord> records, CheckInPurpose purpose, {bool loaded = true, bool isSupervisor = false}) =>
    evaluateCheckInGate(loaded: loaded, todayRecords: records, purpose: purpose, isSupervisor: isSupervisor);

void main() {
  group('patroli: harus sedang check-in', () {
    test('belum ada absen sama sekali: ditahan dengan penjelasan', () {
      final g = _gate(const [], CheckInPurpose.patrol);
      expect(g.allowed, isFalse);
      expect(g.title, 'Check-in dulu');
      expect(g.message, contains('Check-In'));
    });

    test('sedang check-in (belum pulang): boleh', () {
      expect(_gate([_rec(checkIn: '22:00')], CheckInPurpose.patrol).allowed, isTrue);
    });

    test('shift malam: absen yang dibawa dari kemarin tetap terbuka: boleh', () {
      // server mengirimnya di daftar "hari ini" dengan checkIn terisi dan checkOut kosong
      expect(_gate([_rec(checkIn: '22:00')], CheckInPurpose.patrol).allowed, isTrue);
    });

    test('sudah check-out: ditahan (patroli hanya dihitung selama bertugas)', () {
      expect(_gate([_rec(checkIn: '08:00', checkOut: '16:00')], CheckInPurpose.patrol).allowed, isFalse);
    });

    test('data absen belum termuat: tidak menahan siapa pun', () {
      expect(_gate(const [], CheckInPurpose.patrol, loaded: false).allowed, isTrue);
    });
  });

  group('aktivitas: harus sudah check-in hari ini', () {
    test('belum check-in: ditahan', () {
      final g = _gate(const [], CheckInPurpose.activity);
      expect(g.allowed, isFalse);
      expect(g.message, contains('Check-In'));
    });

    test('sedang check-in: boleh', () {
      expect(_gate([_rec(checkIn: '08:00')], CheckInPurpose.activity).allowed, isTrue);
    });

    test('sudah check-out: tetap boleh (laporan setelah pulang tidak terhalang)', () {
      expect(_gate([_rec(checkIn: '08:00', checkOut: '16:00')], CheckInPurpose.activity).allowed, isTrue);
    });

    test('status hadir/terlambat/remote tanpa jam check-in (koreksi admin): boleh, sama dengan server', () {
      for (final s in ['present', 'late', 'remote', 'PRESENT']) {
        expect(_gate([_rec(status: s)], CheckInPurpose.activity).allowed, isTrue, reason: s);
      }
    });

    test('cuti, sakit, atau absen: tidak ditahan di HP; pesan khususnya datang dari server', () {
      for (final s in ['leave', 'sick', 'absent']) {
        expect(_gate([_rec(status: s)], CheckInPurpose.activity).allowed, isTrue, reason: s);
        expect(_gate([_rec(status: s)], CheckInPurpose.patrol).allowed, isTrue, reason: s);
      }
    });

    test('data absen belum termuat: tidak menahan siapa pun', () {
      expect(_gate(const [], CheckInPurpose.activity, loaded: false).allowed, isTrue);
    });
  });

  group('akun supervisor dibebaskan', () {
    test('tanpa absen sama sekali: boleh untuk aktivitas dan patroli (absen lewat akun karyawan)', () {
      expect(_gate(const [], CheckInPurpose.activity, isSupervisor: true).allowed, isTrue);
      expect(_gate(const [], CheckInPurpose.patrol, isSupervisor: true).allowed, isTrue);
    });

    test('karyawan dengan kondisi yang sama tetap ditahan', () {
      expect(_gate(const [], CheckInPurpose.activity).allowed, isFalse);
      expect(_gate(const [], CheckInPurpose.patrol).allowed, isFalse);
    });
  });
}
