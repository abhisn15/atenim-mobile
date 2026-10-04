import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fms_mobile/utils/team_day_stats.dart';
import 'package:fms_mobile/widgets/contact_buttons.dart';
import 'package:fms_mobile/widgets/team_day_stats_card.dart';
import 'package:intl/date_symbol_data_local.dart';

TeamDayStats _stats({int notStarted = 0, int notCheckedIn = 0, int working = 0, int checkedOut = 0, int late = 0}) {
  return TeamDayStats(
    notStarted: notStarted,
    notCheckedIn: notCheckedIn,
    working: working,
    checkedOut: checkedOut,
    late: late,
    notCheckedInPeople: const [],
    latePeople: const [],
  );
}

Widget _host(Widget child, {double scale = 1.0}) {
  return MaterialApp(
    builder: (context, c) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)), child: c!),
    home: Scaffold(body: SingleChildScrollView(padding: const EdgeInsets.all(16), child: child)),
  );
}

void main() {
  setUpAll(() async {
    await initializeDateFormatting('id_ID');
  });

  Future<void> pumpCard(
    WidgetTester tester, {
    TeamDayStats? stats,
    bool loading = false,
    String? error,
    VoidCallback? onShow,
    double scale = 1.0,
  }) async {
    await tester.pumpWidget(_host(
      TeamDayStatsCard(stats: stats, loading: loading, error: error, updatedAt: DateTime(2026, 10, 5, 2, 5), onShowAttention: onShow ?? () {}),
      scale: scale,
    ));
    await tester.pump();
  }

  testWidgets('angka dan label tampil, tombol perlu dihubungi menjumlahkan belum check-in + terlambat', (tester) async {
    var dibuka = 0;
    await pumpCard(tester, stats: _stats(notCheckedIn: 2, working: 5, checkedOut: 1, late: 3), onShow: () => dibuka++);
    expect(find.text('Hari ini'), findsOneWidget);
    expect(find.text('Per 02.05'), findsOneWidget);
    for (final label in ['Belum check-in', 'Sedang bekerja', 'Sudah check-out', 'Terlambat']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(find.text('2'), findsOneWidget);
    expect(find.text('5'), findsOneWidget);
    expect(find.text('Lihat 5 anggota yang perlu dihubungi'), findsOneWidget);
    await tester.tap(find.byType(OutlinedButton));
    expect(dibuka, 1);
  });

  testWidgets('semua beres: tidak ada tombol, tidak ada angka yang menakutkan', (tester) async {
    await pumpCard(tester, stats: _stats(working: 4, checkedOut: 2));
    expect(find.byType(OutlinedButton), findsNothing);
  });

  testWidgets('shift belum mulai dijelaskan, bukan dihitung sebagai belum check-in', (tester) async {
    await pumpCard(tester, stats: _stats(notStarted: 3, working: 1));
    expect(find.text('3 anggota shift-nya belum mulai.'), findsOneWidget);
    expect(find.byType(OutlinedButton), findsNothing);
  });

  testWidgets('belum ada anggota, sedang memuat, dan galat tampil dengan teks yang jelas', (tester) async {
    await pumpCard(tester, stats: _stats());
    expect(find.text('Belum ada anggota yang dijadwalkan atau check-in hari ini.'), findsOneWidget);

    await pumpCard(tester, stats: null, error: 'Statistik hari ini belum bisa dimuat. Tarik layar ke bawah untuk mencoba lagi.');
    expect(find.textContaining('belum bisa dimuat'), findsOneWidget);

    await pumpCard(tester, stats: null);
    expect(find.text('Statistik hari ini belum tersedia.'), findsOneWidget);
  });

  for (final scale in [1.0, 1.8]) {
    testWidgets('tidak meluap di layar 320 px, teks ${scale}x, saat data penuh', (tester) async {
      tester.view.physicalSize = const Size(320 * 2, 640 * 2);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      await pumpCard(tester, stats: _stats(notStarted: 12, notCheckedIn: 124, working: 88, checkedOut: 999, late: 37), scale: scale);
      expect(tester.takeException(), isNull);
      expect(find.textContaining('perlu dihubungi'), findsOneWidget);
    });
  }

  testWidgets('tombol kontak disembunyikan bila nomor HP kosong atau tidak valid', (tester) async {
    await tester.pumpWidget(_host(const Column(children: [
      ContactButtons(phone: '-', memberName: 'Budi', leaderName: 'Sari'),
      ContactButtons(phone: null, memberName: 'Cici', leaderName: 'Sari'),
    ])));
    expect(find.byType(IconButton), findsNothing);
  });

  testWidgets('tombol kontak tampil bila nomor valid, dengan label yang jelas untuk pembaca layar', (tester) async {
    await tester.pumpWidget(_host(const ContactButtons(phone: '0812-3456-7890', memberName: 'Budi', leaderName: 'Sari')));
    expect(find.byType(IconButton), findsNWidgets(2));
    expect(find.byTooltip('Telepon Budi'), findsOneWidget);
    expect(find.byTooltip('WhatsApp Budi'), findsOneWidget);
    final size = tester.getSize(find.byTooltip('WhatsApp Budi'));
    expect(size.width >= 48 && size.height >= 48, isTrue, reason: 'target sentuh minimal 48 dp');
  });
}
