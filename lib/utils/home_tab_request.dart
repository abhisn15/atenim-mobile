import 'package:flutter/foundation.dart';

/// Meminta HomeScreen pindah tab dari layar anak. Tab seperti Patroli adalah halaman di dalam
/// PageView HomeScreen, bukan layar yang di-push, jadi Navigator.pop tidak bisa membawa pengguna
/// ke beranda (dipakai tombol "Ke beranda" di dialog gerbang check-in).
class HomeTabRequest {
  HomeTabRequest._();

  static const int homeIndex = 0;

  static final ValueNotifier<int> _tick = ValueNotifier<int>(0);
  static int _target = homeIndex;

  /// Dipasang HomeScreen. Dipanggil tiap ada permintaan, walau tabnya sama dengan yang diminta sebelumnya.
  static Listenable get listenable => _tick;
  static int get target => _target;

  static void goTo(int index) {
    _target = index;
    _tick.value++;
  }

  static void goHome() => goTo(homeIndex);
}
