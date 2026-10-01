import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'motion.dart';

/// Token dan komponen bersama Atenim, mengikuti DESIGN.md ("Tenang & fokus"):
/// biru identitas untuk aksi, hijau/oranye/merah hanya untuk status, kartu putih bergaris tipis
/// tanpa bayangan tebal, sudut kartu 16 dan kontrol 12, teks pendukung grey[700].
class AtenimUi {
  AtenimUi._();

  static const Color pageBg = Color(0xFFF6F7F9);
  static const double radiusCard = 16;
  static const double radiusControl = 12;

  static Color get brand => Colors.blue[700]!;
  static Color get brandSoft => Colors.blue[50]!;
  static Color get ink => Colors.grey[900]!;
  static Color get inkSoft => Colors.grey[700]!;
  static Color get line => Colors.grey[200]!;
}

/// Nada status. Dipakai hanya untuk menandai keadaan nyata (hadir, terlambat, ditolak), bukan hiasan.
/// Pasangan warna sudah diperiksa kontrasnya >= 4,5:1.
enum Tone { success, warning, danger, info, neutral }

class ToneColors {
  const ToneColors(this.bg, this.fg);
  final Color bg;
  final Color fg;
}

ToneColors toneColors(Tone tone) {
  switch (tone) {
    case Tone.success:
      return ToneColors(Colors.green[50]!, Colors.green[800]!);
    case Tone.warning:
      // orange[900] hanya 3,46:1 di atas orange[50]; oranye tua ini 6,66:1.
      return const ToneColors(Color(0xFFFFF3E0), Color(0xFF9A3412));
    case Tone.danger:
      return ToneColors(Colors.red[50]!, Colors.red[800]!);
    case Tone.info:
      return ToneColors(Colors.blue[50]!, Colors.blue[800]!);
    case Tone.neutral:
      return ToneColors(Colors.grey[100]!, Colors.grey[800]!);
  }
}

/// Kartu putih bergaris tipis. Bila [onTap] diisi, kartu menyusut sedikit saat ditekan (100 ms).
class AtenimCard extends StatefulWidget {
  const AtenimCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.onTap,
    this.color,
    this.borderColor,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final Color? color;
  final Color? borderColor;

  @override
  State<AtenimCard> createState() => _AtenimCardState();
}

class _AtenimCardState extends State<AtenimCard> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(AtenimUi.radiusCard);
    final card = Material(
      color: widget.color ?? Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(color: widget.borderColor ?? AtenimUi.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: widget.onTap == null
          ? Padding(padding: widget.padding, child: widget.child)
          : InkWell(
              onTap: widget.onTap,
              onHighlightChanged: (value) => setState(() => _pressed = value),
              child: Padding(padding: widget.padding, child: widget.child),
            ),
    );
    if (widget.onTap == null) return card;
    return AnimatedScale(
      scale: _pressed && !Motion.reduced(context) ? 0.985 : 1,
      duration: const Duration(milliseconds: 100),
      curve: Curves.easeOut,
      child: card,
    );
  }
}

/// Label status kecil. Teks Indonesia, bukan nilai mentah dari sistem.
class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.label, required this.tone, this.icon});

  final String label;
  final Tone tone;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final colors = toneColors(tone);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: colors.bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: colors.fg),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              color: colors.fg,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              height: 1.2,
            ),
          ),
        ],
      ),
    );
  }
}

class SectionHeader extends StatelessWidget {
  const SectionHeader({super.key, required this.title, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: AtenimUi.ink,
              ),
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// Keadaan kosong: menyebut kenapa kosong dan satu langkah berikutnya.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: AtenimUi.brandSoft,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 30, color: AtenimUi.brand),
          ),
          const SizedBox(height: 16),
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: AtenimUi.ink,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, height: 1.4, color: AtenimUi.inkSoft),
          ),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 20),
            FilledButton(
              onPressed: onAction,
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 48),
                padding: const EdgeInsets.symmetric(horizontal: 24),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AtenimUi.radiusControl),
                ),
              ),
              child: Text(actionLabel!),
            ),
          ],
        ],
      ),
    );
  }
}

/// Keadaan galat: apa yang gagal, bahwa data sebelumnya aman, dan tombol coba lagi.
class ErrorState extends StatelessWidget {
  const ErrorState({
    super.key,
    required this.title,
    required this.message,
    required this.onRetry,
  });

  final String title;
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = toneColors(Tone.danger);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(color: colors.bg, shape: BoxShape.circle),
            child: Icon(Icons.cloud_off_outlined, size: 30, color: colors.fg),
          ),
          const SizedBox(height: 16),
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: AtenimUi.ink,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, height: 1.4, color: AtenimUi.inkSoft),
          ),
          const SizedBox(height: 20),
          OutlinedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('Coba lagi'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(0, 48),
              padding: const EdgeInsets.symmetric(horizontal: 20),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AtenimUi.radiusControl),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Balok kerangka saat memuat. Berdenyut pelan selama masih memuat; diam bila animasi dimatikan.
