import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/activity_model.dart';
import '../../models/attendance_model.dart';
import '../../models/patrol_models.dart';
import '../../providers/activity_provider.dart';
import '../../providers/attendance_provider.dart';
import '../../providers/patrol_provider.dart';
import '../../utils/clock.dart';
import '../../widgets/motion.dart';
import '../../widgets/ui_kit.dart';
import '../patroli/patrol_scan_detail_screen.dart';

/// KPI kehadiran bulan ini dari catatan absen yang dimuat: persentase tepat waktu, rata-rata lama kerja,
/// dan jumlah hari tercatat, plus bilah komposisi. Semua angka dihitung dari catatan nyata; bila belum ada
/// bahan hitung, bagian itu ditulis "-" dan bukan angka perkiraan.
class AttendanceKpiRow extends StatelessWidget {
  const AttendanceKpiRow({super.key, required this.records});

  final List<AttendanceRecord> records;

  List<AttendanceRecord> get _thisMonth {
    final now = DateTime.now();
    return records.where((r) {
      final d = DateTime.tryParse(r.date);
      return d != null && d.year == now.year && d.month == now.month;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final month = _thisMonth;
    if (month.isEmpty) return const SizedBox.shrink();

    int count(bool Function(String s) test) =>
        month.where((r) => test(r.status.toLowerCase())).length;

    final present = count((s) => s == 'present' || s == 'remote');
    final late = count((s) => s == 'late');
    final absent = count((s) => s == 'absent');
    final other = month.length - present - late - absent;

    final attended = present + late;
    final onTimeRate = attended == 0 ? null : (present / attended * 100).round();

    final worked = month
        .where((r) => r.checkOut != null || r.checkOutAt != null)
        .map((r) => r.workDurationMinutes())
        .whereType<int>()
        .toList();
    final avgWorked = worked.isEmpty
        ? null
        : (worked.reduce((a, b) => a + b) / worked.length).round();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 14),
        // Komposisi hari tercatat. Warna hanya menandai status, urutannya sama dengan hitungan di atas.
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: SizedBox(
            height: 8,
            child: Row(
              children: [
                if (present > 0)
                  Expanded(flex: present, child: ColoredBox(color: toneColors(Tone.success).fg)),
                if (late > 0)
                  Expanded(flex: late, child: ColoredBox(color: toneColors(Tone.warning).fg)),
                if (absent > 0)
                  Expanded(flex: absent, child: ColoredBox(color: toneColors(Tone.danger).fg)),
                if (other > 0) Expanded(flex: other, child: ColoredBox(color: Colors.grey[400]!)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        Divider(height: 1, color: AtenimUi.line),
        const SizedBox(height: 12),
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _KpiCell(
                label: 'Tepat waktu',
                value: onTimeRate == null ? '-' : '$onTimeRate%',
                hint: attended == 0 ? 'Belum ada hari hadir' : '$present dari $attended hari hadir',
              ),
              _KpiCell(
                label: 'Rata-rata kerja',
                value: avgWorked == null ? '-' : formatDuration(avgWorked),
                hint: worked.isEmpty ? 'Belum ada hari lengkap' : 'Dari ${worked.length} hari lengkap',
              ),
              _KpiCell(
                label: 'Hari tercatat',
                value: '${month.length}',
                hint: 'Bulan ini',
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _KpiCell extends StatelessWidget {
  const _KpiCell({required this.label, required this.value, required this.hint});

  final String label;
  final String value;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(fontSize: 12, color: AtenimUi.inkSoft)),
          const SizedBox(height: 2),
          Text(
            value,
            maxLines: 2,
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w800,
              height: 1.2,
              color: AtenimUi.ink,
            ),
          ),
          const SizedBox(height: 2),
          Text(hint, style: TextStyle(fontSize: 11.5, color: AtenimUi.inkSoft, height: 1.25)),
        ],
      ),
    );
  }
}

/// Warna baris timeline untuk satu scan patroli, menurut hasil penilaiannya.
Tone patrolTimelineTone(String kind) => switch (kind) {
      'auto_accepted' || 'accepted_by_spv' => Tone.success,
      'pending_review' => Tone.warning,
      'rejected_by_spv' || 'rejected_server' => Tone.danger,
      'unsent' => Tone.info,
      _ => Tone.neutral,
    };

/// Keterangan satu baris untuk scan patroli: jenis, hasil penilaian, dan jumlah tugas yang dikerjakan.
String patrolTimelineDetail(PatrolHistoryItem s) {
  final done = s.tasks.where((t) => t.done).length;
  return [
    if (s.method == 'manual')
      'Tanpa scan QR'
    else if (s.method == 'skip')
      'Dilewati'
    else if (s.condition == 'temuan')
      'Ada temuan',
    s.outcome.title,
    if (s.tasks.isNotEmpty) '$done dari ${s.tasks.length} tugas',
  ].join(' · ');
}

/// Awal jendela timeline. Biasanya tengah malam hari ini; bila ada absen yang masih terbuka sejak kemarin
/// (shift malam, check-in 22.00 dan belum pulang), jendela dimulai dari check-in itu supaya kegiatan sebelum
/// tengah malam tidak hilang dan urutannya benar. Check-in yang lebih tua dari 36 jam (lupa check-out) atau
/// yang ada di masa depan (jam HP salah) diabaikan.
DateTime timelineWindowStart(DateTime now, Iterable<DateTime?> checkIns) {
  var start = DateTime(now.year, now.month, now.day);
  final oldest = now.subtract(const Duration(hours: 36));
  for (final c in checkIns) {
    if (c == null || c.isAfter(now) || c.isBefore(oldest)) continue;
    if (c.isBefore(start)) start = c;
  }
  return start;
}

/// Waktu untuk jam [minutesOfDay] yang terjadi pada atau setelah [anchor], paling lama sehari kemudian.
/// Dipakai untuk jam "HH:mm" dari server: istirahat 01.00 dan check-out 06.00 pada shift yang mulai 22.00
/// jatuh pada hari berikutnya.
DateTime clockOnOrAfter(DateTime anchor, int minutesOfDay) {
  final sameDay = DateTime(anchor.year, anchor.month, anchor.day, minutesOfDay ~/ 60, minutesOfDay % 60);
  if (!sameDay.isBefore(anchor)) return sameDay;
  return DateTime(anchor.year, anchor.month, anchor.day + 1, minutesOfDay ~/ 60, minutesOfDay % 60);
}

class _TimelineEvent {
  const _TimelineEvent({
    required this.key,
    required this.minutes,
    required this.time,
    required this.title,
    required this.icon,
    this.detail,
    this.tone = Tone.neutral,
    this.pending = false,
    this.current = false,
    this.onTap,
    this.dayLabel,
  });

  final String key;
  final int minutes;
  final String time;
  final String title;
  final String? detail;
  final IconData icon;
  final Tone tone;
  final bool pending;
  final bool current;
  final VoidCallback? onTap;

  /// Keterangan hari bila kejadian bukan hari ini (mis. "Kemarin" pada shift malam).
  final String? dayLabel;
}

/// Timeline kegiatan hari ini: check-in, istirahat, aktivitas/patroli yang dicatat, check-out, dan
/// "sedang bekerja" bila belum pulang. Hanya kejadian nyata dari data perangkat dan server.
class TodayTimelineCard extends StatefulWidget {
  const TodayTimelineCard({super.key, this.onSeeActivities});

  final VoidCallback? onSeeActivities;

  @override
  State<TodayTimelineCard> createState() => _TodayTimelineCardState();
}

class _TodayTimelineCardState extends State<TodayTimelineCard> {
  @override
  void initState() {
    super.initState();
    // Aktivitas hari ini baru dimuat bila belum ada datanya (Home tidak memuatnya sendiri).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final p = Provider.of<ActivityProvider>(context, listen: false);
      if (!p.isLoading && p.todayActivity == null && p.recentActivities.isEmpty) {
        p.loadActivities();
      }
    });
  }

