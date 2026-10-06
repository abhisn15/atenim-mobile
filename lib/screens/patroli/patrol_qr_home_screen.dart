import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../models/patrol_models.dart';
import '../../providers/patrol_provider.dart';
import '../../utils/checkin_gate.dart';
import '../../utils/home_tab_request.dart';
import 'patrol_point_check_screen.dart';
import 'patrol_scan_detail_screen.dart';
import 'patrol_scanner_screen.dart';
import '../../widgets/ui_kit.dart';

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

  /// Patroli hanya dihitung saat petugas sedang check-in, jadi ditahan di depan dengan penjelasan yang jelas.
  bool _ensureCheckedIn() => ensureCheckedIn(
        context,
        CheckInPurpose.patrol,
        onGoHome: () {
          // Tutup layar yang di-push di atas beranda (mis. scanner), lalu pindah ke tab Home.
          Navigator.of(context).popUntil((route) => route.isFirst);
          HomeTabRequest.goHome();
        },
      );

  Future<void> _startScan({PatrolPoint? expected}) async {
    if (!_ensureCheckedIn()) return;
    final hit = await Navigator.push<PatrolScanHit>(
      context,
      MaterialPageRoute(builder: (_) => PatrolScannerScreen(expected: expected)),
    );
    if (hit == null || !mounted) return;
    await _openCheck(hit.point, PatrolCheckMethod.qr, token: hit.token, scannedAt: hit.scannedAt);
  }

  Future<void> _openCheck(PatrolPoint point, PatrolCheckMethod method, {String? token, DateTime? scannedAt}) async {
    if (!_ensureCheckedIn()) return;
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
                  const SizedBox(height: 16),
                  SectionHeader(title: 'Titik di ronde ${_window(round)}'),
                  AtenimCard(
                    padding: EdgeInsets.zero,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(AtenimUi.radiusCard),
                      child: Column(
                        children: [
                          for (final (i, point) in p.pointsOfRound(round).indexed) ...[
                            if (i > 0) Divider(height: 1, indent: 68, color: AtenimUi.line),
                            _PointTile(
                              point: point,
                              progress: p.progressOf(round, point.id),
                              optional: !p.isRequiredIn(round, point.id),
                              onTap: () => _openPoint(p, round, point),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
                if (visible.length > 1) ...[
                  const SizedBox(height: 16),
                  const SectionHeader(title: 'Ronde lain di shift ini'),
                  for (final r in visible)
                    if (r.id != round?.id)
                      _RoundChip(
                        provider: p,
                        round: r,
                        now: now,
                        onTap: () => setState(() => _selectedRoundId = r.id),
                      ),
                ],
                const SizedBox(height: 16),
                _HistorySection(items: p.history, error: p.historyError),
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
          const StatusPill(label: 'Semua scan terkirim', tone: Tone.success, icon: Icons.cloud_done_outlined),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '$updated${provider.packError != null ? ' (belum bisa diperbarui)' : ''}',
              style: TextStyle(color: AtenimUi.inkSoft, fontSize: 12),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      );
    }
    final warn = toneColors(Tone.warning);
    return AtenimCard(
      color: warn.bg,
      borderColor: warn.fg.withValues(alpha: 0.25),
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      child: Row(
        children: [
          Icon(Icons.cloud_upload_outlined, color: warn.fg),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${provider.pendingCount} scan tersimpan di HP, belum terkirim',
                    style: TextStyle(fontWeight: FontWeight.w700, color: warn.fg)),
                const SizedBox(height: 2),
                Text(
                  provider.syncing
                      ? 'Sedang mengirim...'
                      : provider.syncError != null
                          ? 'Belum ada sinyal ke server. Terkirim otomatis saat sinyal kembali.'
                          : 'Terkirim otomatis saat ada sinyal.',
                  style: TextStyle(color: AtenimUi.inkSoft, fontSize: 13, height: 1.3),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: provider.syncing ? null : provider.syncNow,
            style: TextButton.styleFrom(minimumSize: const Size(56, 48)),
            child: const Text('Kirim'),
          ),
        ],
      ),
    );
  }
}

class _NoRoundCard extends StatelessWidget {
  const _NoRoundCard();

  @override
  Widget build(BuildContext context) {
    return const AtenimCard(
      padding: EdgeInsets.zero,
      child: EmptyState(
        compact: true,
        icon: Icons.event_available_outlined,
        title: 'Belum ada ronde saat ini',
        message:
            'Tidak ada ronde terjadwal di sekitar jam ini. Anda tetap bisa scan titik; hasilnya tercatat sebagai patroli tambahan.',
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
    final Tone tone;
    if (now.isBefore(round.windowStart)) {
      timing = 'Mulai ${_hm.format(round.windowStart)} · ${_duration(round.windowStart.difference(now))} lagi';
      tone = Tone.neutral;
    } else if (!now.isAfter(round.windowEnd)) {
      timing = 'Berjalan · sisa ${_duration(round.windowEnd.difference(now))}';
      tone = Tone.info;
    } else {
      timing = 'Jendela ronde sudah lewat';
      tone = Tone.neutral;
    }
    final complete = total > 0 && done >= total;
    const ring = 76.0;
    final accent = complete ? Colors.green[600]! : AtenimUi.brand;
    return AtenimCard(
      color: complete ? Colors.green[50] : Colors.white,
      borderColor: complete ? Colors.green[200] : null,
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          SizedBox(
            width: ring,
            height: ring,
            child: Stack(
              alignment: Alignment.center,
              children: [
                SizedBox.expand(
                  child: CircularProgressIndicator(
                    value: total == 0 ? 0 : done / total,
                    strokeWidth: 7,
                    strokeCap: StrokeCap.round,
                    backgroundColor: complete ? Colors.white : AtenimUi.brandSoft,
                    color: accent,
                  ),
                ),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('$done/$total',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: AtenimUi.ink)),
                    Text('titik', style: TextStyle(fontSize: 11, color: AtenimUi.inkSoft)),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  route?.name ?? 'Ronde',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: AtenimUi.inkSoft, fontWeight: FontWeight.w600, fontSize: 13),
                ),
                const SizedBox(height: 2),
                Text('Ronde ${_window(round)}',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: AtenimUi.ink)),
                const SizedBox(height: 8),
                if (complete)
                  const StatusPill(label: 'Semua titik wajib sudah dicek', tone: Tone.success, icon: Icons.check_circle_outline)
                else
                  StatusPill(label: timing, tone: tone, icon: Icons.schedule),
              ],
            ),
          ),
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
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 64),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(color: v.color.withValues(alpha: 0.12), shape: BoxShape.circle),
                child: Icon(v.icon, color: v.color, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${point.code} · ${point.name}',
                        style: TextStyle(fontWeight: FontWeight.w700, color: AtenimUi.ink)),
                    const SizedBox(height: 2),
                    Text(v.label, style: TextStyle(color: v.color, fontSize: 13, fontWeight: FontWeight.w600)),
                    if (place.isNotEmpty)
                      Text(place, style: TextStyle(color: AtenimUi.inkSoft, fontSize: 12)),
                    if (optional || point.isCritical) ...[
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          if (point.isCritical) const StatusPill(label: 'Kritis', tone: Tone.danger),
                          if (optional) const StatusPill(label: 'Opsional', tone: Tone.neutral),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: Colors.grey[500]),
            ],
          ),
        ),
      ),
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
    final running = !now.isBefore(round.windowStart) && !now.isAfter(round.windowEnd);
    final String when = now.isBefore(round.windowStart)
        ? 'Belum mulai'
        : now.isAfter(round.windowEnd)
            ? 'Sudah lewat'
            : 'Berjalan';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: AtenimCard(
        onTap: onTap,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${_window(round)} · ${route?.name ?? ''}',
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w700, color: AtenimUi.ink)),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      StatusPill(label: when, tone: running ? Tone.info : Tone.neutral),
                      const SizedBox(width: 8),
                      Text('$done/$total titik', style: TextStyle(color: AtenimUi.inkSoft, fontSize: 13)),
                    ],
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: Colors.grey[500]),
          ],
        ),
      ),
    );
  }
}

