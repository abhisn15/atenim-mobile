import 'dart:typed_data';
import 'dart:ui' show Size;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

/// Pemanasan Face ID: ML Kit memuat modelnya baru pada frame pertama (±1 dtk di HP kelas bawah) dan
/// daftar kamera butuh waktu juga. Dilakukan sekali per sesi saat Beranda terbuka, supaya layar kamera
/// absen langsung bisa membaca wajah. Detektor dipakai bersama dan tidak ditutup oleh layar kamera.
class FaceWarmup {
  FaceWarmup._();

  static FaceDetector? _detector;
  static List<CameraDescription>? cameras;
  static bool _started = false;

  static FaceDetector get detector => _detector ??= FaceDetector(
    options: FaceDetectorOptions(
      performanceMode: FaceDetectorMode.fast,
      enableClassification: true,
      minFaceSize: 0.2,
    ),
  );

  static Future<void> run() async {
    if (_started) return;
    _started = true;
    final sw = Stopwatch()..start();
    try {
      cameras = await availableCameras();
      // Gambar NV21 kosong kecil: cukup untuk memaksa model termuat.
      const w = 160;
      const h = 120;
      final bytes = Uint8List(w * h * 3 ~/ 2);
      await detector.processImage(
        InputImage.fromBytes(
          bytes: bytes,
          metadata: InputImageMetadata(
            size: Size(w.toDouble(), h.toDouble()),
            rotation: InputImageRotation.rotation0deg,
            format: InputImageFormat.nv21,
            bytesPerRow: w,
          ),
        ),
      );
      debugPrint('[FaceWarmup] siap dalam ${sw.elapsedMilliseconds} ms');
    } catch (e) {
      _started = false; // coba lagi pada kesempatan berikutnya
      debugPrint('[FaceWarmup] gagal: $e');
    }
  }
}
