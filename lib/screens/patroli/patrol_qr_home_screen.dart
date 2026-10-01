import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../models/patrol_models.dart';
import '../../providers/patrol_provider.dart';
import 'patrol_point_check_screen.dart';
import 'patrol_scanner_screen.dart';

final _hm = DateFormat('HH.mm', 'id_ID');

String _window(PatrolRound r) => '${_hm.format(r.windowStart)}-${_hm.format(r.windowEnd)}';

/// Halaman patroli untuk site Patroli QR: ronde shift ini, titik yang harus dicek, dan tombol scan.
class PatrolQrHomeScreen extends StatefulWidget {
  const PatrolQrHomeScreen({super.key});

  @override
  State<PatrolQrHomeScreen> createState() => _PatrolQrHomeScreenState();
}

class _PatrolQrHomeScreenState extends State<PatrolQrHomeScreen> {
  Timer? _tick;
  String? _selectedRoundId;
  DateTime _lastAutoRefresh = DateTime.now();

  @override
  void initState() {
    super.initState();
    // Jam dan sisa waktu ronde ikut bergerak; paket diperbarui tiap 15 menit supaya ronde
    // berikutnya (mis. lewat tengah malam) tetap muncul walau app dibiarkan terbuka
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!mounted) return;
      final patrol = context.read<PatrolProvider>();
      final now = DateTime.now();
      if (now.difference(_lastAutoRefresh) > const Duration(minutes: 15) && !patrol.loadingPack) {
        _lastAutoRefresh = now;
        patrol.refresh();
      }
      setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  /// Ronde yang ditampilkan: pilihan petugas, atau yang sedang berjalan, berikutnya, lalu yang terakhir lewat.
  PatrolRound? _currentRound(PatrolProvider p, List<PatrolRound> visible, DateTime now) {
    if (_selectedRoundId != null) {
      for (final r in visible) {
        if (r.id == _selectedRoundId) return r;
      }
    }
    final active = p.activeRounds(now);
    if (active.isNotEmpty) return active.first;
    return p.nextRound(now) ?? (visible.isNotEmpty ? visible.last : null);
  }

  Future<void> _startScan({PatrolPoint? expected}) async {
    final hit = await Navigator.push<PatrolScanHit>(
      context,
      MaterialPageRoute(builder: (_) => PatrolScannerScreen(expected: expected)),
    );
    if (hit == null || !mounted) return;
    await _openCheck(hit.point, PatrolCheckMethod.qr, token: hit.token, scannedAt: hit.scannedAt);
  }

  Future<void> _openCheck(PatrolPoint point, PatrolCheckMethod method, {String? token, DateTime? scannedAt}) async {
    final scan = await Navigator.push<PatrolQueuedScan>(
      context,
      MaterialPageRoute(
        builder: (_) => PatrolPointCheckScreen(
          point: point,
          method: method,
          token: token,
          scannedAt: scannedAt ?? DateTime.now(),
        ),
      ),
    );
    if (scan == null || !mounted) return;
    final latest = context.read<PatrolProvider>().scanById(scan.clientScanId) ?? scan;
    _showResult(latest);
  }

