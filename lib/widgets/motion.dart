import 'package:flutter/material.dart';

/// Gerak Atenim. Aturannya (skill anti-slop, L-01 dan L-02):
/// - perubahan status 120-250 ms, elemen yang masuk paling lama ~400 ms dengan ease-out;
/// - hanya opacity dan transform, tidak ada gerak yang berulang tanpa pemicu;
/// - bila pengguna mematikan animasi di sistem (MediaQuery.disableAnimations), semua langsung tampil
///   di keadaan akhirnya. Isi tidak pernah bergantung pada animasi supaya tetap terlihat.
class Motion {
  Motion._();

  /// Perubahan status kecil (pilihan, label, ganti isi).
  static const Duration quick = Duration(milliseconds: 180);

  /// Elemen yang baru muncul.
  static const Duration enter = Duration(milliseconds: 320);

  static const Curve easeOut = Curves.easeOutCubic;

  /// Jeda antar-item pada daftar. Dibatasi 6 langkah supaya daftar panjang tidak terasa lambat.
  static Duration stagger(int index) =>
      Duration(milliseconds: index.clamp(0, 6) * 45);

  static bool reduced(BuildContext context) =>
      MediaQuery.maybeOf(context)?.disableAnimations ?? false;
}

/// Muncul sekali saat pertama dipasang: memudar masuk sambil naik sedikit.
/// Tidak diulang saat data diperbarui, karena gerak harus menandai perubahan, bukan penyegaran.
class FadeSlideIn extends StatefulWidget {
  const FadeSlideIn({
    super.key,
    required this.child,
    this.delay = Duration.zero,
    this.dy = 12,
  });

  final Widget child;
  final Duration delay;

  /// Jarak naik dalam piksel logis.
  final double dy;

  @override
  State<FadeSlideIn> createState() => _FadeSlideInState();
}

class _FadeSlideInState extends State<FadeSlideIn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _curve;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    final total = Motion.enter + widget.delay;
    _controller = AnimationController(vsync: this, duration: total);
    final begin = widget.delay.inMilliseconds / total.inMilliseconds;
    _curve = CurvedAnimation(
      parent: _controller,
      curve: Interval(begin, 1.0, curve: Motion.easeOut),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (Motion.reduced(context)) {
      _controller.value = 1;
    } else {
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _curve,
      child: widget.child,
      builder: (context, child) {
        final t = _curve.value;
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, (1 - t) * widget.dy),
            child: child,
          ),
        );
      },
    );
  }
}

/// Ganti isi dengan pemudaran singkat (mis. memuat -> daftar). Tanpa gerak bila animasi dimatikan.
class FadeSwitcher extends StatelessWidget {
  const FadeSwitcher({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: Motion.reduced(context) ? Duration.zero : Motion.quick,
      switchInCurve: Motion.easeOut,
      switchOutCurve: Curves.easeIn,
      transitionBuilder: (child, animation) =>
          FadeTransition(opacity: animation, child: child),
      layoutBuilder: (currentChild, previousChildren) => Stack(
        alignment: Alignment.topCenter,
        children: [
          ...previousChildren,
          if (currentChild != null) currentChild,
        ],
      ),
      child: child,
    );
  }
}
