import 'package:flutter_test/flutter_test.dart';
import 'package:fms_mobile/models/attendance_model.dart';
import 'package:fms_mobile/models/shift_assignment_model.dart';
import 'package:fms_mobile/models/shift_model.dart';
import 'package:fms_mobile/utils/phone_contact.dart';
import 'package:fms_mobile/utils/team_day_stats.dart';

ShiftAssignment _assign(String owner, String name, String date, String start, String end, {String? dayType}) {
  return ShiftAssignment(
    id: '$owner-$date',
    date: date,
    ownerId: owner,
    owner: ShiftOwner(id: owner, name: name),
    dailyShift: DailyShift(id: 's', name: 'Shift $start', code: 'S', startTime: start, endTime: end, dayType: dayType),
  );
}

LeaderAttendanceLogItem _log(String user, String name, String date, {String? checkIn, String? checkOut, String status = 'present'}) {
  return LeaderAttendanceLogItem(id: '$user-$date', userId: user, date: date, status: status, checkIn: checkIn, checkOut: checkOut, userName: name);
}

void main() {
  group('normalizeIndonesianPhone', () {
    test('format umum diubah ke 62...', () {
      expect(normalizeIndonesianPhone('0812-3456-7890'), '6281234567890');
      expect(normalizeIndonesianPhone('+62 812 3456 7890'), '6281234567890');
      expect(normalizeIndonesianPhone('6281234567890'), '6281234567890');
      expect(normalizeIndonesianPhone('81234567890'), '6281234567890');
      expect(normalizeIndonesianPhone('(0812) 3456.7890'), '6281234567890');
    });

    test('data HRIS kosong atau rusak menghasilkan null, bukan tombol yang pasti gagal', () {
      for (final bad in [null, '', '  ', '-', '--', 'tidak ada', '0', '08', '12345', '99999999999999999999']) {
        expect(normalizeIndonesianPhone(bad), isNull, reason: '$bad');
      }
    });

    test('nomor luar negeri hanya diterima bila ditulis lengkap dengan +', () {
      expect(normalizeIndonesianPhone('+60123456789'), '60123456789');
      expect(normalizeIndonesianPhone('60123456789'), isNull);
    });
  });

  group('tautan WhatsApp dan telepon', () {
    test('wa.me memakai nomor internasional dan pesan ter-encode', () {
      final uri = whatsappUri('0812-3456-7890', message: 'Halo Budi, ada kendala?')!;
      expect(uri.host, 'wa.me');
      expect(uri.path, '/6281234567890');
      expect(uri.queryParameters['text'], 'Halo Budi, ada kendala?');
      expect(uri.toString(), contains('text=Halo%20Budi'));
    });

    test('tanpa pesan tidak ada parameter text; nomor tidak valid menghasilkan null', () {
      expect(whatsappUri('0812-3456-7890')!.hasQuery, isFalse);
      expect(whatsappUri('-'), isNull);
      expect(telUri('-'), isNull);
      expect(telUri('0812-3456-7890').toString(), 'tel:+6281234567890');
    });
  });

  group('contactMessage', () {
    test('belum check-in: sopan, bertanya, memakai nama depan', () {
      final m = contactMessage(memberName: 'Budi Santoso', leaderName: 'Sari', reason: ContactReason.notCheckedIn);
      expect(m, 'Halo Budi, saya Sari. Hari ini kamu belum tercatat check-in. Ada kendala?');
    });

    test('terlambat dan umum', () {
      expect(contactMessage(memberName: 'Budi', leaderName: 'Sari', reason: ContactReason.late), contains('terlambat check-in'));
      expect(contactMessage(memberName: 'Budi', leaderName: 'Sari'), 'Halo Budi, saya Sari. ');
    });

    test('nama kosong tidak menghasilkan kalimat aneh', () {
      expect(contactMessage(memberName: '', leaderName: '', reason: ContactReason.notCheckedIn), 'Halo. Hari ini kamu belum tercatat check-in. Ada kendala?');
    });
  });

  group('TeamDayStats', () {
    final now = DateTime(2026, 10, 5, 9, 0); // Senin 09.00

    TeamDayStats stats(List<ShiftAssignment> a, List<LeaderAttendanceLogItem> l, {DateTime? at}) =>
        TeamDayStats.compute(now: at ?? now, assignments: a, logs: l);

    test('shift sudah mulai: belum check-in, sedang bekerja, sudah pulang, dan terlambat terhitung benar', () {
      final s = stats(
        [
          _assign('a', 'Andi', '2026-10-05', '07:00', '15:00'),
          _assign('b', 'Budi', '2026-10-05', '07:00', '15:00'),
          _assign('c', 'Cici', '2026-10-05', '07:00', '15:00'),
          _assign('d', 'Dedi', '2026-10-05', '07:00', '15:00'),
        ],
        [
          _log('a', 'Andi', '2026-10-05', checkIn: '06:55'),
          _log('b', 'Budi', '2026-10-05', checkIn: '07:40', status: 'late'),
          _log('c', 'Cici', '2026-10-05', checkIn: '06:50', checkOut: '08:30'),
        ],
      );
      expect([s.working, s.checkedOut, s.late, s.notCheckedIn, s.notStarted], [2, 1, 1, 1, 0]);
      expect(s.notCheckedInPeople.map((p) => p.name), ['Dedi']);
      expect(s.latePeople.map((p) => p.name), ['Budi']);
    });

    test('shift yang belum dimulai tidak dihitung sebagai belum check-in', () {
      final s = stats([_assign('a', 'Andi', '2026-10-05', '14:00', '22:00')], const []);
      expect([s.notStarted, s.notCheckedIn], [1, 0]);
      expect(s.notCheckedInPeople, isEmpty);
    });

    test('shift libur atau tanpa jam tidak dihitung', () {
      final s = stats(
        [
          _assign('a', 'Andi', '2026-10-05', '00:00', '00:00', dayType: 'off'),
          _assign('b', 'Budi', '2026-10-05', 'abc', 'xyz'),
        ],
        const [],
      );
      expect(s.isEmpty, isTrue);
    });

    test('hari libur nasional tidak mengharuskan check-in', () {
      final s = stats([_assign('a', 'Andi', '2026-10-05', '07:00', '15:00', dayType: 'holiday')], const []);
      expect(s.isEmpty, isTrue);
    });

    test('shift malam: check-in kemarin dan belum pulang tetap sedang bekerja', () {
      final s = stats(
        [_assign('a', 'Andi', '2026-10-04', '22:00', '06:00')],
        [_log('a', 'Andi', '2026-10-04', checkIn: '21:58')],
        at: DateTime(2026, 10, 5, 1, 0),
      );
      expect([s.working, s.notCheckedIn, s.checkedOut], [1, 0, 0]);
    });

    test('shift malam: jam 01.00 belum check-in padahal shift kemarin malam masih berjalan = belum check-in', () {
      final s = stats(
        [_assign('a', 'Andi', '2026-10-04', '22:00', '06:00')],
        const [],
        at: DateTime(2026, 10, 5, 1, 0),
      );
      expect(s.notCheckedIn, 1);
      expect(s.notCheckedInPeople.single.name, 'Andi');
    });

    test('shift malam yang sudah berakhir (jam 07.00) tidak lagi dihitung', () {
      final s = stats(
        [_assign('a', 'Andi', '2026-10-04', '22:00', '06:00')],
        const [],
        at: DateTime(2026, 10, 5, 7, 0),
      );
      expect(s.isEmpty, isTrue);
    });

    test('shift malam yang sudah pulang pagi tadi dihitung sudah check-out', () {
      final s = stats(
        [_assign('a', 'Andi', '2026-10-04', '22:00', '09:30')],
        [_log('a', 'Andi', '2026-10-04', checkIn: '21:58', checkOut: '09:10')],
        at: DateTime(2026, 10, 5, 9, 20),
      );
      expect([s.checkedOut, s.working], [1, 0]);
    });

    test('lupa check-out kemarin (absen masih terbuka) dibawa ke hari ini sebagai sedang bekerja', () {
      final s = stats(
        [_assign('a', 'Andi', '2026-10-05', '07:00', '15:00')],
        [_log('a', 'Andi', '2026-10-04', checkIn: '07:00')],
      );
      expect([s.working, s.notCheckedIn], [1, 0]);
    });

    test('anggota tanpa jadwal tetapi sudah check-in tetap dihitung, dan tidak dua kali', () {
      final s = stats(
        [_assign('a', 'Andi', '2026-10-05', '07:00', '15:00')],
        [_log('a', 'Andi', '2026-10-05', checkIn: '07:00'), _log('z', 'Zaki', '2026-10-05', checkIn: '08:00')],
      );
      expect(s.working, 2);
      expect(s.total, 2);
    });

    test('data kosong tidak membuat galat', () {
      expect(stats(const [], const []).isEmpty, isTrue);
    });
  });
}
