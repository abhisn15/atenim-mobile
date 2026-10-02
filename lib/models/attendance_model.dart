import 'package:flutter/foundation.dart';

import '../utils/clock.dart' show workedMinutes;

class AttendanceRecord {
  final String id;
  final String userId;
  final String date;
  final String status; // present, late, absent, leave, sick, remote
  final String? checkIn;
  final String? checkOut;
  /// Waktu penuh (tanggal + jam) check-in/out dari server, zona waktu perangkat. Dipakai untuk menghitung lama kerja:
  /// teks "HH:mm" tidak membawa tanggal sehingga shift lintas hari salah hitung.
  final DateTime? checkInAt;
  final DateTime? checkOutAt;
  final String? originalCheckInDate;
  final String? shiftId;
  final String? notes;
  final String?
  photoUrl; // Deprecated: use checkInPhotoUrl and checkOutPhotoUrl instead
  final String? checkInPhotoUrl;
  final String? checkOutPhotoUrl;
  final Location?
  location; // Deprecated: use checkInLocation and checkOutLocation instead
  final Location? checkInLocation;
  final Location? checkOutLocation;
  final bool isAutoCheckout;
  final bool needsValidation;
  final String? breakStatus;
  final String? breakStart;
  final String? breakEnd;
  final int? breakDurationMinutes;
  final int? breakOverByMinutes;
  final String? breakReason;

  AttendanceRecord({
    required this.id,
    required this.userId,
    required this.date,
    required this.status,
    this.checkIn,
    this.checkOut,
    this.checkInAt,
    this.checkOutAt,
    this.originalCheckInDate,
    this.shiftId,
    this.notes,
    this.photoUrl,
    this.checkInPhotoUrl,
    this.checkOutPhotoUrl,
    this.location,
    this.checkInLocation,
    this.checkOutLocation,
    this.isAutoCheckout = false,
    this.needsValidation = false,
    this.breakStatus,
    this.breakStart,
    this.breakEnd,
    this.breakDurationMinutes,
    this.breakOverByMinutes,
    this.breakReason,
  });

  static DateTime? _parseInstant(dynamic raw) {
    if (raw is! String || raw.trim().isEmpty) return null;
    return DateTime.tryParse(raw)?.toLocal();
  }

  /// Lama kerja kotor (menit, belum dikurangi istirahat) dari waktu penuh masuk sampai pulang, jadi masuk 07:00
  /// kemarin dan pulang 10:00 hari ini = 27 jam. Bila belum pulang dan [now] diberikan, dihitung sampai [now].
  /// Tanpa waktu penuh (data lama/cache lama) jatuh ke selisih "HH:mm" yang paling jauh 24 jam. Null bila tak terbaca.
  int? workDurationMinutes({DateTime? now}) {
    final start = checkInAt;
    if (start != null) {
      final end = checkOutAt ?? (checkOut == null ? now : null);
      if (end != null) {
        final diff = end.difference(start).inMinutes;
        // Pulang lebih awal dari masuk = data/jam janggal: lebih baik kosong daripada angka palsu.
        return diff >= 0 ? diff : null;
      }
    }
    if (checkOut == null) {
      // Belum pulang dan tanpa waktu penuh: tidak ada dasar yang benar untuk menghitung.
      return null;
    }
    return workedMinutes(checkIn, checkOut);
  }

