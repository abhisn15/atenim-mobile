import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart' show ResolutionPreset;
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../models/patrol_models.dart';
import '../../providers/auth_provider.dart';
import '../../providers/patrol_provider.dart';
import '../../utils/patrol_geo.dart';
import '../../utils/photo_watermark.dart';
import '../../widgets/ui_kit.dart';
import '../camera/camera_screen.dart';

/// Cara titik dicatat: scan stiker, "tidak bisa scan" (ditinjau SPV), atau dilewati dengan alasan.
enum PatrolCheckMethod { qr, manual, skip }

/// Alasan "tidak bisa scan" / dilewati harus cukup jelas bagi SPV; server menandai alasan yang lebih pendek.
const int _minReasonChars = 10;

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
  // Foto bukti per tugas (satu per tugas). Hanya yang tugasnya dicentang yang dikirim.
  final Map<String, File> _taskPhotos = {};
  final ScrollController _scroll = ScrollController();
  String _condition = 'aman';
  geo.Position? _fix;
  bool _locating = true;
  String? _locError;
  bool _saving = false;
  bool _saved = false;
  String? _formError;

  /// Penilaian lokasi saat ini (jarak ke titik, radius, akurasi) dengan aturan yang sama dengan server.
  PatrolGeoCheck get _geo => PatrolGeoCheck.evaluate(
        pointLat: _point.latitude,
        pointLng: _point.longitude,
        radiusMeters: _point.radiusMeters,
        gpsMode: _point.gpsMode,
        lat: _fix?.latitude,
        lng: _fix?.longitude,
        accuracy: _fix?.accuracy,
        mocked: _fix?.isMocked ?? false,
        fixTime: _fix?.timestamp,
      );

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
    if (mounted && !_locating) setState(() => _locating = true);
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
      _taskPhotos.isNotEmpty ||
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
        builder: (_) => const CameraScreen(title: 'Foto titik patroli', allowGallery: false, preset: ResolutionPreset.medium),
      ),
    );
    if (photo != null && mounted) {
      final stamped = await _stampPhoto(photo);
      if (!mounted) return;
      setState(() {
        _photos.add(stamped);
        _formError = null;
      });
    }
  }

  /// Membakar titik, jam, koordinat GPS, dan nama petugas ke foto. Jalur "tidak bisa scan" diberi penanda
  /// tegas supaya peninjau tahu foto ini bukan bukti scan QR.
  Future<File> _stampPhoto(File photo, {String? taskLabel}) {
    final fix = _fix;
    final officer = context.read<AuthProvider>().user?.name;
    return PhotoWatermark.stamp(photo, [
      '${_point.code} · ${_point.name}${taskLabel == null ? '' : ' · $taskLabel'}',
      PhotoWatermark.formatMoment(DateTime.now()),
      PhotoWatermark.formatLocation(
        latitude: fix?.latitude,
        longitude: fix?.longitude,
        accuracy: fix?.accuracy,
        mocked: fix?.isMocked ?? false,
      ),
      if (officer != null && officer.isNotEmpty) 'Petugas: $officer',
      if (_method == PatrolCheckMethod.manual) 'TANPA SCAN QR',
    ]);
  }

  Future<void> _takeTaskPhoto(PatrolTask task) async {
    FocusManager.instance.primaryFocus?.unfocus();
    final photo = await Navigator.push<File>(
      context,
      MaterialPageRoute(
        builder: (_) => CameraScreen(title: 'Foto: ${task.label}', allowGallery: false, preset: ResolutionPreset.medium),
      ),
    );
    if (photo != null && mounted) {
      final stamped = await _stampPhoto(photo, taskLabel: task.label);
      if (!mounted) return;
      setState(() => _taskPhotos[task.id] = stamped);
    }
  }

  Future<void> _submit() async {
    if (_saving) return;
    FocusManager.instance.primaryFocus?.unfocus();
    final patrol = context.read<PatrolProvider>();
    final reason = _reasonCtrl.text.trim();
    final note = _noteCtrl.text.trim();
    String? error;
    if (_method != PatrolCheckMethod.qr && reason.length < _minReasonChars) {
      error = _method == PatrolCheckMethod.skip
          ? 'Tulis alasan titik ini dilewati (minimal $_minReasonChars huruf).'
          : 'Tulis alasan stiker tidak bisa discan (minimal $_minReasonChars huruf).';
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

    final geoCheck = _geo;
    if (_method != PatrolCheckMethod.skip && geoCheck.willBeFlaggedHeavy) {
      final detail = geoCheck.mocked
          ? 'HP ini terdeteksi memakai lokasi palsu. Scan akan ditandai dan menunggu tinjauan SPV.'
          : 'Anda terdeteksi sekitar ${geoCheck.distanceM!.round()} m dari titik (radius ${geoCheck.radiusM} m). '
              'Scan akan ditandai dan menunggu tinjauan SPV. Dekati titiknya lalu perbarui lokasi, atau tetap simpan bila memang di titik yang benar.';
      if (!mounted) return;
      final choice = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(geoCheck.mocked ? 'Lokasi palsu terdeteksi' : 'Lokasi jauh dari titik'),
          content: Text(detail),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Perbarui lokasi')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Tetap simpan')),
          ],
        ),
      );
      if (choice != true) {
        if (choice == false) unawaited(_locate());
        return;
      }
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
            taskPhotos: _taskPhotos,
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
            _LocationCard(locating: _locating, check: _geo, hasFix: _fix != null, error: _locError, onRefresh: _locate),
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
                      for (final t in _point.tasks) ...[
                        CheckboxListTile(
                          value: _taskDone[t.id] == true,
                          onChanged: (v) => setState(() => _taskDone[t.id] = v == true),
                          title: Text(t.label),
                          controlAffinity: ListTileControlAffinity.leading,
                        ),
                        // Foto bukti per tugas: muncul setelah tugasnya dicentang, boleh dikosongkan.
                        if (_taskDone[t.id] == true)
                          _TaskPhotoRow(
                            photo: _taskPhotos[t.id],
                            onTake: () => _takeTaskPhoto(t),
                            onRemove: () => setState(() => _taskPhotos.remove(t.id)),
                          ),
                      ],
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

