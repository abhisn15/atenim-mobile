import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'motion.dart';

enum _Phase { working, success, failure }

/// Menampilkan lapisan "Memverifikasi wajah..." selama [task] berjalan, lalu hasil singkat
/// (centang atau tanda gagal) sebelum lapisan ditutup dan hasil dikembalikan.
/// Gerak hanya opacity/transform dan mengikuti pengaturan "matikan animasi" di sistem.
Future<T> showFaceVerifying<T>(
  BuildContext context,
  Future<T> Function() task, {
  required bool Function(T result) isSuccess,
  String message = 'Memverifikasi wajah...',
}) async {
  final phase = ValueNotifier<_Phase>(_Phase.working);
  final navigator = Navigator.of(context, rootNavigator: true);
  var shown = true;
  unawaited(
    showGeneralDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black54,
      transitionDuration: Motion.reduced(context) ? Duration.zero : Motion.quick,
      pageBuilder: (_, __, ___) => PopScope(
        canPop: false,
        child: Center(child: _VerifyCard(phase: phase, message: message)),
      ),
      transitionBuilder: (_, anim, __, child) => FadeTransition(opacity: anim, child: child),
    ).whenComplete(() => shown = false),
  );
  try {
    final result = await task();
    phase.value = isSuccess(result) ? _Phase.success : _Phase.failure;
    if (phase.value == _Phase.success) HapticFeedback.lightImpact();
    await Future<void>.delayed(const Duration(milliseconds: 650));
    return result;
  } finally {
    if (shown) navigator.pop();
    phase.dispose();
  }
}

class _VerifyCard extends StatelessWidget {
  final ValueNotifier<_Phase> phase;
  final String message;
  const _VerifyCard({required this.phase, required this.message});

  @override
  Widget build(BuildContext context) {
    final reduced = Motion.reduced(context);
    return Material(
      color: Colors.transparent,
      child: ValueListenableBuilder<_Phase>(
        valueListenable: phase,
        builder: (context, p, _) {
          final (IconData? icon, Color color, String text) = switch (p) {
            _Phase.working => (null, Colors.white, message),
            _Phase.success => (Icons.check_circle_rounded, Colors.greenAccent, 'Terverifikasi'),
            _Phase.failure => (Icons.cancel_rounded, Colors.redAccent, 'Belum berhasil'),
          };
          return Semantics(
            liveRegion: true,
            label: text,
            child: Container(
              width: 220,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
              decoration: BoxDecoration(color: const Color(0xE6111111), borderRadius: BorderRadius.circular(18)),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    height: 56,
                    width: 56,
                    child: icon == null
                        ? const CircularProgressIndicator(strokeWidth: 4, color: Colors.white)
                        : TweenAnimationBuilder<double>(
                            key: ValueKey(p),
                            tween: Tween(begin: reduced ? 1 : 0.5, end: 1),
                            duration: reduced ? Duration.zero : Motion.enter,
                            curve: Curves.easeOutBack,
                            builder: (_, v, child) => Opacity(opacity: v.clamp(0.0, 1.0), child: Transform.scale(scale: v, child: child)),
                            child: Icon(icon, color: color, size: 56),
                          ),
                  ),
                  const SizedBox(height: 14),
                  Text(text, textAlign: TextAlign.center, style: TextStyle(color: color, fontSize: 16, fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