  factory AttendanceRecord.fromJson(Map<String, dynamic> json) {
    return AttendanceRecord(
      id: json['id'] as String? ?? '',
      userId: json['userId'] as String? ?? '',
      date: json['date'] as String? ?? '',
      status: json['status'] as String? ?? 'absent',
      checkIn: json['checkIn'] as String?,
      checkOut: json['checkOut'] as String?,
      checkInAt: _parseInstant(json['checkInAt']),
      checkOutAt: _parseInstant(json['checkOutAt']),
      originalCheckInDate: json['originalCheckInDate'] as String?,
      shiftId: json['shiftId'] as String?,
      notes: json['notes'] as String?,
      photoUrl: json['photoUrl'] as String?, // Keep for backward compatibility
      checkInPhotoUrl: json['checkInPhotoUrl'] as String?,
      checkOutPhotoUrl: json['checkOutPhotoUrl'] as String?,
      location: json['location'] != null
          ? Location.fromJson(json['location'] as Map<String, dynamic>)
          : null, // Keep for backward compatibility
      checkInLocation: json['checkInLocation'] != null
          ? Location.fromJson(json['checkInLocation'] as Map<String, dynamic>)
          : null,
      checkOutLocation: json['checkOutLocation'] != null
          ? Location.fromJson(json['checkOutLocation'] as Map<String, dynamic>)
          : null,
      isAutoCheckout: json['isAutoCheckout'] as bool? ?? false,
      needsValidation: json['needsValidation'] as bool? ?? false,
      breakStatus: json['breakStatus'] as String?,
      breakStart: json['breakStart'] as String?,
      breakEnd: json['breakEnd'] as String?,
      breakDurationMinutes: (json['breakDurationMinutes'] as num?)?.toInt(),
      breakOverByMinutes: (json['breakOverByMinutes'] as num?)?.toInt(),
      breakReason: json['breakReason'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'userId': userId,
      'date': date,
      'status': status,
      'checkIn': checkIn,
      'checkOut': checkOut,
      'checkInAt': checkInAt?.toUtc().toIso8601String(),
      'checkOutAt': checkOutAt?.toUtc().toIso8601String(),
      'originalCheckInDate': originalCheckInDate,
      'shiftId': shiftId,
      'notes': notes,
      'photoUrl': photoUrl, // Keep for backward compatibility
      'checkInPhotoUrl': checkInPhotoUrl,
      'checkOutPhotoUrl': checkOutPhotoUrl,
      'location': location?.toJson(), // Keep for backward compatibility
      'checkInLocation': checkInLocation?.toJson(),
      'checkOutLocation': checkOutLocation?.toJson(),
      'isAutoCheckout': isAutoCheckout,
      'needsValidation': needsValidation,
      'breakStatus': breakStatus,
      'breakStart': breakStart,
      'breakEnd': breakEnd,
      'breakDurationMinutes': breakDurationMinutes,
      'breakOverByMinutes': breakOverByMinutes,
      'breakReason': breakReason,
    };
  }
}

class AttendanceBreakSession {
  final String id;
  final String attendanceId;
  final String status;
  final String startAt;
  final String? endAt;
  final int? durationMinutes;
  final int? overByMinutes;
  final String? reason;

  AttendanceBreakSession({
    required this.id,
    required this.attendanceId,
    required this.status,
    required this.startAt,
    this.endAt,
    this.durationMinutes,
    this.overByMinutes,
    this.reason,
  });

  factory AttendanceBreakSession.fromJson(Map<String, dynamic> json) {
    return AttendanceBreakSession(
      id: json['id'] as String? ?? '',
      attendanceId: json['attendanceId'] as String? ?? '',
      status:
          json['tagStatus'] as String? ??
          json['tag_status'] as String? ??
          json['status'] as String? ??
          'NOT_APPLICABLE',
      startAt: json['startAt'] as String? ?? json['start_at'] as String? ?? '',
      endAt: json['endAt'] as String? ?? json['end_at'] as String?,
      durationMinutes: (json['durationMinutes'] as num?)?.toInt(),
      overByMinutes: (json['overByMinutes'] as num?)?.toInt(),
      reason: json['reason'] as String?,
    );
  }
}

class AttendanceBreakState {
  final bool enabled;
  final bool mandatory;
  final bool strict;
  final int maxMinutes;
  final String currentAttendanceState;
  final String breakState;
  final String breakTagStatus;
  final String reviewStatus;
  final List<String> warnings;
  final bool canStart;
  final bool canEnd;
  final List<String> canStartReasons;
  final List<String> canEndReasons;
  final bool canCheckOut;
  final List<String> canCheckOutReasons;
  final String? attendanceId;
  final String? message;
  final AttendanceBreakSession? activeSession;
  final AttendanceBreakSession? latestSession;

