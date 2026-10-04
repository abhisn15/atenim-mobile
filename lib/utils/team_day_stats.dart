import '../models/attendance_model.dart';
import '../models/shift_assignment_model.dart';

/// Anggota yang perlu ditindaklanjuti leader (belum check-in atau terlambat).
class TeamDayPerson {
  const TeamDayPerson({required this.id, required this.name, this.shiftName});

  final String id;
  final String name;
  final String? shiftName;
}

/// Gambaran absensi anggota team pada saat ini untuk leader.
///
/// Tiap anggota masuk tepat satu kelompok: belum mulai (shift hari ini belum dimulai), belum check-in (shift sudah
/// dimulai tetapi belum check-in), sedang bekerja (sudah check-in, belum pulang), atau sudah check-out. Terlambat
/// adalah catatan tambahan dari yang sudah check-in. Shift malam diperhitungkan: yang check-in kemarin dan belum pulang
/// tetap "sedang bekerja", dan yang shift malam kemarinnya masih berjalan tetapi belum check-in tetap "belum check-in".
class TeamDayStats {
  const TeamDayStats({
    required this.notStarted,
    required this.notCheckedIn,
    required this.working,
    required this.checkedOut,
    required this.late,
    required this.notCheckedInPeople,
    required this.latePeople,
  });

  final int notStarted;
  final int notCheckedIn;
  final int working;
  final int checkedOut;
  final int late;
  final List<TeamDayPerson> notCheckedInPeople;
  final List<TeamDayPerson> latePeople;

  int get total => notStarted + notCheckedIn + working + checkedOut;
  bool get isEmpty => total == 0;

  static String _ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  static int? _minutes(String? raw) {
    final m = RegExp(r'^\s*(\d{1,2}):(\d{2})').firstMatch(raw ?? '');
    if (m == null) return null;
    final h = int.parse(m.group(1)!);
    final mm = int.parse(m.group(2)!);
    return h > 24 || mm > 59 ? null : h * 60 + mm;
  }

  static bool _hasValue(String? v) => v != null && v.trim().isNotEmpty && v.trim() != '-';

  static DateTime _at(DateTime day, int minutes, {int addDays = 0}) =>
      DateTime(day.year, day.month, day.day + addDays, minutes ~/ 60, minutes % 60);

  /// [assignments] dan [logs] sebaiknya mencakup kemarin dan hari ini (shift malam butuh data kemarin).
  static TeamDayStats compute({
    required DateTime now,
    required List<ShiftAssignment> assignments,
    required List<LeaderAttendanceLogItem> logs,
  }) {
    final today = _ymd(now);
    final yesterdayDate = DateTime(now.year, now.month, now.day - 1);
    final yesterday = _ymd(yesterdayDate);
    final todayDate = DateTime(now.year, now.month, now.day);

    // Log per orang: hari ini, dan kemarin (untuk shift malam)
    final todayLog = <String, LeaderAttendanceLogItem>{};
    final yesterdayLog = <String, LeaderAttendanceLogItem>{};
    for (final log in logs) {
      if (!_hasValue(log.checkIn)) continue;
      final key = log.date.length >= 10 ? log.date.substring(0, 10) : log.date;
      if (key == today) todayLog[log.userId] = log;
      if (key == yesterday) yesterdayLog[log.userId] = log;
    }

    // Jadwal kerja yang berlaku sekarang per orang. Shift malam kemarin yang belum berakhir didahulukan.
    final entries = <String, _Entry>{};
    for (final a in assignments) {
      final shift = a.dailyShift;
      // Hanya hari kerja yang mengharuskan check-in (libur dan hari libur nasional tidak), sama dengan pengingat check-in
      if (shift == null || shift.isOff || (shift.dayType ?? '').toLowerCase() == 'holiday') continue;
      final ownerId = (a.ownerId ?? a.owner?.id ?? '').trim();
      if (ownerId.isEmpty) continue;
      final start = _minutes(shift.startTime);
      final end = _minutes(shift.endTime);
      if (start == null || end == null) continue;
      final name = (a.owner?.name ?? '').trim();

      if (a.date == yesterday && end <= start) {
        final shiftEnd = _at(yesterdayDate, end, addDays: 1);
        if (now.isBefore(shiftEnd)) {
          entries[ownerId] = _Entry(ownerId, name, shift.name, _at(yesterdayDate, start), carryOver: true);
        }
      } else if (a.date == today && !(entries[ownerId]?.carryOver ?? false)) {
        entries[ownerId] = _Entry(ownerId, name, shift.name, _at(todayDate, start), carryOver: false);
      }
    }

    var notStarted = 0, notCheckedIn = 0, working = 0, checkedOut = 0, late = 0;
    final notCheckedInPeople = <TeamDayPerson>[];
    final latePeople = <TeamDayPerson>[];
    final counted = <String>{};

    void countLog(LeaderAttendanceLogItem log, String name, String? shiftName) {
      if (_hasValue(log.checkOut)) {
        checkedOut += 1;
      } else {
        working += 1;
      }
      if (log.status == 'late') {
        late += 1;
        latePeople.add(TeamDayPerson(id: log.userId, name: name, shiftName: shiftName));
      }
    }

    for (final e in entries.values) {
      counted.add(e.ownerId);
      final log = e.carryOver ? yesterdayLog[e.ownerId] : (todayLog[e.ownerId] ?? _openLog(yesterdayLog[e.ownerId]));
      final name = e.name.isNotEmpty ? e.name : (log?.userName.trim() ?? '');
      if (log != null) {
        countLog(log, name, e.shiftName);
      } else if (now.isBefore(e.start)) {
        notStarted += 1;
      } else {
        notCheckedIn += 1;
        notCheckedInPeople.add(TeamDayPerson(id: e.ownerId, name: name, shiftName: e.shiftName));
      }
    }

    // Anggota yang tidak punya jadwal hari ini tetapi tercatat check-in tetap dihitung
    for (final log in [...todayLog.values, ...yesterdayLog.values.map(_openLog).whereType<LeaderAttendanceLogItem>()]) {
      if (counted.contains(log.userId)) continue;
      counted.add(log.userId);
      final effective = todayLog[log.userId] ?? log;
      countLog(effective, effective.userName.trim(), effective.shiftName);
    }

    int byName(TeamDayPerson a, TeamDayPerson b) => a.name.toLowerCase().compareTo(b.name.toLowerCase());
    notCheckedInPeople.sort(byName);
    latePeople.sort(byName);
    return TeamDayStats(
      notStarted: notStarted,
      notCheckedIn: notCheckedIn,
      working: working,
      checkedOut: checkedOut,
      late: late,
      notCheckedInPeople: notCheckedInPeople,
      latePeople: latePeople,
    );
  }

  /// Log kemarin yang masih terbuka (belum check-out): absennya dibawa ke hari ini.
  static LeaderAttendanceLogItem? _openLog(LeaderAttendanceLogItem? log) =>
      log != null && !_hasValue(log.checkOut) ? log : null;
}

class _Entry {
  const _Entry(this.ownerId, this.name, this.shiftName, this.start, {required this.carryOver});

  final String ownerId;
  final String name;
  final String shiftName;
  final DateTime start;
  final bool carryOver;
}
