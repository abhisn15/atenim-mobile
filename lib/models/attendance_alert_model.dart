/// Satu peringatan kehadiran dari `/api/attendance-alerts` (belum check-in, terlambat, atau keluar radius).
/// Di HP baru dipakai untuk "keluar radius" di halaman Team leader.
class AttendanceAlert {
  const AttendanceAlert({
    required this.key,
    required this.kind,
    required this.userId,
    required this.name,
    required this.phone,
    required this.siteName,
    required this.detail,
    required this.dateLabel,
    required this.timeLabel,
    required this.at,
  });

  final String key;

  /// `late`, `missing`, atau `outside`
  final String kind;
  final String userId;
  final String name;
  final String? phone;
  final String siteName;
  final String detail;

  /// yyyy-MM-dd menurut zona waktu site
  final String dateLabel;

  /// HH:mm menurut zona waktu site
  final String timeLabel;
  final DateTime? at;

  factory AttendanceAlert.fromJson(Map<String, dynamic> json) {
    String text(String k) => json[k]?.toString() ?? '';
    final phone = json['phone']?.toString();
    return AttendanceAlert(
      key: text('key'),
      kind: text('kind'),
      userId: text('userId'),
      name: text('name').trim(),
      phone: (phone == null || phone.trim().isEmpty) ? null : phone,
      siteName: text('siteName'),
      detail: text('detail'),
      dateLabel: text('dateLabel'),
      timeLabel: text('timeLabel'),
      at: DateTime.tryParse(text('at')),
    );
  }
}

/// Anggota yang terdeteksi keluar radius, dirangkum per orang (satu baris per orang, bukan per kejadian).
class OutsideRadiusPerson {
  const OutsideRadiusPerson({
    required this.userId,
    required this.name,
    required this.phone,
    required this.siteName,
    required this.count,
    required this.lastDateLabel,
    required this.lastTimeLabel,
  });

  final String userId;
  final String name;
  final String? phone;
  final String siteName;

  /// Berapa kali terdeteksi dalam periode
  final int count;
  final String lastDateLabel;
  final String lastTimeLabel;
}

/// Ambil kejadian keluar radius, batasi ke [onlyUserIds] bila diisi (team yang sedang dipilih leader), dan rangkum per
/// orang. Urutan: yang terakhir terdeteksi paling baru di atas. Daftar masukan boleh dalam urutan apa pun.
List<OutsideRadiusPerson> groupOutsideRadius(List<AttendanceAlert> alerts, {Set<String>? onlyUserIds}) {
  final latest = <String, AttendanceAlert>{};
  final counts = <String, int>{};
  for (final a in alerts) {
    if (a.kind != 'outside' || a.userId.isEmpty) continue;
    if (onlyUserIds != null && !onlyUserIds.contains(a.userId)) continue;
    counts[a.userId] = (counts[a.userId] ?? 0) + 1;
    final current = latest[a.userId];
    if (current == null || _isLater(a, current)) latest[a.userId] = a;
  }
  final people = [
    for (final e in latest.entries)
      OutsideRadiusPerson(
        userId: e.key,
        name: e.value.name,
        phone: e.value.phone,
        siteName: e.value.siteName,
        count: counts[e.key] ?? 1,
        lastDateLabel: e.value.dateLabel,
        lastTimeLabel: e.value.timeLabel,
      ),
  ];
  people.sort((a, b) {
    final byTime = '${b.lastDateLabel} ${b.lastTimeLabel}'.compareTo('${a.lastDateLabel} ${a.lastTimeLabel}');
    return byTime != 0 ? byTime : a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
  return people;
}

bool _isLater(AttendanceAlert a, AttendanceAlert b) {
  if (a.at != null && b.at != null) return a.at!.isAfter(b.at!);
  return '${a.dateLabel} ${a.timeLabel}'.compareTo('${b.dateLabel} ${b.timeLabel}') > 0;
}
