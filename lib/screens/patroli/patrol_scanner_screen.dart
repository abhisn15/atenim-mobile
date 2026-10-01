import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../../models/patrol_models.dart';
import '../../providers/patrol_provider.dart';
import '../../services/patrol_service.dart';

/// Hasil scan yang sudah dikenali: titik dari paket HP + token mentah + jam scan.
class PatrolScanHit {
  final PatrolPoint point;
  final String token;
  final DateTime scannedAt;

  const PatrolScanHit(this.point, this.token, this.scannedAt);
}

/// Kamera pemindai stiker QR patroli. Stiker dikenali dari paket di HP (hash token), jadi tetap
/// bekerja tanpa sinyal. Mengembalikan [PatrolScanHit] lewat Navigator.pop.
class PatrolScannerScreen extends StatefulWidget {
  /// Titik yang diharapkan (bila scan dimulai dari daftar titik), untuk peringatan salah stiker.
  final PatrolPoint? expected;

  const PatrolScannerScreen({super.key, this.expected});

  @override
  State<PatrolScannerScreen> createState() => _PatrolScannerScreenState();
}

class _PatrolScannerScreenState extends State<PatrolScannerScreen> {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    formats: const [BarcodeFormat.qrCode],
  );
  bool _handling = false;
  String? _hint;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_handling) return;
    final raw = capture.barcodes.map((b) => b.rawValue).whereType<String>().firstOrNull;
    if (raw == null) return;
    await _handleRaw(raw);
  }

  Future<void> _handleRaw(String raw) async {
    if (_handling) return;
    _handling = true;
    final scannedAt = DateTime.now();
    final token = normalizePatrolToken(raw);
    if (token == null) {
      _showHint('Ini bukan stiker patroli. Arahkan kamera ke stiker QR bertuliskan PATROLI.');
      return;
    }
    final provider = context.read<PatrolProvider>();
    final point = provider.pointForToken(token);
    if (point == null) {
      await _controller.stop();
      if (!mounted) return;
      final action = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Stiker tidak dikenali'),
          content: const Text(
            'Stiker ini tidak ada di paket patroli HP. Bisa jadi stiker baru diganti atau milik site lain. '
            'Perbarui paket bila ada sinyal. Bila tetap tidak dikenali, pakai "Tidak bisa scan?" di daftar titik.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, 'back'), child: const Text('Kembali')),
            FilledButton(onPressed: () => Navigator.pop(ctx, 'refresh'), child: const Text('Perbarui paket')),
          ],
        ),
      );
      if (!mounted) return;
      if (action == 'refresh') {
        await provider.refresh();
        if (!mounted) return;
        final retry = provider.pointForToken(token);
        if (retry != null) {
          Navigator.pop(context, PatrolScanHit(retry, token, scannedAt));
          return;
        }
        _showHint(provider.packError != null
            ? 'Paket belum bisa diperbarui: ${provider.packError}'
            : 'Stiker tetap tidak dikenali setelah paket diperbarui.');
      } else {
        Navigator.pop(context);
        return;
      }
      await _controller.start();
      return;
    }
    final expected = widget.expected;
    if (expected != null && expected.id != point.id) {
      await _controller.stop();
      if (!mounted) return;
      final proceed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Stiker titik lain'),
          content: Text('Yang terbaca ${point.code} (${point.name}), bukan ${expected.code}. Lanjut cek ${point.code}?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Scan ulang')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text('Lanjut ${point.code}')),
          ],
        ),
      );
      if (!mounted) return;
      if (proceed != true) {
        _handling = false;
        await _controller.start();
        return;
      }
    }
    if (!mounted) return;
    Navigator.pop(context, PatrolScanHit(point, token, scannedAt));
  }

  void _showHint(String message) {
    setState(() => _hint = message);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) _handling = false;
    });
  }

  /// Hanya untuk uji di emulator (build debug): isi QR diketik manual. Tidak ada di APK rilis.
  Future<void> _debugEnterToken() async {
    final ctrl = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Isi QR (khusus debug)'),
        content: TextField(controller: ctrl, autofocus: true, decoration: const InputDecoration(hintText: 'MMSP1:...')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Batal')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('Pakai')),
        ],
      ),
    );
    if (value != null && value.trim().isNotEmpty) await _handleRaw(value);
  }

  @override
  Widget build(BuildContext context) {
    final expected = widget.expected;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(expected == null ? 'Scan stiker titik' : 'Scan ${expected.code}'),
        actions: [
          ValueListenableBuilder<MobileScannerState>(
            valueListenable: _controller,
            builder: (context, state, _) {
              if (state.torchState == TorchState.unavailable) return const SizedBox.shrink();
              final on = state.torchState == TorchState.on;
              return IconButton(
                tooltip: on ? 'Matikan senter' : 'Nyalakan senter',
                icon: Icon(on ? Icons.flash_on : Icons.flash_off),
                onPressed: () => _controller.toggleTorch(),
              );
            },
          ),
          if (kDebugMode)
            IconButton(tooltip: 'Isi QR manual (debug)', icon: const Icon(Icons.keyboard), onPressed: _debugEnterToken),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            errorBuilder: (context, error) => _ScannerError(error: error),
          ),
          IgnorePointer(child: CustomPaint(painter: _FramePainter())),
          Positioned(
            left: 16,
            right: 16,
            bottom: 32,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.7), borderRadius: BorderRadius.circular(12)),
                  child: Text(
                    _hint ??
                        (expected == null
                            ? 'Arahkan kamera ke stiker QR di titik patroli.'
                            : 'Arahkan kamera ke stiker ${expected.code} di ${expected.name}.'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, fontSize: 15, height: 1.35),
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Jam scan dan lokasi dicatat saat stiker terbaca.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white70, fontSize: 13),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ScannerError extends StatelessWidget {
  final MobileScannerException error;

  const _ScannerError({required this.error});

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
              const Icon(Icons.no_photography_outlined, color: Colors.white70, size: 56),
              const SizedBox(height: 16),
              Text(
                denied
                    ? 'Izin kamera ditolak. Kamera dibutuhkan untuk membaca stiker QR patroli.'
                    : 'Kamera tidak bisa dibuka (${error.errorCode.name}). Tutup halaman ini lalu coba lagi.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 15, height: 1.4),
              ),
              if (denied) ...[
                const SizedBox(height: 16),
                FilledButton(onPressed: openAppSettings, child: const Text('Buka pengaturan izin')),
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
    final rect = Rect.fromCenter(center: Offset(size.width / 2, size.height * 0.42), width: side, height: side);
    final shade = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRRect(RRect.fromRectAndRadius(rect, const Radius.circular(16)));
    canvas.drawPath(shade, Paint()..color = Colors.black.withValues(alpha: 0.45));
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