  static String _cleanSummary(String summary) {
    return summary
        .replaceFirst(RegExp(r'^\[TASK:[^\]]+\]\s*', caseSensitive: false), '')
        .replaceFirst(RegExp(r'^penyelesaian tugas:\s*', caseSensitive: false), '')
        .trim();
  }

  static String _hm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  /// Waktu check-in yang sebenarnya: stempel waktu dari server bila ada, kalau tidak jam "HH:mm" pada
  /// tanggal check-in (absen yang dibawa dari kemarin membawa tanggal aslinya di originalCheckInDate).
  static DateTime? _checkInInstant(AttendanceRecord r, DateTime today0) {
    final exact = r.checkInAt?.toLocal();
    if (exact != null) return exact;
    final minutes = clockMinutes(r.checkIn);
    if (minutes == null) return null;
    final origin = r.originalCheckInDate == null ? null : DateTime.tryParse(r.originalCheckInDate!);
    final base = origin == null ? today0 : DateTime(origin.year, origin.month, origin.day);
    return DateTime(base.year, base.month, base.day, minutes ~/ 60, minutes % 60);
  }

  static DateTime _windowStart(AttendanceProvider attendance, DateTime now) {
    final today0 = DateTime(now.year, now.month, now.day);
    return timelineWindowStart(now, [for (final r in attendance.todayRecords) _checkInInstant(r, today0)]);
  }

