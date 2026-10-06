import '../models/attendance_model.dart';

/// Absen yang dihitung sebagai "hari ini" di HP.
///
/// Data segar dari server sudah tepat: absen tanggal hari ini ditambah absen terbuka dari hari sebelumnya (shift malam).
/// Cache lokal ditampilkan lebih dulu dan dipakai penuh saat offline, jadi sesudah tengah malam isinya masih absen
/// kemarin. Absen kemarin yang sudah selesai tidak boleh dihitung sebagai absen hari ini: itu membuat check-in tanpa
/// shift ditolak dengan "hanya bisa sekali per hari" padahal absennya kemarin. Yang masih terbuka tetap ikut, karena
/// itu shift malam yang berjalan.
///
/// [fetchedAt] = kapan data diambil dari server (null = cache lama tanpa penanda, dianggap basi). Data yang diambil
/// pada hari kalender yang sama dengan [now] dipercaya apa adanya, supaya zona waktu perangkat yang berbeda dari
/// site tidak ikut menyaring data server.
List<AttendanceRecord> recordsForToday(
  List<AttendanceRecord> records, {
  required DateTime? fetchedAt,
  required DateTime now,
}) {
  if (fetchedAt != null && _sameDay(fetchedAt, now)) return records;
  final todayKey = _dateKey(now);
  return records
      .where((r) => (r.checkIn != null && r.checkOut == null) || r.date.startsWith(todayKey))
      .toList(growable: false);
}

bool _sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

String _dateKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
