import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fms_mobile/models/attendance_alert_model.dart';
import 'package:fms_mobile/utils/phone_contact.dart';
import 'package:fms_mobile/widgets/outside_radius_card.dart';

AttendanceAlert _alert(String user, String name, String time, {String kind = 'outside', String date = '2026-10-05', String? phone = '0812-3456-7890', String site = 'Site A', DateTime? at}) {
  return AttendanceAlert(
    key: '$kind:$user:$date $time',
    kind: kind,
    userId: user,
    name: name,
    phone: phone,
    siteName: site,
    detail: 'detail',
    dateLabel: date,
    timeLabel: time,
    at: at,
  );
}

Widget _host(Widget child, {double scale = 1.0}) {
  return MaterialApp(
    builder: (context, c) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)), child: c!),
    home: Scaffold(body: SingleChildScrollView(padding: const EdgeInsets.all(16), child: child)),
  );
}

void main() {
  group('AttendanceAlert.fromJson', () {
    test('mengisi semua bidang dan menganggap nomor kosong sebagai null', () {
      final a = AttendanceAlert.fromJson({
        'key': 'outside:1',
        'kind': 'outside',
        'userId': 'u1',
        'name': '  Budi  ',
        'phone': '  ',
        'siteName': 'Site A',
        'detail': 'x',
        'dateLabel': '2026-10-05',
        'timeLabel': '09:10',
        'at': '2026-10-05T02:10:00.000Z',
      });
      expect([a.name, a.phone, a.timeLabel], ['Budi', null, '09:10']);
      expect(a.at, isNotNull);
    });

    test('bidang hilang tidak membuat galat', () {
      final a = AttendanceAlert.fromJson(const {});
      expect([a.kind, a.userId, a.name, a.at], ['', '', '', null]);
    });
  });

  group('groupOutsideRadius', () {
    test('satu baris per orang, jumlah kejadian dihitung, yang terbaru di atas', () {
      final list = groupOutsideRadius([
        _alert('a', 'Andi', '08:00'),
        _alert('b', 'Budi', '09:30'),
        _alert('a', 'Andi', '10:15'),
        _alert('a', 'Andi', '07:00'),
      ]);
      expect(list.map((p) => p.name), ['Andi', 'Budi']);
      expect(list.first.count, 3);
      expect(list.first.lastTimeLabel, '10:15');
      expect(list.last.count, 1);
    });

    test('hanya jenis keluar radius; terlambat dan belum check-in diabaikan', () {
      final list = groupOutsideRadius([
        _alert('a', 'Andi', '08:00', kind: 'late'),
        _alert('b', 'Budi', '09:00', kind: 'missing'),
        _alert('c', 'Cici', '09:30'),
      ]);
      expect(list.map((p) => p.name), ['Cici']);
    });

    test('dibatasi ke anggota team yang dipilih (filter team di layar)', () {
      final alerts = [_alert('a', 'Andi', '08:00'), _alert('b', 'Budi', '09:00')];
      expect(groupOutsideRadius(alerts, onlyUserIds: {'b'}).map((p) => p.name), ['Budi']);
      expect(groupOutsideRadius(alerts, onlyUserIds: <String>{}), isEmpty);
    });

    test('kemarin malam lebih lama dari hari ini pagi, walau jamnya lebih besar', () {
      final list = groupOutsideRadius([
        _alert('a', 'Andi', '23:30', date: '2026-10-04'),
        _alert('b', 'Budi', '06:10', date: '2026-10-05'),
      ]);
      expect(list.map((p) => p.name), ['Budi', 'Andi']);
    });

    test('waktu terakhir memakai stempel waktu bila ada, bukan urutan masukan', () {
      final list = groupOutsideRadius([
        _alert('a', 'Andi', '10:15', at: DateTime.utc(2026, 10, 5, 3, 15)),
        _alert('a', 'Andi', '08:00', at: DateTime.utc(2026, 10, 5, 1, 0)),
      ]);
      expect(list.single.lastTimeLabel, '10:15');
      expect(list.single.count, 2);
    });

    test('daftar kosong dan pengguna tanpa id tidak membuat galat', () {
      expect(groupOutsideRadius(const []), isEmpty);
      expect(groupOutsideRadius([_alert('', 'Tanpa id', '08:00')]), isEmpty);
    });
  });

  group('pesan WhatsApp keluar radius', () {
    test('netral dan bertanya, bukan menuduh', () {
      expect(
        contactMessage(memberName: 'Budi Santoso', leaderName: 'Sari', reason: ContactReason.outside),
        'Halo Budi, saya Sari. Sistem mencatat kamu berada di luar area site saat jam kerja. Ada kendala?',
      );
    });
  });

  group('OutsideRadiusCard', () {
    List<OutsideRadiusPerson> people(int n) => groupOutsideRadius([for (var i = 0; i < n; i++) _alert('u$i', 'Orang $i', '${(8 + i).toString().padLeft(2, '0')}:00')]);

    Future<void> pump(WidgetTester tester, {List<OutsideRadiusPerson>? list, bool loading = false, String? error, double scale = 1.0}) async {
      await tester.pumpWidget(_host(
        OutsideRadiusCard(people: list, loading: loading, error: error, leaderName: 'Sari', today: '2026-10-05'),
        scale: scale,
      ));
      await tester.pump();
    }

    testWidgets('kosong: menjelaskan batas pemantauan, bukan sekadar "tidak ada"', (tester) async {
      await pump(tester, list: const []);
      expect(find.text('Keluar radius'), findsOneWidget);
      expect(find.textContaining('Hanya site yang memakai radius'), findsOneWidget);
    });

    testWidgets('galat tanpa data lama tampil sebagai teks; sedang memuat tidak menampilkan pesan kosong', (tester) async {
      await pump(tester, list: null, error: 'Daftar keluar radius belum bisa dimuat. Tarik layar ke bawah untuk mencoba lagi.');
      expect(find.textContaining('belum bisa dimuat'), findsOneWidget);
      await pump(tester, list: null, loading: true);
      expect(find.textContaining('Hanya site yang memakai radius'), findsNothing);
    });

    testWidgets('menampilkan tiga orang dulu, sisanya lewat "Lihat semua"', (tester) async {
      await pump(tester, list: people(5));
      expect(find.text('Orang 4'), findsOneWidget); // paling baru (jam 12.00) di atas
      expect(find.text('Orang 0'), findsNothing);
      expect(find.text('Lihat semua (2 lagi)'), findsOneWidget);
      await tester.tap(find.text('Lihat semua (2 lagi)'));
      await tester.pump();
      expect(find.text('Orang 0'), findsOneWidget);
      expect(find.text('Tampilkan lebih sedikit'), findsOneWidget);
    });

    testWidgets('jam ditulis dengan titik, jumlah kejadian dan site tampil', (tester) async {
      final list = groupOutsideRadius([_alert('a', 'Andi', '08:05'), _alert('a', 'Andi', '10:15')]);
      await pump(tester, list: list);
      expect(find.text('2 kali, terakhir 10.15 · Site A'), findsOneWidget);
    });

    testWidgets('kejadian kemarin menyebut tanggalnya', (tester) async {
      await pump(tester, list: groupOutsideRadius([_alert('a', 'Andi', '23:10', date: '2026-10-04')]));
      expect(find.text('Terdeteksi 4 Okt, 23.10 · Site A'), findsOneWidget);
    });

    testWidgets('nomor HP kosong: tanpa tombol, ada keterangan', (tester) async {
      await pump(tester, list: groupOutsideRadius([_alert('a', 'Andi', '08:05', phone: '-')]));
      expect(find.byType(IconButton), findsNothing);
      expect(find.text('Nomor HP belum diisi'), findsOneWidget);
    });

    testWidgets('nomor valid: tombol telepon dan WhatsApp dengan label jelas', (tester) async {
      await pump(tester, list: groupOutsideRadius([_alert('a', 'Andi', '08:05')]));
      expect(find.byTooltip('Telepon Andi'), findsOneWidget);
      expect(find.byTooltip('WhatsApp Andi'), findsOneWidget);
    });

    for (final scale in [1.0, 1.8]) {
      testWidgets('tidak meluap di layar 320 px, teks ${scale}x, dengan nama dan site panjang', (tester) async {
        tester.view.physicalSize = const Size(320 * 2, 700 * 2);
        tester.view.devicePixelRatio = 2;
        addTearDown(tester.view.reset);
        final list = groupOutsideRadius([
          for (var i = 0; i < 4; i++)
            _alert('u$i', 'Muhammad Abdurrahman Al-Fatih bin Sulaiman $i', '0$i:30', site: 'PT Contoh Makmur Sejahtera Abadi Nusantara - Gedung Utama')
        ]);
        await pump(tester, list: list, scale: scale);
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.textContaining('Lihat semua'));
        await tester.tap(find.textContaining('Lihat semua'));
        await tester.pump();
        expect(tester.takeException(), isNull);
      });
    }
  });
}