class SkeletonBox extends StatefulWidget {
  const SkeletonBox({super.key, this.width, required this.height, this.radius = 8});

  final double? width;
  final double height;
  final double radius;

  @override
  State<SkeletonBox> createState() => _SkeletonBoxState();
}

class _SkeletonBoxState extends State<SkeletonBox>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (!Motion.reduced(context)) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Container(
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            color: Color.lerp(Colors.grey[200], Colors.grey[300], _controller.value),
            borderRadius: BorderRadius.circular(widget.radius),
          ),
        );
      },
    );
  }
}

/// Kerangka satu baris kartu daftar (ikon + dua baris teks).
class SkeletonListCard extends StatelessWidget {
  const SkeletonListCard({super.key});

  @override
  Widget build(BuildContext context) {
    return const AtenimCard(
      padding: EdgeInsets.all(14),
      child: Row(
        children: [
          SkeletonBox(width: 48, height: 48, radius: 12),
          SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SkeletonBox(width: 140, height: 14),
                SizedBox(height: 8),
                SkeletonBox(height: 12),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Bilah rentang tanggal: pintasan yang sering dipakai + pemilih tanggal bebas.
/// Pintasan yang cocok dengan rentang saat ini tampil terpilih.
class DateRangeBar extends StatelessWidget {
  const DateRangeBar({
    super.key,
    required this.start,
    required this.end,
    required this.onRange,
    required this.onPickCustom,
  });

  final DateTime start;
  final DateTime end;
  final void Function(DateTime start, DateTime end) onRange;
  final VoidCallback onPickCustom;

  static DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

  @override
  Widget build(BuildContext context) {
    final today = _day(DateTime.now());
    final presets = <_Preset>[
      _Preset('Bulan ini', DateTime(today.year, today.month, 1), today),
      _Preset('7 hari', today.subtract(const Duration(days: 6)), today),
      _Preset('30 hari', today.subtract(const Duration(days: 29)), today),
    ];
    final s = _day(start);
    final e = _day(end);
    final activeIndex = presets.indexWhere((p) => p.start == s && p.end == e);
    final fmt = DateFormat('d MMM yyyy', 'id_ID');
    final sameDay = s == e;

    return Column(
      // stretch: lebar penuh, supaya pilihan rata kiri walau induknya memusatkan anak (mis. Aktivitas).
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Wrap: bila layar sempit, pilihan turun ke baris berikutnya dan tidak terpotong di tepi layar.
        Wrap(
          spacing: 8,
          runSpacing: 0,
          children: [
            for (var i = 0; i < presets.length; i++)
              ChoiceChip(
                label: Text(presets[i].label),
                selected: activeIndex == i,
                onSelected: (_) => onRange(presets[i].start, presets[i].end),
                showCheckmark: false,
              ),
            ActionChip(
              avatar: const Icon(Icons.calendar_today_outlined, size: 16),
              label: const Text('Pilih tanggal'),
              onPressed: onPickCustom,
            ),
          ],
        ),
        const SizedBox(height: 6),
        Padding(
          padding: const EdgeInsets.only(left: 4),
          child: Text(
            sameDay ? fmt.format(s) : '${fmt.format(s)} sampai ${fmt.format(e)}',
            style: TextStyle(fontSize: 13, color: AtenimUi.inkSoft),
          ),
        ),
      ],
    );
  }
}

class _Preset {
  const _Preset(this.label, this.start, this.end);
  final String label;
  final DateTime start;
  final DateTime end;
}

/// Ubin tanggal kecil: angka hari besar dan bulan singkat. Dipakai di daftar riwayat.
class DateTile extends StatelessWidget {
  const DateTile({super.key, required this.date});

  final DateTime? date;

  @override
  Widget build(BuildContext context) {
    final d = date;
    return Container(
      width: 48,
      height: 52,
      decoration: BoxDecoration(
        color: Colors.grey[100],
        borderRadius: BorderRadius.circular(AtenimUi.radiusControl),
      ),
      alignment: Alignment.center,
      child: d == null
          ? Icon(Icons.event, color: Colors.grey[700])
          : Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '${d.day}',
                  style: TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w800,
                    height: 1.1,
                    color: AtenimUi.ink,
                  ),
                ),
                Text(
                  DateFormat('MMM', 'id_ID').format(d),
                  style: TextStyle(fontSize: 11, color: AtenimUi.inkSoft),
                ),
              ],
            ),
    );
  }
}
