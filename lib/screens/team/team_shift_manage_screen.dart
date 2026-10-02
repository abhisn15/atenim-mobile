import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../models/team_model.dart';
import '../../models/shift_model.dart';
import '../../models/shift_assignment_model.dart';
import '../../services/team_service.dart';

class TeamShiftManageScreen extends StatefulWidget {
  final String teamId;
  final List<TeamSummary> leaderTeams;

  const TeamShiftManageScreen({
    super.key,
    required this.teamId,
    required this.leaderTeams,
  });

  @override
  State<TeamShiftManageScreen> createState() => _TeamShiftManageScreenState();
}

class _TeamShiftManageScreenState extends State<TeamShiftManageScreen> {
  final TeamService _teamService = TeamService();
  final bool _isReadOnly = true;
  bool _isLoading = false;
  String? _error;
  List<TeamMember> _members = [];
  List<DailyShift> _shifts = [];
  List<ShiftAssignment> _assignments = [];
  String? _selectedTeamId;
  String? _selectedMemberId;
  String? _selectedShiftId;
  DateTime _selectedDate = DateTime.now();
  late DateTime _startDate;
  late DateTime _endDate;

  @override
  void initState() {
    super.initState();
    _selectedTeamId = widget.teamId;
    final now = DateTime.now();
    _startDate = DateTime(now.year, now.month, 1);
    _endDate = DateTime(now.year, now.month + 1, 0);
    _loadData();
  }

  Future<void> _loadData() async {
    if (_isLoading || _selectedTeamId == null) return;
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final members = await _teamService.getLeaderTeamMembers(teamId: _selectedTeamId!);
      final shifts = await _teamService.getLeaderShiftMaster();
      final assignments = await _teamService.getLeaderShiftAssignments(
        teamId: _selectedTeamId!,
        startDate: _startDate,
        endDate: _endDate,
      );
      if (!mounted) return;
      setState(() {
        _members = members;
        _shifts = shifts;
        _assignments = assignments;
        final memberIds = members.map((m) => m.id).toSet();
        final shiftIds = shifts.map((s) => s.id).toSet();
        if (_selectedMemberId == null || !memberIds.contains(_selectedMemberId)) {
          _selectedMemberId = members.isNotEmpty ? members.first.id : null;
        }
        if (_selectedShiftId == null || !shiftIds.contains(_selectedShiftId)) {
          _selectedShiftId = shifts.isNotEmpty ? shifts.first.id : null;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceAll('Exception: ', '');
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
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
      await _loadData();
    }
  }

  Future<void> _assignShift() async {
    if (_selectedTeamId == null || _selectedMemberId == null || _selectedShiftId == null) {
      return;
    }
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      await _teamService.assignShift(
        teamId: _selectedTeamId!,
        date: _selectedDate,
        dailyShiftId: _selectedShiftId!,
        ownerIds: [_selectedMemberId!],
      );
      await _loadData();
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
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _deleteAssignment(ShiftAssignment assignment) async {
    if (_selectedTeamId == null) return;
    setState(() {
      _isLoading = true;
    });
    try {
      await _teamService.deleteShiftAssignment(
        teamId: _selectedTeamId!,
        assignmentId: assignment.id,
      );
      await _loadData();
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
          _isLoading = false;
        });
      }
    }
  }

  TeamMember? _findMember(String? id) {
    if (id == null) return null;
    return _members.firstWhere((m) => m.id == id, orElse: () => _members.first);
  }

