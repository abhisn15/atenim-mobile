import 'dart:async';
import 'dart:io';
import 'dart:ui' show PathMetric;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../services/face_warmup.dart';
import '../../widgets/motion.dart';

/// Posisi kepala/ekspresi yang diminta pada satu foto.
enum FacePose { front, turn, smile, blink }

class FaceShot {
  final String prompt;
  final FacePose pose;

  /// Hanya untuk [FacePose.turn]: harus menoleh ke sisi SEBALIKNYA dari tolehan sebelumnya.
  final bool opposite;
  const FaceShot(this.prompt, this.pose, {this.opposite = false});
}

/// Kamera depan dengan panduan wajah realtime dan jepret OTOMATIS (tanpa tombol foto).
/// Foto baru diambil setelah wajah memenuhi syarat beberapa frame berturut-turut.
///
/// Hasil pop: daftar File (satu per langkah), `null` bila dibatalkan, atau daftar KOSONG bila HP ini tidak
/// bisa memakai kamera Face ID (pemanggil jatuh ke kamera biasa supaya absen tidak buntu).
///
/// Pengecekan di HP hanya untuk memandu pengguna; keputusan cocok/tidak cocok tetap di server.
class FaceCaptureScreen extends StatefulWidget {
  final String title;

  /// Arahan + pose tiap foto. Jumlahnya menentukan banyaknya foto yang diambil.
  final List<FaceShot> shots;

  /// Mode cepat (absen harian): lebih sedikit frame stabil sebelum jepret. Pendaftaran memakai mode teliti.
  final bool fast;

  const FaceCaptureScreen({
    super.key,
    required this.title,
    this.shots = const [FaceShot('Lihat lurus ke kamera', FacePose.front)],
    this.fast = false,
  });

  @override
  State<FaceCaptureScreen> createState() => _FaceCaptureScreenState();
}

class _FaceCaptureScreenState extends State<FaceCaptureScreen> with WidgetsBindingObserver, TickerProviderStateMixin {
  static const _orientations = {
    DeviceOrientation.portraitUp: 0,
    DeviceOrientation.landscapeLeft: 90,
    DeviceOrientation.portraitDown: 180,
    DeviceOrientation.landscapeRight: 270,
  };
  static const _blinkGiveUp = Duration(seconds: 7);
  static const _tipAfter = Duration(seconds: 5);
  static const _maxUnreadableFrames = 20;

  CameraController? _controller;
  CameraDescription? _camera;
  // Detektor bersama yang sudah dipanaskan; tidak ditutup saat layar ini ditutup.
  final FaceDetector _detector = FaceWarmup.detector;

  final List<File> _shots = [];
  bool _busy = false; // sedang memproses satu frame
  bool _capturing = false;
  bool _streaming = false;
  bool _disposed = false;
  int _stable = 0;
  int _unreadable = 0;
  DateTime _lastFrame = DateTime.fromMillisecondsSinceEpoch(0);
  double _avgMs = 80; // rata-rata waktu proses satu frame; mengatur jarak antar frame di HP lambat
  final Stopwatch _clock = Stopwatch()..start();
  bool _loggedFirstFrame = false;

  String? _fatal;
  String _hint = 'Menyiapkan kamera...';
  String? _tip;
  DateTime _hintSince = DateTime.now();
  bool _good = false;
  bool _blinkClosedSeen = false;
  DateTime? _blinkDeadline;
  double? _lastTurnSign; // tanda sudut tolehan pertama, untuk meminta sisi sebaliknya
  double? _pendingTurnSign;

  late final AnimationController _ring = AnimationController(vsync: this, duration: Motion.quick);
  late final AnimationController _flash = AnimationController(vsync: this, duration: const Duration(milliseconds: 220));
  late final AnimationController _pop = AnimationController(vsync: this, duration: Motion.enter);

  int get _stableFramesNeeded => widget.fast ? 3 : 5;
  int get _total => widget.shots.length;
  FaceShot get _shot => widget.shots[_shots.length.clamp(0, _total - 1)];
  Duration get _frameGap => Duration(milliseconds: (_avgMs * 1.15).clamp(120, 450).round());

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
    _ring.dispose();
    _flash.dispose();
    _pop.dispose();
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

  /// HP ini tidak bisa memakai kamera Face ID: serahkan ke kamera biasa (daftar kosong), jangan buntukan absen.
  void _giveUpToPlainCamera(String why) {
    debugPrint('[FaceCapture] jatuh ke kamera biasa: $why');
    if (!mounted || _disposed) return;
    Navigator.of(context).pop(<File>[]);
  }