  void _showResult(PatrolQueuedScan scan) {
    final (String text, Color color) = switch (scan.status) {
      PatrolScanStatus.accepted => ('${scan.pointCode}: tersimpan dan terkirim.', Colors.green[700]!),
      PatrolScanStatus.flagged => ('${scan.pointCode}: tersimpan, masuk tinjauan SPV.', Colors.orange[800]!),
      PatrolScanStatus.duplicate => ('${scan.pointCode} sudah tercatat di ronde ini.', Colors.blueGrey[700]!),
      PatrolScanStatus.rejected => ('${scan.pointCode} ditolak server: ${scan.message ?? ''}', Colors.red[700]!),
      _ => ('${scan.pointCode}: tersimpan di HP. Terkirim otomatis saat ada sinyal.', Colors.blue[800]!),
    };
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), backgroundColor: color, behavior: SnackBarBehavior.floating),
    );
  }

  void _openPoint(PatrolProvider p, PatrolRound? round, PatrolPoint point) {
    final progress = round == null ? const PatrolPointProgress(PatrolPointState.todo) : p.progressOf(round, point.id);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${point.code} · ${point.name}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              if (point.placeLabel.isNotEmpty) Text(point.placeLabel, style: TextStyle(color: Colors.grey[800])),
              const SizedBox(height: 8),
              _StateLine(progress: progress),
              if (point.instruction != null) ...[
                const SizedBox(height: 12),
                Text(point.instruction!, style: const TextStyle(height: 1.4)),
              ],
              if (point.tasks.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text('Tugas (terbuka setelah stiker discan)', style: TextStyle(color: Colors.grey[800], fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                for (final t in point.tasks)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.lock_outline, size: 16, color: Colors.grey[700]),
                        const SizedBox(width: 8),
                        Expanded(child: Text(t.label)),
                      ],
                    ),
                  ),
              ],
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () {
                  Navigator.pop(ctx);
                  _startScan(expected: point);
                },
                icon: const Icon(Icons.qr_code_scanner),
                label: Text('Scan stiker ${point.code}'),
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () {
                        Navigator.pop(ctx);
                        _openCheck(point, PatrolCheckMethod.manual);
                      },
                      style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                      child: const Text('Tidak bisa scan?'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () {
                        Navigator.pop(ctx);
                        _openCheck(point, PatrolCheckMethod.skip);
                      },
                      style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                      child: const Text('Lewati titik'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<PatrolProvider>(
      builder: (context, p, _) {
        final now = DateTime.now();
        final pack = p.pack!;
        // Ronde shift ini: 12 jam ke belakang dan ke depan
        final visible = p.rounds
            .where((r) => r.windowEnd.isAfter(now.subtract(const Duration(hours: 12))) &&
                r.windowStart.isBefore(now.add(const Duration(hours: 12))))
            .toList();
        final round = _currentRound(p, visible, now);
        return Scaffold(
          appBar: AppBar(
            title: const Text('Patroli'),
            actions: [
              IconButton(
                tooltip: 'Perbarui paket & kirim antrean',
                onPressed: p.loadingPack || p.syncing ? null : () => p.refresh(),
                icon: p.loadingPack || p.syncing
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.sync),
              ),
            ],
          ),
          body: RefreshIndicator(
            onRefresh: p.refresh,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 120),
              children: [
                _SyncBanner(provider: p, pack: pack),
                const SizedBox(height: 12),
                if (round == null)
                  const _NoRoundCard()
                else
                  _RoundCard(provider: p, round: round, now: now),
                if (round != null) ...[
                  const SizedBox(height: 20),
                  Text('Titik di ronde ${_window(round)}', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                  const SizedBox(height: 8),
                  Card(
                    margin: EdgeInsets.zero,
                    child: Column(
                      children: [
                        for (final point in p.pointsOfRound(round))
                          _PointTile(
                            point: point,
                            progress: p.progressOf(round, point.id),
                            optional: !p.isRequiredIn(round, point.id),
                            onTap: () => _openPoint(p, round, point),
                          ),
                      ],
                    ),
                  ),
                ],
                if (visible.length > 1) ...[
                  const SizedBox(height: 20),
                  const Text('Ronde lain di shift ini', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                  const SizedBox(height: 8),
                  for (final r in visible)
                    if (r.id != round?.id)
                      _RoundChip(
                        provider: p,
                        round: r,
                        now: now,
                        onTap: () => setState(() => _selectedRoundId = r.id),
                      ),
                ],
                const SizedBox(height: 20),
                _HistorySection(scans: p.queue),
              ],
            ),
          ),
          floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
          floatingActionButton: SizedBox(
            width: MediaQuery.of(context).size.width - 32,
            height: 56,
            child: FloatingActionButton.extended(
              heroTag: 'patrol-scan',
              onPressed: () => _startScan(),
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Scan QR titik', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            ),
          ),
        );
      },
    );
  }
}

class _SyncBanner extends StatelessWidget {
  final PatrolProvider provider;
  final PatrolPack pack;

  const _SyncBanner({required this.provider, required this.pack});

