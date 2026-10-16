import 'dart:io';

import 'package:flutter/material.dart';

import '../providers/attendance_provider.dart';
import '../screens/camera/camera_screen.dart';
import '../screens/face_id/face_capture_screen.dart';
import '../screens/face_id/face_id_enroll_screen.dart';
import '../services/face_id_service.dart';
import '../widgets/face_verify_overlay.dart';

/// Hasil pengambilan foto untuk absen: foto utama + (bila site meminta gerakan) foto tiap langkah.
class AttendanceCapture {
  final File photo;
  final FaceLiveData? live;

  /// Diambil lewat kamera Face ID (bukan kamera biasa): pengiriman diberi lapisan "Memverifikasi wajah".
  final bool usedFace;
  const AttendanceCapture(this.photo, {this.live, this.usedFace = false});
}

FaceShot _shotFor(String step) {
  switch (step) {
    case 'turn':
      return const FaceShot('Tolehkan kepala pelan-pelan ke satu sisi', FacePose.turn);
    case 'smile':
      return const FaceShot('Senyum ke kamera', FacePose.smile);
    default:
      return const FaceShot('Kedipkan mata Anda sekali', FacePose.blink);
  }
}

/// Mengambil foto untuk check-in/out. Bila karyawan sudah mendaftarkan wajah di site yang Face ID-nya
/// aktif, dipakai kamera Face ID (jepret otomatis, tanpa tombol foto) ditambah gerakan acak pilihan
/// server bila site memintanya; selain itu kamera biasa. Status dan tantangan diambil bersamaan supaya
/// tidak menambah waktu tunggu, dan gagal membacanya tidak pernah memblokir absen.
Future<AttendanceCapture?> captureAttendancePhoto(
  BuildContext context, {
  required String title,
  required bool checkOut,
}) async {
  final service = FaceIdService();
  FaceIdState? state;
  FaceChallenge? challenge;
  try {
    final results = await Future.wait<Object?>([
      service.getState().timeout(const Duration(seconds: 4), onTimeout: () => null),
      service.getChallenge(checkOut ? 'checkout' : 'checkin').timeout(const Duration(seconds: 4), onTimeout: () => null),
    ]);
    state = results[0] as FaceIdState?;
    challenge = results[1] as FaceChallenge?;
  } catch (_) {}
  if (!context.mounted) return null;

  // Status tidak bisa dimuat (offline/server tak terjangkau) di site yang Face ID-nya WAJIB: absen butuh internet, jadi jangan
  // biarkan karyawan mengambil foto biasa yang nanti pasti ditolak.
  if (state == null && await service.cachedEnforce()) {
    if (!context.mounted) return null;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.wifi_off_rounded),
        title: const Text('Face ID wajib, butuh internet'),
        content: const Text('Absen di lokasi kerja Anda wajib memakai Face ID dan harus terhubung ke internet. Sambungkan internet lalu coba lagi.'),
        actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Mengerti'))],
      ),
    );
    return null;
  }

  // Face ID wajib tetapi belum terdaftar (belum pernah, atau pendaftaran ditolak sistem): wajib daftar dulu, TIDAK boleh jatuh
  // ke kamera biasa. Tanpa pendaftaran yang berhasil, absen dibatalkan.
  if (state != null && state.enabled && state.enforce && state.needsEnrollment) {
    final done = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => FaceIdEnrollScreen(state: state!)),
    );
    if (done != true || !context.mounted) return null;
    state = await service.getState();
    if (state == null || !state.usesFaceCapture || !context.mounted) return null;
  }

  if (state != null && state.usesFaceCapture) {
    final steps = challenge?.steps ?? const <String>[];
    final shots = [
      const FaceShot('Lihat lurus ke kamera', FacePose.front),
      ...steps.map(_shotFor),
    ];
    final files = await Navigator.of(context).push<List<File>>(
      MaterialPageRoute(builder: (_) => FaceCaptureScreen(title: title, shots: shots, fast: true)),
    );
    if (files == null) return null; // dibatalkan
    if (files.isNotEmpty) {
      final live = (challenge != null && files.length == shots.length)
          ? FaceLiveData(token: challenge.token, kinds: steps, photos: files.sublist(1))
          : null;
      return AttendanceCapture(files.first, live: live, usedFace: true);
    }
    // Daftar kosong = HP ini tidak bisa memakai kamera Face ID: jatuh ke kamera biasa agar absen tidak buntu.
    if (!context.mounted) return null;
  }

  final plain = await Navigator.of(context).push<File>(
    MaterialPageRoute(
      builder: (_) => CameraScreen(title: title, allowGallery: false, preferLowResolution: true),
    ),
  );
  return plain == null ? null : AttendanceCapture(plain);
}