  AttendanceBreakState({
    required this.enabled,
    required this.mandatory,
    required this.strict,
    required this.maxMinutes,
    this.currentAttendanceState = 'NOT_CHECKED_IN',
    this.breakState = 'NOT_APPLICABLE',
    this.breakTagStatus = 'NOT_APPLICABLE',
    this.reviewStatus = 'NONE',
    this.warnings = const [],
    required this.canStart,
    required this.canEnd,
    this.canStartReasons = const [],
    this.canEndReasons = const [],
    this.canCheckOut = false,
    this.canCheckOutReasons = const [],
    this.attendanceId,
    this.message,
    this.activeSession,
    this.latestSession,
  });

  factory AttendanceBreakState.fromJson(Map<String, dynamic> json) {
    final availableActionsRaw = json['available_actions'];
    final availableActions = availableActionsRaw is Map<String, dynamic>
        ? availableActionsRaw
        : <String, dynamic>{};

    Map<String, dynamic> _action(String key) {
      final raw = availableActions[key];
      return raw is Map<String, dynamic> ? raw : <String, dynamic>{};
    }

    List<String> _reasons(Map<String, dynamic> action) {
      final raw = action['reason_codes'];
      if (raw is List) {
        return raw.map((e) => e.toString()).toList();
      }
      return const [];
    }

    final startAction = _action('can_start_break');
    final endAction = _action('can_end_break');
    final checkoutAction = _action('can_check_out');

    final activeRaw = json['activeSession'];
    final latestRaw = json['latestSession'];
    final openRaw = json['open_break'];
    final latestNewRaw = json['latest_break'];

    final activeSessionRaw = openRaw is Map<String, dynamic>
        ? openRaw
        : activeRaw is Map<String, dynamic>
            ? activeRaw
            : null;
    final latestSessionRaw = latestNewRaw is Map<String, dynamic>
        ? latestNewRaw
        : latestRaw is Map<String, dynamic>
            ? latestRaw
            : null;

    final warningsRaw = json['warnings'];
    final warnings = warningsRaw is List
        ? warningsRaw.map((e) => e.toString()).toList()
        : const <String>[];

    final canStart = startAction['allowed'] as bool? ?? json['canStart'] as bool? ?? false;
    final canEnd = endAction['allowed'] as bool? ?? json['canEnd'] as bool? ?? false;
    final canCheckOut = checkoutAction['allowed'] as bool? ?? false;

    return AttendanceBreakState(
      enabled: json['enabled'] as bool? ?? false,
      mandatory: json['mandatory'] as bool? ?? false,
      strict: json['strict'] as bool? ?? false,
      maxMinutes: (json['maxMinutes'] as num?)?.toInt() ?? 60,
      currentAttendanceState:
          json['current_attendance_state'] as String? ?? 'NOT_CHECKED_IN',
      breakState: json['break_state'] as String? ?? 'NOT_APPLICABLE',
      breakTagStatus:
          json['break_tag_status'] as String? ??
          json['break_state'] as String? ??
          'NOT_APPLICABLE',
      reviewStatus: json['review_status'] as String? ?? 'NONE',
      warnings: warnings,
      canStart: canStart,
      canEnd: canEnd,
      canStartReasons: _reasons(startAction),
      canEndReasons: _reasons(endAction),
      canCheckOut: canCheckOut,
      canCheckOutReasons: _reasons(checkoutAction),
      attendanceId: json['attendance_id'] as String? ?? json['attendanceId'] as String?,
      message: json['message'] as String?,
      activeSession: activeSessionRaw is Map<String, dynamic>
          ? AttendanceBreakSession.fromJson(activeSessionRaw)
          : null,
      latestSession: latestSessionRaw is Map<String, dynamic>
          ? AttendanceBreakSession.fromJson(latestSessionRaw)
          : null,
    );
  }
}

class Location {
  final double lat;
  final double lng;