  @override
  Widget build(BuildContext context) {
    final pending = provider.pendingCount;
    final updated = 'Paket diperbarui ${DateFormat('d MMM HH.mm', 'id_ID').format(pack.fetchedAt)}';
    if (pending == 0) {
      return Row(
        children: [
          Icon(Icons.cloud_done_outlined, size: 18, color: Colors.green[800]),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Semua scan terkirim · $updated${provider.packError != null ? ' (belum bisa diperbarui)' : ''}',
              style: TextStyle(color: Colors.grey[800], fontSize: 13),
            ),
          ),
        ],
      );
    }
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.amber[50],
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.amber[300]!),
      ),
      child: Row(
        children: [
          Icon(Icons.cloud_upload_outlined, color: Colors.brown[700]),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('$pending scan tersimpan di HP, belum terkirim',
                    style: TextStyle(fontWeight: FontWeight.w600, color: Colors.brown[800])),
                Text(
                  provider.syncing
                      ? 'Sedang mengirim...'
                      : provider.syncError != null
                          ? 'Belum ada sinyal ke server. Terkirim otomatis saat sinyal kembali.'
                          : 'Terkirim otomatis saat ada sinyal.',
                  style: TextStyle(color: Colors.grey[900], fontSize: 13),
                ),
              ],
            ),
          ),
          TextButton(onPressed: provider.syncing ? null : provider.syncNow, child: const Text('Kirim')),
        ],
      ),
    );
  }
}

class _NoRoundCard extends StatelessWidget {
  const _NoRoundCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.grey[100],
        borderRadius: BorderRadius.circular(14),
      ),
      child: const Text(
        'Belum ada ronde terjadwal di sekitar jam ini. Scan tetap bisa dilakukan dan tercatat sebagai patroli tambahan.',
        style: TextStyle(height: 1.4),
      ),
    );
  }
}

class _RoundCard extends StatelessWidget {
  final PatrolProvider provider;
  final PatrolRound round;
  final DateTime now;

  const _RoundCard({required this.provider, required this.round, required this.now});

  @override
  Widget build(BuildContext context) {
    final (done, total) = provider.countOf(round);
    final route = provider.pack?.routeById(round.routeId);
    final String timing;
    final Color tone;
    if (now.isBefore(round.windowStart)) {
      timing = 'Mulai ${_hm.format(round.windowStart)} (${_duration(round.windowStart.difference(now))} lagi)';
      tone = Colors.blueGrey[700]!;
    } else if (!now.isAfter(round.windowEnd)) {
      timing = 'Berjalan, sisa ${_duration(round.windowEnd.difference(now))}';
      tone = Colors.blue[800]!;
    } else {
      timing = 'Jendela ronde sudah lewat';
      tone = Colors.grey[800]!;
    }
    final complete = total > 0 && done >= total;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: complete ? Colors.green[50] : Colors.blue[50],
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: complete ? Colors.green[200]! : Colors.blue[100]!),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(route?.name ?? 'Ronde', style: TextStyle(color: Colors.grey[800], fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Text('Ronde ${_window(round)}', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          Text(timing, style: TextStyle(color: tone, fontWeight: FontWeight.w600)),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    value: total == 0 ? 0 : done / total,
                    minHeight: 10,
                    backgroundColor: Colors.white,
                    color: complete ? Colors.green[600] : Colors.blue[700],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Text('$done/$total titik', style: const TextStyle(fontWeight: FontWeight.w700)),
            ],
          ),
          if (complete) ...[
            const SizedBox(height: 8),
            Text('Semua titik wajib sudah dicek.', style: TextStyle(color: Colors.green[800])),
          ],
        ],
      ),
    );
  }
}

String _duration(Duration d) {
  final m = d.inMinutes;
  if (m < 1) return 'kurang dari 1 menit';
  if (m < 60) return '$m menit';
  final h = m ~/ 60;
  final rest = m % 60;
  return rest == 0 ? '$h jam' : '$h jam $rest menit';
}

class _StateLine extends StatelessWidget {
  final PatrolPointProgress progress;

  const _StateLine({required this.progress});

  @override
  Widget build(BuildContext context) {
    final v = _stateVisual(progress);
    return Row(
      children: [
        Icon(v.icon, size: 18, color: v.color),
        const SizedBox(width: 6),
        Expanded(child: Text(v.label, style: TextStyle(color: v.color, fontWeight: FontWeight.w600))),
      ],
    );
  }
}

class _Visual {
  final IconData icon;
  final Color color;
  final String label;

  const _Visual(this.icon, this.color, this.label);
}

_Visual _stateVisual(PatrolPointProgress p) {
  final t = p.scan == null ? '' : ' ${_hm.format(p.scan!.scannedAt)}';
  return switch (p.state) {
    PatrolPointState.done => _Visual(Icons.check_circle, Colors.green[700]!, p.scan == null ? 'Sudah dicek (rekan satu shift)' : 'Sudah dicek$t'),
    PatrolPointState.queued => _Visual(Icons.cloud_upload_outlined, Colors.blue[800]!, 'Tersimpan di HP$t, belum terkirim'),
    PatrolPointState.review => _Visual(Icons.warning_amber_rounded, Colors.orange[800]!, 'Menunggu tinjauan SPV$t'),
    PatrolPointState.skipped => _Visual(Icons.skip_next, Colors.grey[700]!, 'Dilewati$t'),
    PatrolPointState.rejected => _Visual(Icons.block, Colors.red[700]!, 'Ditolak$t: ${p.scan?.message ?? ''}'),
    PatrolPointState.todo => _Visual(Icons.radio_button_unchecked, Colors.grey[600]!, 'Belum dicek'),
  };
}

