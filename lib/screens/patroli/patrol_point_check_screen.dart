import 'dart:io';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../models/patrol_models.dart';
import '../../providers/patrol_provider.dart';
import '../camera/camera_screen.dart';

/// Cara titik dicatat: scan stiker, "tidak bisa scan" (ditinjau SPV), atau dilewati dengan alasan.
enum PatrolCheckMethod { qr, manual, skip }

/// Halaman cek satu titik. Untuk scan QR, tugas titik baru terbuka di sini setelah stikernya terbaca.
class PatrolPointCheckScreen extends StatefulWidget {
  final PatrolPoint point;
  final PatrolCheckMethod method;
  final String? token;
  final DateTime scannedAt;

  const PatrolPointCheckScreen({
    super.key,
    required this.point,
    required this.method,
    this.token,
    required this.scannedAt,
  });

  @override
  State<PatrolPointCheckScreen> createState() => _PatrolPointCheckScreenState();
}

class _PatrolPointCheckScreenState extends State<PatrolPointCheckScreen> {
  late final String _clientScanId;
  final Map<String, bool> _taskDone = {};
  final TextEditingController _noteCtrl = TextEditingController();
  final TextEditingController _reasonCtrl = TextEditingController();
  final List<File> _photos = [];
  final ScrollController _scroll = ScrollController();
  String _condition = 'aman';
  geo.Position? _fix;
  bool _locating = true;
  String? _locError;
  bool _saving = false;
  bool _saved = false;
  String? _formError;

  PatrolCheckMethod get _method => widget.method;
  PatrolPoint get _point => widget.point;

  @override
  void initState() {
    super.initState();
    _clientScanId = context.read<PatrolProvider>().newClientScanId();
    for (final t in _point.tasks) {
      _taskDone[t.id] = false;
    }
    _locate();
  }

