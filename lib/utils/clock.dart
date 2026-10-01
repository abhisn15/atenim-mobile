import '../widgets/ui_kit.dart';

/// Pembaca jam kehadiran. Server mengirim jam masuk/pulang sebagai "HH:mm", "HH:mm:ss", atau ISO 8601.

final RegExp _hhmm = RegExp(r'^\s*(\d{1,2}):(\d{2})');

/// Menit sejak tengah malam, atau null bila tidak terbaca. ISO dibaca sebagai waktu lokal perangkat.
int? clockMinutes(String? raw) {
  if (raw == null || raw.trim().isEmpty) return null;
  final text = raw.trim();
  if (text.contains('T')) {
    final parsed = DateTime.tryParse(text);
    if (parsed == null) return null;
    final local = parsed.toLocal();
    return local.hour * 60 + local.minute;
  }
  final match = _hhmm.firstMatch(text);
  if (match == null) return null;
  final h = int.tryParse(match.group(1)!);
  final m = int.tryParse(match.group(2)!);
  if (h == null || m == null || h > 23 || m > 59) return null;
  return h * 60 + m;
}

/// "HH:mm" untuk ditampilkan, atau null.
String? clockLabel(String? raw) {
  final minutes = clockMinutes(raw);
  if (minutes == null) return null;
  final h = (minutes ~/ 60).toString().padLeft(2, '0');
  final m = (minutes % 60).toString().padLeft(2, '0');
  return '$h:$m';
}

/// Lama kerja dalam menit. Bila jam pulang lebih kecil dari jam masuk, dianggap lewat tengah malam.
int? workedMinutes(String? checkIn, String? checkOut) {
  final a = clockMinutes(checkIn);
  final b = clockMinutes(checkOut);
  if (a == null || b == null) return null;
  var diff = b - a;
  if (diff < 0) diff += 24 * 60;
  return diff;
}

/// "8 jam 5 menit", "45 menit", "2 jam".
String formatDuration(int minutes) {
  if (minutes <= 0) return '0 menit';
  final h = minutes ~/ 60;
  final m = minutes % 60;
  if (h == 0) return '$m menit';
  if (m == 0) return '$h jam';
  return '$h jam $m menit';
}

/// Teks status kehadiran dalam bahasa Indonesia (nilai dari server: present, late, absent, leave, sick, remote).
String attendanceStatusLabel(String status) {
  switch (status.toLowerCase()) {
    case 'present':
      return 'Hadir';
    case 'late':
      return 'Terlambat';
    case 'absent':
      return 'Tidak hadir';
    case 'leave':
      return 'Izin';
    case 'sick':
      return 'Sakit';
    case 'remote':
      return 'Remote';
    default:
      return 'Belum ada status';
  }
}

Tone attendanceStatusTone(String status) {
  switch (status.toLowerCase()) {
    case 'present':
    case 'remote':
      return Tone.success;
    case 'late':
      return Tone.warning;
    case 'absent':
      return Tone.danger;
    case 'leave':
    case 'sick':
      return Tone.info;
    default:
      return Tone.neutral;
  }
}
