import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../config/api_config.dart';
import '../../models/patrol_models.dart';
import '../../widgets/photo_gallery_viewer.dart';

IconData patrolOutcomeIcon(String kind) => switch (kind) {
      'auto_accepted' => Icons.check_circle,
      'accepted_by_spv' => Icons.verified,
      'pending_review' => Icons.hourglass_top_rounded,
      'rejected_by_spv' || 'rejected_server' => Icons.block,
      'duplicate' => Icons.copy_all_outlined,
      'extra' => Icons.add_circle_outline,
      'skipped' => Icons.skip_next_outlined,
      'unsent' => Icons.cloud_upload_outlined,
      _ => Icons.info_outline,
    };

Color patrolOutcomeColor(String kind) => switch (kind) {
      'auto_accepted' || 'accepted_by_spv' => Colors.green[700]!,
      'pending_review' => Colors.orange[800]!,
      'rejected_by_spv' || 'rejected_server' => Colors.red[700]!,
      'unsent' => Colors.blue[800]!,
      _ => Colors.blueGrey[600]!,
    };

/// Rincian satu scan di riwayat: hasil penilaian dan alasannya, apa yang dilaporkan petugas, foto, dan lokasi.
class PatrolScanDetailScreen extends StatelessWidget {
  final PatrolHistoryItem item;

  const PatrolScanDetailScreen({super.key, required this.item});

  static final _full = DateFormat('EEEE, d MMMM yyyy · HH.mm', 'id_ID');
  static final _short = DateFormat('d MMM yyyy HH.mm', 'id_ID');
  static final _hm = DateFormat('HH.mm', 'id_ID');

  List<String> get _viewerUrls => [
        ...item.photoUrls,
        ...item.tasks.map((t) => t.photoUrl).whereType<String>(),
      ];