  List<_TimelineEvent> _buildEvents(
    BuildContext context,
    AttendanceProvider attendance,
    ActivityProvider activities,
    List<PatrolHistoryItem> patrolScans,
  ) {
    final events = <_TimelineEvent>[];
    final now = DateTime.now();
    final today0 = DateTime(now.year, now.month, now.day);
    final windowStart = _windowStart(attendance, now);
    // Urutan memakai menit sejak awal jendela (bukan menit dalam sehari), supaya kejadian setelah tengah malam
    // pada shift malam tidak tampil sebelum check-in 22.00-nya.
    int since(DateTime t) => t.difference(windowStart).inMinutes;
    String? dayOf(DateTime t) => t.isBefore(today0) ? 'Kemarin' : null;
    bool inWindow(DateTime t) => !t.isBefore(windowStart) && !t.isAfter(now.add(const Duration(minutes: 5)));

    for (final r in attendance.todayRecords) {
      final checkInAt = _checkInInstant(r, today0);
      if (checkInAt != null) {
        final status = r.status.toLowerCase();
        events.add(_TimelineEvent(
          key: 'in-${r.id}',
          minutes: since(checkInAt),
          time: _hm(checkInAt),
          dayLabel: dayOf(checkInAt),
          title: 'Check-in',
          detail: status == 'present' || status == 'remote'
              ? 'Tepat waktu'
              : attendanceStatusLabel(r.status),
          icon: Icons.login,
          tone: attendanceStatusTone(r.status),
        ));
      }

      DateTime? breakStartAt;
      DateTime? breakEndAt;
      final breakStartMin = clockMinutes(r.breakStart);
      final breakEndMin = clockMinutes(r.breakEnd);
      var breakDuration = r.breakDurationMinutes;
      final session = attendance.breakState?.latestSession;
      if (breakStartMin == null && session != null && session.attendanceId == r.id) {
        breakStartAt = DateTime.tryParse(session.startAt)?.toLocal();
        breakEndAt = session.endAt == null ? null : DateTime.tryParse(session.endAt!)?.toLocal();
        breakDuration ??= session.durationMinutes;
      } else {
        final anchor = checkInAt ?? today0;
        if (breakStartMin != null) breakStartAt = clockOnOrAfter(anchor, breakStartMin);
        if (breakEndMin != null) breakEndAt = clockOnOrAfter(breakStartAt ?? anchor, breakEndMin);
      }
      if (breakStartAt != null) {
        events.add(_TimelineEvent(
          key: 'bs-${r.id}',
          minutes: since(breakStartAt),
          time: _hm(breakStartAt),
          dayLabel: dayOf(breakStartAt),
          title: 'Mulai istirahat',
          icon: Icons.free_breakfast_outlined,
          tone: Tone.info,
        ));
      }
      if (breakEndAt != null) {
        events.add(_TimelineEvent(
          key: 'be-${r.id}',
          minutes: since(breakEndAt),
          time: _hm(breakEndAt),
          dayLabel: dayOf(breakEndAt),
          title: 'Selesai istirahat',
          detail: breakDuration != null && breakDuration > 0
              ? 'Lama ${formatDuration(breakDuration)}'
              : null,
          icon: Icons.free_breakfast_outlined,
          tone: (r.breakOverByMinutes ?? 0) > 0 ? Tone.warning : Tone.info,
        ));
      }

      final checkOutMin = clockMinutes(r.checkOut);
      if (checkOutMin != null) {
        final checkOutAt = r.checkOutAt?.toLocal() ?? clockOnOrAfter(checkInAt ?? today0, checkOutMin);
        final worked = r.workDurationMinutes();
        events.add(_TimelineEvent(
          key: 'out-${r.id}',
          minutes: since(checkOutAt),
          time: _hm(checkOutAt),
          dayLabel: dayOf(checkOutAt),
          title: r.isAutoCheckout ? 'Check-out otomatis' : 'Check-out',
          detail: worked != null ? 'Lama kerja ${formatDuration(worked)}' : null,
          icon: Icons.logout,
          tone: Tone.success,
        ));
      } else if (checkInAt != null) {
        final running = now.difference(checkInAt).inMinutes;
        events.add(_TimelineEvent(
          key: 'now-${r.id}',
          minutes: 1 << 20, // selalu paling akhir
          time: 'Sekarang',
          title: 'Sedang bekerja',
          detail: 'Sudah ${formatDuration(running < 0 ? 0 : running)}',
          icon: Icons.work_outline,
          current: true,
        ));
      }
    }

    final seen = <String>{};
    final all = <DailyActivity>[
      if (activities.todayActivity != null) activities.todayActivity!,
      ...activities.recentActivities,
    ];
    for (final a in all) {
      if (!seen.add(a.id)) continue;
      final created = DateTime.tryParse(a.createdAt)?.toLocal();
      if (created == null || !inWindow(created)) continue;
      final checkpoints = a.checkpoints;
      String title;
      String? detail;
      IconData icon;
      if (a.isPatroli) {
        title = 'Patroli';
        detail = (a.locationName ?? '').isNotEmpty ? a.locationName : _cleanSummary(a.summary);
        icon = Icons.shield_outlined;
      } else if (checkpoints != null && checkpoints.isNotEmpty) {
        final done = checkpoints.where((c) => c.completed).length;
        title = 'Checkpoint';
        detail = '$done dari ${checkpoints.length} selesai';
        icon = Icons.checklist_rtl;
      } else {
        title = 'Aktivitas';
        detail = _cleanSummary(a.summary);
        icon = Icons.assignment_outlined;
      }
      events.add(_TimelineEvent(
        key: 'act-${a.id}',
        minutes: since(created),
        time: _hm(created),
        dayLabel: dayOf(created),
        title: title,
        detail: (detail ?? '').isEmpty ? null : detail,
        icon: icon,
        tone: Tone.info,
        pending: a.isLocal,
      ));
    }

    // Scan Patroli QR: langsung tampil begitu discan (juga yang masih menunggu sinyal), karena scan tidak
    // membuat catatan aktivitas harian sehingga tidak muncul lewat daftar aktivitas di atas.
    for (final s in patrolScans) {
      if (!inWindow(s.scannedAt)) continue;
      events.add(_TimelineEvent(
        key: 'pq-${s.clientScanId}',
        minutes: since(s.scannedAt),
        time: _hm(s.scannedAt),
        dayLabel: dayOf(s.scannedAt),
        title: 'Patroli ${s.pointCode}',
        detail: patrolTimelineDetail(s),
        icon: Icons.qr_code_scanner,
        tone: patrolTimelineTone(s.outcome.kind),
        pending: s.outcome.kind == 'unsent',
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => PatrolScanDetailScreen(item: s)),
        ),
      ));
    }

    events.sort((a, b) => a.minutes.compareTo(b.minutes));
    return events;
  }

  @override
  Widget build(BuildContext context) {
    return Consumer3<AttendanceProvider, ActivityProvider, PatrolProvider>(
      builder: (context, attendance, activities, patrol, _) {
        final events = _buildEvents(context, attendance, activities, patrol.history);
        final nowForTitle = DateTime.now();
        final overnight = _windowStart(attendance, nowForTitle).isBefore(DateTime(nowForTitle.year, nowForTitle.month, nowForTitle.day));
        final loadingFirst = attendance.isLoading &&
            attendance.todayRecords.isEmpty &&
            attendance.recentAttendance.isEmpty;

        return AtenimCard(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      overnight ? 'Kegiatan shift ini' : 'Kegiatan hari ini',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: AtenimUi.ink,
                      ),
                    ),
                  ),
                  if (widget.onSeeActivities != null)
                    TextButton(
                      onPressed: widget.onSeeActivities,
                      style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                      child: const Text('Lihat aktivitas'),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              if (loadingFirst)
                const Column(
                  children: [
                    SkeletonBox(height: 44),
                    SizedBox(height: 10),
                    SkeletonBox(height: 44),
                  ],
                )
              else if (events.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    'Belum ada kegiatan hari ini. Lakukan check-in untuk memulai hari kerja. Aktivitas dan patroli yang Anda catat juga akan tampil di sini.',
                    style: TextStyle(fontSize: 14, color: AtenimUi.inkSoft, height: 1.45),
                  ),
                )
              else
                for (var i = 0; i < events.length; i++)
                  FadeSlideIn(
                    key: ValueKey('tl-${events[i].key}'),
                    delay: Motion.stagger(i),
                    dy: 8,
                    child: _TimelineRow(event: events[i], isLast: i == events.length - 1),
                  ),
            ],
          ),
        );
      },
    );
  }
}