class _PointTile extends StatelessWidget {
  final PatrolPoint point;
  final PatrolPointProgress progress;
  final bool optional;
  final VoidCallback onTap;

  const _PointTile({required this.point, required this.progress, required this.optional, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final v = _stateVisual(progress);
    final place = point.placeLabel;
    return ListTile(
      onTap: onTap,
      minTileHeight: 64,
      leading: Icon(v.icon, color: v.color, size: 28),
      title: Text('${point.code} · ${point.name}', style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(
        [
          v.label,
          if (place.isNotEmpty) place,
          if (optional) 'opsional',
          if (point.isCritical) 'kritis',
        ].join(' · '),
      ),
      trailing: const Icon(Icons.chevron_right),
    );
  }
}

class _RoundChip extends StatelessWidget {
  final PatrolProvider provider;
  final PatrolRound round;
  final DateTime now;
  final VoidCallback onTap;

  const _RoundChip({required this.provider, required this.round, required this.now, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final (done, total) = provider.countOf(round);
    final route = provider.pack?.routeById(round.routeId);
    final String when = now.isBefore(round.windowStart)
        ? 'belum mulai'
        : now.isAfter(round.windowEnd)
            ? 'sudah lewat'
            : 'berjalan';
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        onTap: onTap,
        title: Text('${_window(round)} · ${route?.name ?? ''}'),
        subtitle: Text('$when · $done/$total titik'),
        trailing: const Icon(Icons.chevron_right),
      ),
    );
  }
}

class _HistorySection extends StatelessWidget {
  final List<PatrolQueuedScan> scans;

  const _HistorySection({required this.scans});

  @override
  Widget build(BuildContext context) {
    final list = [...scans]..sort((a, b) => b.scannedAt.compareTo(a.scannedAt));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Scan saya', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
        const SizedBox(height: 8),
        if (list.isEmpty)
          Text('Belum ada scan di HP ini.', style: TextStyle(color: Colors.grey[800]))
        else
          Card(
            margin: EdgeInsets.zero,
            child: Column(
              children: [
                for (final s in list.take(30))
                  ListTile(
                    dense: true,
                    leading: Icon(_historyIcon(s), color: _historyColor(s)),
                    title: Text('${s.pointCode} · ${_hm.format(s.scannedAt)} ${DateFormat('d MMM', 'id_ID').format(s.scannedAt)}'),
                    subtitle: Text(_historyText(s)),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

IconData _historyIcon(PatrolQueuedScan s) => switch (s.status) {
      PatrolScanStatus.accepted => Icons.check_circle,
      PatrolScanStatus.flagged => Icons.warning_amber_rounded,
      PatrolScanStatus.duplicate => Icons.copy_all_outlined,
      PatrolScanStatus.rejected => Icons.block,
      _ => Icons.cloud_upload_outlined,
    };

Color _historyColor(PatrolQueuedScan s) => switch (s.status) {
      PatrolScanStatus.accepted => Colors.green[700]!,
      PatrolScanStatus.flagged => Colors.orange[800]!,
      PatrolScanStatus.duplicate => Colors.blueGrey[600]!,
      PatrolScanStatus.rejected => Colors.red[700]!,
      _ => Colors.blue[800]!,
    };

String _historyText(PatrolQueuedScan s) {
  final kind = switch (s.method) {
    'manual' => 'Tanpa scan',
    'skip' => 'Dilewati',
    _ => s.condition == 'temuan' ? 'Ada temuan' : 'Aman',
  };
  final status = switch (s.status) {
    PatrolScanStatus.accepted => 'terkirim',
    PatrolScanStatus.flagged => 'ditinjau SPV',
    PatrolScanStatus.duplicate => 'dobel, sudah tercatat',
    PatrolScanStatus.rejected => 'ditolak: ${s.message ?? ''}',
    _ => 'belum terkirim',
  };
  return '$kind · $status';
}
