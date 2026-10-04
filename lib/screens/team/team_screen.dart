import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../models/attendance_alert_model.dart';
import '../../models/shift_assignment_model.dart';
import '../../models/shift_model.dart';
import '../../models/team_model.dart';
import '../../providers/auth_provider.dart';
import 'team_tasks_screen.dart';
import 'leader_checkpoint_tasks_screen.dart';
import '../../services/team_service.dart';
import '../../utils/phone_contact.dart';
import '../../utils/team_day_stats.dart';
import '../../widgets/contact_buttons.dart';
import '../../widgets/motion.dart';
import '../../widgets/outside_radius_card.dart';
import '../../widgets/shimmer_loading.dart';
import '../../widgets/team_day_stats_card.dart';
import '../../widgets/ui_kit.dart';

class TeamScreen extends StatefulWidget {
  const TeamScreen({super.key});

  @override
  State<TeamScreen> createState() => _TeamScreenState();
}

class _TeamScreenState extends State<TeamScreen> {
  final TeamService _teamService = TeamService();
  final bool _leaderReadOnly = true;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  static const int _pageSize = 10;
  int _memberPage = 0;

  bool _isLoading = false;
  bool _isManageLoading = false;
  String? _error;
  String? _manageError;

  bool _isLeader = false;
  List<TeamSummary> _leaderTeams = [];
  List<TeamSummary> _myTeams = [];
  Map<String, List<TeamMember>> _leaderMembersByTeam = {};
  Set<String> _selectedLeaderTeamIds = {};
  String? _selectedTeamId; // for employee team selection
  String? _manageTeamId; // for leader manage shift

  // Statistik absensi anggota hari ini (khusus karyawan yang menjadi team leader), diperbarui tiap menit
  TeamDayStats? _dayStats;
  bool _dayStatsLoading = false;
  String? _dayStatsError;
  DateTime? _dayStatsAt;
  Timer? _dayStatsTimer;

  // Peringatan keluar radius 24 jam terakhir (dari /api/attendance-alerts; server membatasi ke anggota team leader ini)
  List<AttendanceAlert>? _outsideAlerts;
  bool _outsideLoading = false;
  String? _outsideError;

  List<TeamMember> _members = [];
  List<TeamMember> _manageMembers = [];
  List<DailyShift> _shifts = [];
  List<ShiftAssignment> _assignments = [];

