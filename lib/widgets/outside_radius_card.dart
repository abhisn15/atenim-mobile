import 'package:flutter/material.dart';

import '../models/attendance_alert_model.dart';
import '../utils/phone_contact.dart';
import 'contact_buttons.dart';
import 'shimmer_loading.dart';
import 'ui_kit.dart';

/// Kartu "Keluar radius" di halaman Team untuk karyawan team leader: anggota yang terdeteksi di luar area site saat
/// jam kerja (24 jam terakhir), satu baris per orang, dengan tombol telepon dan WhatsApp untuk menanyakan sebabnya.
/// Hanya site yang memakai radius dan pelacakan yang dipantau; karena itu keadaan kosong menjelaskan batasnya.
class OutsideRadiusCard extends StatefulWidget {
  const OutsideRadiusCard({
    super.key,
    required this.people,
    required this.loading,
    required this.error,
    required this.leaderName,
    this.today,
    this.collapsedCount = 3,
  });

  /// null = belum pernah berhasil dimuat
  final List<OutsideRadiusPerson>? people;
  final bool loading;
  final String? error;
  final String leaderName;

  /// Tanggal hari ini (yyyy-MM-dd) untuk memutuskan perlu tidaknya menulis tanggal; untuk pengujian.
  final String? today;
  final int collapsedCount;

  @override
  State<OutsideRadiusCard> createState() => _OutsideRadiusCardState();
}

class _OutsideRadiusCardState extends State<OutsideRadiusCard> {
  bool _expanded = false;

  static String _ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  static const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'Mei', 'Jun', 'Jul', 'Agu', 'Sep', 'Okt', 'Nov', 'Des'];

  String _when(OutsideRadiusPerson p) {
    final time = p.lastTimeLabel.replaceAll(':', '.');
    final today = widget.today ?? _ymd(DateTime.now());
    if (p.lastDateLabel == today || p.lastDateLabel.length < 10) return time;
    final month = int.tryParse(p.lastDateLabel.substring(5, 7));
    final day = int.tryParse(p.lastDateLabel.substring(8, 10));
    if (month == null || day == null || month < 1 || month > 12) return time;
    return '$day ${_months[month - 1]}, $time';
  }

  @override
  Widget build(BuildContext context) {
    final people = widget.people;
    final shown = people == null ? const <OutsideRadiusPerson>[] : (_expanded ? people : people.take(widget.collapsedCount).toList());
    final hidden = people == null ? 0 : people.length - shown.length;
    final warn = toneColors(Tone.warning);
    return AtenimCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.location_off_outlined, size: 18, color: warn.fg),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Keluar radius',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AtenimUi.ink),
                    ),
                    Text('24 jam terakhir', style: TextStyle(fontSize: 12, color: AtenimUi.inkSoft)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (people == null && widget.loading)
            ShimmerLoading(width: double.infinity, height: 56, borderRadius: BorderRadius.circular(10))
          else if (people == null)
            Text(
              widget.error ?? 'Daftar keluar radius belum tersedia.',
              style: TextStyle(fontSize: 13, color: AtenimUi.inkSoft),
            )
          else if (people.isEmpty)
            Text(
              'Tidak ada anggota yang terdeteksi di luar radius site. Hanya site yang memakai radius dan pelacakan yang dipantau.',
              style: TextStyle(fontSize: 13, height: 1.35, color: AtenimUi.inkSoft),
            )
          else ...[
            for (final p in shown)
              Row(
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            p.name.isEmpty ? '-' : p.name,
                            style: TextStyle(fontWeight: FontWeight.w600, color: AtenimUi.ink),
                          ),
                          Text(
                            '${p.count > 1 ? '${p.count} kali, terakhir ' : 'Terdeteksi '}${_when(p)}'
                            '${p.siteName.isEmpty ? '' : ' · ${p.siteName}'}',
                            style: TextStyle(fontSize: 12, height: 1.3, color: AtenimUi.inkSoft),
                          ),
                          if (normalizeIndonesianPhone(p.phone) == null)
                            Text('Nomor HP belum diisi', style: TextStyle(fontSize: 12, color: AtenimUi.inkSoft)),
                        ],
                      ),
                    ),
                  ),
                  ContactButtons(
                    phone: p.phone,
                    memberName: p.name,
                    leaderName: widget.leaderName,
                    reason: ContactReason.outside,
                  ),
                ],
              ),
            if (hidden > 0 || (_expanded && people.length > widget.collapsedCount))
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => setState(() => _expanded = !_expanded),
                  child: Text(_expanded ? 'Tampilkan lebih sedikit' : 'Lihat semua ($hidden lagi)'),
                ),
              ),
          ],
        ],
      ),
    );
  }
}
