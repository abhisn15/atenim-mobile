import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:permission_handler/permission_handler.dart';

/// Kamera depan dengan panduan wajah realtime dan jepret OTOMATIS (tanpa tombol foto).
/// Foto baru diambil setelah wajah memenuhi semua syarat beberapa frame berturut-turut.
/// Mengembalikan [shots] foto (daftar File) atau null bila dibatalkan.
///
/// Pengecekan di HP hanya untuk memandu pengguna; keputusan cocok/tidak cocok tetap di server.
class FaceCaptureScreen extends StatefulWidget {
  final String title;

  /// Teks arahan tiap foto. Jumlahnya menentukan banyaknya foto yang diambil.
  final List<String> shotPrompts;

  const FaceCaptureScreen({
    super.key,
    required this.title,
    this.shotPrompts = const ['Lihat lurus ke kamera'],
  });

  @override
  State<FaceCaptureScreen> createState() => _FaceCaptureScreenState();
}

class _FaceCaptureScreenState extends State<FaceCaptureScreen> with WidgetsBindingObserver {
  static const _stableFramesNeeded = 5;
  static const _frameGap = Duration(milliseconds: 180);
  static const _orientations = {
    DeviceOrientation.portraitUp: 0,
    DeviceOrientation.landscapeLeft: 90,
    DeviceOrientation.portraitDown: 180,
    DeviceOrientation.landscapeRight: 270,
  };

  CameraController? _controller;
  CameraDescription? _camera;
  final FaceDetector _detector = FaceDetector(
    options: FaceDetectorOptions(
      performanceMode: FaceDetectorMode.fast,
      enableClassification: true,
      minFaceSize: 0.2,
    ),
  );

  final List<File> _shots = [];
  bool _busy = false; // sedang memproses satu frame
  bool _capturing = false;
  bool _streaming = false;
  bool _disposed = false;
  int _stable = 0;
  DateTime _lastFrame = DateTime.fromMillisecondsSinceEpoch(0);
  String? _fatal;
  String _hint = 'Menyiapkan kamera...';
  bool _good = false;