class _HistorySection extends StatelessWidget {
  final List<PatrolHistoryItem> items;
  final String? error;

  const _HistorySection({required this.items, this.error});

  @override
  Widget build(BuildContext context) {
    final onlyOnPhone = items.every((i) => !i.fromServer);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(title: 'Riwayat scan saya'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            'Ketuk satu scan untuk melihat foto, hasil penilaian, dan alasannya.',
            style: TextStyle(fontSize: 12, color: AtenimUi.inkSoft),
          ),
        ),
        if (error != null && onlyOnPhone) ...[
          const SizedBox(height: 6),
          Text(
            'Riwayat lengkap dari server belum bisa dimuat. Yang tampil hanya scan yang tersimpan di HP ini.',
            style: TextStyle(fontSize: 12, color: Colors.orange[900]),
          ),
        ],
        const SizedBox(height: 8),
        if (items.isEmpty)
          const AtenimCard(
            padding: EdgeInsets.zero,
            child: EmptyState(
              compact: true,
              icon: Icons.qr_code_scanner,
              title: 'Belum ada scan',
              message: 'Scan stiker titik patroli yang pertama. Riwayat dan hasil penilaiannya muncul di sini.',
            ),
          )
        else
          Card(
            margin: EdgeInsets.zero,
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (final item in items.take(30))
                  ListTile(
                    dense: true,
                    leading: Icon(patrolOutcomeIcon(item.outcome.kind), color: patrolOutcomeColor(item.outcome.kind)),
                    title: Text('${item.pointCode} · ${_hm.format(item.scannedAt)} ${DateFormat('d MMM', 'id_ID').format(item.scannedAt)}'),
                    subtitle: Text(_historySubtitle(item), maxLines: 3, overflow: TextOverflow.ellipsis),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (item.photoCount > 0) ...[
                          Icon(Icons.photo_outlined, size: 16, color: Colors.grey[700]),
                          const SizedBox(width: 2),
                          Text('${item.photoCount}', style: TextStyle(fontSize: 12, color: Colors.grey[700])),
                        ],
                        const Icon(Icons.chevron_right),
                      ],
                    ),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => PatrolScanDetailScreen(item: item)),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

String _historySubtitle(PatrolHistoryItem item) {
  final kind = switch (item.method) {
    'manual' => 'Tanpa scan',
    'skip' => 'Dilewati',
    _ => item.condition == 'temuan' ? 'Ada temuan' : 'Aman',
  };
  final why = _historyWhy(item);
  return '$kind · ${item.outcome.title}${why == null ? '' : '\n$why'}';
}

/// Satu baris alasan di daftar; rincian lengkapnya ada di layar detail.
String? _historyWhy(PatrolHistoryItem item) {
  final o = item.outcome;
  switch (o.kind) {
    case 'pending_review':
      return o.reasons.isEmpty ? null : 'Ditandai karena: ${o.reasons.first}';
    case 'accepted_by_spv':
    case 'rejected_by_spv':
      final note = (item.reviewNote ?? '').trim();
      if (note.isNotEmpty) return 'Catatan SPV: $note';
      return o.reasons.isEmpty ? null : 'Ditandai karena: ${o.reasons.first}';
    case 'extra':
      return 'Tidak dihitung ke ronde';
    default:
      return null;
  }
}