  @override
  void dispose() {
    _noteCtrl.dispose();
    _reasonCtrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _locate() async {
    try {
      final permission = await geo.Geolocator.checkPermission();
      if (permission == geo.LocationPermission.denied || permission == geo.LocationPermission.deniedForever) {
        setState(() {
          _locating = false;
          _locError = 'Izin lokasi belum diberikan. Hasil cek tetap bisa disimpan.';
        });
        return;
      }
      geo.Position? pos;
      try {
        pos = await geo.Geolocator.getCurrentPosition(
          desiredAccuracy: geo.LocationAccuracy.high,
          timeLimit: const Duration(seconds: 10),
        );
      } catch (_) {
        pos = await geo.Geolocator.getLastKnownPosition();
      }
      if (!mounted) return;
      setState(() {
        _fix = pos;
        _locating = false;
        _locError = pos == null ? 'Lokasi GPS tidak didapat (wajar di dalam gedung). Hasil cek tetap bisa disimpan.' : null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _locating = false;
        _locError = 'Lokasi GPS tidak didapat. Hasil cek tetap bisa disimpan.';
      });
    }
  }

  /// Aturan foto: temuan dan "tidak bisa scan" selalu berfoto; selebihnya mengikuti pengaturan titik.
  /// Pengaturan "acak": selalu di titik dalam ruangan/tertutup dan titik kritis, 1 dari 3 scan di luar ruangan.
  bool get _photoRequired {
    if (_method == PatrolCheckMethod.skip) return false;
    if (_method == PatrolCheckMethod.manual || _condition == 'temuan') return true;
    switch (_point.photoPolicy) {
      case 'always':
        return true;
      case 'none':
        return false;
      default:
        if (_point.isCritical || _point.locationType != 'outdoor') return true;
        return int.parse(_clientScanId.substring(0, 2), radix: 16) % 3 == 0;
    }
  }

  bool get _dirty =>
      _photos.isNotEmpty ||
      _noteCtrl.text.trim().isNotEmpty ||
      _reasonCtrl.text.trim().isNotEmpty ||
      _taskDone.values.any((v) => v) ||
      _condition != 'aman';

  Future<void> _takePhoto() async {
    // Lepas fokus dulu: tanpa ini keyboard muncul lagi saat kembali dari kamera
    FocusManager.instance.primaryFocus?.unfocus();
    final photo = await Navigator.push<File>(
      context,
      MaterialPageRoute(
        builder: (_) => const CameraScreen(title: 'Foto titik patroli', allowGallery: false, preferLowResolution: true),
      ),
    );
    if (photo != null && mounted) {
      setState(() {
        _photos.add(photo);
        _formError = null;
      });
    }
  }

  Future<void> _submit() async {
    if (_saving) return;
    FocusManager.instance.primaryFocus?.unfocus();
    final patrol = context.read<PatrolProvider>();
    final reason = _reasonCtrl.text.trim();
    final note = _noteCtrl.text.trim();
    String? error;
    if (_method != PatrolCheckMethod.qr && reason.length < 3) {
      error = _method == PatrolCheckMethod.skip ? 'Tulis alasan titik ini dilewati.' : 'Tulis alasan stiker tidak bisa discan.';
    } else if (_condition == 'temuan' && note.length < 5) {
      error = 'Jelaskan temuan di catatan (minimal 5 huruf).';
    } else if (_photoRequired && _photos.isEmpty) {
      error = 'Ambil minimal 1 foto di titik ini.';
    }
    setState(() => _formError = error);
    if (error != null) {
      _revealError();
      return;
    }

    final undone = _point.tasks.where((t) => _taskDone[t.id] != true).length;
    if (_method != PatrolCheckMethod.skip && undone > 0) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Ada tugas belum dicentang'),
          content: Text('$undone tugas akan tercatat tidak dikerjakan. Tetap simpan?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Periksa lagi')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Tetap simpan')),
          ],
        ),
      );
      if (ok != true) return;
    }

    setState(() => _saving = true);
    final fix = _fix;
    try {
      final scan = await patrol.submit(
            clientScanId: _clientScanId,
            method: _method.name,
            token: widget.token,
            point: _point,
            reason: reason.isEmpty ? null : reason,
            scannedAt: widget.scannedAt,
            latitude: fix?.latitude,
            longitude: fix?.longitude,
            accuracy: fix?.accuracy,
            fixAgeMs: fix == null ? null : widget.scannedAt.difference(fix.timestamp).inMilliseconds.abs(),
            isMocked: fix?.isMocked ?? false,
            condition: _method == PatrolCheckMethod.skip ? 'aman' : _condition,
            note: note.isEmpty ? null : note,
            taskResults: _method == PatrolCheckMethod.skip
                ? const []
                : _point.tasks.map((t) => PatrolTaskResult(id: t.id, label: t.label, done: _taskDone[t.id] == true)).toList(),
            photos: _photos,
          );
      _saved = true;
      if (mounted) Navigator.pop(context, scan);
    } catch (e) {
      if (mounted) {
        setState(() => _formError = 'Belum tersimpan: $e');
        _revealError();
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Pesan galat ada di bawah formulir: gulir ke sana supaya terlihat.
  void _revealError() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  Future<bool> _confirmLeave() async {
    if (_saved || !_dirty) return true;
    final leave = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Hasil cek belum disimpan'),
        content: const Text('Isian di titik ini akan hilang. Keluar?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Lanjut isi')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Keluar')),
        ],
      ),
    );
    return leave == true;
  }

  @override
  Widget build(BuildContext context) {
    final title = switch (_method) {
      PatrolCheckMethod.qr => 'Cek titik',
      PatrolCheckMethod.manual => 'Tidak bisa scan',
      PatrolCheckMethod.skip => 'Lewati titik',
    };
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmLeave() && context.mounted) Navigator.pop(context);
      },
      child: Scaffold(
        appBar: AppBar(title: Text(title)),
        body: ListView(
          controller: _scroll,
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
          children: [
            _PointHeader(point: _point, method: _method, scannedAt: widget.scannedAt),
            const SizedBox(height: 12),
            _LocationLine(locating: _locating, fix: _fix, error: _locError),
            if (_method != PatrolCheckMethod.qr) ...[
              const SizedBox(height: 20),
              _ReasonField(
                controller: _reasonCtrl,
                label: _method == PatrolCheckMethod.skip ? 'Kenapa titik ini dilewati?' : 'Kenapa stiker tidak bisa discan?',
                presets: _method == PatrolCheckMethod.skip
                    ? const ['Area dikunci', 'Sedang ada pekerjaan di area', 'Diminta atasan']
                    : const ['Stiker rusak', 'Stiker hilang', 'Kamera tidak bisa membaca'],
                note: _method == PatrolCheckMethod.skip
                    ? 'Titik yang dilewati tidak dihitung selesai.'
                    : 'Hasil cek ini masuk tinjauan SPV sebelum dihitung.',
                onChanged: () => setState(() => _formError = null),
              ),
            ],
            if (_method != PatrolCheckMethod.skip) ...[
              if (_point.tasks.isNotEmpty) ...[
                const SizedBox(height: 20),
                _SectionTitle('Tugas di titik ini', trailing: '${_taskDone.values.where((v) => v).length}/${_point.tasks.length}'),
                Card(
                  margin: EdgeInsets.zero,
                  child: Column(
                    children: [
                      for (final t in _point.tasks)
                        CheckboxListTile(
                          value: _taskDone[t.id] == true,
                          onChanged: (v) => setState(() => _taskDone[t.id] = v == true),
                          title: Text(t.label),
                          controlAffinity: ListTileControlAffinity.leading,
                        ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 20),
              const _SectionTitle('Kondisi titik'),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'aman', label: Text('Aman'), icon: Icon(Icons.verified_outlined)),
                  ButtonSegment(value: 'temuan', label: Text('Ada temuan'), icon: Icon(Icons.flag_outlined)),
                ],
                selected: {_condition},
                onSelectionChanged: (s) => setState(() => _condition = s.first),
                style: const ButtonStyle(visualDensity: VisualDensity.standard),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _noteCtrl,
                minLines: 2,
                maxLines: 5,
                maxLength: 2000,
                onChanged: (_) => setState(() => _formError = null),
                decoration: InputDecoration(
                  labelText: _condition == 'temuan' ? 'Jelaskan temuan (wajib)' : 'Catatan (boleh kosong)',
                  hintText: _condition == 'temuan' ? 'Contoh: gembok pintu longgar, sudah dikunci ulang' : null,
                  border: const OutlineInputBorder(),
                ),
              ),
            ],
            const SizedBox(height: 12),
            _PhotoSection(
              photos: _photos,
              required: _photoRequired,
              onAdd: _takePhoto,
              onRemove: (i) => setState(() => _photos.removeAt(i)),
            ),
            if (_formError != null) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red[50],
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.red[200]!),
                ),
                child: Row(
                  children: [
                    Icon(Icons.error_outline, color: Colors.red[800]),
                    const SizedBox(width: 8),
                    Expanded(child: Text(_formError!, style: TextStyle(color: Colors.red[900]))),
                  ],
                ),
              ),
            ],
          ],
        ),
        bottomNavigationBar: SafeArea(
          minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: FilledButton.icon(
            onPressed: _saving ? null : _submit,
            icon: _saving
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.save_outlined),
            label: Text(_saving ? 'Menyimpan...' : 'Simpan hasil cek'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          ),
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  final String? trailing;

  const _SectionTitle(this.text, {this.trailing});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(child: Text(text, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600))),
          if (trailing != null) Text(trailing!, style: TextStyle(color: Colors.grey[700])),
        ],
      ),
    );
  }
}