  Location({required this.lat, required this.lng});

  factory Location.fromJson(Map<String, dynamic> json) {
    final latVal = json['lat'];
    final lngVal = json['lng'];
    return Location(
      lat: (latVal is num)
          ? latVal.toDouble()
          : (double.tryParse(latVal?.toString() ?? '') ?? 0.0),
      lng: (lngVal is num)
          ? lngVal.toDouble()
          : (double.tryParse(lngVal?.toString() ?? '') ?? 0.0),
    );
  }

  Map<String, dynamic> toJson() {
    return {'lat': lat, 'lng': lng};
  }
}

class AttendancePayload {
  final List<AttendanceRecord> today;
  final List<AttendanceRecord> recent; // Alias untuk history dari backend

  AttendancePayload({required this.today, required this.recent});

  factory AttendancePayload.fromJson(Map<String, dynamic> json) {
    // Backend mengembalikan { today: [...], history: [...] }
    // Kita map history ke recent untuk konsistensi dengan Flutter code
    final historyRaw = json['history'];
    final recentRaw = json['recent'];
    final todayRaw = json['today'];

    // Safely extract history list
    List<dynamic> historyList = [];

    if (historyRaw is List<dynamic>) {
      historyList = historyRaw;
    } else if (recentRaw is List<dynamic>) {
      historyList = recentRaw;
    } else if (historyRaw is Map<String, dynamic>) {
      // If history is a Map, try to convert it to a List
      debugPrint(
        '[AttendancePayload] Warning: history is Map, not List. Converting...',
      );
      historyList = historyRaw.values.toList();
    } else if (recentRaw is Map<String, dynamic>) {
      // If recent is a Map, try to convert it to a List
      debugPrint(
        '[AttendancePayload] Warning: recent is Map, not List. Converting...',
      );
      historyList = recentRaw.values.toList();
    } else {
      debugPrint(
        '[AttendancePayload] Warning: Neither history nor recent is a List. history type: ${historyRaw.runtimeType}, recent type: ${recentRaw.runtimeType}',
      );
    }

    // Safely parse history records
    List<AttendanceRecord> parsedHistory = [];
    try {
      parsedHistory = historyList
          .where((e) => e is Map<String, dynamic>)
          .map((e) => AttendanceRecord.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('[AttendancePayload] Error parsing history records: $e');
      debugPrint('[AttendancePayload] Raw historyList: $historyList');
    }

    // Safely parse today records (list or single object for backward compatibility)
    List<AttendanceRecord> parsedToday = [];
    try {
      if (todayRaw is List<dynamic>) {
        parsedToday = todayRaw
            .where((e) => e is Map<String, dynamic>)
            .map((e) => AttendanceRecord.fromJson(e as Map<String, dynamic>))
            .toList();
      } else if (todayRaw is Map<String, dynamic>) {
        parsedToday = [AttendanceRecord.fromJson(todayRaw)];
      } else if (todayRaw is Map) {
        parsedToday = [
          AttendanceRecord.fromJson(Map<String, dynamic>.from(todayRaw)),
        ];
      }
    } catch (e) {
      debugPrint('[AttendancePayload] Error parsing today records: $e');
      debugPrint('[AttendancePayload] Raw today: $todayRaw');
    }

    return AttendancePayload(today: parsedToday, recent: parsedHistory);
  }

  Map<String, dynamic> toJson() {
    return {
      'today': today.map((e) => e.toJson()).toList(),
      'recent': recent.map((e) => e.toJson()).toList(),
    };
  }
}

/// Summary for leader attendance report (team monitoring).
class LeaderAttendanceReportSummary {
  final int present;
  final int absent;
  final int late;
  final int leave;
  final int pendingValidation;

