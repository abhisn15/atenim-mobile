import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/activity_model.dart';
import '../../models/attendance_model.dart';
import '../../providers/activity_provider.dart';
import '../../providers/attendance_provider.dart';
import '../../utils/clock.dart';
import '../../widgets/motion.dart';
import '../../widgets/ui_kit.dart';

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
        .map((r) => workedMinutes(r.checkIn, r.checkOut))
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

  static bool _isToday(DateTime? d) {
    if (d == null) return false;
    final now = DateTime.now();
    return d.year == now.year && d.month == now.month && d.day == now.day;
  }

  static String _cleanSummary(String summary) {
    return summary
        .replaceFirst(RegExp(r'^\[TASK:[^\]]+\]\s*', caseSensitive: false), '')
        .replaceFirst(RegExp(r'^penyelesaian tugas:\s*', caseSensitive: false), '')
        .trim();
  }

  List<_TimelineEvent> _buildEvents(AttendanceProvider attendance, ActivityProvider activities) {
    final events = <_TimelineEvent>[];
    final nowMinutes = DateTime.now().hour * 60 + DateTime.now().minute;

    for (final r in attendance.todayRecords) {
      final inMin = clockMinutes(r.checkIn);
      if (inMin != null) {
        final status = r.status.toLowerCase();
        events.add(_TimelineEvent(
          key: 'in-${r.id}',
          minutes: inMin,
          time: clockLabel(r.checkIn)!,
          title: 'Check-in',
          detail: status == 'present' || status == 'remote'
              ? 'Tepat waktu'
              : attendanceStatusLabel(r.status),
          icon: Icons.login,
          tone: attendanceStatusTone(r.status),
        ));
      }

      var breakStartMin = clockMinutes(r.breakStart);
      var breakEndMin = clockMinutes(r.breakEnd);
      var breakStartLabel = clockLabel(r.breakStart);
      var breakEndLabel = clockLabel(r.breakEnd);
      var breakDuration = r.breakDurationMinutes;
      final session = attendance.breakState?.latestSession;
      if (breakStartMin == null && session != null && session.attendanceId == r.id) {
        final s = DateTime.tryParse(session.startAt)?.toLocal();
        final e = session.endAt == null ? null : DateTime.tryParse(session.endAt!)?.toLocal();
        if (s != null) {
          breakStartMin = s.hour * 60 + s.minute;
          breakStartLabel = clockLabel(s.toIso8601String());
        }
        if (e != null) {
          breakEndMin = e.hour * 60 + e.minute;
          breakEndLabel = clockLabel(e.toIso8601String());
        }
        breakDuration ??= session.durationMinutes;
      }
      if (breakStartMin != null && breakStartLabel != null) {
        events.add(_TimelineEvent(
          key: 'bs-${r.id}',
          minutes: breakStartMin,
          time: breakStartLabel,
          title: 'Mulai istirahat',
          icon: Icons.free_breakfast_outlined,
          tone: Tone.info,
        ));
      }
      if (breakEndMin != null && breakEndLabel != null) {
        events.add(_TimelineEvent(
          key: 'be-${r.id}',
          minutes: breakEndMin,
          time: breakEndLabel,
          title: 'Selesai istirahat',
          detail: breakDuration != null && breakDuration > 0
              ? 'Lama ${formatDuration(breakDuration)}'
              : null,
          icon: Icons.free_breakfast_outlined,
          tone: (r.breakOverByMinutes ?? 0) > 0 ? Tone.warning : Tone.info,
        ));
      }

      final outMin = clockMinutes(r.checkOut);
      if (outMin != null) {
        final worked = workedMinutes(r.checkIn, r.checkOut);
        events.add(_TimelineEvent(
          key: 'out-${r.id}',
          minutes: outMin,
          time: clockLabel(r.checkOut)!,
          title: r.isAutoCheckout ? 'Check-out otomatis' : 'Check-out',
          detail: worked != null ? 'Lama kerja ${formatDuration(worked)}' : null,
          icon: Icons.logout,
          tone: Tone.success,
        ));
      } else if (inMin != null) {
        var running = nowMinutes - inMin;
        if (running < 0) running += 24 * 60;
        events.add(_TimelineEvent(
          key: 'now-${r.id}',
          minutes: 24 * 60, // selalu paling akhir
          time: 'Sekarang',
          title: 'Sedang bekerja',
          detail: 'Sudah ${formatDuration(running)}',
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
      if (!_isToday(created)) continue;
      final minutes = created!.hour * 60 + created.minute;
      final label = clockLabel(created.toIso8601String())!;
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
        minutes: minutes,
        time: label,
        title: title,
        detail: (detail ?? '').isEmpty ? null : detail,
        icon: icon,
        tone: Tone.info,
        pending: a.isLocal,
      ));
    }

    events.sort((a, b) => a.minutes.compareTo(b.minutes));
    return events;
  }

  @override
  Widget build(BuildContext context) {
    return Consumer2<AttendanceProvider, ActivityProvider>(
      builder: (context, attendance, activities, _) {
        final events = _buildEvents(attendance, activities);
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
                      'Kegiatan hari ini',
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
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 68,
            child: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
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
  }
}
