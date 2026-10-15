import 'dart:io';

import 'package:flutter/material.dart';

import '../providers/attendance_provider.dart';
import '../screens/camera/camera_screen.dart';
import '../screens/face_id/face_capture_screen.dart';
import '../services/face_id_service.dart';

/// Mengambil foto untuk check-in/out. Bila karyawan sudah mendaftarkan wajah di site yang Face ID-nya
/// aktif, dipakai kamera Face ID (jepret otomatis, tanpa tombol foto); selain itu kamera biasa.
/// Gagal membaca status Face ID tidak pernah memblokir absen: jatuh ke kamera biasa.
Future<File?> captureAttendancePhoto(BuildContext context, {required String title}) async {
  FaceIdState? state;
  try {
    state = await FaceIdService().getState().timeout(const Duration(seconds: 4), onTimeout: () => null);
  } catch (_) {
    state = null;
  }
  if (!context.mounted) return null;
  if (state != null && state.usesFaceCapture) {
    final shots = await Navigator.of(context).push<List<File>>(
      MaterialPageRoute(builder: (_) => FaceCaptureScreen(title: title)),
    );
    return (shots == null || shots.isEmpty) ? null : shots.first;
  }
  return Navigator.of(context).push<File>(
    MaterialPageRoute(
      builder: (_) => CameraScreen(title: title, allowGallery: false, preferLowResolution: true),
    ),
  );
}

enum _FaceChoice { retry, fallback, cancel }

/// Mengirim absen dan menangani penolakan Face ID dari server (wajah tidak cocok / foto belum layak):
/// karyawan boleh mengulang foto, dan setelah beberapa kali gagal boleh melanjutkan tanpa verifikasi
/// (ditandai untuk ditinjau admin). Penolakan selain Face ID dikembalikan apa adanya (false).
Future<bool> submitWithFaceRetry(
  BuildContext context, {
  required AttendanceProvider provider,
  required String captureTitle,
  required File firstPhoto,
  required Future<bool> Function(File photo, bool faceFallback) submit,
}) async {
  var photo = firstPhoto;
  var fallback = false;
  while (true) {
    final ok = await submit(photo, fallback);
    if (ok) return true;
    final failure = provider.takeFaceIdFailure();
    if (failure == null || !context.mounted) return false;

    final canFallback = failure['canFallback'] == true;
    final choice = await showDialog<_FaceChoice>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.face_retouching_off),
        title: const Text('Wajah belum terverifikasi'),
        content: Text(
          '${provider.error ?? 'Wajah Anda belum bisa diverifikasi.'}\n\n'
          '${canFallback ? 'Anda sudah mencoba beberapa kali. Anda boleh lanjut tanpa verifikasi; absen akan ditandai dan ditinjau admin.' : 'Coba lagi dengan pencahayaan yang cukup dan wajah menghadap lurus ke kamera.'}',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, _FaceChoice.cancel), child: const Text('Batal')),
          if (canFallback)
            TextButton(onPressed: () => Navigator.pop(ctx, _FaceChoice.fallback), child: const Text('Lanjut tanpa verifikasi')),
          FilledButton(onPressed: () => Navigator.pop(ctx, _FaceChoice.retry), child: const Text('Coba lagi')),
        ],
      ),
    );
    if (choice == _FaceChoice.fallback) {
      fallback = true; // kirim ulang foto yang sama dengan penanda lanjut
      continue;
    }
    if (choice == _FaceChoice.retry) {
      if (!context.mounted) return false;
      final next = await captureAttendancePhoto(context, title: captureTitle);
      if (next == null) return false;
      photo = next;
      fallback = false;
      continue;
    }
    return false;
  }
}