  int get _total => widget.shotPrompts.length;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _stopStream();
    _controller?.dispose();
    _detector.close();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      _stopStream();
    } else if (state == AppLifecycleState.resumed && !_capturing && _controller?.value.isInitialized == true) {
      _startStream();
    }
  }

  Future<void> _init() async {
    final status = await Permission.camera.request();
    if (!status.isGranted) {
      _setFatal('Izin kamera ditolak. Aktifkan izin kamera di pengaturan HP.');
      return;
    }
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        _setFatal('Kamera tidak ditemukan di HP ini.');
        return;
      }
      _camera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        _camera!,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.nv21,
      );
      await controller.initialize();
      if (_disposed) {
        await controller.dispose();
        return;
      }
      _controller = controller;
      if (mounted) setState(() => _hint = widget.shotPrompts.first);
      await _startStream();
    } catch (e) {
      debugPrint('[FaceCapture] init gagal: $e');
      _setFatal('Kamera tidak bisa dibuka. Tutup aplikasi kamera lain lalu coba lagi.');
    }
  }

  void _setFatal(String message) {
    if (!mounted) return;
    setState(() => _fatal = message);
  }

  Future<void> _startStream() async {
    final c = _controller;
    if (c == null || _streaming || _disposed || !c.value.isInitialized) return;
    _streaming = true;
    _stable = 0;
    try {
      await c.startImageStream(_onFrame);
    } catch (e) {
      _streaming = false;
      debugPrint('[FaceCapture] startImageStream gagal: $e');
      _setFatal('Kamera di HP ini belum mendukung Face ID.');
    }
  }

  Future<void> _stopStream() async {
    final c = _controller;
    if (c == null || !_streaming) return;
    _streaming = false;
    try {
      if (c.value.isStreamingImages) await c.stopImageStream();
    } catch (_) {}
  }

  InputImage? _toInputImage(CameraImage image) {
    final camera = _camera;
    final controller = _controller;
    if (camera == null || controller == null) return null;
    final comp = _orientations[controller.value.deviceOrientation];
    if (comp == null) return null;
    final sensor = camera.sensorOrientation;
    final rotationDeg = camera.lensDirection == CameraLensDirection.front
        ? (sensor + comp) % 360
        : (sensor - comp + 360) % 360;
    final rotation = InputImageRotationValue.fromRawValue(rotationDeg);
    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    if (rotation == null || format == null || format != InputImageFormat.nv21 || image.planes.length != 1) return null;
    final plane = image.planes.first;
    return InputImage.fromBytes(
      bytes: plane.bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: format,
        bytesPerRow: plane.bytesPerRow,
      ),
    );
  }

  /// Rerata luma dari sampel jarang pada bidang Y (NV21), 0..255.
  double _brightness(CameraImage image) {
    final y = image.planes.first.bytes;
    final n = image.width * image.height;
    var sum = 0;
    var count = 0;
    for (var i = 0; i < n && i < y.length; i += 37) {
      sum += y[i];
      count++;
    }
    return count == 0 ? 128 : sum / count;
  }

  Future<void> _onFrame(CameraImage image) async {
    if (_busy || _capturing || _disposed) return;
    final now = DateTime.now();
    if (now.difference(_lastFrame) < _frameGap) return;
    _lastFrame = now;
    _busy = true;
    try {
      final input = _toInputImage(image);
      if (input == null) return;
      final faces = await _detector.processImage(input);
      if (_disposed) return;
      final swapped = input.metadata!.rotation == InputImageRotation.rotation90deg ||
          input.metadata!.rotation == InputImageRotation.rotation270deg;
      final w = (swapped ? image.height : image.width).toDouble();
      final h = (swapped ? image.width : image.height).toDouble();
      final problem = _checkFrame(faces, w, h, _brightness(image));
      if (problem == null) {
        _stable++;
        _update(_stable >= _stableFramesNeeded ? 'Tahan, mengambil foto...' : 'Bagus, tahan sebentar', true);
        if (_stable >= _stableFramesNeeded) await _capture();
      } else {
        _stable = 0;
        _update(problem, false);
      }
    } catch (e) {
      debugPrint('[FaceCapture] frame gagal: $e');
    } finally {
      _busy = false;
    }
  }

  /// Teks masalah pertama yang ditemukan, atau null bila wajah sudah layak diambil.
  String? _checkFrame(List<Face> faces, double w, double h, double brightness) {
    if (faces.isEmpty) return 'Wajah tidak terdeteksi. Hadapkan wajah ke kamera.';
    if (faces.length > 1) return 'Terdeteksi lebih dari satu wajah. Hanya wajah Anda yang boleh terlihat.';
    if (brightness < 55) return 'Terlalu gelap. Cari tempat yang lebih terang.';
    if (brightness > 205) return 'Terlalu terang atau silau. Geser dari cahaya langsung.';
    final f = faces.first;
    final box = f.boundingBox;
    final ratio = box.width / w;
    if (ratio < 0.33) return 'Wajah terlalu jauh. Dekatkan HP.';
    if (ratio > 0.85) return 'Wajah terlalu dekat. Jauhkan HP sedikit.';
    final dx = (box.center.dx - w / 2).abs() / w;
    final dy = (box.center.dy - h / 2).abs() / h;
    if (dx > 0.15 || dy > 0.17) return 'Posisikan wajah di tengah lingkaran.';
    final yaw = f.headEulerAngleY ?? 0;
    final roll = f.headEulerAngleZ ?? 0;
    if (yaw.abs() > 14 || roll.abs() > 14) return 'Hadapkan wajah lurus ke kamera.';
    final left = f.leftEyeOpenProbability;
    final right = f.rightEyeOpenProbability;
    if ((left != null && left < 0.4) || (right != null && right < 0.4)) return 'Buka mata Anda.';
    return null;
  }

  void _update(String hint, bool good) {
    if (!mounted || (_hint == hint && _good == good)) return;
    setState(() {
      _hint = hint;
      _good = good;
    });
  }

  Future<void> _capture() async {
    final c = _controller;
    if (c == null || _capturing) return;
    _capturing = true;
    try {
      await _stopStream();
      final file = await c.takePicture();
      _shots.add(File(file.path));
      HapticFeedback.mediumImpact();
      if (_shots.length >= _total) {
        if (mounted) Navigator.of(context).pop(List<File>.from(_shots));
        return;
      }
      _update('Foto ${_shots.length} dari $_total tersimpan', true);
      await Future<void>.delayed(const Duration(milliseconds: 900));
      if (!mounted || _disposed) return;
      setState(() {
        _hint = widget.shotPrompts[_shots.length];
        _good = false;
      });
      _capturing = false;
      await _startStream();
    } catch (e) {
      debugPrint('[FaceCapture] ambil foto gagal: $e');
      _capturing = false;
      _update('Gagal mengambil foto. Coba lagi.', false);
      await _startStream();
    } finally {
      if (_shots.length < _total) _capturing = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            if (_fatal != null)
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.no_photography_outlined, color: Colors.white70, size: 48),
                      const SizedBox(height: 12),
                      Text(_fatal!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 16)),
                      const SizedBox(height: 16),
                      FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Kembali')),
                    ],
                  ),
                ),
              )
            else if (c == null || !c.value.isInitialized)
              const Center(child: CircularProgressIndicator(color: Colors.white))
            else
              Positioned.fill(
                child: ClipRect(
                  child: FittedBox(
                    fit: BoxFit.cover,
                    child: SizedBox(
                      width: c.value.previewSize!.height,
                      height: c.value.previewSize!.width,
                      child: CameraPreview(c),
                    ),
                  ),
                ),
              ),
            if (_fatal == null)
              Positioned.fill(
                child: IgnorePointer(child: CustomPaint(painter: _OvalGuidePainter(good: _good))),
              ),
            Positioned(
              top: 4,
              left: 4,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                tooltip: 'Batal',
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
            Positioned(
              top: 14,
              left: 0,
              right: 0,
              child: Text(widget.title, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
            ),
            if (_fatal == null)
              Positioned(
                left: 20,
                right: 20,
                bottom: 28,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_total > 1)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            for (var i = 0; i < _total; i++)
                              Container(
                                width: 10,
                                height: 10,
                                margin: const EdgeInsets.symmetric(horizontal: 4),
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: i < _shots.length ? Colors.greenAccent : Colors.white30,
                                ),
                              ),
                          ],
                        ),
                      ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.65), borderRadius: BorderRadius.circular(12)),
                      child: Text(
                        _hint,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: _good ? Colors.greenAccent : Colors.white, fontSize: 16, fontWeight: FontWeight.w500),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Lapisan gelap dengan lubang oval sebagai panduan posisi wajah; hijau bila sudah pas.
class _OvalGuidePainter extends CustomPainter {
  final bool good;
  const _OvalGuidePainter({required this.good});

  @override
  void paint(Canvas canvas, Size size) {
    final oval = Rect.fromCenter(
      center: Offset(size.width / 2, size.height * 0.5),
      width: size.width * 0.72,
      height: size.width * 0.72 * 1.3,
    );
    final overlay = Path()
      ..addRect(Offset.zero & size)
      ..addOval(oval)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(overlay, Paint()..color = Colors.black.withValues(alpha: 0.55));
    canvas.drawOval(
      oval,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..color = good ? Colors.greenAccent : Colors.white,
    );
  }

  @override
  bool shouldRepaint(_OvalGuidePainter old) => old.good != good;
}
