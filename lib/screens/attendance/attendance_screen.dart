import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../providers/attendance_provider.dart';
import '../../models/attendance_model.dart';
import '../../utils/clock.dart';
import '../../widgets/motion.dart';
import '../../widgets/ui_kit.dart';

class AttendanceScreen extends StatefulWidget {
  const AttendanceScreen({super.key});

  @override
  State<AttendanceScreen> createState() => _AttendanceScreenState();
}

class _AttendanceScreenState extends State<AttendanceScreen> {
  // Default: bulan ini (tanggal 1 sampai hari ini)
  late DateTime _startDate = _getDefaultStartDate();
  late DateTime _endDate = _getDefaultEndDate();

  static DateTime _getDefaultStartDate() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, 1);
  }

  static DateTime _getDefaultEndDate() {
    return DateTime.now();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _reload();
    });
  }

  Future<void> _reload() {
    return Provider.of<AttendanceProvider>(context, listen: false)
        .loadAttendance(startDate: _startDate, endDate: _endDate);
  }

  void _setRange(DateTime start, DateTime end) {
    if (start == _startDate && end == _endDate) return;
    setState(() {
      _startDate = start;
      _endDate = end;
    });
    _reload();
  }

  Future<void> _selectDateRange() async {
    final DateTimeRange? picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
      initialDateRange: DateTimeRange(start: _startDate, end: _endDate),
      locale: const Locale('id', 'ID'),
      helpText: 'Pilih Rentang Tanggal',
      cancelText: 'Batal',
      confirmText: 'Pilih',
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: ColorScheme.light(
              primary: AtenimUi.brand,
              onPrimary: Colors.white,
              surface: Colors.white,
              onSurface: Colors.black87,
            ),
          ),
          child: child!,
        );
      },
    );
    if (picked != null) _setRange(picked.start, picked.end);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Absensi')),
      body: Consumer<AttendanceProvider>(
        builder: (context, provider, _) {
          return RefreshIndicator(
            onRefresh: _reload,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
              children: [
                DateRangeBar(
                  start: _startDate,
                  end: _endDate,
                  onRange: _setRange,
                  onPickCustom: _selectDateRange,
                ),
                const SizedBox(height: 16),
                FadeSwitcher(child: _buildBody(provider)),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildBody(AttendanceProvider provider) {
    final today = provider.todayAttendance;
    final history = provider.recentAttendance
        .where((record) => today == null || record.id != today.id)
        .toList();
    final hasData = today != null || history.isNotEmpty;

    // Data yang sudah tampil tidak diganti kerangka saat dimuat ulang (tarik untuk segarkan).
    if (provider.isLoading && !hasData) {
      return Column(
        key: const ValueKey('memuat'),
        children: const [
          SkeletonListCard(),
          SizedBox(height: 12),
          SkeletonListCard(),
          SizedBox(height: 12),
          SkeletonListCard(),
        ],
      );
    }

    if (provider.error != null && !hasData) {
      return ErrorState(
        key: const ValueKey('galat'),
        title: 'Riwayat absensi tidak bisa dimuat',
        message:
            'Periksa koneksi internet Anda, lalu coba lagi. Absen yang sudah Anda lakukan tetap tersimpan.',
        onRetry: _reload,
      );
    }

    if (!hasData) {
      return EmptyState(
        key: const ValueKey('kosong'),
        icon: Icons.event_busy_outlined,
        title: 'Belum ada catatan absensi',
        message:
            'Tidak ada catatan absen pada rentang tanggal ini. Perluas rentangnya untuk melihat riwayat sebelumnya.',
        actionLabel: '30 hari terakhir',
        onAction: () {
          final now = DateTime.now();
          final end = DateTime(now.year, now.month, now.day);
          _setRange(end.subtract(const Duration(days: 29)), end);
        },
      );
    }

    final all = <AttendanceRecord>[if (today != null) today, ...history];
    return Column(
      key: const ValueKey('isi'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FadeSlideIn(child: _SummaryCard(records: all)),
        if (today != null) ...[
          const SizedBox(height: 12),
          FadeSlideIn(
            delay: Motion.stagger(1),
            child: _TodayCard(
              record: today,
              onPhoto: _showPhotoDialog,
            ),
          ),
        ],
        if (history.isNotEmpty) ...[
          const SizedBox(height: 8),
          const SectionHeader(title: 'Riwayat'),
          for (var i = 0; i < history.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: FadeSlideIn(
                key: ValueKey('riwayat-${history[i].id}'),
                delay: Motion.stagger(i + 2),
                child: _HistoryTile(
                  record: history[i],
                  onPhoto: _showPhotoDialog,
                ),
              ),
            ),
        ],
      ],
    );
  }

  void _showPhotoDialog(String photoUrl, String title) {
    showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Colors.transparent,
        child: Stack(
          children: [
            Center(
              child: CachedNetworkImage(
                imageUrl: photoUrl,
                fit: BoxFit.contain,
                placeholder: (context, url) =>
                    const Center(child: CircularProgressIndicator()),
                errorWidget: (context, url, error) => const Icon(
                  Icons.broken_image_outlined,
                  color: Colors.white,
                  size: 48,
                ),
              ),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                tooltip: 'Tutup',
                onPressed: () => Navigator.of(context).pop(),
                style: IconButton.styleFrom(
                  backgroundColor: Colors.black54,
                  minimumSize: const Size(48, 48),
                ),
              ),
            ),
            Positioned(
              bottom: 8,
              left: 0,
              right: 0,
              child: Container(
                padding: const EdgeInsets.all(8),
                color: Colors.black54,
                child: Text(
                  title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String? _checkInPhotoUrl(AttendanceRecord record) {
  // Utamakan foto check-in; foto lama (photoUrl) hanya dipakai bila belum check-out.
  return record.checkInPhotoUrl ??
      (record.checkIn != null && record.checkOut == null
          ? record.photoUrl
          : null);
}

String? _checkOutPhotoUrl(AttendanceRecord record) {
  return record.checkOutPhotoUrl ??
      (record.checkOut != null ? record.photoUrl : null);
}

typedef _PhotoOpener = void Function(String url, String title);

/// Ringkasan periode: hitungan per status dari catatan yang dimuat, dan rata-rata lama kerja
/// hanya dari hari yang punya jam masuk dan pulang. Tidak ada angka karangan.
class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.records});

  final List<AttendanceRecord> records;

  @override
  Widget build(BuildContext context) {
    int count(bool Function(String s) test) =>
        records.where((r) => test(r.status.toLowerCase())).length;

    final onTime = count((s) => s == 'present' || s == 'remote');
    final late = count((s) => s == 'late');
    final absent = count((s) => s == 'absent');
    final leave = count((s) => s == 'leave' || s == 'sick');

    final worked = records
        .where((r) => r.checkOut != null || r.checkOutAt != null)
        .map((r) => r.workDurationMinutes())
        .whereType<int>()
        .toList();
    final avgWorked = worked.isEmpty
        ? null
        : (worked.reduce((a, b) => a + b) / worked.length).round();

    return AtenimCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Ringkasan periode ini',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: AtenimUi.ink,
            ),
          ),
          const SizedBox(height: 12),
          IntrinsicHeight(
            child: Row(
              children: [
                _SummaryCell(value: onTime, label: 'Hadir', tone: Tone.success),
                const _CellDivider(),
                _SummaryCell(value: late, label: 'Terlambat', tone: Tone.warning),
                const _CellDivider(),
                _SummaryCell(value: absent, label: 'Tidak hadir', tone: Tone.danger),
                const _CellDivider(),
                _SummaryCell(value: leave, label: 'Izin/Sakit', tone: Tone.info),
              ],
            ),
          ),
          if (avgWorked != null) ...[
            const SizedBox(height: 12),
            Text(
              'Rata-rata lama kerja ${formatDuration(avgWorked)} per hari (dari ${worked.length} hari yang lengkap).',
              style: TextStyle(fontSize: 13, color: AtenimUi.inkSoft, height: 1.35),
            ),
          ],
        ],
      ),
    );
  }
}

class _CellDivider extends StatelessWidget {
  const _CellDivider();

  @override
  Widget build(BuildContext context) =>
      VerticalDivider(width: 1, thickness: 1, color: AtenimUi.line);
}

class _SummaryCell extends StatelessWidget {
  const _SummaryCell({required this.value, required this.label, required this.tone});

  final int value;
  final String label;
  final Tone tone;

  @override
  Widget build(BuildContext context) {
    final colors = toneColors(tone);
    return Expanded(
      child: Column(
        children: [
          Text(
            '$value',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w800,
              height: 1.1,
              color: value == 0 ? Colors.grey[600] : colors.fg,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: AtenimUi.inkSoft),
          ),
        ],
      ),
    );
  }
}

