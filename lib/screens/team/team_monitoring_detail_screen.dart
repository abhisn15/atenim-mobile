import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../models/attendance_model.dart';
import '../../models/shift_assignment_model.dart';
import 'package:provider/provider.dart';

import '../../models/team_model.dart';
import '../../providers/auth_provider.dart';
import '../../services/team_service.dart';
import '../../utils/phone_contact.dart';
import '../../widgets/contact_buttons.dart';
import '../../widgets/shimmer_loading.dart';

/// One row in the monitoring list (assignment + optional attendance log).
class _MonitoringRow {
  final String ownerId;
  final String ownerName;
  final String shiftName;
  final bool hasCheckIn;
  final String? checkIn;
  final String? checkOut;
  final String status;

  _MonitoringRow({
    required this.ownerId,
    required this.ownerName,
    required this.shiftName,
    required this.hasCheckIn,
    this.checkIn,
    this.checkOut,
    this.status = 'absent',
  });
}

class TeamMonitoringDetailScreen extends StatefulWidget {
  final String teamId;
  final String teamName;

  const TeamMonitoringDetailScreen({
    super.key,
    required this.teamId,
    required this.teamName,
  });

  @override
  State<TeamMonitoringDetailScreen> createState() =>
      _TeamMonitoringDetailScreenState();
}

class _TeamMonitoringDetailScreenState extends State<TeamMonitoringDetailScreen> {
  final TeamService _teamService = TeamService();
  static const int _pageSize = 50;

  DateTime _selectedDate = DateTime.now();
  List<ShiftAssignment> _assignments = [];
  LeaderAttendanceReport? _report;
  /// Fallback: id -> nama dari daftar anggota tim (jika API assignment/log tidak kirim nama)
  Map<String, String> _ownerIdToName = {};
  Map<String, String> _ownerIdToPhone = {};
  bool _loading = true;
  String? _error;
  int _currentPage = 1;
  /// Cari nama anggota
  String _searchQuery = '';
  /// all | belum | sudah — filter status check-in
  String _checkInFilter = 'all';