enum _FaceChoice { retry, fallback, cancel }

/// Mengirim absen dan menangani penolakan Face ID dari server (wajah tidak cocok / foto belum layak /
/// gerakan belum terdeteksi / belum mendaftar): karyawan boleh mengulang, dan setelah beberapa kali
/// gagal boleh melanjutkan tanpa verifikasi (ditandai untuk ditinjau admin). Penolakan selain Face ID
/// dikembalikan apa adanya (false).
Future<bool> submitWithFaceRetry(
  BuildContext context, {
  required AttendanceProvider provider,
  required String captureTitle,
  required bool checkOut,
  required AttendanceCapture first,
  required Future<bool> Function(AttendanceCapture capture, bool faceFallback) submit,
}) async {
  var capture = first;
  var fallback = false;
  while (true) {
    final ok = capture.usedFace
        ? await showFaceVerifying<bool>(
            context,
            () => submit(capture, fallback),
            // Hanya VERIFIED yang tampil "Terverifikasi"; absen yang cuma tercatat (mode pencatat, lanjut tanpa
            // verifikasi, offline) ditampilkan apa adanya.
            outcomeOf: (ok) {
              if (!ok) return FaceVerifyOutcome.failed;
              final status = provider.takeFaceStatus();
              return (status == null || status == 'VERIFIED') ? FaceVerifyOutcome.verified : FaceVerifyOutcome.recordedOnly;
            },
          )
        : await submit(capture, fallback);
    if (ok) return true;
    final failure = provider.takeFaceIdFailure();
    if (failure == null || !context.mounted) return false;

    // Mode wajib dan belum mendaftar: daftar dulu (atau menolak secara sadar), lalu ulangi foto absen.
    if (failure['code'] == 'NOT_ENROLLED') {
      final state = await FaceIdService().getState();
      if (state == null || !context.mounted) return false;
      final done = await Navigator.of(context).push<bool>(
        MaterialPageRoute(builder: (_) => FaceIdEnrollScreen(state: state)),
      );
      if (done != true || !context.mounted) return false;
      final next = await captureAttendancePhoto(context, title: captureTitle, checkOut: checkOut);
      if (next == null) return false;
      capture = next;
      fallback = false;
      continue;
    }

    final canFallback = failure['canFallback'] == true;
    final choice = await showDialog<_FaceChoice>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.face_retouching_off),
        title: const Text('Wajah belum terverifikasi'),
        content: Text(
          '${provider.error ?? 'Wajah Anda belum bisa diverifikasi.'}\n\n'
          '${canFallback ? 'Anda sudah mencoba beberapa kali. Anda boleh lanjut tanpa verifikasi; absen akan ditandai dan ditinjau admin.' : 'Coba lagi dengan pencahayaan yang cukup dan wajah menghadap lurus ke kamera. Bila terus gagal, hubungi admin atau atasan Anda untuk koreksi absen.'}',
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
      fallback = true; // kirim ulang dengan penanda lanjut (tantangan lama sudah terpakai; server menerima karena sudah 3 gagal)
      continue;
    }
    if (choice == _FaceChoice.retry) {
      if (!context.mounted) return false;
      final next = await captureAttendancePhoto(context, title: captureTitle, checkOut: checkOut);
      if (next == null) return false;
      capture = next;
      fallback = false;
      continue;
    }
    return false;
  }
}