class _TodayCard extends StatelessWidget {
  const _TodayCard({required this.record, required this.onPhoto});

  final AttendanceRecord record;
  final _PhotoOpener onPhoto;

  @override
  Widget build(BuildContext context) {
    final inLabel = clockLabel(record.checkIn);
    final outLabel = clockLabel(record.checkOut);
    final date = DateTime.tryParse(record.date);

    String durationLabel = '-';
    String durationCaption = 'Durasi';
    final isRunning = record.checkOut == null && record.checkOutAt == null;
    final worked = record.workDurationMinutes(now: DateTime.now());
    if (worked != null) {
      durationLabel = formatDuration(worked);
      if (isRunning) durationCaption = 'Berjalan';
    }

    final notes = <Widget>[
      if (record.needsValidation)
        const StatusPill(
          label: 'Menunggu validasi',
          tone: Tone.warning,
          icon: Icons.hourglass_top,
        ),
      if (record.isAutoCheckout)
        const StatusPill(label: 'Pulang otomatis', tone: Tone.neutral),
      if (record.breakDurationMinutes != null && record.breakDurationMinutes! > 0)
        StatusPill(
          label: 'Istirahat ${formatDuration(record.breakDurationMinutes!)}',
          tone: Tone.info,
        ),
      if ((record.breakOverByMinutes ?? 0) > 0)
        StatusPill(
          label: 'Lebih ${record.breakOverByMinutes} menit',
          tone: Tone.warning,
        ),
    ];

    final inPhoto = _checkInPhotoUrl(record);
    final outPhoto = _checkOutPhotoUrl(record);

    return AtenimCard(
      borderColor: Colors.blue[100],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Hari ini',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: AtenimUi.ink,
                  ),
                ),
              ),
              StatusPill(
                label: attendanceStatusLabel(record.status),
                tone: attendanceStatusTone(record.status),
              ),
            ],
          ),
          if (date != null) ...[
            const SizedBox(height: 2),
            Text(
              DateFormat('EEEE, d MMMM yyyy', 'id_ID').format(date),
              style: TextStyle(fontSize: 13, color: AtenimUi.inkSoft),
            ),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(flex: 3, child: _TimeBlock(caption: 'Masuk', value: inLabel ?? '-')),
              Expanded(
                flex: 3,
                child: _TimeBlock(
                  caption: 'Pulang',
                  value: outLabel ?? (inLabel != null ? 'Belum' : '-'),
                ),
              ),
              Expanded(flex: 5, child: _TimeBlock(caption: durationCaption, value: durationLabel)),
            ],
          ),
          if (notes.isNotEmpty) ...[
            const SizedBox(height: 14),
            Wrap(spacing: 8, runSpacing: 8, children: notes),
          ],
          if (inPhoto != null || outPhoto != null) ...[
            const SizedBox(height: 14),
            _PhotoPair(
              checkInUrl: inPhoto,
              checkOutUrl: outPhoto,
              onPhoto: onPhoto,
            ),
          ],
        ],
      ),
    );
  }
}