  Future<void> _init() async {
    final status = await Permission.camera.request();
    if (!status.isGranted) {
      _setFatal('Izin kamera ditolak. Aktifkan izin kamera di pengaturan HP.');
      return;
    }
    try {
      final cameras = FaceWarmup.cameras ?? await availableCameras();
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
      if (mounted) setState(() => _hint = widget.shots.first.prompt);
      _hintSince = DateTime.now();
      _armShot();
      await _startStream();
    } catch (e) {
      debugPrint('[FaceCapture] init gagal: $e');
      _giveUpToPlainCamera('init kamera: $e');
    }
  }

  void _setFatal(String message) {
    if (!mounted) return;
    setState(() => _fatal = message);
  }

  /// Menyiapkan keadaan awal untuk langkah yang sedang berjalan.
  void _armShot() {
    _blinkClosedSeen = false;
    _blinkDeadline = _shot.pose == FacePose.blink ? DateTime.now().add(_blinkGiveUp) : null;
    _stable = 0;
    _setRing(0);
  }

  void _setRing(double v) {
    if (!mounted || _disposed) return;
    final target = v.clamp(0.0, 1.0);
    if (Motion.reduced(context)) {
      _ring.value = target;
    } else {
      _ring.animateTo(target, duration: Motion.quick, curve: Motion.easeOut);
    }
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
      _giveUpToPlainCamera('startImageStream: $e');
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
    final rotationDeg = camera.lensDirection == CameraLensDirection.front ? (sensor + comp) % 360 : (sensor - comp + 360) % 360;
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
    final sw = Stopwatch()..start();
    try {
      final input = _toInputImage(image);
      if (input == null) {
        // Format kamera yang tidak bisa dibaca ML Kit di HP ini: setelah beberapa frame, jatuh ke kamera biasa.
        if (++_unreadable >= _maxUnreadableFrames) _giveUpToPlainCamera('format frame tidak didukung');
        return;
      }
      _unreadable = 0;
      final faces = await _detector.processImage(input);
      if (_disposed) return;
      _avgMs = _avgMs * 0.8 + sw.elapsedMilliseconds * 0.2;
      if (!_loggedFirstFrame) {
        _loggedFirstFrame = true;
        debugPrint('[FaceCapture] frame pertama terbaca ${_clock.elapsedMilliseconds} ms sejak layar dibuka, proses ${sw.elapsedMilliseconds} ms');
      }
      final swapped = input.metadata!.rotation == InputImageRotation.rotation90deg || input.metadata!.rotation == InputImageRotation.rotation270deg;
      final w = (swapped ? image.height : image.width).toDouble();
      final h = (swapped ? image.width : image.height).toDouble();
      final problem = _checkFrame(faces, w, h, _brightness(image));
      if (problem == null) {
        _stable++;
        _setRing(_stable / _stableFramesNeeded);
        _update(_stable >= _stableFramesNeeded ? 'Tahan, mengambil foto...' : 'Bagus, tahan sebentar', true);
        if (_stable >= _stableFramesNeeded) await _capture();
      } else {
        if (_stable > 0) _setRing(0);
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
    _pendingTurnSign = null;
    if (faces.length > 1) return 'Terdeteksi lebih dari satu wajah. Hanya wajah Anda yang boleh terlihat.';
    if (brightness < 55) return 'Terlalu gelap. Cari tempat yang lebih terang.';
    if (brightness > 205) return 'Terlalu terang atau silau. Geser dari cahaya langsung.';
    final f = faces.first;
    final box = f.boundingBox;
    final ratio = box.width / w;
    if (ratio < 0.33) return 'Wajah terlalu jauh. Dekatkan HP.';
    if (ratio > 0.85) return 'Wajah terlalu dekat. Jauhkan HP sedikit.';
    final shot = _shot;
    final turning = shot.pose == FacePose.turn;
    final dx = (box.center.dx - w / 2).abs() / w;
    final dy = (box.center.dy - h / 2).abs() / h;
    if (dx > (turning ? 0.25 : 0.15) || dy > 0.17) return 'Posisikan wajah di tengah lingkaran.';
    final yaw = f.headEulerAngleY ?? 0;
    final roll = f.headEulerAngleZ ?? 0;
    if (roll.abs() > (turning ? 22 : 14)) return 'Tegakkan kepala Anda.';
    final left = f.leftEyeOpenProbability;
    final right = f.rightEyeOpenProbability;
    if (shot.pose == FacePose.blink) {
      // Kedip = mata terlihat menutup lalu terbuka lagi; foto diambil saat mata sudah terbuka kembali.
      // Kacamata/pantulan sering membuat mata tak terbaca: setelah beberapa detik langkah ini dilewati.
      if (left == null || right == null) return null;
      if (_blinkDeadline != null && DateTime.now().isAfter(_blinkDeadline!)) return null;
      if (left < 0.3 && right < 0.3) _blinkClosedSeen = true;
      if (!_blinkClosedSeen) return shot.prompt;
      if (left < 0.6 || right < 0.6) return 'Buka mata kembali.';
      if (yaw.abs() > 20) return 'Hadapkan wajah lurus ke kamera.';
      return null;
    }
    if ((left != null && left < 0.4) || (right != null && right < 0.4)) return 'Buka mata Anda.';
    if (turning) {
      if (yaw.abs() < 20) return shot.opposite ? 'Tolehkan kepala pelan-pelan ke sisi sebaliknya.' : shot.prompt;
      if (yaw.abs() > 42) return 'Jangan terlalu menoleh, cukup sedikit.';
      if (shot.opposite && _lastTurnSign != null && yaw.sign == _lastTurnSign) return 'Tolehkan ke sisi sebaliknya dari tadi.';
      _pendingTurnSign = yaw.sign;
      return null;
    }
    if (yaw.abs() > 14) return 'Hadapkan wajah lurus ke kamera.';
    if (shot.pose == FacePose.smile) {
      final smile = f.smilingProbability;
      if (smile != null && smile < 0.55) return 'Senyum tipis ke kamera.';
    }
    return null;
  }

  /// Saran tambahan bila masalah yang sama bertahan lama (mis. kacamata hitam, cahaya dari belakang).
  String? _tipFor(String hint) {
    if (hint.startsWith('Wajah tidak terdeteksi')) {
      return 'Lepas kacamata hitam, topi, atau masker. Kacamata bening boleh; hindari pantulan lampu di lensa.';
    }
    if (hint.startsWith('Terlalu gelap') || hint.startsWith('Terlalu terang')) {
      return 'Hadapkan wajah ke arah cahaya, jangan membelakangi jendela atau lampu.';
    }
    if (hint.startsWith('Buka mata') || hint.startsWith('Kedip') || hint.startsWith('Kedipkan')) {
      return 'Kedip tidak terbaca? Langkah ini otomatis dilewati beberapa detik lagi.';
    }
    return null;
  }

  void _update(String hint, bool good) {
    if (!mounted) return;
    final changed = _hint != hint || _good != good;
    if (changed) {
      if (_hint != hint) _hintSince = DateTime.now();
      if (good && !_good) HapticFeedback.selectionClick();
      setState(() {
        _hint = hint;
        _good = good;
        _tip = good ? null : _tip;
      });
    }
    // Tip muncul hanya bila hambatan yang sama bertahan > 5 dtk.
    if (!good && _tip == null && DateTime.now().difference(_hintSince) > _tipAfter) {
      final tip = _tipFor(hint);
      if (tip != null && mounted) setState(() => _tip = tip);
    }
  }

  Future<void> _capture() async {
    final c = _controller;
    if (c == null || _capturing) return;
    _capturing = true;
    try {
      await _stopStream();
      final file = await c.takePicture();
      _shots.add(File(file.path));
      if (_pendingTurnSign != null) _lastTurnSign = _pendingTurnSign;
      HapticFeedback.mediumImpact();
      if (!Motion.reduced(context)) {
        _flash.forward(from: 0).then((_) => _flash.reverse());
      }
      if (_shots.length >= _total) {
        if (mounted) Navigator.of(context).pop(List<File>.from(_shots));
        return;
      }
      _setRing(1);
      _pop.forward(from: 0);
      if (mounted) setState(() {
        _hint = 'Foto ${_shots.length} dari $_total tersimpan';
        _good = true;
        _tip = null;
      });
      await Future<void>.delayed(const Duration(milliseconds: 750));
      if (!mounted || _disposed) return;
      setState(() {
        _hint = widget.shots[_shots.length].prompt;
        _good = false;
      });
      _hintSince = DateTime.now();
      _armShot();
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

  IconData get _poseIcon {
    switch (_shot.pose) {
      case FacePose.turn:
        return Icons.swap_horiz_rounded;
      case FacePose.smile:
        return Icons.sentiment_satisfied_alt_rounded;
      case FacePose.blink:
        return Icons.visibility_rounded;
      case FacePose.front:
        return Icons.face_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    final reduced = Motion.reduced(context);
    final fade = reduced ? Duration.zero : Motion.quick;
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
                child: IgnorePointer(
                  child: RepaintBoundary(
                    child: AnimatedBuilder(
                      animation: _ring,
                      builder: (_, __) => CustomPaint(painter: _OvalGuidePainter(good: _good, progress: _ring.value)),
                    ),
                  ),
                ),
              ),
            // Tanda centang saat satu langkah selesai (pemicu: foto berhasil diambil).
            if (_fatal == null)
              Positioned.fill(
                child: IgnorePointer(
                  child: Center(
                    child: AnimatedBuilder(
                      animation: _pop,
                      builder: (_, __) {
                        final t = Motion.easeOut.transform(_pop.value);
                        final visible = _pop.isAnimating || _pop.value == 1;
                        return Opacity(
                          opacity: visible ? (1 - (_pop.value > 0.8 ? (_pop.value - 0.8) * 5 : 0.0)).clamp(0.0, 1.0).toDouble() : 0.0,
                          child: Transform.scale(
                            scale: 0.6 + 0.4 * t,
                            child: const Icon(Icons.check_circle_rounded, color: Colors.greenAccent, size: 96),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            // Kilatan singkat saat foto diambil.
            if (_fatal == null)
              Positioned.fill(
                child: IgnorePointer(
                  child: AnimatedBuilder(
                    animation: _flash,
                    builder: (_, __) => ColoredBox(color: Colors.white.withValues(alpha: 0.35 * _flash.value)),
                  ),
                ),
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
            if (_fatal == null && _total > 1)
              Positioned(top: 48, left: 0, right: 0, child: _StepDots(total: _total, done: _shots.length, fade: fade)),
            if (_fatal == null)
              Positioned(
                left: 20,
                right: 20,
                bottom: 28,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Semantics(
                      liveRegion: true,
                      label: _hint,
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.7), borderRadius: BorderRadius.circular(14)),
                        child: AnimatedSwitcher(
                          duration: fade,
                          child: Column(
                            key: ValueKey('$_hint|$_tip'),
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(_poseIcon, color: _good ? Colors.greenAccent : Colors.white70, size: 22),
                                  const SizedBox(width: 10),
                                  Flexible(
                                    child: Text(
                                      _hint,
                                      textAlign: TextAlign.center,
                                      style: TextStyle(color: _good ? Colors.greenAccent : Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
                                    ),
                                  ),
                                ],
                              ),
                              if (_tip != null) ...[
                                const SizedBox(height: 6),
                                Text(_tip!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70, fontSize: 13)),
                              ],
                            ],
                          ),
                        ),
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

/// Lapisan gelap dengan lubang oval sebagai panduan posisi wajah. Busur kemajuan mengisi
/// mengelilingi oval selama wajah stabil; hijau bila sudah pas.
class _OvalGuidePainter extends CustomPainter {
  final bool good;
  final double progress;
  const _OvalGuidePainter({required this.good, required this.progress});

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
        ..color = good ? Colors.greenAccent.withValues(alpha: 0.55) : Colors.white.withValues(alpha: 0.7),
    );
    if (progress > 0) {
      final path = Path()..addOval(oval);
      final PathMetric metric = path.computeMetrics().first;
      canvas.drawPath(
        metric.extractPath(0, metric.length * progress.clamp(0.0, 1.0).toDouble()),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = 7
          ..color = Colors.greenAccent,
      );
    }
  }

  @override
  bool shouldRepaint(_OvalGuidePainter old) => old.good != good || old.progress != progress;
}

/// Titik kemajuan langkah: yang selesai hijau, yang sedang berjalan memanjang.
class _StepDots extends StatelessWidget {
  final int total;
  final int done;
  final Duration fade;
  const _StepDots({required this.total, required this.done, required this.fade});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < total; i++)
          AnimatedContainer(
            duration: fade,
            width: i == done ? 22 : 10,
            height: 10,
            margin: const EdgeInsets.symmetric(horizontal: 4),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(5),
              color: i < done ? Colors.greenAccent : (i == done ? Colors.white : Colors.white30),
            ),
          ),
      ],
    );
  }
}
