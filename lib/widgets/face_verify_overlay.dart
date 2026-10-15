import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'motion.dart';

/// Hasil yang ditampilkan lapisan verifikasi. Jujur terhadap hasil server: absen yang tercatat tetapi
/// wajahnya TIDAK terverifikasi (mode pencatat, jalur lanjut, offline) tidak boleh tampil sebagai "Terverifikasi".
enum FaceVerifyOutcome { verified, recordedOnly, failed }

enum _Phase { working, verified, recordedOnly, failed }

/// Menampilkan lapisan "Memverifikasi wajah..." selama [task] berjalan, lalu hasil singkat
/// (centang / tanda info / gagal) sebelum lapisan ditutup dan hasil dikembalikan.
/// Gerak hanya opacity/transform dan mengikuti pengaturan "matikan animasi" di sistem.
Future<T> showFaceVerifying<T>(
  BuildContext context,
  Future<T> Function() task, {
  required FaceVerifyOutcome Function(T result) outcomeOf,
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
    switch (outcomeOf(result)) {
      case FaceVerifyOutcome.verified:
        phase.value = _Phase.verified;
        HapticFeedback.lightImpact();
      case FaceVerifyOutcome.recordedOnly:
        phase.value = _Phase.recordedOnly;
      case FaceVerifyOutcome.failed:
        phase.value = _Phase.failed;
    }
    // Hasil "tercatat tapi belum terverifikasi" butuh waktu baca lebih lama.
    await Future<void>.delayed(Duration(milliseconds: phase.value == _Phase.recordedOnly ? 1400 : 650));
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
          final (IconData? icon, Color color, String text, String? sub) = switch (p) {
            _Phase.working => (null, Colors.white, message, null),
            _Phase.verified => (Icons.check_circle_rounded, Colors.greenAccent, 'Terverifikasi', null),
            _Phase.recordedOnly => (
              Icons.info_rounded,
              Colors.amberAccent,
              'Absen tercatat',
              'Wajah belum terverifikasi. Hasilnya dicatat untuk ditinjau.',
            ),
            _Phase.failed => (Icons.cancel_rounded, Colors.redAccent, 'Belum berhasil', null),
          };
          return Semantics(
            liveRegion: true,
            label: sub == null ? text : '$text. $sub',
            child: Container(
              width: 240,
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
                  if (sub != null) ...[
                    const SizedBox(height: 6),
                    Text(sub, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70, fontSize: 13)),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