class _PointHeader extends StatelessWidget {
  final PatrolPoint point;
  final PatrolCheckMethod method;
  final DateTime scannedAt;

  const _PointHeader({required this.point, required this.method, required this.scannedAt});

  @override
  Widget build(BuildContext context) {
    final time = DateFormat('HH.mm', 'id_ID').format(scannedAt);
    final headline = switch (method) {
      PatrolCheckMethod.qr => 'Stiker terbaca pukul $time',
      PatrolCheckMethod.manual => 'Dicatat tanpa scan pukul $time',
      PatrolCheckMethod.skip => 'Dicatat pukul $time',
    };
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.blue[50],
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.blue[100]!),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(point.code, style: TextStyle(fontWeight: FontWeight.w700, color: Colors.blue[900], fontSize: 13)),
              if (point.isCritical) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(color: Colors.red[50], borderRadius: BorderRadius.circular(6)),
                  child: Text('Kritis', style: TextStyle(color: Colors.red[800], fontSize: 12, fontWeight: FontWeight.w600)),
                ),
              ],
            ],
          ),
          const SizedBox(height: 4),
          Text(point.name, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
          if (point.placeLabel.isNotEmpty) Text(point.placeLabel, style: TextStyle(color: Colors.grey[800])),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(method == PatrolCheckMethod.qr ? Icons.qr_code_2 : Icons.edit_note, size: 18, color: Colors.blue[800]),
              const SizedBox(width: 6),
              Text(headline, style: TextStyle(color: Colors.blue[900])),
            ],
          ),
          if (point.instruction != null) ...[
            const SizedBox(height: 10),
            Text(point.instruction!, style: TextStyle(color: Colors.grey[900], height: 1.4)),
          ],
        ],
      ),
    );
  }
}

