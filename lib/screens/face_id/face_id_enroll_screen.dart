import 'dart:io';

import 'package:flutter/material.dart';

import '../../services/face_id_service.dart';
import '../../utils/toast_helper.dart';
import 'face_capture_screen.dart';

/// Persetujuan + pendaftaran wajah. Pop dengan `true` bila data terkirim (menunggu admin) atau ditolak
/// secara sadar oleh karyawan; `false`/null bila ditunda.
class FaceIdEnrollScreen extends StatefulWidget {
  final FaceIdState state;
  const FaceIdEnrollScreen({super.key, required this.state});

  @override
  State<FaceIdEnrollScreen> createState() => _FaceIdEnrollScreenState();
}

class _FaceIdEnrollScreenState extends State<FaceIdEnrollScreen> {
  static const _prompts = [
    'Lihat lurus ke kamera',
    'Senyum tipis, tetap lihat lurus',
    'Sekali lagi, lihat lurus ke kamera',
  ];

  final _service = FaceIdService();
  bool _agreed = false;
  bool _busy = false;
  String? _error;

  Future<void> _start() async {
    final photos = await Navigator.of(context).push<List<File>>(
      MaterialPageRoute(
        builder: (_) => const FaceCaptureScreen(title: 'Daftarkan wajah', shotPrompts: _prompts),
      ),
    );
    if (photos == null || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await _service.enroll(photos: photos, consentVersion: widget.state.consentVersion);
    for (final p in photos) {
      p.delete().catchError((_) => p); // foto wajah tidak dibiarkan menumpuk di HP
    }
    if (!mounted) return;
    if (result.ok) {
      ToastHelper.showSuccess(context, 'Face ID terkirim. Menunggu persetujuan admin.');
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _busy = false;
      _error = result.photoIndex != null ? 'Foto ${result.photoIndex! + 1}: ${result.message}' : result.message;
    });
  }

  Future<void> _decline() async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Tidak memakai Face ID?'),
        content: const Text('Absensi Anda tetap memakai foto seperti biasa. Anda bisa mengaktifkannya lagi nanti lewat admin.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Ya, tidak memakai')),
        ],
      ),
    );
    if (sure != true) return;
    setState(() => _busy = true);
    final ok = await _service.decline();
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _busy = false;
        _error = 'Gagal menyimpan pilihan Anda. Coba lagi.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Face ID absensi')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text('Absen dengan wajah', style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Text(
              'Lokasi kerja Anda memakai Face ID agar check-in dan check-out dipastikan dilakukan oleh Anda sendiri. Daftarkan wajah satu kali; ambil 3 foto singkat.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            for (final line in widget.state.consentText)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(padding: EdgeInsets.only(top: 3, right: 10), child: Icon(Icons.circle, size: 7)),
                    Expanded(child: Text(line, style: theme.textTheme.bodyMedium)),
                  ],
                ),
              ),
            const SizedBox(height: 4),
            CheckboxListTile(
              value: _agreed,
              onChanged: _busy ? null : (v) => setState(() => _agreed = v == true),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
              title: const Text('Saya mengerti dan menyetujui data wajah saya diproses seperti di atas.'),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(_error!, style: TextStyle(color: theme.colorScheme.error, fontWeight: FontWeight.w600)),
              ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: (_agreed && !_busy) ? _start : null,
              icon: _busy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.face_retouching_natural),
              label: Text(_busy ? 'Mengirim...' : 'Daftarkan wajah saya'),
            ),
            const SizedBox(height: 8),
            OutlinedButton(onPressed: _busy ? null : _decline, child: const Text('Saya tidak mau memakai Face ID')),
            TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(false), child: const Text('Nanti saja')),
          ],
        ),
      ),
    );
  }
}