  LeaderAttendanceReportSummary({
    required this.present,
    required this.absent,
    required this.late,
    required this.leave,
    required this.pendingValidation,
  });

  factory LeaderAttendanceReportSummary.fromJson(Map<String, dynamic> json) {
    return LeaderAttendanceReportSummary(
      present: (json['present'] as num?)?.toInt() ?? 0,
      absent: (json['absent'] as num?)?.toInt() ?? 0,
      late: (json['late'] as num?)?.toInt() ?? 0,
      leave: (json['leave'] as num?)?.toInt() ?? 0,
      pendingValidation: (json['pendingValidation'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Single log row from leader attendance report (for team monitoring list).
class LeaderAttendanceLogItem {
  final String id;
  final String userId;
  final String date;
  final String status;
  final String? checkIn;
  final String? checkOut;
  final String userName;
  final String? shiftName;

  LeaderAttendanceLogItem({
    required this.id,
    required this.userId,
    required this.date,
    required this.status,
    this.checkIn,
    this.checkOut,
    required this.userName,
    this.shiftName,
  });

  factory LeaderAttendanceLogItem.fromJson(Map<String, dynamic> json) {
    final user = json['user'];
    final name = user is Map ? (user['name'] as String? ?? '') : '';
    return LeaderAttendanceLogItem(
      id: json['id'] as String? ?? '',
      userId: json['userId'] as String? ?? '',
      date: json['date'] as String? ?? '',
      status: json['status'] as String? ?? 'absent',
      checkIn: json['checkIn'] as String?,
      checkOut: json['checkOut'] as String?,
      userName: name,
      shiftName: json['shiftName'] as String?,
    );
  }
}

/// Pagination info for leader attendance report.
class LeaderAttendancePagination {
  final int page;
  final int limit;
  final int total;
  final int totalPages;

  LeaderAttendancePagination({
    required this.page,
    required this.limit,
    required this.total,
    required this.totalPages,
  });

  factory LeaderAttendancePagination.fromJson(Map<String, dynamic> json) {
    return LeaderAttendancePagination(
      page: (json['page'] as num?)?.toInt() ?? 1,
      limit: (json['limit'] as num?)?.toInt() ?? 0,
      total: (json['total'] as num?)?.toInt() ?? 0,
      totalPages: (json['totalPages'] as num?)?.toInt() ?? 1,
    );
  }
}

/// Full leader attendance report (team monitoring).
class LeaderAttendanceReport {
  final LeaderAttendanceReportSummary summary;
  final List<LeaderAttendanceLogItem> logs;
  final LeaderAttendancePagination? pagination;

  LeaderAttendanceReport({
    required this.summary,
    required this.logs,
    this.pagination,
  });

  factory LeaderAttendanceReport.fromJson(Map<String, dynamic> json) {
    final summaryJson = json['summary'];
    final logsRaw = json['logs'];
    final paginationJson = json['pagination'];

    final summary = summaryJson is Map<String, dynamic>
        ? LeaderAttendanceReportSummary.fromJson(summaryJson)
        : LeaderAttendanceReportSummary(
            present: 0,
            absent: 0,
            late: 0,
            leave: 0,
            pendingValidation: 0,
          );

    final logs = logsRaw is List
        ? (logsRaw)
              .where((e) => e is Map<String, dynamic>)
              .map(
                (e) =>
                    LeaderAttendanceLogItem.fromJson(e as Map<String, dynamic>),
              )
              .toList()
        : <LeaderAttendanceLogItem>[];

    final pagination = paginationJson is Map<String, dynamic>
        ? LeaderAttendancePagination.fromJson(paginationJson)
        : null;

    return LeaderAttendanceReport(
      summary: summary,
      logs: logs,
      pagination: pagination,
    );
  }
}