  String? _selectedMemberId;
  String? _selectedShiftId;
  DateTime _selectedDate = DateTime.now();
  late DateTime _startDate;
  late DateTime _endDate;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _startDate = DateTime(now.year, now.month, 1);
    _endDate = DateTime(now.year, now.month + 1, 0);
    _loadTeamData();
    _dayStatsTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted && _isLeader) _loadDayStats(silent: true);
    });
  }

  @override
  void dispose() {
    _dayStatsTimer?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadTeamData() async {
    if (_isLoading) return;
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final leaderTeams = await _teamService.getLeaderTeams();
      if (!mounted) return;

      if (leaderTeams.isNotEmpty) {
        _isLeader = true;
        _leaderTeams = leaderTeams;
        _myTeams = [];

        if (_manageTeamId == null ||
            !_leaderTeams.any((team) => team.id == _manageTeamId)) {
          _manageTeamId = _leaderTeams.first.id;
        }

        if (_selectedLeaderTeamIds.isEmpty) {
          _selectedLeaderTeamIds = _leaderTeams.map((team) => team.id).toSet();
        }

        _leaderMembersByTeam = await _fetchLeaderMembers(_leaderTeams);
        _members = _mergeLeaderMembers(_selectedLeaderTeamIds);
        _manageMembers = _leaderMembersByTeam[_manageTeamId] ?? [];

        await _loadManageData();
      } else {
        _isLeader = false;
        _leaderTeams = [];
        _leaderMembersByTeam = {};
        _selectedLeaderTeamIds = {};

        _myTeams = await _teamService.getMyTeamsWithMembers();
        if (_myTeams.isNotEmpty) {
          final teamIds = _myTeams.map((team) => team.id).toSet();
          if (_selectedTeamId == null || !teamIds.contains(_selectedTeamId)) {
            _selectedTeamId = _myTeams.first.id;
          }
          final selectedTeam = _myTeams.firstWhere(
            (team) => team.id == _selectedTeamId,
            orElse: () => _myTeams.first,
          );
          _members = selectedTeam.members;
        } else {
          _members = [];
        }
      }
    } on TeamServiceException catch (e) {
      if (e.statusCode == 403) {
        _isLeader = false;
        try {
          _myTeams = await _teamService.getMyTeamsWithMembers();
          if (_myTeams.isNotEmpty) {
            _selectedTeamId = _myTeams.first.id;
            _members = _myTeams.first.members;
          }
        } catch (inner) {
          _error = inner.toString().replaceAll('Exception: ', '');
        }
      } else {
        _error = e.message;
      }
    } catch (e) {
      _error = e.toString().replaceAll('Exception: ', '');
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
        if (_isLeader) unawaited(_loadDayStats());
      }
    }
  }

  /// Absensi anggota hari ini dari semua team yang dipilih. Data kemarin ikut diambil supaya shift malam
  /// (check-in kemarin, belum pulang) dan shift malam yang belum check-in terhitung benar.
  Future<void> _loadDayStats({bool silent = false}) async {
    if (!_isLeader) return;
    unawaited(_loadOutsideAlerts(silent: silent));
    final ids = _selectedLeaderTeamIds.toList();
    if (ids.isEmpty) {
      if (mounted) setState(() => _dayStats = null);
      return;
    }
    if (!silent && mounted) setState(() => _dayStatsLoading = true);
    try {
      final now = DateTime.now();
      final start = DateTime(now.year, now.month, now.day - 1);
      final end = DateTime(now.year, now.month, now.day, 23, 59, 59);
      final perTeam = await Future.wait(ids.map((id) async {
        final assignments = await _teamService.getLeaderShiftAssignments(teamId: id, startDate: start, endDate: end);
        final report = await _teamService.getLeaderAttendance(teamId: id, startDate: start, endDate: end, page: 1, limit: 500);
        return (assignments, report.logs);
      }));
      final stats = TeamDayStats.compute(
        now: now,
        assignments: [for (final t in perTeam) ...t.$1],
        logs: [for (final t in perTeam) ...t.$2],
      );
      if (!mounted) return;
      setState(() {
        _dayStats = stats;
        _dayStatsAt = now;
        _dayStatsLoading = false;
        _dayStatsError = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _dayStatsLoading = false;
        // Angka lama yang masih ada tetap ditampilkan; pesan hanya muncul bila belum pernah berhasil dimuat
        _dayStatsError = 'Statistik hari ini belum bisa dimuat. Tarik layar ke bawah untuk mencoba lagi.';
      });
    }
  }

  Future<void> _loadOutsideAlerts({bool silent = false}) async {
    if (!_isLeader) return;
    if (!silent && mounted) setState(() => _outsideLoading = true);
    try {
      final alerts = await _teamService.getAttendanceAlerts(hours: 24, kind: 'outside');
      if (!mounted) return;
      setState(() {
        _outsideAlerts = alerts;
        _outsideLoading = false;
        _outsideError = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _outsideLoading = false;
        // Daftar lama yang masih ada tetap ditampilkan; pesan hanya muncul bila belum pernah berhasil dimuat
        _outsideError = 'Daftar keluar radius belum bisa dimuat. Tarik layar ke bawah untuk mencoba lagi.';
      });
    }
  }

  Future<Map<String, List<TeamMember>>> _fetchLeaderMembers(
    List<TeamSummary> teams,
  ) async {
    final entries = await Future.wait(
      teams.map((team) async {
        final members = await _teamService.getLeaderTeamMembers(
          teamId: team.id,
        );
        return MapEntry(team.id, members);
      }),
    );
    return Map<String, List<TeamMember>>.fromEntries(entries);
  }

  List<TeamMember> _mergeLeaderMembers(Set<String> teamIds) {
    final map = <String, TeamMember>{};
    for (final teamId in teamIds) {
      final members = _leaderMembersByTeam[teamId] ?? [];
      for (final member in members) {
        if (member.id.isNotEmpty) {
          map[member.id] = member;
        }
      }
    }
    return map.values.toList()..sort((a, b) => a.name.compareTo(b.name));
  }

  List<TeamMember> _filterMembers(List<TeamMember> members) {
    final query = _searchQuery.trim().toLowerCase();
    if (query.isEmpty) return members;
    return members.where((member) {
      final name = member.name.toLowerCase();
      final nik = (member.externalId ?? '').toLowerCase();
      final phone = (member.phone ?? '').toLowerCase();
      final site = (member.siteName ?? '').toLowerCase();
      return name.contains(query) ||
          nik.contains(query) ||
          phone.contains(query) ||
          site.contains(query);
    }).toList();
  }

  List<T> _paginateList<T>(List<T> items, int page) {
    final start = page * _pageSize;
    if (start >= items.length) return [];
    final end = (start + _pageSize).clamp(0, items.length);
    return items.sublist(start, end);
  }

  int _totalPages(int total) {
    if (total == 0) return 1;
    return (total / _pageSize).ceil();
  }

  Widget _buildSearchBar() {
    return TextField(
      controller: _searchController,
      onChanged: (value) {
        setState(() {
          _searchQuery = value;
          _memberPage = 0;
        });
      },
      decoration: InputDecoration(
        prefixIcon: const Icon(Icons.search),
        hintText: 'Cari nama',
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.grey[300]!),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.grey[300]!),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(
            color: Theme.of(context).primaryColor,
            width: 1.5,
          ),
        ),
      ),
    );
  }

  Widget _buildTeamInfoCard(TeamSummary team) {
    return _buildSectionCard(
      title: 'Info Team',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildInfoRow('Nama Team', team.name),
          const SizedBox(height: 8),
          _buildInfoRow('Team Leader', team.leaderName),
          const SizedBox(height: 8),
          _buildInfoRow('Total Anggota', team.memberCount.toString()),
        ],
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Row(
      children: [
        Expanded(
          flex: 2,
          child: Text(
            label,
            style: TextStyle(fontSize: 13, color: AtenimUi.inkSoft),
          ),
        ),
        Expanded(
          flex: 3,
          child: Text(
            value.isNotEmpty ? value : '-',
            style: TextStyle(fontWeight: FontWeight.w600, color: AtenimUi.ink),
          ),
        ),
      ],
    );
  }

  Future<void> _loadManageData() async {
    if (_isManageLoading || !_isLeader || _manageTeamId == null) return;
    setState(() {
      _isManageLoading = true;
      _manageError = null;
    });

    try {
      final shifts = await _teamService.getLeaderShiftMaster();
      final assignments = await _teamService.getLeaderShiftAssignments(
        teamId: _manageTeamId!,
        startDate: _startDate,
        endDate: _endDate,
      );

      final members =
          _leaderMembersByTeam[_manageTeamId] ??
          await _teamService.getLeaderTeamMembers(teamId: _manageTeamId!);
      final memberIds = members
          .map((m) => m.id)
          .where((id) => id.isNotEmpty)
          .toSet();
      final filteredAssignments = assignments.where((assignment) {
        final ownerId = assignment.ownerId ?? assignment.owner?.id;
        if (ownerId == null) return false;
        return memberIds.contains(ownerId);
      }).toList();

      if (!mounted) return;
      setState(() {
        _manageMembers = members;
        _shifts = shifts;
        _assignments = filteredAssignments;

        final memberIds = members.map((m) => m.id).toSet();
        final shiftIds = shifts.map((s) => s.id).toSet();
        if (_selectedMemberId == null ||
            !memberIds.contains(_selectedMemberId)) {
          _selectedMemberId = members.isNotEmpty ? members.first.id : null;
        }
        if (_selectedShiftId == null || !shiftIds.contains(_selectedShiftId)) {
          _selectedShiftId = shifts.isNotEmpty ? shifts.first.id : null;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _manageError = e.toString().replaceAll('Exception: ', '');
      });
    } finally {
      if (mounted) {
        setState(() {
          _isManageLoading = false;
        });
      }
    }
  }

  Future<void> _pickDateRange() async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      initialDateRange: DateTimeRange(start: _startDate, end: _endDate),
      locale: const Locale('id', 'ID'),
      helpText: 'Pilih Rentang Tanggal',
      cancelText: 'Batal',
      confirmText: 'Pilih',
    );
    if (picked != null) {
      setState(() {
        _startDate = picked.start;
        _endDate = picked.end;
      });
      await _loadManageData();
    }
  }

  Future<void> _assignShift() async {
    if (_manageTeamId == null ||
        _selectedMemberId == null ||
        _selectedShiftId == null) {
      return;
    }
    setState(() {
      _isManageLoading = true;
      _manageError = null;
    });
    try {
      await _teamService.assignShift(
        teamId: _manageTeamId!,
        date: _selectedDate,
        dailyShiftId: _selectedShiftId!,
        ownerIds: [_selectedMemberId!],
      );
      await _loadManageData();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Shift anggota berhasil ditambahkan'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.toString().replaceAll('Exception: ', '')),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isManageLoading = false;
        });
      }
    }
  }

  Future<void> _deleteAssignment(ShiftAssignment assignment) async {
    if (_manageTeamId == null) return;
    setState(() {
      _isManageLoading = true;
    });
    try {
      await _teamService.deleteShiftAssignment(
        teamId: _manageTeamId!,
        assignmentId: assignment.id,
      );
      await _loadManageData();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.toString().replaceAll('Exception: ', '')),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isManageLoading = false;
        });
      }
    }
  }

  TeamSummary? _currentTeam() {
    return _myTeams.firstWhere(
      (team) => team.id == _selectedTeamId,
      orElse: () => _myTeams.isNotEmpty
          ? _myTeams.first
          : TeamSummary(id: '', name: '-', leaderName: '-', memberCount: 0),
    );
  }

  bool _isSameDate(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  ShiftAssignment? _findAssignmentFor(DateTime date, String? memberId) {
    if (memberId == null) return null;
    for (final assignment in _assignments) {
      if (assignment.ownerId != memberId) continue;
      final parsed = DateTime.tryParse(assignment.date);
      if (parsed == null) continue;
      if (_isSameDate(parsed, date)) {
        return assignment;
      }
    }
    return null;
  }

  List<DateTime> _buildDateRange() {
    final dates = <DateTime>[];
    var current = DateTime(_startDate.year, _startDate.month, _startDate.day);
    final end = DateTime(_endDate.year, _endDate.month, _endDate.day);
    while (!current.isAfter(end)) {
      dates.add(current);
      current = current.add(const Duration(days: 1));
    }
    return dates;
  }

  void _openLeaderCheckpointTasksScreen() {
    final membersByTeam = <String, List<TeamMember>>{};
    membersByTeam.addAll(_leaderMembersByTeam);

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LeaderCheckpointTasksScreen(
          teams: _leaderTeams,
          membersByTeam: membersByTeam,
          initialTeamId: _manageTeamId,
        ),
      ),
    );
  }

  void _openLeaderManualTasksScreen() {
    final membersByTeam = <String, List<TeamMember>>{};
    membersByTeam.addAll(_leaderMembersByTeam);

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TeamTasksScreen(
          isLeader: true,
          teams: _leaderTeams,
          membersByTeam: membersByTeam,
          initialTeamId: _manageTeamId,
        ),
      ),
    );
  }

  void _openTeamTasksScreen() {
    if (_isLeader) {
      _openLeaderManualTasksScreen();
      return;
    }
    final membersByTeam = <String, List<TeamMember>>{};
    for (final team in _myTeams) {
      membersByTeam[team.id] = team.members;
    }

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TeamTasksScreen(
          isLeader: false,
          teams: _myTeams,
          membersByTeam: membersByTeam,
          initialTeamId: _selectedTeamId,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = Provider.of<AuthProvider>(context).user;
    final currentUserId = user?.id;

    return Scaffold(
      appBar: AppBar(title: const Text('Team')),
      body: RefreshIndicator(
        onRefresh: _loadTeamData,
        child: ListView(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 16,
            bottom: 16 + MediaQuery.of(context).padding.bottom,
          ),
          children: [
            if (_isLoading)
              _buildSkeletonScreen()
            else if (_error != null)
              _buildErrorCard()
            else ...[
              if (_isLeader) _buildLeaderSummary(),
              if (_isLeader) const SizedBox(height: 16),
              if (_isLeader) _buildLeaderTeamFilter(),
              if (_isLeader) const SizedBox(height: 12),
              if (!_isLeader && _myTeams.length > 1)
                _buildEmployeeTeamSelector(),
              if (!_isLeader && _myTeams.length > 1) const SizedBox(height: 12),
              if (!_isLeader && _myTeams.isNotEmpty)
                _buildTeamInfoCard(_currentTeam()!),
              if (!_isLeader && _myTeams.isNotEmpty) const SizedBox(height: 12),
              if (!_isLeader && _myTeams.isNotEmpty) _buildSearchBar(),
              if (!_isLeader && _myTeams.isNotEmpty) const SizedBox(height: 12),
              if (_isLeader)
                _buildMemberList(currentUserId)
              else
                _buildMemberTable(currentUserId),
              if (_isLeader) const SizedBox(height: 12),
              if (_isLeader)
                _buildSectionCard(
                  title: 'Tugas Team',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ElevatedButton.icon(
                        onPressed: _leaderTeams.isEmpty
                            ? null
                            : _openLeaderCheckpointTasksScreen,
                        icon: const Icon(Icons.assignment_outlined),
                        label: const Text('Monitoring Checkpoint Anggota'),
                      ),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: _leaderTeams.isEmpty
                            ? null
                            : _openLeaderManualTasksScreen,
                        icon: const Icon(Icons.playlist_add_check),
                        label: const Text('Tambah Tugas Manual Anggota'),
                      ),
                    ],
                  ),
                ),
              if (!_isLeader) const SizedBox(height: 12),
              if (!_isLeader)
                _buildSectionCard(
                  title: 'Tugas Team',
                  child: SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _myTeams.isEmpty ? null : _openTeamTasksScreen,
                      icon: const Icon(Icons.assignment_outlined),
                      label: const Text('Lihat Tugas Saya'),
                    ),
                  ),
                ),
              if (_isLeader) const SizedBox(height: 20),
              if (_isLeader) _buildManageShiftSection(),
            ],
          ],
        ),
      ),
    );
  }

  /// Total anggota dari backend (memberCount per team) agar sama dengan web app.
  int _totalMembersFromBackend() {
    return _leaderTeams
        .where((t) => _selectedLeaderTeamIds.contains(t.id))
        .fold<int>(0, (sum, t) => sum + t.memberCount);
  }

  Widget _buildLeaderSummary() {
    final totalMembers = _totalMembersFromBackend();
    return FadeSlideIn(
      key: const ValueKey('team-kpi'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: _buildKpiCard(
                  label: 'Team dipimpin',
                  value: _leaderTeams.length.toString(),
                  icon: Icons.groups_outlined,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildKpiCard(
                  label: 'Total anggota',
                  value: totalMembers.toString(),
                  icon: Icons.people_outline,
                ),
              ),
            ],
          ),
          if (_selectedLeaderTeamIds.isNotEmpty) ...[
            const SizedBox(height: 12),
            TeamDayStatsCard(
              stats: _dayStats,
              loading: _dayStatsLoading,
              error: _dayStatsError,
              updatedAt: _dayStatsAt,
              onShowAttention: _showAttentionSheet,
            ),
            const SizedBox(height: 12),
            OutsideRadiusCard(
              // Mengikuti filter team yang sedang dipilih, tanpa memuat ulang
              people: _outsideAlerts == null
                  ? null
                  : groupOutsideRadius(
                      _outsideAlerts!,
                      onlyUserIds: _mergeLeaderMembers(_selectedLeaderTeamIds).map((m) => m.id).toSet(),
                    ),
              loading: _outsideLoading,
              error: _outsideError,
              leaderName: Provider.of<AuthProvider>(context, listen: false).user?.name ?? '',
            ),
          ],
        ],
      ),
    );
  }

  String? _phoneOf(String memberId) {
    for (final list in _leaderMembersByTeam.values) {
      for (final m in list) {
        if (m.id == memberId) return m.phone;
      }
    }
    return null;
  }

  /// Daftar anggota yang belum check-in dan yang terlambat, dengan tombol telepon dan WhatsApp untuk menanyakan sebabnya.
  void _showAttentionSheet() {
    final stats = _dayStats;
    if (stats == null) return;
    final leaderName = Provider.of<AuthProvider>(context, listen: false).user?.name ?? '';

    Widget section(String title, List<TeamDayPerson> people, ContactReason reason) {
      if (people.isEmpty) return const SizedBox.shrink();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 4),
            child: Text('$title (${people.length})', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
          ),
          for (final p in people)
            Row(
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(p.name.isEmpty ? '-' : p.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                        if ((p.shiftName ?? '').isNotEmpty)
                          Text(p.shiftName!, style: TextStyle(fontSize: 12, color: AtenimUi.inkSoft)),
                        if (normalizeIndonesianPhone(_phoneOf(p.id)) == null)
                          Text('Nomor HP belum diisi', style: TextStyle(fontSize: 12, color: AtenimUi.inkSoft)),
                      ],
                    ),
                  ),
                ),
                ContactButtons(phone: _phoneOf(p.id), memberName: p.name, leaderName: leaderName, reason: reason),
              ],
            ),
        ],
      );
    }

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(sheetContext).size.height * 0.7),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Perlu dihubungi', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
                const SizedBox(height: 2),
                Text(
                  'Tanyakan sebabnya lewat WhatsApp atau telepon.',
                  style: TextStyle(fontSize: 13, color: AtenimUi.inkSoft),
                ),
                section('Belum check-in', stats.notCheckedInPeople, ContactReason.notCheckedIn),
                section('Terlambat', stats.latePeople, ContactReason.late),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLeaderTeamFilter() {
    if (_leaderTeams.isEmpty) return const SizedBox.shrink();
    final allSelected = _selectedLeaderTeamIds.length == _leaderTeams.length;

    return _buildSectionCard(
      title: 'Filter Team',
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            FilterChip(
              label: const Text('Semua'),
              selected: allSelected,
              onSelected: (selected) {
                setState(() {
                  if (selected) {
                    _selectedLeaderTeamIds = _leaderTeams
                        .map((team) => team.id)
                        .toSet();
                  } else {
                    _selectedLeaderTeamIds = {};
                  }
                  _members = _mergeLeaderMembers(_selectedLeaderTeamIds);
                });
                _loadDayStats();
              },
            ),
            const SizedBox(width: 8),
            ..._leaderTeams.map((team) {
              final selected = _selectedLeaderTeamIds.contains(team.id);
              final label = team.name.isNotEmpty
                  ? team.name
                  : '(Tanpa Nama Team)';
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: FilterChip(
                  label: Text(label),
                  selected: selected,
                  onSelected: (value) {
                    setState(() {
                      if (value) {
                        _selectedLeaderTeamIds.add(team.id);
                      } else {
                        _selectedLeaderTeamIds.remove(team.id);
                      }
                      _members = _mergeLeaderMembers(_selectedLeaderTeamIds);
                    });
                    _loadDayStats();
                  },
                ),
              );
            }).toList(),
          ],
        ),
      ),
    );
  }

  Widget _buildEmployeeTeamSelector() {
    return _buildSectionCard(
      title: 'Pilih Team',
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: _selectedTeamId,
          isExpanded: true,
          items: _myTeams
              .map(
                (team) => DropdownMenuItem(
                  value: team.id,
                  child: Text(
                    team.leaderName.isNotEmpty
                        ? '${team.leaderName} — ${team.name.isNotEmpty ? team.name : '(Tanpa Nama Team)'}'
                        : (team.name.isNotEmpty
                              ? team.name
                              : '(Tanpa Nama Team)'),
                  ),
                ),
              )
              .toList(),
          onChanged: (value) {
            if (value == null || value == _selectedTeamId) return;
            final selected = _myTeams.firstWhere(
              (team) => team.id == value,
              orElse: () => _myTeams.first,
            );
            setState(() {
              _selectedTeamId = value;
              _members = selected.members;
              _memberPage = 0;
            });
          },
        ),
      ),
    );
  }

  Widget _buildMemberList(String? currentUserId) {
    final filtered = _filterMembers(_members);
    final totalMembers = _totalMembersFromBackend();
    return _buildSectionCard(
      title: 'Anggota Team',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            totalMembers > 0
                ? 'Total anggota: $totalMembers'
                : 'Belum ada anggota team',
            style: TextStyle(color: Colors.grey.shade700),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _members.isEmpty
                  ? null
                  : () => _showMembersModal(currentUserId),
              icon: const Icon(Icons.people_alt_outlined),
              label: const Text('Lihat Anggota'),
            ),
          ),
        ],
      ),
    );
  }

  void _showMembersModal(String? currentUserId) {
    final controller = TextEditingController(text: _searchQuery);
    int page = _memberPage;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            final filtered = _filterMembers(_members);
            final totalPages = _totalPages(filtered.length);
            if (page >= totalPages) page = 0;
            final pageItems = _paginateList(filtered, page);
            final maxHeight = MediaQuery.of(context).size.height * 0.6;

            return Padding(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 16,
                bottom:
                    16 +
                    MediaQuery.of(context).padding.bottom +
                    MediaQuery.of(context).viewInsets.bottom,
              ),
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: maxHeight),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Daftar Anggota',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => Navigator.pop(context),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: controller,
                      onChanged: (value) {
                        setState(() {
                          _searchQuery = value;
                          _memberPage = 0;
                        });
                        setModalState(() {
                          page = 0;
                        });
                      },
                      decoration: InputDecoration(
                        prefixIcon: const Icon(Icons.search),
                        hintText: 'Cari nama',
                        filled: true,
                        fillColor: Colors.grey.shade100,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: Colors.grey[300]!),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: Colors.grey[300]!),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(
                            color: Theme.of(context).primaryColor,
                            width: 1.5,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (filtered.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        child: Text(
                          'Tidak ada anggota sesuai pencarian',
                          style: TextStyle(color: Colors.grey.shade600),
                        ),
                      )
                    else
                      Flexible(
                        child: ListView.separated(
                          shrinkWrap: true,
                          itemCount: pageItems.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 8),
                          itemBuilder: (context, index) => _buildMemberCard(
                            pageItems[index],
                            currentUserId: currentUserId,
                          ),
                        ),
                      ),
                    if (filtered.isNotEmpty) const SizedBox(height: 8),
                    if (filtered.isNotEmpty)
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          TextButton(
                            onPressed: page > 0
                                ? () {
                                    setModalState(() {
                                      page -= 1;
                                    });
                                  }
                                : null,
                            child: const Text('Sebelumnya'),
                          ),
                          Text('Hal ${page + 1} / $totalPages'),
                          TextButton(
                            onPressed: page + 1 < totalPages
                                ? () {
                                    setModalState(() {
                                      page += 1;
                                    });
                                  }
                                : null,
                            child: const Text('Berikutnya'),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildMemberTable(String? currentUserId) {
    if (_members.isEmpty && _myTeams.isEmpty) {
      return _buildSectionCard(
        title: 'Susunan Team',
        child: Text(
          'Akun Anda belum tergabung di team mana pun. Hubungi leader atau admin untuk ditambahkan.',
          style: TextStyle(color: AtenimUi.inkSoft, height: 1.4),
        ),
      );
    }

    final team = _currentTeam();
    final leaderName = (team?.leaderName ?? '').isNotEmpty
        ? team!.leaderName
        : 'Tanpa leader';
    final filtered = _filterMembers(_members);
    final totalPages = _totalPages(filtered.length);
    final effectivePage = totalPages > 0
        ? _memberPage.clamp(0, totalPages - 1)
        : 0;
    final pageItems = _paginateList(filtered, effectivePage);

    return _buildSectionCard(
      title: 'Susunan Team',
      child: Column(
        children: [
          _buildPersonRow(name: leaderName, subtitle: 'Leader team', isLeader: true),
          if (filtered.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                'Tidak ada anggota yang cocok dengan pencarian.',
                style: TextStyle(color: AtenimUi.inkSoft),
              ),
            )
          else
            ...pageItems.map((member) {
              final isMe = member.id.isNotEmpty && member.id == currentUserId;
              return _buildPersonRow(
                name: member.name,
                subtitle: member.title ?? member.positionName ?? 'Anggota',
                isMe: isMe,
              );
            }),
          if (filtered.isNotEmpty && totalPages > 1) ...[
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                TextButton(
                  onPressed: effectivePage > 0
                      ? () => setState(() => _memberPage = effectivePage - 1)
                      : null,
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  child: const Text('Sebelumnya'),
                ),
                Text(
                  'Halaman ${effectivePage + 1} dari $totalPages',
                  style: TextStyle(fontSize: 13, color: AtenimUi.inkSoft),
                ),
                TextButton(
                  onPressed: effectivePage + 1 < totalPages
                      ? () => setState(() => _memberPage = effectivePage + 1)
                      : null,
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  child: const Text('Berikutnya'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPersonRow({
    required String name,
    required String subtitle,
    bool isLeader = false,
    bool isMe = false,
  }) {
    final initials = name.trim().isEmpty
        ? '?'
        : name
              .trim()
              .split(RegExp(r'\s+'))
              .map((part) => part[0])
              .take(2)
              .join()
              .toUpperCase();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          CircleAvatar(
            radius: 20,
            backgroundColor: isLeader ? AtenimUi.brandSoft : Colors.grey[100],
            child: Text(
              initials,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: isLeader ? Colors.blue[800] : Colors.grey[800],
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: AtenimUi.ink,
                  ),
                ),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: AtenimUi.inkSoft),
                ),
              ],
            ),
          ),
          if (isLeader)
            const StatusPill(label: 'Leader', tone: Tone.info)
          else if (isMe)
            const StatusPill(label: 'Anda', tone: Tone.success),
        ],
      ),
    );
  }

  Widget _buildManageShiftSection() {
    final dateFormatter = DateFormat('dd MMM yyyy', 'id_ID');
    final totalAssignments = _assignments.length;
    final uniqueMembers = _assignments
        .map((assignment) => assignment.ownerId ?? assignment.owner?.id)
        .whereType<String>()
        .toSet()
        .length;
    final bkoCount = _assignments.where(_isBackupAssignment).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Jadwal Shift Team',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
        ),
        if (_leaderReadOnly) ...[
          const SizedBox(height: 6),
          Text(
            'Leader hanya bisa memantau jadwal. Jika ada kesalahan, hubungi supervisor.',
            style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
          ),
        ],
        const SizedBox(height: 12),
        Builder(
          builder: (context) {
            final teamCard = _buildSectionCard(
              title: 'Team',
              child: _leaderTeams.length <= 1
                  ? Text(
                      _leaderTeams.isNotEmpty ? _leaderTeams.first.name : '-',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    )
                  : DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: _manageTeamId,
                        isExpanded: true,
                        items: _leaderTeams
                            .map(
                              (team) => DropdownMenuItem(
                                value: team.id,
                                child: Text(team.name),
                              ),
                            )
                            .toList(),
                        onChanged: (value) async {
                          if (value == null || value == _manageTeamId) return;
                          setState(() {
                            _manageTeamId = value;
                            _manageMembers = _leaderMembersByTeam[value] ?? [];
                          });
                          await _loadManageData();
                        },
                      ),
                    ),
            );
            final quickActionCard = _buildSectionCard(
              title: 'Aksi Cepat',
              child: _isManageLoading
                  ? Column(
                      children: [
                        ShimmerLoading(
                          width: double.infinity,
                          height: 44,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        const SizedBox(height: 10),
                        ShimmerLoading(
                          width: double.infinity,
                          height: 44,
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        OutlinedButton.icon(
                          onPressed: _manageTeamId == null
                              ? null
                              : _showScheduleModal,
                          icon: const Icon(Icons.calendar_month_outlined),
                          label: const Text('Lihat Jadwal'),
                        ),
                        const SizedBox(height: 10),
                        OutlinedButton.icon(
                          onPressed: _manageTeamId == null
                              ? null
                              : () {
                                  final teamName =
                                      _leaderTeams
                                          .where((t) => t.id == _manageTeamId)
                                          .map((t) => t.name)
                                          .firstOrNull ??
                                      '';
                                  Navigator.pushNamed(
                                    context,
                                    '/team_monitoring_detail',
                                    arguments: {
                                      'teamId': _manageTeamId!,
                                      'teamName': teamName,
                                    },
                                  );
                                },
                          icon: const Icon(Icons.people_outline),
                          label: const Text('Monitoring Check-in'),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          'Total jadwal di rentang ini: $totalAssignments',
                          style: TextStyle(
                            color: Colors.grey.shade600,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
            );
            final dateCard = _buildSectionCard(
              title: 'Rentang Tanggal',
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${dateFormatter.format(_startDate)} - ${dateFormatter.format(_endDate)}',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                  TextButton(
                    onPressed: _pickDateRange,
                    child: const Text('Ubah'),
                  ),
                ],
              ),
            );

            final monitoringCard = _buildMonitoringSummaryCard(
              totalAssignments: totalAssignments,
              uniqueMembers: uniqueMembers,
              bkoCount: bkoCount,
            );

            // Always take all the cards full width (single column)
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                teamCard,
                const SizedBox(height: 12),
                dateCard,
                const SizedBox(height: 12),
                quickActionCard,
                const SizedBox(height: 12),
                monitoringCard,
              ],
            );
          },
        ),
        if (_manageError != null) ...[
          const SizedBox(height: 12),
          _buildErrorCard(message: _manageError, onRetry: _loadManageData),
        ],
      ],
    );
  }

  bool _isBackupAssignment(ShiftAssignment assignment) {
    final note = assignment.notes?.toLowerCase() ?? '';
    return note.contains('menggantikan') ||
        note.contains('backup') ||
        note.contains('bko');
  }

  Widget _buildMonitoringSummaryCard({
    required int totalAssignments,
    required int uniqueMembers,
    required int bkoCount,
  }) {
    return _buildSectionCard(
      title: 'Monitoring Shift',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildInfoRow('Total jadwal', totalAssignments.toString()),
          _buildInfoRow('Anggota terjadwal', uniqueMembers.toString()),
          _buildInfoRow('BKO/Backup', bkoCount.toString()),
          const SizedBox(height: 6),
          Text(
            'Monitoring bersifat read-only.',
            style: TextStyle(color: Colors.grey.shade600, fontSize: 11),
          ),
        ],
      ),
    );
  }

  List<_AssignmentGroup> _groupAssignments() {
    final map = <String, _AssignmentGroup>{};
    for (final assignment in _assignments) {
      final parsed = DateTime.tryParse(assignment.date);
      if (parsed == null) continue;
      final shift = assignment.dailyShift;
      final shiftId = shift?.id ?? 'unknown';
      final key = '${parsed.toIso8601String().split('T').first}|$shiftId';
      final existing = map[key];
      if (existing == null) {
        map[key] = _AssignmentGroup(
          date: parsed,
          shift: shift,
          items: [assignment],
        );
      } else {
        existing.items.add(assignment);
      }
    }
    final groups = map.values.toList();
    groups.sort((a, b) {
      final dateCompare = b.date.compareTo(a.date);
      if (dateCompare != 0) return dateCompare;
      final nameA = a.shift?.name ?? '';
      final nameB = b.shift?.name ?? '';
      return nameA.compareTo(nameB);
    });
    return groups;
  }

  void _showAssignShiftModal() {
    if (_manageTeamId == null) return;
    final dateFormatter = DateFormat('dd MMM yyyy', 'id_ID');
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 16,
                bottom: MediaQuery.of(context).viewInsets.bottom + 16,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Tambah Shift',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Text('Tanggal'),
                  const SizedBox(height: 6),
                  InkWell(
                    onTap: () async {
                      final picked = await showDatePicker(
                        context: context,
                        firstDate: DateTime(2020),
                        lastDate: DateTime.now().add(const Duration(days: 365)),
                        initialDate: _selectedDate,
                        locale: const Locale('id', 'ID'),
                        helpText: 'Pilih Tanggal',
                        cancelText: 'Batal',
                        confirmText: 'Pilih',
                      );
                      if (picked != null) {
                        setState(() {
                          _selectedDate = picked;
                        });
                        setModalState(() {});
                      }
                    },
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.grey[300]!),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(dateFormatter.format(_selectedDate)),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text('Anggota'),
                  const SizedBox(height: 6),
                  DropdownButtonFormField<String>(
                    value: _selectedMemberId,
                    items: _manageMembers
                        .map(
                          (member) => DropdownMenuItem(
                            value: member.id,
                            child: Text(member.name),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      setState(() {
                        _selectedMemberId = value;
                      });
                      setModalState(() {});
                    },
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text('Shift'),
                  const SizedBox(height: 6),
                  DropdownButtonFormField<String>(
                    value: _selectedShiftId,
                    items: _shifts
                        .map(
                          (shift) => DropdownMenuItem(
                            value: shift.id,
                            child: Text(
                              '${shift.name} (${shift.startTime}-${shift.endTime})',
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      setState(() {
                        _selectedShiftId = value;
                      });
                      setModalState(() {});
                    },
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed:
                          (_isManageLoading ||
                              _selectedMemberId == null ||
                              _selectedShiftId == null)
                          ? null
                          : () async {
                              Navigator.pop(context);
                              await _assignShift();
                            },
                      icon: const Icon(Icons.save),
                      label: const Text('Simpan Shift'),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _showScheduleModal() {
    final dateFormatter = DateFormat('dd MMM yyyy', 'id_ID');
    final groups = _groupAssignments();
    final memberMap = {for (final member in _manageMembers) member.id: member};
    int page = 0;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            final totalPages = _totalPages(groups.length);
            if (page >= totalPages) page = 0;
            final pageItems = _paginateList(groups, page);
            final maxHeight = MediaQuery.of(context).size.height * 0.6;

            return Padding(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 16,
                bottom:
                    16 +
                    MediaQuery.of(context).padding.bottom +
                    MediaQuery.of(context).viewInsets.bottom,
              ),
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: maxHeight),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Jadwal Shift Team',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => Navigator.pop(context),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${dateFormatter.format(_startDate)} - ${dateFormatter.format(_endDate)}',
                      style: TextStyle(
                        color: Colors.grey.shade600,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (groups.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 20),
                        child: Text(
                          'Belum ada jadwal di rentang ini',
                          style: TextStyle(color: Colors.grey.shade600),
                        ),
                      )
                    else
                      Flexible(
                        child: ListView.separated(
                          shrinkWrap: true,
                          itemCount: pageItems.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 10),
                          itemBuilder: (context, index) {
                            final group = pageItems[index];
                            final shift = group.shift;
                            final shiftName = shift?.name ?? 'Shift';
                            final uniqueCount = group.items
                                .map((item) => item.ownerId ?? item.owner?.id)
                                .whereType<String>()
                                .toSet()
                                .length;
                            return Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: Colors.grey.shade50,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: Colors.grey[200]!),
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          dateFormatter.format(group.date),
                                          style: const TextStyle(
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          '$shiftName (${shift?.startTime ?? '-'}-${shift?.endTime ?? '-'})',
                                          style: TextStyle(
                                            color: Colors.grey.shade700,
                                            fontSize: 12,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          'Total anggota: $uniqueCount',
                                          style: TextStyle(
                                            color: Colors.grey.shade600,
                                            fontSize: 11,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  TextButton(
                                    onPressed: () => _showAssignmentDetailModal(
                                      group,
                                      memberMap,
                                    ),
                                    child: const Text('Detail'),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                    if (groups.isNotEmpty) const SizedBox(height: 8),
                    if (groups.isNotEmpty)
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          TextButton(
                            onPressed: page > 0
                                ? () {
                                    setModalState(() {
                                      page -= 1;
                                    });
                                  }
                                : null,
                            child: const Text('Sebelumnya'),
                          ),
                          Text('Hal ${page + 1} / $totalPages'),
                          TextButton(
                            onPressed: page + 1 < totalPages
                                ? () {
                                    setModalState(() {
                                      page += 1;
                                    });
                                  }
                                : null,
                            child: const Text('Berikutnya'),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _showAssignmentDetailModal(
    _AssignmentGroup group,
    Map<String, TeamMember> memberMap,
  ) {
    int page = 0;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            final totalPages = _totalPages(group.items.length);
            if (page >= totalPages) page = 0;
            final pageItems = _paginateList(group.items, page);
            final maxHeight = MediaQuery.of(context).size.height * 0.6;
            return Padding(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 16,
                bottom:
                    16 +
                    MediaQuery.of(context).padding.bottom +
                    MediaQuery.of(context).viewInsets.bottom,
              ),
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: maxHeight),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Detail Anggota',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => Navigator.pop(context),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Flexible(
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: pageItems.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final assignment = pageItems[index];
                          final ownerId =
                              assignment.ownerId ?? assignment.owner?.id;
                          final member = ownerId != null
                              ? memberMap[ownerId]
                              : null;
                          final owner = assignment.owner;
                          final name = member?.name ?? owner?.name ?? 'Anggota';
                          final siteName =
                              member?.siteName ?? owner?.site ?? '-';
                          return Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.grey.shade50,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Colors.grey[200]!),
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(name),
                                      const SizedBox(height: 4),
                                      Text(
                                        siteName,
                                        style: TextStyle(
                                          color: Colors.grey.shade600,
                                          fontSize: 12,
                                        ),
                                      ),
                                      if (assignment.notes != null &&
                                          assignment.notes!
                                              .trim()
                                              .isNotEmpty) ...[
                                        const SizedBox(height: 4),
                                        Text(
                                          assignment.notes!,
                                          style: TextStyle(
                                            color: Colors.grey.shade700,
                                            fontSize: 11,
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                                if (!_leaderReadOnly)
                                  IconButton(
                                    onPressed: () async {
                                      await _deleteAssignment(assignment);
                                      setModalState(() {});
                                    },
                                    icon: const Icon(
                                      Icons.delete_outline,
                                      color: Colors.red,
                                    ),
                                  ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        TextButton(
                          onPressed: page > 0
                              ? () {
                                  setModalState(() {
                                    page -= 1;
                                  });
                                }
                              : null,
                          child: const Text('Sebelumnya'),
                        ),
                        Text('Hal ${page + 1} / $totalPages'),
                        TextButton(
                          onPressed: page + 1 < totalPages
                              ? () {
                                  setModalState(() {
                                    page += 1;
                                  });
                                }
                              : null,
                          child: const Text('Berikutnya'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildAssignmentsList(DateFormat dateFormatter) {
    if (_assignments.isEmpty) {
      return _buildSectionCard(
        title: 'Jadwal Shift Anggota',
        child: Text(
          'Belum ada jadwal di rentang ini',
          style: TextStyle(color: Colors.grey.shade600),
        ),
      );
    }

    final memberMap = {for (final member in _manageMembers) member.id: member};

    return _buildSectionCard(
      title: 'Jadwal Shift Anggota',
      child: Column(
        children: _assignments.map((assignment) {
          final ownerId = assignment.ownerId ?? assignment.owner?.id;
          final owner = ownerId != null ? memberMap[ownerId] : null;
          final shift = assignment.dailyShift;
          return Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.grey.shade50,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.grey[200]!),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        owner?.name ?? 'Anggota',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        dateFormatter.format(DateTime.parse(assignment.date)),
                        style: TextStyle(
                          color: Colors.grey.shade600,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color:
                              (shift?.color != null
                                      ? Color(
                                          int.parse(
                                            'FF${shift!.color!.replaceAll('#', '')}',
                                            radix: 16,
                                          ),
                                        )
                                      : Colors.blue)
                                  .withOpacity(0.15),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          '${shift?.name ?? '-'} (${shift?.startTime ?? '-'}-${shift?.endTime ?? '-'})',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
                if (!_leaderReadOnly)
                  IconButton(
                    onPressed: () => _deleteAssignment(assignment),
                    icon: const Icon(Icons.delete_outline, color: Colors.red),
                    tooltip: 'Hapus shift',
                  ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildMemberCard(TeamMember member, {String? currentUserId}) {
    final isMe = member.id.isNotEmpty && member.id == currentUserId;
    final subtitle = [member.title, member.siteName]
        .where((item) => (item ?? '').isNotEmpty)
        .join(' · ');
    return AtenimCard(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          _buildMemberAvatar(member),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        member.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: AtenimUi.ink,
                        ),
                      ),
                    ),
                    if (isMe) ...[
                      const SizedBox(width: 8),
                      const StatusPill(label: 'Anda', tone: Tone.success),
                    ],
                  ],
                ),
                if (subtitle.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      subtitle,
                      style: TextStyle(fontSize: 13, color: AtenimUi.inkSoft),
                    ),
                  ),
                if (isMe && (member.externalId ?? '').isNotEmpty)
                  Text(
                    'NIK: ${member.externalId}',
                    style: TextStyle(fontSize: 12, color: AtenimUi.inkSoft),
                  ),
                if ((member.teamName ?? '').isNotEmpty)
                  Text(
                    member.teamName!,
                    style: TextStyle(fontSize: 12, color: AtenimUi.inkSoft),
                  ),
                if (_isLeader && !isMe && normalizeIndonesianPhone(member.phone) != null)
                  Text(
                    'HP: ${member.phone}',
                    style: TextStyle(fontSize: 12, color: AtenimUi.inkSoft),
                  ),
              ],
            ),
          ),
          if (_isLeader && !isMe)
            ContactButtons(
              phone: member.phone,
              memberName: member.name,
              leaderName: Provider.of<AuthProvider>(context, listen: false).user?.name ?? '',
            ),
        ],
      ),
    );
  }

  Widget _buildMemberAvatar(TeamMember member) {
    if (member.photoUrl != null && member.photoUrl!.isNotEmpty) {
      return CircleAvatar(
        radius: 22,
        backgroundImage: NetworkImage(member.photoUrl!),
      );
    }
    final nameStr = member.name;
    final initials = nameStr.isEmpty
        ? '?'
        : nameStr
              .split(' ')
              .where((part) => part.isNotEmpty)
              .map((part) => part[0])
              .take(2)
              .join()
              .toUpperCase();
    Color bgColor = Colors.blueGrey;
    if (member.avatarColor != null && member.avatarColor!.isNotEmpty) {
      try {
        final hex = member.avatarColor!.replaceFirst('#', '').trim();
        if (hex.isNotEmpty) {
          final value = hex.length == 8 ? hex : 'FF$hex';
          bgColor = Color(int.parse(value, radix: 16));
        }
      } catch (_) {
        bgColor = Colors.blueGrey;
      }
    }
    return CircleAvatar(
      radius: 22,
      backgroundColor: bgColor,
      child: Text(
        initials.isEmpty ? '?' : initials,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _buildErrorCard({String? message, VoidCallback? onRetry}) {
    return ErrorState(
      title: 'Data team tidak bisa dimuat',
      message: message ?? 'Periksa koneksi internet Anda, lalu coba lagi.',
      onRetry: onRetry ?? _loadTeamData,
    );
  }

  Widget _buildSkeletonScreen() {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SkeletonListCard(),
        SizedBox(height: 12),
        SkeletonListCard(),
        SizedBox(height: 12),
        SkeletonListCard(),
      ],
    );
  }

  Widget _buildSectionCard({required String title, required Widget child}) {
    return FadeSlideIn(
      key: ValueKey('team-card-$title'),
      child: AtenimCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: AtenimUi.ink,
              ),
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }

  Widget _buildKpiCard({
    required String label,
    required String value,
    required IconData icon,
  }) {
    return AtenimCard(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: AtenimUi.brandSoft,
              borderRadius: BorderRadius.circular(AtenimUi.radiusControl),
            ),
            child: Icon(icon, color: AtenimUi.brand, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  value,
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    height: 1.1,
                    color: AtenimUi.ink,
                  ),
                ),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: AtenimUi.inkSoft),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AssignmentGroup {
  _AssignmentGroup({
    required this.date,
    required this.shift,
    required this.items,
  });

  final DateTime date;
  final DailyShift? shift;
  final List<ShiftAssignment> items;
}