  @override
  Widget build(BuildContext context) {
    final dateFormatter = DateFormat('dd MMM yyyy', 'id_ID');
    final selectedTeam = widget.leaderTeams.isNotEmpty
        ? widget.leaderTeams.firstWhere(
            (team) => team.id == _selectedTeamId,
            orElse: () => widget.leaderTeams.first,
          )
        : TeamSummary(id: '', name: '-', leaderName: '-', memberCount: 0);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Jadwal Shift Team'),
      ),
      body: RefreshIndicator(
        onRefresh: _loadData,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _buildTeamSelector(selectedTeam),
            const SizedBox(height: 12),
            _buildDateFilterCard(dateFormatter),
            if (_isReadOnly) ...[
              const SizedBox(height: 12),
              _buildSectionCard(
                title: 'Info',
                child: Text(
                  'Leader hanya bisa memantau jadwal. Jika ada kesalahan, hubungi supervisor.',
                  style: TextStyle(color: Colors.grey[600]),
                ),
              ),
            ] else ...[
              const SizedBox(height: 16),
              _buildAssignForm(dateFormatter),
            ],
            const SizedBox(height: 16),
            if (_isLoading)
              const Center(child: Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: CircularProgressIndicator(),
              ))
            else if (_error != null)
              _buildErrorCard()
            else
              _buildAssignmentsList(dateFormatter),
          ],
        ),
      ),
    );
  }

  Widget _buildTeamSelector(TeamSummary selectedTeam) {
    if (widget.leaderTeams.length <= 1) {
      return _buildSectionCard(
        title: 'Team',
        child: Text(
          selectedTeam.name,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
      );
    }
    return _buildSectionCard(
      title: 'Pilih Team',
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: _selectedTeamId,
          isExpanded: true,
          items: widget.leaderTeams
              .map((team) => DropdownMenuItem(
                    value: team.id,
                    child: Text(team.name),
                  ))
              .toList(),
          onChanged: (value) async {
            if (value == null || value == _selectedTeamId) return;
            setState(() {
              _selectedTeamId = value;
            });
            await _loadData();
          },
        ),
      ),
    );
  }

  Widget _buildDateFilterCard(DateFormat dateFormatter) {
    return _buildSectionCard(
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
  }

  Widget _buildAssignForm(DateFormat dateFormatter) {
    return _buildSectionCard(
      title: 'Tambah / Atur Shift',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Tanggal'),
          const SizedBox(height: 6),
          InkWell(
            onTap: () async {
              final picked = await showDatePicker(
                context: context,
                initialDate: _selectedDate,
                firstDate: _startDate,
                lastDate: _endDate,
                locale: const Locale('id', 'ID'),
              );
              if (picked != null) {
                setState(() {
                  _selectedDate = picked;
                });
              }
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey[300]!),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(dateFormatter.format(_selectedDate)),
            ),
          ),
          const SizedBox(height: 12),
          const Text('Anggota'),
          const SizedBox(height: 6),
          DropdownButtonFormField<String>(
            value: _selectedMemberId,
            items: _members
                .map((member) => DropdownMenuItem(
                      value: member.id,
                      child: Text(member.name),
                    ))
                .toList(),
            onChanged: (value) {
              setState(() {
                _selectedMemberId = value;
              });
            },
            decoration: const InputDecoration(border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          const Text('Shift'),
          const SizedBox(height: 6),
          DropdownButtonFormField<String>(
            value: _selectedShiftId,
            items: _shifts
                .map((shift) => DropdownMenuItem(
                      value: shift.id,
                      child: Text('${shift.name} (${shift.startTime}-${shift.endTime})'),
                    ))
                .toList(),
            onChanged: (value) {
              setState(() {
                _selectedShiftId = value;
              });
            },
            decoration: const InputDecoration(border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: (_isLoading || _selectedMemberId == null || _selectedShiftId == null || _selectedTeamId == null)
                  ? null
                  : _assignShift,
              icon: const Icon(Icons.save),
              label: const Text('Simpan Shift'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAssignmentsList(DateFormat dateFormatter) {
    if (_assignments.isEmpty) {
      return _buildSectionCard(
        title: 'Jadwal Shift Anggota',
        child: Text(
          'Belum ada jadwal di rentang ini',
          style: TextStyle(color: Colors.grey[600]),
        ),
      );
    }

    final memberMap = {for (final member in _members) member.id: member};

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
              color: Colors.grey[50],
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
                        style: TextStyle(color: Colors.grey[600], fontSize: 12),
                      ),
                      const SizedBox(height: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: (shift?.color != null
                                  ? Color(int.parse('FF${shift!.color!.replaceAll('#', '')}', radix: 16))
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
                if (!_isReadOnly)
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

  Widget _buildErrorCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.red[50],
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.red[200]!),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _error ?? 'Gagal memuat data',
            style: TextStyle(color: Colors.red[700]),
          ),
          const SizedBox(height: 8),
          ElevatedButton(
            onPressed: _loadData,
            child: const Text('Coba Lagi'),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionCard({required String title, required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 8,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}