class _TimeBlock extends StatelessWidget {
  const _TimeBlock({required this.caption, required this.value});

  final String caption;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(caption, style: TextStyle(fontSize: 12, color: AtenimUi.inkSoft)),
        const SizedBox(height: 2),
        Text(
          value,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w700,
            height: 1.2,
            color: AtenimUi.ink,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

class _PhotoPair extends StatelessWidget {
  const _PhotoPair({this.checkInUrl, this.checkOutUrl, required this.onPhoto});

  final String? checkInUrl;
  final String? checkOutUrl;
  final _PhotoOpener onPhoto;

  @override
  Widget build(BuildContext context) {
    Widget thumb(String? url, String label) {
      if (url == null) return const SizedBox.shrink();
      return Expanded(
        child: Semantics(
          button: true,
          label: 'Buka $label',
          child: GestureDetector(
            onTap: () => onPhoto(url, label),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(AtenimUi.radiusControl),
                  child: AspectRatio(
                    aspectRatio: 4 / 3,
                    child: CachedNetworkImage(
                      imageUrl: url,
                      fit: BoxFit.cover,
                      fadeInDuration: const Duration(milliseconds: 180),
                      placeholder: (context, url) =>
                          Container(color: Colors.grey[200]),
                      errorWidget: (context, url, error) => Container(
                        color: Colors.grey[100],
                        alignment: Alignment.center,
                        child: Icon(Icons.broken_image_outlined, color: Colors.grey[600]),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Text(label, style: TextStyle(fontSize: 12, color: AtenimUi.inkSoft)),
              ],
            ),
          ),
        ),
      );
    }

    final hasBoth = checkInUrl != null && checkOutUrl != null;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        thumb(checkInUrl, 'Foto masuk'),
        if (hasBoth) const SizedBox(width: 10),
        thumb(checkOutUrl, 'Foto pulang'),
        // Satu foto saja tidak melebar penuh.
        if (!hasBoth) const Spacer(),
      ],
    );
  }
}

/// Satu hari di riwayat: tanggal, jam, lama kerja, status. Ketuk untuk membuka rincian dan foto.
class _HistoryTile extends StatefulWidget {
  const _HistoryTile({required this.record, required this.onPhoto});