class _LocationCard extends StatelessWidget {
  final bool locating;
  final PatrolGeoCheck check;
  final bool hasFix;
  final String? error;
  final VoidCallback onRefresh;

  const _LocationCard({
    required this.locating,
    required this.check,
    required this.hasFix,
    required this.error,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    final String title;
    String? detail;
    final IconData icon;
    final Tone tone;
    var canRefresh = true;

    final acc = check.accuracyM == null ? '' : ', akurasi ± ${check.accuracyM!.round()} m';
    if (locating) {
      title = 'Mencari lokasi GPS...';
      icon = Icons.gps_not_fixed;
      tone = Tone.neutral;
      canRefresh = false;
    } else if (check.mocked) {
      title = 'Lokasi palsu terdeteksi';
      detail = 'Matikan aplikasi lokasi palsu di HP ini. Scan akan ditandai dan menunggu tinjauan SPV.';
      icon = Icons.location_off;
      tone = Tone.danger;
    } else {
      switch (check.state) {
        case PatrolGeoState.notEvaluated:
          title = hasFix ? 'Lokasi tercatat$acc' : 'Titik ini tidak memeriksa jarak GPS';
          detail = hasFix ? 'Titik ini tidak memakai pengecekan jarak.' : null;
          icon = hasFix ? Icons.gps_fixed : Icons.gps_not_fixed;
          tone = Tone.neutral;
        case PatrolGeoState.noFix:
          title = 'Lokasi GPS belum didapat';
          detail = '${error ?? 'Keluar ke area terbuka'} lalu ketuk Perbarui lokasi. Hasil cek tetap bisa disimpan, tetapi akan ditandai.';
          icon = Icons.gps_off;
          tone = Tone.warning;
        case PatrolGeoState.weakGps:
          title = 'GPS lemah$acc';
          detail = 'Jarak ke titik belum bisa dipastikan. Tunggu beberapa detik atau pindah ke area terbuka, lalu ketuk Perbarui lokasi.';
          icon = Icons.signal_cellular_connected_no_internet_0_bar;
          tone = Tone.warning;
        case PatrolGeoState.atPoint:
          title = 'Di titik: ± ${check.distanceM!.round()} m dari titik';
          detail = 'Radius ${check.radiusM} m$acc.';
          icon = Icons.gps_fixed;
          tone = Tone.success;
        case PatrolGeoState.edge:
          title = 'Di tepi radius: ± ${check.distanceM!.round()} m dari titik';
          detail = 'Radius ${check.radiusM} m$acc. Mendekatlah ke titik supaya scan tidak ditandai.';
          icon = Icons.near_me;
          tone = Tone.warning;
        case PatrolGeoState.outside:
          title = 'Jauh dari titik: ± ${check.distanceM!.round()} m';
          detail = 'Radius ${check.radiusM} m$acc. Scan akan ditandai dan menunggu tinjauan SPV. Dekati titiknya lalu ketuk Perbarui lokasi.';
          icon = Icons.wrong_location;
          tone = Tone.danger;
      }
      if (check.stale && check.state != PatrolGeoState.noFix) {
        detail = '${detail ?? ''} Lokasi ini dari pembacaan lama, ketuk Perbarui lokasi.'.trim();
      }
    }

    final colors = toneColors(tone);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
      decoration: BoxDecoration(
        color: colors.bg,
        borderRadius: BorderRadius.circular(AtenimUi.radiusControl),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: locating
                ? SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: colors.fg))
                : Icon(icon, size: 18, color: colors.fg),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(color: colors.fg, fontSize: 14, fontWeight: FontWeight.w700)),
                if (detail != null) ...[
                  const SizedBox(height: 2),
                  Text(detail, style: TextStyle(color: colors.fg, fontSize: 13, height: 1.3)),
                ],
              ],
            ),
          ),
          if (canRefresh)
            TextButton(
              onPressed: onRefresh,
              style: TextButton.styleFrom(minimumSize: const Size(48, 48), foregroundColor: colors.fg),
              child: const Text('Perbarui lokasi', textAlign: TextAlign.center),
            ),
        ],
      ),
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
          decoration: const InputDecoration(border: OutlineInputBorder(), hintText: 'Tulis alasan, minimal 10 huruf'),
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

/// Baris foto di bawah satu tugas: tombol ambil foto, atau gambar kecil dengan Ganti/Hapus.
class _TaskPhotoRow extends StatelessWidget {
  final File? photo;
  final VoidCallback onTake;
  final VoidCallback onRemove;

  const _TaskPhotoRow({required this.photo, required this.onTake, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(72, 0, 16, 12),
      child: photo == null
          ? Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: onTake,
                icon: const Icon(Icons.photo_camera_outlined, size: 20),
                label: const Text('Foto tugas (boleh tidak)'),
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
              ),
            )
          : Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.file(photo!, width: 64, height: 64, fit: BoxFit.cover),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: onTake,
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  child: const Text('Ganti'),
                ),
                TextButton(
                  onPressed: onRemove,
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48), foregroundColor: Colors.red[800]),
                  child: const Text('Hapus'),
                ),
              ],
            ),
    );
  }
}
