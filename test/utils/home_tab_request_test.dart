import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fms_mobile/utils/home_tab_request.dart';

void main() {
  late int calls;
  late VoidCallback listener;

  setUp(() {
    // HomeTabRequest menyimpan status statis; kembalikan ke beranda sebelum listener dipasang
    // supaya tiap tes mulai dari keadaan yang sama dan hitungan panggilan tidak tercemar.
    HomeTabRequest.goTo(HomeTabRequest.homeIndex);
    calls = 0;
    listener = () => calls++;
    HomeTabRequest.listenable.addListener(listener);
  });

  tearDown(() {
    HomeTabRequest.listenable.removeListener(listener);
  });

  test('homeIndex adalah tab pertama (0)', () {
    expect(HomeTabRequest.homeIndex, 0);
  });

  test('goHome() memicu listener satu kali dan menyetel target ke beranda', () {
    HomeTabRequest.goTo(3);
    calls = 0;

    HomeTabRequest.goHome();

    expect(calls, 1);
    expect(HomeTabRequest.target, HomeTabRequest.homeIndex);
  });

  test('goHome() dua kali berturut-turut memicu listener lagi walau targetnya sama', () {
    HomeTabRequest.goHome();
    HomeTabRequest.goHome();

    expect(calls, 2);
    expect(HomeTabRequest.target, HomeTabRequest.homeIndex);
  });

  test('goTo(n) menyetel target dan memicu listener', () {
    HomeTabRequest.goTo(5);

    expect(HomeTabRequest.target, 5);
    expect(calls, 1);
  });

  test('goTo(n) dua kali dengan n yang sama tetap memicu listener dua kali', () {
    HomeTabRequest.goTo(2);
    HomeTabRequest.goTo(2);

    expect(HomeTabRequest.target, 2);
    expect(calls, 2);
  });

  test('target sudah terisi saat listener dipanggil', () {
    int? seenTarget;
    void reader() => seenTarget = HomeTabRequest.target;
    HomeTabRequest.listenable.addListener(reader);

    HomeTabRequest.goTo(4);

    HomeTabRequest.listenable.removeListener(reader);
    expect(seenTarget, 4);
  });

  test('listener yang sudah dilepas tidak dipanggil lagi', () {
    HomeTabRequest.listenable.removeListener(listener);

    HomeTabRequest.goHome();

    expect(calls, 0);
    // dipasang lagi agar tearDown tidak melepas listener yang tidak terpasang
    HomeTabRequest.listenable.addListener(listener);
  });
}
