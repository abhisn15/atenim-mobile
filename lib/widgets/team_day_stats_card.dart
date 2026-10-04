import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../utils/team_day_stats.dart';
import 'shimmer_loading.dart';
import 'ui_kit.dart';

/// Kartu "Hari ini" di halaman Team untuk karyawan yang menjadi team leader: berapa anggota yang belum check-in,
/// sedang bekerja, sudah check-out, dan terlambat, ditambah jalan pintas ke daftar yang perlu dihubungi.
class TeamDayStatsCard extends StatelessWidget {
  const TeamDayStatsCard({
    super.key,
    required this.stats,
    required this.loading,
    required this.error,
    required this.updatedAt,
    required this.onShowAttention,
  });

  final TeamDayStats? stats;
  final bool loading;
  final String? error;
  final DateTime? updatedAt;
  final VoidCallback onShowAttention;

  @override
  Widget build(BuildContext context) {
    final s = stats;
    final updated = updatedAt == null ? null : DateFormat('HH.mm', 'id_ID').format(updatedAt!);
    final needAttention = s == null ? 0 : s.notCheckedIn + s.late;
    return AtenimCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Hari ini',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AtenimUi.ink),
                ),
              ),
              if (updated != null) Text('Per $updated', style: TextStyle(fontSize: 12, color: AtenimUi.inkSoft)),
            ],
          ),
          const SizedBox(height: 10),
          if (s == null && loading)
            ShimmerLoading(width: double.infinity, height: 64, borderRadius: BorderRadius.circular(10))
          else if (s == null)
            Text(
              error ?? 'Statistik hari ini belum tersedia.',
              style: TextStyle(fontSize: 13, color: AtenimUi.inkSoft),
            )
          else if (s.isEmpty)
            Text(
              'Belum ada anggota yang dijadwalkan atau check-in hari ini.',
              style: TextStyle(fontSize: 13, color: AtenimUi.inkSoft),
            )
          else ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: _Tile('Belum check-in', s.notCheckedIn, s.notCheckedIn > 0 ? Tone.warning : Tone.neutral)),
                const SizedBox(width: 8),
                Expanded(child: _Tile('Sedang bekerja', s.working, Tone.info)),
                const SizedBox(width: 8),
                Expanded(child: _Tile('Sudah check-out', s.checkedOut, Tone.success)),
                const SizedBox(width: 8),
                Expanded(child: _Tile('Terlambat', s.late, s.late > 0 ? Tone.warning : Tone.neutral)),
              ],
            ),
            if (s.notStarted > 0) ...[
              const SizedBox(height: 8),
              Text(
                '${s.notStarted} anggota shift-nya belum mulai.',
                style: TextStyle(fontSize: 12, color: AtenimUi.inkSoft),
              ),
            ],
            if (needAttention > 0) ...[
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: onShowAttention,
                icon: const Icon(Icons.chat_outlined),
                label: Text('Lihat $needAttention anggota yang perlu dihubungi'),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile(this.label, this.value, this.tone);

  final String label;
  final int value;
  final Tone tone;

  @override
  Widget build(BuildContext context) {
    final colors = toneColors(tone);
    return Semantics(
      label: '$label: $value',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
        decoration: BoxDecoration(color: colors.bg, borderRadius: BorderRadius.circular(AtenimUi.radiusControl)),
        child: Column(
          children: [
            Text(
              '$value',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, height: 1.1, color: colors.fg),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              maxLines: 2,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, height: 1.2, color: colors.fg),
            ),
          ],
        ),
      ),
    );
  }
}