class _LocationLine extends StatelessWidget {
  final bool locating;
  final geo.Position? fix;
  final String? error;

  const _LocationLine({required this.locating, required this.fix, required this.error});

  @override
  Widget build(BuildContext context) {
    final String text;
    final IconData icon;
    Color color = Colors.grey[800]!;
    if (locating) {
      text = 'Mencari lokasi GPS...';
      icon = Icons.gps_not_fixed;
    } else if (fix != null) {
      text = 'Lokasi tercatat, akurasi ± ${fix!.accuracy.round()} m';
      icon = Icons.gps_fixed;
      color = Colors.green[800]!;
    } else {
      text = error ?? 'Lokasi GPS tidak didapat.';
      icon = Icons.gps_off;
    }
    return Row(
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: TextStyle(color: color, fontSize: 13))),
      ],
    );
  }
}

class _ReasonField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final List<String> presets;
  final String note;
  final VoidCallback onChanged;

  const _ReasonField({
    required this.controller,
    required this.label,
    required this.presets,
    required this.note,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(label),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final p in presets)
              ActionChip(
                label: Text(p),
                onPressed: () {
                  controller.text = p;
                  controller.selection = TextSelection.collapsed(offset: p.length);
                  onChanged();
                },
              ),
          ],
        ),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          maxLength: 500,
          onChanged: (_) => onChanged(),
          decoration: const InputDecoration(border: OutlineInputBorder(), hintText: 'Tulis alasan singkat'),
        ),
        Text(note, style: TextStyle(color: Colors.grey[800], fontSize: 13)),
      ],
    );
  }
}

class _PhotoSection extends StatelessWidget {
  final List<File> photos;
  final bool required;
  final VoidCallback onAdd;
  final void Function(int) onRemove;

  const _PhotoSection({required this.photos, required this.required, required this.onAdd, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(required ? 'Foto (wajib di titik ini)' : 'Foto (boleh tidak)'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (var i = 0; i < photos.length; i++)
              Stack(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Image.file(photos[i], width: 88, height: 88, fit: BoxFit.cover),
                  ),
                  Positioned(
                    right: 0,
                    top: 0,
                    child: IconButton(
                      tooltip: 'Hapus foto ${i + 1}',
                      onPressed: () => onRemove(i),
                      style: IconButton.styleFrom(backgroundColor: Colors.black54, foregroundColor: Colors.white),
                      icon: const Icon(Icons.close, size: 18),
                    ),
                  ),
                ],
              ),
            if (photos.length < 5)
              SizedBox(
                width: 88,
                height: 88,
                child: OutlinedButton(
                  onPressed: onAdd,
                  style: OutlinedButton.styleFrom(padding: EdgeInsets.zero, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                  child: const Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [Icon(Icons.photo_camera_outlined), SizedBox(height: 4), Text('Ambil foto', style: TextStyle(fontSize: 12))],
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}