  final AttendanceRecord record;
  final _PhotoOpener onPhoto;

  @override
  State<_HistoryTile> createState() => _HistoryTileState();
}

class _HistoryTileState extends State<_HistoryTile> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final record = widget.record;
    final date = DateTime.tryParse(record.date);
    final inLabel = clockLabel(record.checkIn);
    final outLabel = clockLabel(record.checkOut);
    final worked = record.workDurationMinutes();
    final inPhoto = _checkInPhotoUrl(record);
    final outPhoto = _checkOutPhotoUrl(record);
    final hasDetail = inLabel != null ||
        outLabel != null ||
        inPhoto != null ||
        outPhoto != null ||
        (record.notes ?? '').trim().isNotEmpty;

    final timeText = (inLabel == null && outLabel == null)
        ? 'Tidak ada jam tercatat'
        : '${inLabel ?? '-'} - ${outLabel ?? '-'}';

    return AtenimCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: hasDetail ? () => setState(() => _open = !_open) : null,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  DateTile(date: date),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          date != null
                              ? DateFormat('EEEE', 'id_ID').format(date)
                              : record.date,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: AtenimUi.ink,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          timeText,
                          style: TextStyle(fontSize: 13, color: AtenimUi.inkSoft, height: 1.3),
                        ),
                        if (worked != null)
                          Text(
                            'Lama kerja ${formatDuration(worked)}',
                            style: TextStyle(fontSize: 13, color: AtenimUi.inkSoft, height: 1.3),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  StatusPill(
                    label: attendanceStatusLabel(record.status),
                    tone: attendanceStatusTone(record.status),
                  ),
                  if (hasDetail) ...[
                    const SizedBox(width: 4),
                    AnimatedRotation(
                      turns: _open ? 0.5 : 0,
                      duration: Motion.reduced(context) ? Duration.zero : Motion.quick,
                      curve: Motion.easeOut,
                      child: Icon(Icons.expand_more, color: Colors.grey[700]),
                    ),
                  ],
                ],
              ),
            ),
          ),
          AnimatedSize(
            duration: Motion.reduced(context) ? Duration.zero : Motion.quick,
            curve: Motion.easeOut,
            alignment: Alignment.topCenter,
            child: _open
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Divider(height: 1, color: AtenimUi.line),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(flex: 3, child: _TimeBlock(caption: 'Masuk', value: inLabel ?? '-')),
                            Expanded(flex: 3, child: _TimeBlock(caption: 'Pulang', value: outLabel ?? '-')),
                            Expanded(
                              flex: 5,
                              child: _TimeBlock(
                                caption: 'Durasi',
                                value: worked != null ? formatDuration(worked) : '-',
                              ),
                            ),
                          ],
                        ),
                        if ((record.breakDurationMinutes ?? 0) > 0 ||
                            record.needsValidation ||
                            record.isAutoCheckout) ...[
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              if (record.needsValidation)
                                const StatusPill(
                                  label: 'Menunggu validasi',
                                  tone: Tone.warning,
                                  icon: Icons.hourglass_top,
                                ),
                              if (record.isAutoCheckout)
                                const StatusPill(label: 'Pulang otomatis', tone: Tone.neutral),
                              if ((record.breakDurationMinutes ?? 0) > 0)
                                StatusPill(
                                  label: 'Istirahat ${formatDuration(record.breakDurationMinutes!)}',
                                  tone: Tone.info,
                                ),
                            ],
                          ),
                        ],
                        if ((record.notes ?? '').trim().isNotEmpty) ...[
                          const SizedBox(height: 12),
                          Text(
                            record.notes!.trim(),
                            style: TextStyle(fontSize: 13, color: AtenimUi.inkSoft, height: 1.35),
                          ),
                        ],
                        if (inPhoto != null || outPhoto != null) ...[
                          const SizedBox(height: 12),
                          _PhotoPair(
                            checkInUrl: inPhoto,
                            checkOutUrl: outPhoto,
                            onPhoto: widget.onPhoto,
                          ),
                        ],
                      ],
                    ),
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }
}