class _TimelineRow extends StatelessWidget {
  const _TimelineRow({required this.event, required this.isLast});

  final _TimelineEvent event;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final colors = toneColors(event.tone);
    final row = IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 68,
            child: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    event.time,
                    maxLines: 1,
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: event.current ? AtenimUi.brand : AtenimUi.inkSoft,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  if (event.dayLabel != null)
                    Text(
                      event.dayLabel!,
                      maxLines: 1,
                      style: TextStyle(fontSize: 11, color: AtenimUi.inkSoft),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 28,
            child: Column(
              children: [
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: event.current ? AtenimUi.brand : colors.bg,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    event.icon,
                    size: 15,
                    color: event.current ? Colors.white : colors.fg,
                  ),
                ),
                if (!isLast)
                  Expanded(
                    child: Container(width: 2, color: AtenimUi.line),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: isLast ? 4 : 16, top: 3),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    event.title,
                    style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w700,
                      color: AtenimUi.ink,
                    ),
                  ),
                  if (event.detail != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Text(
                        event.detail!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13, color: AtenimUi.inkSoft, height: 1.3),
                      ),
                    ),
                  if (event.pending)
                    const Padding(
                      padding: EdgeInsets.only(top: 6),
                      child: StatusPill(
                        label: 'Menunggu koneksi',
                        tone: Tone.warning,
                        icon: Icons.schedule,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
    if (event.onTap == null) return row;
    return Semantics(
      button: true,
      hint: 'Buka rincian',
      child: InkWell(onTap: event.onTap, borderRadius: BorderRadius.circular(8), child: row),
    );
  }
}