  void _openUrl(BuildContext context, String url) {
    final index = _viewerUrls.indexOf(url);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PhotoGalleryViewer(
          imageUrls: _viewerUrls,
          initialIndex: index < 0 ? 0 : index,
          urlResolver: ApiConfig.getImageUrl,
        ),
      ),
    );
  }

  void _openFile(BuildContext context, String path) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        backgroundColor: Colors.black,
        insetPadding: const EdgeInsets.all(12),
        child: Stack(
          children: [
            InteractiveViewer(child: Image.file(File(path), fit: BoxFit.contain)),
            Positioned(
              top: 4,
              right: 4,
              child: IconButton(
                tooltip: 'Tutup',
                color: Colors.white,
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(dialogContext).pop(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final outcome = item.outcome;
    final color = patrolOutcomeColor(outcome.kind);
    final place = [item.area, item.floor].whereType<String>().where((s) => s.isNotEmpty).join(' · ');
    final hasRound = item.roundStart != null && item.roundEnd != null;
    final kindLabel = switch (item.method) {
      'manual' => 'Tanpa scan QR',
      'skip' => 'Dilewati',
      _ => item.condition == 'temuan' ? 'Ada temuan' : 'Aman',
    };

    return Scaffold(
      appBar: AppBar(title: const Text('Detail scan')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          Text(
            item.pointName == null ? item.pointCode : '${item.pointCode} · ${item.pointName}',
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          ),
          if (place.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(place, style: TextStyle(color: Colors.grey[700])),
          ],
          const SizedBox(height: 4),
          Text(_full.format(item.scannedAt), style: TextStyle(color: Colors.grey[700])),
          Text(
            hasRound
                ? 'Ronde ${_hm.format(item.roundStart!)}-${_hm.format(item.roundEnd!)}'
                : (item.fromServer ? 'Di luar ronde terjadwal' : ''),
            style: TextStyle(color: Colors.grey[700]),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: color.withValues(alpha: 0.35)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(patrolOutcomeIcon(outcome.kind), color: color, size: 26),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        outcome.title,
                        style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: color),
                      ),
                    ),
                  ],
                ),
                if (outcome.explanation.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(outcome.explanation, style: const TextStyle(fontSize: 14, height: 1.35)),
                ],
                if (outcome.reasons.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  const Text('Ditandai karena', style: TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  for (final reason in outcome.reasons) _Bullet(reason),
                ],
                if (outcome.notes.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  const Text('Catatan sistem', style: TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  for (final note in outcome.notes) _Bullet(note),
                ],
                if (item.reviewedAt != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    'Ditinjau${item.reviewedBy == null ? '' : ' oleh ${item.reviewedBy}'} · ${_short.format(item.reviewedAt!)}',
                    style: TextStyle(fontSize: 12, color: Colors.grey[800]),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 20),
          const _SectionTitle('Yang Anda laporkan'),
          _InfoRow('Jenis', kindLabel),
          if (item.method == 'manual' && item.reason != null) _InfoRow('Alasan tidak bisa scan', item.reason!),
          if (item.note != null) _InfoRow('Catatan', item.note!),
          if (item.tasks.isNotEmpty) ...[
            const SizedBox(height: 8),
            for (final task in item.tasks)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      task.done ? Icons.check_box_outlined : Icons.cancel_outlined,
                      size: 20,
                      color: task.done ? Colors.green[700] : Colors.red[700],
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('${task.label}${task.done ? '' : ' (tidak dikerjakan)'}'),
                          if (task.note != null) Text(task.note!, style: TextStyle(fontSize: 12, color: Colors.grey[700])),
                        ],
                      ),
                    ),
                    if (task.photoUrl != null) ...[
                      const SizedBox(width: 8),
                      _NetThumb(url: task.photoUrl!, size: 56, onTap: () => _openUrl(context, task.photoUrl!)),
                    ] else if (task.photoPath != null && File(task.photoPath!).existsSync()) ...[
                      const SizedBox(width: 8),
                      _FileThumb(path: task.photoPath!, size: 56, onTap: () => _openFile(context, task.photoPath!)),
                    ],
                  ],
                ),
              ),
          ],
          if (item.photoUrls.isNotEmpty || item.localPhotoPaths.isNotEmpty) ...[
            const SizedBox(height: 20),
            const _SectionTitle('Foto titik'),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final url in item.photoUrls) _NetThumb(url: url, size: 96, onTap: () => _openUrl(context, url)),
                for (final path in item.localPhotoPaths)
                  if (File(path).existsSync()) _FileThumb(path: path, size: 96, onTap: () => _openFile(context, path)),
              ],
            ),
          ],
          if (item.geoLine != null) ...[
            const SizedBox(height: 20),
            const _SectionTitle('Lokasi'),
            Text(item.geoLine!),
          ],
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(text, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
      );
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  const _InfoRow(this.label, this.value);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 120, child: Text(label, style: TextStyle(color: Colors.grey[700]))),
            Expanded(child: Text(value)),
          ],
        ),
      );
}

class _Bullet extends StatelessWidget {
  final String text;
  const _Bullet(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('•  '),
            Expanded(child: Text(text)),
          ],
        ),
      );
}

class _NetThumb extends StatelessWidget {
  final String url;
  final double size;
  final VoidCallback onTap;
  const _NetThumb({required this.url, required this.size, required this.onTap});

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: 'Buka foto',
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: size,
              height: size,
              child: CachedNetworkImage(
                imageUrl: ApiConfig.getImageUrl(url),
                fit: BoxFit.cover,
                memCacheWidth: (size * 3).round(),
                placeholder: (_, _) => Container(color: Colors.grey[200]),
                errorWidget: (_, _, _) => Container(
                  color: Colors.grey[200],
                  child: Icon(Icons.broken_image_outlined, color: Colors.grey[600]),
                ),
              ),
            ),
          ),
        ),
      );
}

class _FileThumb extends StatelessWidget {
  final String path;
  final double size;
  final VoidCallback onTap;
  const _FileThumb({required this.path, required this.size, required this.onTap});

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: 'Buka foto',
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: size,
              height: size,
              child: Image.file(File(path), fit: BoxFit.cover, cacheWidth: (size * 3).round()),
            ),
          ),
        ),
      );
}