  String get _selectedDateStr {
    final d = _selectedDate;
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  List<_MonitoringRow> get _mergedRows {
    final rows = <_MonitoringRow>[];
    final dateStr = _selectedDateStr;
    final logsByUser = <String, LeaderAttendanceLogItem>{};
    for (final log in _report?.logs ?? []) {
      final logDate = log.date.length >= 10 ? log.date.substring(0, 10) : log.date;
      if (logDate == dateStr) {
        logsByUser[log.userId] = log;
      }
    }

    for (final a in _assignments) {
      if (a.date != dateStr) continue;
      // Hanya tampilkan yang punya shift kerja di hari itu (bukan off / tanpa shift)
      if (a.dailyShift == null || a.dailyShift!.isOff) continue;
      final ownerId = a.ownerId ?? a.owner?.id ?? '';
      if (ownerId.isEmpty) continue;
      final log = logsByUser[ownerId];
      // Tampilkan nama (assignment.owner -> log.userName -> anggota tim -> jangan id)
      final ownerName = a.owner?.name?.trim().isNotEmpty == true
          ? a.owner!.name
          : (log?.userName.trim().isNotEmpty == true ? log!.userName : null) ??
            _ownerIdToName[ownerId] ??
            ownerId;
      final shiftName = a.dailyShift?.name ?? '-';
      final hasCheckIn = log != null &&
          (log.checkIn != null && log.checkIn!.isNotEmpty);
      rows.add(_MonitoringRow(
        ownerId: ownerId,
        ownerName: ownerName,
        shiftName: shiftName,
        hasCheckIn: hasCheckIn,
        checkIn: log?.checkIn,
        checkOut: log?.checkOut,
        status: log?.status ?? 'absent',
      ));
    }

    rows.sort((a, b) {
      // Belum check-in di atas, lalu sudah check-in; dalam grup urut nama
      if (a.hasCheckIn != b.hasCheckIn) return a.hasCheckIn ? 1 : -1;
      return a.ownerName.compareTo(b.ownerName);
    });
    return rows;
  }

  /// Setelah filter search + status check-in; urutan: belum di atas, lalu nama
  List<_MonitoringRow> get _filteredRows {
    final rows = _mergedRows;
    final q = _searchQuery.trim().toLowerCase();
    var out = q.isEmpty
        ? List<_MonitoringRow>.from(rows)
        : rows.where((r) => r.ownerName.toLowerCase().contains(q)).toList();
    if (_checkInFilter == 'belum') {
      out = out.where((r) => !r.hasCheckIn).toList();
    } else if (_checkInFilter == 'sudah') {
      out = out.where((r) => r.hasCheckIn).toList();
    }
    out.sort((a, b) {
      if (a.hasCheckIn != b.hasCheckIn) return a.hasCheckIn ? 1 : -1;
      return a.ownerName.compareTo(b.ownerName);
    });
    return out;
  }

  int get _totalRows => _filteredRows.length;
  int get _totalPages => (_totalRows / _pageSize).ceil().clamp(1, 999999);
  List<_MonitoringRow> get _pageRows {
    final all = _filteredRows;
    final start = (_currentPage - 1) * _pageSize;
    if (start >= all.length) return [];
    return all.sublist(start, (start + _pageSize).clamp(0, all.length));
  }

  Future<void> _loadData() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final start = DateTime(_selectedDate.year, _selectedDate.month, _selectedDate.day);
      final end = start.add(const Duration(days: 1)).subtract(const Duration(milliseconds: 1));

      final assignmentsFuture = _teamService.getLeaderShiftAssignments(
        teamId: widget.teamId,
        startDate: start,
        endDate: end,
      );
      final membersFuture = _teamService.getLeaderTeamMembers(teamId: widget.teamId);

      final assignments = await assignmentsFuture;
      List<TeamMember> members = [];
      try {
        members = await membersFuture;
      } catch (_) {}

      final ownerIdToName = <String, String>{};
      final ownerIdToPhone = <String, String>{};
      for (final m in members) {
        if (m.id.trim().isNotEmpty && m.name.trim().isNotEmpty) {
          ownerIdToName[m.id] = m.name.trim();
        }
        if (m.id.trim().isNotEmpty && (m.phone ?? '').trim().isNotEmpty) {
          ownerIdToPhone[m.id] = m.phone!.trim();
        }
      }

      LeaderAttendanceReport? report;
      try {
        report = await _teamService.getLeaderAttendance(
          teamId: widget.teamId,
          startDate: start,
          endDate: end,
          page: 1,
          limit: 500,
        );
      } catch (_) {
        report = LeaderAttendanceReport(
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

      if (!mounted) return;
      setState(() {
        _assignments = assignments;
        _report = report;
        _ownerIdToName = ownerIdToName;
        _ownerIdToPhone = ownerIdToPhone;
        _loading = false;
        _currentPage = 1;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString().replaceAll('Exception: ', '');
        _assignments = [];
        _report = null;
      });
    }
  }

  Future<void> _pickDate() async {
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
    if (picked != null && picked != _selectedDate) {
      setState(() => _selectedDate = picked);
      await _loadData();
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadData());
  }

  @override
  Widget build(BuildContext context) {
    final dateFormatter = DateFormat('dd MMM yyyy', 'id_ID');

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Monitoring Check-in'),
            if (widget.teamName.isNotEmpty)
              Text(
                widget.teamName,
                style: TextStyle(fontSize: 12, color: Colors.white.withValues(alpha: 0.9), fontWeight: FontWeight.normal),
              ),
          ],
        ),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Tanggal', style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                InkWell(
                  onTap: _pickDate,
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey.shade300),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(dateFormatter.format(_selectedDate), style: const TextStyle(fontWeight: FontWeight.w500)),
                        const Icon(Icons.calendar_today, size: 20),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (_loading)
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: ShimmerLoading(width: double.infinity, height: 200, borderRadius: BorderRadius.circular(12)),
                ),
              ),
            )
          else if (_error != null)
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.error_outline, size: 48, color: Colors.red.shade300),
                      const SizedBox(height: 12),
                      Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: Colors.grey.shade700)),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: _loadData,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Coba lagi'),
                      ),
                    ],
                  ),
                ),
              ),
            )
          else ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                onChanged: (value) {
                  setState(() {
                    _searchQuery = value;
                    _currentPage = 1;
                  });
                },
                decoration: InputDecoration(
                  hintText: 'Cari nama anggota...',
                  prefixIcon: const Icon(Icons.search),
                  filled: true,
                  fillColor: Colors.grey.shade50,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: Colors.grey.shade300),
                  ),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _filterChip('Semua', _checkInFilter == 'all', () => setState(() { _checkInFilter = 'all'; _currentPage = 1; })),
                    const SizedBox(width: 8),
                    _filterChip('Belum check-in', _checkInFilter == 'belum', () => setState(() { _checkInFilter = 'belum'; _currentPage = 1; })),
                    const SizedBox(width: 8),
                    _filterChip('Sudah check-in', _checkInFilter == 'sudah', () => setState(() { _checkInFilter = 'sudah'; _currentPage = 1; })),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Builder(
              builder: (context) {
                final rows = _filteredRows;
                final belum = rows.where((r) => !r.hasCheckIn).length;
                final sudah = rows.where((r) => r.hasCheckIn).length;
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      _summaryChip('Belum check-in', belum, Colors.orange),
                      const SizedBox(width: 8),
                      _summaryChip('Sudah check-in', sudah, Colors.green),
                    ],
                  ),
                );
              },
            ),
            const SizedBox(height: 12),
            Expanded(
              child: _totalRows == 0
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.event_busy, size: 48, color: Colors.grey.shade400),
                          const SizedBox(height: 12),
                          Text(
                            _mergedRows.isEmpty
                                ? 'Tidak ada jadwal di tanggal ini'
                                : 'Tidak ada yang sesuai pencarian atau filter',
                            style: TextStyle(color: Colors.grey.shade600),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      key: ValueKey('monitoring_$_checkInFilter\_$_currentPage'),
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: _pageRows.length,
                      itemBuilder: (context, index) {
                        final pageRows = _pageRows;
                        if (index < 0 || index >= pageRows.length) {
                          return const SizedBox.shrink();
                        }
                        final row = pageRows[index];
                        final checkInStr = row.checkIn;
                        final checkOutStr = row.checkOut;
                        final checkInLabel = row.hasCheckIn
                            ? (checkInStr != null && checkInStr.isNotEmpty
                                ? _formatTimeLabel(checkInStr)
                                : '-')
                            : 'Belum';
                        final checkOutLabel = row.hasCheckIn && checkOutStr != null && checkOutStr.isNotEmpty
                            ? _formatTimeLabel(checkOutStr)
                            : '-';
                        final displayName = (row.ownerName).trim().isEmpty ? '-' : row.ownerName;
                        final shiftLabel = row.shiftName;
                        final statusLabel = _statusLabel(row.status);
                        final notCheckedInColor = Colors.orange.shade800;
                        final checkedInColor = Colors.green.shade700;
                        return Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          child: ListTile(
                            title: Text(
                              displayName,
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                color: row.hasCheckIn ? null : notCheckedInColor,
                              ),
                            ),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const SizedBox(height: 4),
                                Text('Shift: $shiftLabel', style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                                const SizedBox(height: 2),
                                Row(
                                  children: [
                                    Text('Check-in: $checkInLabel', style: TextStyle(fontSize: 12, color: row.hasCheckIn ? checkedInColor : Colors.orange.shade700)),
                                    const SizedBox(width: 12),
                                    Text('Check-out: $checkOutLabel', style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                                  ],
                                ),
                                if (row.hasCheckIn && row.status.isNotEmpty && row.status != 'present')
                                  Padding(
                                    padding: const EdgeInsets.only(top: 2),
                                    child: Text('Status: $statusLabel', style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
                                  ),
                              ],
                            ),
                            trailing: ContactButtons(
                              phone: _ownerIdToPhone[row.ownerId],
                              memberName: row.ownerName,
                              leaderName: Provider.of<AuthProvider>(context, listen: false).user?.name ?? '',
                              reason: !row.hasCheckIn
                                  ? ContactReason.notCheckedIn
                                  : (row.status == 'late' ? ContactReason.late : ContactReason.general),
                            ),
                            leading: CircleAvatar(
                              backgroundColor: row.hasCheckIn ? Colors.green.shade100 : Colors.orange.shade100,
                              child: Icon(
                                row.hasCheckIn ? Icons.check_circle : Icons.schedule,
                                color: row.hasCheckIn ? Colors.green : Colors.orange,
                                size: 22,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
            if (_totalRows > _pageSize) _buildPagination(),
          ],
        ],
      ),
    );
  }

  Widget _filterChip(String label, bool selected, VoidCallback onTap) {
    return FilterChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
      selectedColor: Colors.blue.shade100,
      checkmarkColor: Colors.blue.shade700,
    );
  }

  Widget _summaryChip(String label, int value, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withValues(alpha: 0.5)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('$label: ', style: TextStyle(fontSize: 12, color: color.withValues(alpha: 0.9))),
            Text('$value', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: color)),
          ],
        ),
      ),
    );
  }

  Widget _buildPagination() {
    final start = (_currentPage - 1) * _pageSize + 1;
    final end = (_currentPage * _pageSize).clamp(0, _totalRows);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
      decoration: BoxDecoration(color: Colors.grey.shade100),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text('Menampilkan $start–$end dari $_totalRows', style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
          Row(
            children: [
              IconButton(
                onPressed: _currentPage > 1 ? () => setState(() => _currentPage--) : null,
                icon: const Icon(Icons.chevron_left),
              ),
              Text('$_currentPage / $_totalPages', style: const TextStyle(fontWeight: FontWeight.w500)),
              IconButton(
                onPressed: _currentPage < _totalPages ? () => setState(() => _currentPage++) : null,
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _formatTimeLabel(String value) {
    if (value.contains('T') || value.contains('-')) {
      try {
        final dt = DateTime.parse(value);
        return DateFormat('HH:mm').format(dt);
      } catch (_) {}
    }
    if (value.contains(':')) {
      final parts = value.split(':');
      if (parts.length >= 2) return '${parts[0]}:${parts[1]}';
    }
    return value;
  }

  String _statusLabel(String status) {
    if (status.isEmpty) return '-';
    try {
      switch (status.toLowerCase()) {
        case 'present': return 'Hadir';
        case 'late': return 'Terlambat';
        case 'absent': return 'Tidak hadir';
        case 'leave': return 'Cuti';
        case 'sick': return 'Sakit';
        case 'remote': return 'Remote';
        default: return status;
      }
    } catch (_) {
      return status;
    }
  }
}
