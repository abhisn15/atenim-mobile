import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../../providers/attendance_provider.dart';

/// Awalan isi QR absen dari layar absen (lihat lib/attendance-qr.ts di server).
const String attendanceQrPrefix = 'MMSA1:';

/// Kamera untuk absen dengan QR yang tampil di layar absen. QR berganti tiap 30 detik dan
/// diperiksa server bersama lokasi GPS. Mengembalikan pesan sukses lewat Navigator.pop.
class AttendanceQrScannerScreen extends StatefulWidget {
  final bool checkOut;

  const AttendanceQrScannerScreen({super.key, required this.checkOut});

  @override
  State<AttendanceQrScannerScreen> createState() =>
      _AttendanceQrScannerScreenState();
}

class _AttendanceQrScannerScreenState extends State<AttendanceQrScannerScreen> {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    formats: const [BarcodeFormat.qrCode],
  );
  bool _handling = false;
  bool _submitting = false;
  String? _hint;
  String? _error;

  String get _action => widget.checkOut ? 'Check-out' : 'Check-in';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    final raw = capture.barcodes
        .map((b) => b.rawValue)
        .whereType<String>()
        .firstOrNull;
    if (raw != null) await _handleRaw(raw);
  }

  Future<void> _handleRaw(String raw) async {
    if (_handling) return;
    _handling = true;
    final value = raw.trim();
    if (!value.startsWith(attendanceQrPrefix)) {
      setState(() {
        _hint = value.startsWith('MMSP1:')
            ? 'Ini stiker patroli, bukan QR absen. Scan QR yang tampil di layar absen.'
            : 'Ini bukan QR absen. Scan QR yang tampil di layar absen.';
      });
      Future.delayed(const Duration(seconds: 2), () => _handling = false);
      return;
    }

    await _controller.stop();
    if (!mounted) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    final result = await context.read<AttendanceProvider>().submitQrAttendance(
      checkOut: widget.checkOut,
      qrData: value,
    );
    if (!mounted) return;
    if (result['success'] == true) {
      Navigator.pop(context, '$_action berhasil');
      return;
    }
    setState(() {
      _submitting = false;
      _error = result['message']?.toString() ?? '$_action gagal. Coba lagi.';
    });
  }

  Future<void> _scanAgain() async {
    setState(() {
      _error = null;
      _hint = null;
    });
    _handling = false;
    await _controller.start();
  }

  /// Hanya untuk uji di emulator (build debug): isi QR ditempel manual. Tidak ada di APK rilis.
  Future<void> _debugEnterQr() async {
    final ctrl = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Isi QR (khusus debug)'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          // Tanpa saran/koreksi keyboard supaya isi QR yang diketik tidak diubah
          keyboardType: TextInputType.visiblePassword,
          autocorrect: false,
          enableSuggestions: false,
          decoration: const InputDecoration(hintText: 'MMSA1:...'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('Pakai'),
          ),
        ],
      ),
    );
    FocusManager.instance.primaryFocus?.unfocus();
    if (value != null && value.trim().isNotEmpty) await _handleRaw(value);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text('$_action dengan QR'),
        actions: [
          ValueListenableBuilder<MobileScannerState>(
            valueListenable: _controller,
            builder: (context, state, _) {
              if (state.torchState == TorchState.unavailable)
                return const SizedBox.shrink();
              final on = state.torchState == TorchState.on;
              return IconButton(
                tooltip: on ? 'Matikan senter' : 'Nyalakan senter',
                icon: Icon(on ? Icons.flash_on : Icons.flash_off),
                onPressed: () => _controller.toggleTorch(),
              );
            },
          ),
          if (kDebugMode && !_submitting)
            IconButton(
              tooltip: 'Isi QR manual (debug)',
              icon: const Icon(Icons.keyboard),
              onPressed: _debugEnterQr,
            ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            errorBuilder: (context, error) => _CameraError(error: error),
          ),
          IgnorePointer(child: CustomPaint(painter: _FramePainter())),
          Positioned(
            left: 16,
            right: 16,
            bottom: 32,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                _hint ??
                    'Arahkan kamera ke QR di layar absen. Lokasi GPS ikut diperiksa.',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  height: 1.35,
                ),
              ),
            ),
          ),
          if (_submitting || _error != null)
            _ResultPanel(
              submitting: _submitting,
              action: _action,
              error: _error,
              onRetry: _scanAgain,
              onClose: () => Navigator.pop(context),
            ),
        ],
      ),
    );
  }
}

/// Panel di atas kamera saat absen dikirim, atau saat server menolak.
class _ResultPanel extends StatelessWidget {
  final bool submitting;
  final String action;
  final String? error;
  final VoidCallback onRetry;
  final VoidCallback onClose;

  const _ResultPanel({
    required this.submitting,
    required this.action,
    required this.error,
    required this.onRetry,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.82),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
            ),
            child: submitting
                ? Semantics(
                    liveRegion: true,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(
                          width: 32,
                          height: 32,
                          child: CircularProgressIndicator(strokeWidth: 3),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Memeriksa QR dan lokasi, lalu mengirim $action...',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 15,
                            height: 1.4,
                            color: Color(0xFF1F2937),
                          ),
                        ),
                      ],
                    ),
                  )
                : Semantics(
                    liveRegion: true,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          '$action belum tercatat',
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF111827),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          error ?? '',
                          style: const TextStyle(
                            fontSize: 15,
                            height: 1.4,
                            color: Color(0xFF374151),
                          ),
                        ),
                        const SizedBox(height: 20),
                        FilledButton(
                          onPressed: onRetry,
                          style: FilledButton.styleFrom(
                            minimumSize: const Size.fromHeight(48),
                          ),
                          child: const Text('Scan ulang'),
                        ),
                        const SizedBox(height: 8),
                        TextButton(
                          onPressed: onClose,
                          style: TextButton.styleFrom(
                            minimumSize: const Size.fromHeight(44),
                          ),
                          child: const Text('Tutup'),
                        ),
                      ],
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

class _CameraError extends StatelessWidget {
  final MobileScannerException error;

  const _CameraError({required this.error});

  @override
  Widget build(BuildContext context) {
    final denied = error.errorCode == MobileScannerErrorCode.permissionDenied;
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.no_photography_outlined,
                color: Colors.white70,
                size: 56,
              ),
              const SizedBox(height: 16),
              Text(
                denied
                    ? 'Izin kamera ditolak. Kamera dibutuhkan untuk membaca QR absen.'
                    : 'Kamera tidak bisa dibuka (${error.errorCode.name}). Tutup halaman ini lalu coba lagi.',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  height: 1.4,
                ),
              ),
              if (denied) ...[
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: openAppSettings,
                  child: const Text('Buka pengaturan izin'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Bingkai bidik di tengah layar, sisanya digelapkan.
class _FramePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final side = size.shortestSide * 0.68;
    final rect = Rect.fromCenter(
      center: Offset(size.width / 2, size.height * 0.42),
      width: side,
      height: side,
    );
    final shade = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRRect(RRect.fromRectAndRadius(rect, const Radius.circular(16)));
    canvas.drawPath(
      shade,
      Paint()..color = Colors.black.withValues(alpha: 0.45),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(16)),
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
