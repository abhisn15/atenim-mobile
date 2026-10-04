import '../services/api_service.dart';
import '../config/api_config.dart';
import '../models/team_model.dart';
import '../models/shift_model.dart';
import '../models/shift_assignment_model.dart';
import '../models/attendance_model.dart';
import '../models/attendance_alert_model.dart';
import '../models/team_task_model.dart';
import '../models/leader_checkpoint_model.dart';

class TeamServiceException implements Exception {
  final String message;
  final int? statusCode;
  TeamServiceException(this.message, {this.statusCode});

  @override
  String toString() => message;
}

class TeamService {
  final ApiService _apiService = ApiService();

  Future<List<TeamSummary>> getLeaderTeams() async {
    final response = await _apiService.get(ApiConfig.leaderTeams);
    if (response.statusCode == 200) {
      final data = response.data?['data'];
      if (data is List) {
        return data
            .where((e) => e is Map)
            .map(
              (e) => TeamSummary.fromJson(Map<String, dynamic>.from(e as Map)),
            )
            .toList();
      }
      return [];
    }
    throw TeamServiceException(
      response.data?['message']?.toString() ?? 'Gagal memuat team leader',
      statusCode: response.statusCode,
    );
  }

  /// Server membatasi 50 anggota per halaman (min(50, limit)). [limit] harus <= 50: meminta lebih membuat perulangan
  /// berhenti di halaman pertama karena hasilnya selalu lebih sedikit dari yang diminta, dan anggota ke-51 dst hilang.
  Future<List<TeamMember>> getLeaderTeamMembers({
    required String teamId,
    int limit = 50,
    bool fetchAll = true,
  }) async {
    final allMembers = <TeamMember>[];
    var page = 1;

    while (true) {
      final response = await _apiService.get(
        ApiConfig.leaderTeamMembers,
        queryParameters: {'teamId': teamId, 'limit': limit, 'page': page},
      );

      if (response.statusCode != 200) {
        throw TeamServiceException(
          response.data?['message']?.toString() ?? 'Gagal memuat anggota team',
          statusCode: response.statusCode,
        );
      }

      final data = response.data?['data'];
      if (data is! List || data.isEmpty) {
        break;
      }

      final members = data
          .where((e) => e is Map)
          .map((e) => TeamMember.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
      allMembers.addAll(members);

      if (!fetchAll || members.length < limit) {
        break;
      }
      page += 1;
    }

    return allMembers;
  }

  Future<List<TeamSummary>> getMyTeamsWithMembers() async {
    final response = await _apiService.get(ApiConfig.teamMembers);
    if (response.statusCode == 200) {
      final data = response.data?['data'];
      if (data is List) {
        return data
            .where((e) => e is Map)
            .map(
              (e) => TeamSummary.fromJson(Map<String, dynamic>.from(e as Map)),
            )
            .toList();
      }
      return [];
    }
    throw TeamServiceException(
      response.data?['message']?.toString() ?? 'Gagal memuat data team',
      statusCode: response.statusCode,
    );
  }

  Future<List<DailyShift>> getLeaderShiftMaster() async {
    final response = await _apiService.get(
      ApiConfig.leaderShiftMaster,
      queryParameters: {'scope': 'core'},
    );
    if (response.statusCode != 200) {
      throw TeamServiceException(
        response.data?['message']?.toString() ?? 'Gagal memuat master shift',
        statusCode: response.statusCode,
      );
    }
    final data = response.data?['data'];
    if (data is Map && data['daily'] is List) {
      final list = data['daily'] as List;
      return list
          .where((e) => e is Map)
          .map((e) => DailyShift.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    }
    if (data is List) {
      return data
          .where((e) => e is Map)
          .map((e) => DailyShift.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    }
    return [];
  }

  Future<List<ShiftAssignment>> getLeaderShiftAssignments({
    required String teamId,
    required DateTime startDate,
    required DateTime endDate,
    List<String> ownerIds = const [],
  }) async {
    String formatDate(DateTime date) {
      final year = date.year.toString().padLeft(4, '0');
      final month = date.month.toString().padLeft(2, '0');
      final day = date.day.toString().padLeft(2, '0');
      return '$year-$month-$day';
    }

    final params = <String, dynamic>{
      'teamId': teamId,
      'startDate': formatDate(startDate),
      'endDate': formatDate(endDate),
      'mode': 'schedule',
    };

    if (ownerIds.isNotEmpty) {
      params['ownerIds'] = ownerIds;
    }

    final response = await _apiService.get(
      ApiConfig.leaderShiftAssignments,
      queryParameters: params,
    );
    if (response.statusCode != 200) {
      throw TeamServiceException(
        response.data?['message']?.toString() ??
            'Gagal memuat jadwal shift team',
        statusCode: response.statusCode,
      );
    }

    final data = response.data?['data'];
    if (data is List) {
      return data
          .where((e) => e is Map)
          .map(
            (e) =>
                ShiftAssignment.fromJson(Map<String, dynamic>.from(e as Map)),
          )
          .toList();
    }
    return [];
  }

  Future<void> assignShift({
    required String teamId,
    required DateTime date,
    required String dailyShiftId,
    required List<String> ownerIds,
    bool overwrite = false,
  }) async {
    String formatDate(DateTime value) {
      final year = value.year.toString().padLeft(4, '0');
      final month = value.month.toString().padLeft(2, '0');
      final day = value.day.toString().padLeft(2, '0');
      return '$year-$month-$day';
    }

    final response = await _apiService.post(
      ApiConfig.leaderShiftAssignments,
      data: {
        'teamId': teamId,
        'date': formatDate(date),
        'dailyShiftId': dailyShiftId,
        'ownerIds': ownerIds,
        'overwrite': overwrite,
      },
    );

    if (response.statusCode != 200) {
      throw TeamServiceException(
        response.data?['message']?.toString() ?? 'Gagal assign shift',
        statusCode: response.statusCode,
      );
    }
  }

  Future<void> deleteShiftAssignment({
    required String teamId,
    required String assignmentId,
  }) async {
    final response = await _apiService.delete(
      ApiConfig.leaderShiftAssignments,
      data: {'teamId': teamId, 'id': assignmentId},
    );

    if (response.statusCode != 200) {
      throw TeamServiceException(
        response.data?['message']?.toString() ?? 'Gagal menghapus shift',
        statusCode: response.statusCode,
      );
    }
  }

  /// GET leader attendance report for team (for monitoring check-in).
  /// Uses teamId, startDate, endDate, optional page and limit.
  Future<LeaderAttendanceReport> getLeaderAttendance({
    required String teamId,
    required DateTime startDate,
    required DateTime endDate,
    int page = 1,
    int limit = 200,
  }) async {
    String formatDate(DateTime date) {
      final year = date.year.toString().padLeft(4, '0');
      final month = date.month.toString().padLeft(2, '0');
      final day = date.day.toString().padLeft(2, '0');
      return '$year-$month-$day';
    }

    final response = await _apiService.get(
      ApiConfig.leaderAttendance,
      queryParameters: {
        'teamId': teamId,
        'startDate': formatDate(startDate),
        'endDate': formatDate(endDate),
        'page': page,
        'limit': limit,
      },
    );

    if (response.statusCode != 200) {
      throw TeamServiceException(
        response.data?['message']?.toString() ??
            'Gagal memuat laporan kehadiran',
        statusCode: response.statusCode,
      );
    }

    final data = response.data?['data'];
    if (data is! Map<String, dynamic>) {
      return LeaderAttendanceReport(
        summary: LeaderAttendanceReportSummary(
          present: 0,
          absent: 0,
          late: 0,
          leave: 0,
          pendingValidation: 0,
        ),
        logs: [],
        pagination: null,
      );
    }

    return LeaderAttendanceReport.fromJson(data);
  }

  /// Peringatan kehadiran anggota team yang dipimpin (server membatasi ke anggota team milik leader ini).
  /// [kind]: `late`, `missing`, atau `outside`; kosong = semua.
  Future<List<AttendanceAlert>> getAttendanceAlerts({int hours = 24, String? kind}) async {
    final response = await _apiService.get(
      ApiConfig.attendanceAlerts,
      queryParameters: {'hours': hours, if (kind != null) 'kind': kind},
    );
    if (response.statusCode != 200) {
      throw TeamServiceException(
        response.data?['message']?.toString() ?? 'Gagal memuat peringatan kehadiran',
        statusCode: response.statusCode,
      );
    }
    final events = response.data?['data']?['events'];
    if (events is! List) return [];
    return [
      for (final e in events)
        if (e is Map) AttendanceAlert.fromJson(Map<String, dynamic>.from(e)),
    ];
  }

  Future<List<TeamTask>> getLeaderTasks({
    String? teamId,
    String? status,
    String? assigneeId,
    String? search,
    int page = 1,
    int limit = 50,
  }) async {
    final response = await _apiService.get(
      ApiConfig.leaderTasks,
      queryParameters: {
        if (teamId != null && teamId.isNotEmpty) 'teamId': teamId,
        if (status != null && status.isNotEmpty) 'status': status,
        if (assigneeId != null && assigneeId.isNotEmpty)
          'assigneeId': assigneeId,
        if (search != null && search.isNotEmpty) 'search': search,
        'page': page,
        'limit': limit,
      },
    );

    if (response.statusCode != 200) {
      throw TeamServiceException(
        response.data?['message']?.toString() ?? 'Gagal memuat tugas team',
        statusCode: response.statusCode,
      );
    }

    final raw = response.data?['data'];
    if (raw is! List) return [];
    return raw
        .where((e) => e is Map)
        .map((e) => TeamTask.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  Future<TeamTask> createLeaderTask({
    required String teamId,
    required String assigneeId,
    required String title,
    String? description,
    DateTime? dueDate,
    String status = 'todo',
  }) async {
    final response = await _apiService.post(
      ApiConfig.leaderTasks,
      data: {
        'teamId': teamId,
        'assigneeId': assigneeId,
        'title': title,
        'description': description,
        'dueDate': dueDate?.toIso8601String(),
        'status': status,
      },
    );

    if (response.statusCode != 200) {
      throw TeamServiceException(
        response.data?['message']?.toString() ?? 'Gagal membuat tugas team',
        statusCode: response.statusCode,
      );
    }

    final data = response.data?['data'];
    if (data is! Map) {
      throw TeamServiceException('Respons tugas tidak valid');
    }
    return TeamTask.fromJson(Map<String, dynamic>.from(data));
  }

  Future<TeamTask> updateLeaderTask(
    String taskId, {
    String? title,
    String? description,
    String? status,
    DateTime? dueDate,
    String? assigneeId,
  }) async {
    final response = await _apiService.patch(
      '${ApiConfig.leaderTasks}/$taskId',
      data: {
        if (title != null) 'title': title,
        if (description != null) 'description': description,
        if (status != null) 'status': status,
        if (dueDate != null) 'dueDate': dueDate.toIso8601String(),
        if (assigneeId != null) 'assigneeId': assigneeId,
      },
    );

    if (response.statusCode != 200) {
      throw TeamServiceException(
        response.data?['message']?.toString() ?? 'Gagal memperbarui tugas team',
        statusCode: response.statusCode,
      );
    }

    final data = response.data?['data'];
    if (data is! Map) {
      throw TeamServiceException('Respons tugas tidak valid');
    }
    return TeamTask.fromJson(Map<String, dynamic>.from(data));
  }

  Future<void> deleteLeaderTask(String taskId) async {
    final response = await _apiService.delete(
      '${ApiConfig.leaderTasks}/$taskId',
    );
    if (response.statusCode != 200) {
      throw TeamServiceException(
        response.data?['message']?.toString() ?? 'Gagal menghapus tugas team',
        statusCode: response.statusCode,
      );
    }
  }

  Future<List<TeamTask>> getMyTasks({
    String? status,
    int page = 1,
    int limit = 50,
    bool fetchAll = false,
  }) async {
    final all = <TeamTask>[];
    var currentPage = page;
    while (true) {
      final response = await _apiService.get(
        ApiConfig.essTasks,
        queryParameters: {
          if (status != null && status.isNotEmpty) 'status': status,
          'page': currentPage,
          'limit': limit,
        },
      );

      if (response.statusCode != 200) {
        throw TeamServiceException(
          response.data?['message']?.toString() ?? 'Gagal memuat tugas Anda',
          statusCode: response.statusCode,
        );
      }

      final raw = response.data?['data'];
      if (raw is! List || raw.isEmpty) break;
      final mapped = raw
          .where((e) => e is Map)
          .map((e) => TeamTask.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
      all.addAll(mapped);

      if (!fetchAll || mapped.length < limit) break;
      currentPage += 1;
    }

    return all;
  }

  Future<List<TeamTask>> getMyOpenTasks({int limit = 100}) async {
    final open = await Future.wait([
      getMyTasks(status: 'todo', limit: limit, fetchAll: true),
      getMyTasks(status: 'in_progress', limit: limit, fetchAll: true),
    ]);

    final byId = <String, TeamTask>{};
    for (final list in open) {
      for (final task in list) {
        byId[task.id] = task;
      }
    }

    final merged = byId.values.toList();
    merged.sort((a, b) {
      final aDue = a.dueDate;
      final bDue = b.dueDate;
      if (aDue == null && bDue == null) {
        return b.createdAt.compareTo(a.createdAt);
      }
      if (aDue == null) return 1;
      if (bDue == null) return -1;
      final dueCompare = aDue.compareTo(bDue);
      if (dueCompare != 0) return dueCompare;
      return b.createdAt.compareTo(a.createdAt);
    });
    return merged;
  }

  Future<TeamTask> updateMyTaskStatus(
    String taskId,
    String status, {
    String? proofActivityId,
  }) async {
    final response = await _apiService.patch(
      '${ApiConfig.essTasks}/$taskId',
      data: {
        'status': status,
        if (proofActivityId != null && proofActivityId.isNotEmpty)
          'proofActivityId': proofActivityId,
      },
    );

    if (response.statusCode != 200) {
      throw TeamServiceException(
        response.data?['message']?.toString() ??
            'Gagal memperbarui status tugas',
        statusCode: response.statusCode,
      );
    }

    final data = response.data?['data'];
    if (data is! Map) {
      throw TeamServiceException('Respons tugas tidak valid');
    }
    return TeamTask.fromJson(Map<String, dynamic>.from(data));
  }

  Future<List<LeaderCheckpointTemplateOption>> getLeaderCheckpointTemplates({
    String? search,
    int page = 1,
    int limit = 100,
  }) async {
    final response = await _apiService.get(
      ApiConfig.leaderCheckpointTemplates,
      queryParameters: {
        if (search != null && search.isNotEmpty) 'search': search,
        'page': page,
        'limit': limit,
      },
    );

    if (response.statusCode != 200) {
      throw TeamServiceException(
        response.data?['message']?.toString() ??
            'Gagal memuat template checkpoint',
        statusCode: response.statusCode,
      );
    }

    final payload = response.data?['data'];
    final rawTemplates = payload is Map ? payload['templates'] : null;
    if (rawTemplates is! List) return [];

    return rawTemplates
        .whereType<Map>()
        .map(
          (entry) => LeaderCheckpointTemplateOption.fromJson(
            Map<String, dynamic>.from(entry),
          ),
        )
        .toList();
  }

  Future<LeaderCheckpointMonitoringResult> getLeaderCheckpointMonitoring({
    required DateTime date,
    String? search,
    int page = 1,
    int limit = 250,
  }) async {
    final year = date.year.toString().padLeft(4, '0');
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    final dateText = '$year-$month-$day';

    final response = await _apiService.get(
      ApiConfig.leaderCheckpointProgress,
      queryParameters: {
        'date': dateText,
        if (search != null && search.isNotEmpty) 'search': search,
        'page': page,
        'limit': limit,
      },
    );

    if (response.statusCode != 200) {
      throw TeamServiceException(
        response.data?['message']?.toString() ??
            'Gagal memuat monitoring checkpoint',
        statusCode: response.statusCode,
      );
    }

    final payload = response.data?['data'];
    if (payload is! Map<String, dynamic>) {
      return LeaderCheckpointMonitoringResult.fromJson(const {
        'items': [],
        'pagination': {'page': 1, 'limit': 50, 'total': 0, 'totalPages': 1},
      });
    }

    return LeaderCheckpointMonitoringResult.fromJson(payload);
  }

  Future<void> createLeaderCheckpointAssignment({
    required String templateId,
    required List<String> userIds,
    required DateTime date,
  }) async {
    final cleanedUserIds = userIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList();
    if (cleanedUserIds.isEmpty) {
      throw TeamServiceException('Pilih minimal 1 karyawan');
    }

    final year = date.year.toString().padLeft(4, '0');
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    final dateText = '$year-$month-$day';

    final response = await _apiService.post(
      ApiConfig.leaderCheckpointAssignments,
      data: {
        'templateId': templateId,
        'userIds': cleanedUserIds,
        'startDate': dateText,
        'endDate': dateText,
        'scheduleType': 'daily',
      },
    );

    if (response.statusCode != 200) {
      throw TeamServiceException(
        response.data?['message']?.toString() ??
            'Gagal menambah tugas checkpoint',
        statusCode: response.statusCode,
      );
    }
  }
}
