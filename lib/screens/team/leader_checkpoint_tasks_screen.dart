import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../models/leader_checkpoint_model.dart';
import '../../models/team_model.dart';
import '../../services/team_service.dart';

class LeaderCheckpointTasksScreen extends StatefulWidget {
  final List<TeamSummary> teams;
  final Map<String, List<TeamMember>> membersByTeam;
  final String? initialTeamId;

  const LeaderCheckpointTasksScreen({
    super.key,
    required this.teams,
    required this.membersByTeam,
    this.initialTeamId,
  });

  @override
  State<LeaderCheckpointTasksScreen> createState() =>
      _LeaderCheckpointTasksScreenState();
}

class _LeaderCheckpointTasksScreenState
    extends State<LeaderCheckpointTasksScreen> {
  final TeamService _teamService = TeamService();
  final TextEditingController _searchController = TextEditingController();

  bool _isLoading = false;
  bool _isAssigning = false;
  String? _error;
  DateTime _selectedDate = DateTime.now();
  String _selectedTeamId = 'all';
  String _searchQuery = '';

  List<LeaderCheckpointTemplateOption> _templates = [];
  LeaderCheckpointMonitoringResult? _monitoringResult;

  @override
  void initState() {
    super.initState();
    if (widget.initialTeamId != null &&
        widget.teams.any((team) => team.id == widget.initialTeamId)) {
      _selectedTeamId = widget.initialTeamId!;
    }
    _loadData();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    if (_isLoading) return;
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        _teamService.getLeaderCheckpointTemplates(limit: 100),
        _teamService.getLeaderCheckpointMonitoring(
          date: _selectedDate,
          limit: 500,
        ),
      ]);

      if (!mounted) return;
      setState(() {
        _templates = results[0] as List<LeaderCheckpointTemplateOption>;
        _monitoringResult = results[1] as LeaderCheckpointMonitoringResult;
      });
    } on TeamServiceException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.message;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString().replaceAll('Exception: ', '');
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  List<TeamMember> _membersForTeam(String? teamId) {
    if (teamId == null || teamId == 'all') {
      final merged = <String, TeamMember>{};
      for (final members in widget.membersByTeam.values) {
        for (final member in members) {
          merged[member.id] = member;
        }
      }
      return merged.values.toList()
        ..sort((left, right) => left.name.compareTo(right.name));
    }
    final members = widget.membersByTeam[teamId] ?? [];
    return [...members]..sort((left, right) => left.name.compareTo(right.name));
  }

  Future<void> _pickMonitoringDate() async {
    final picked = await showDatePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      initialDate: _selectedDate,
      locale: const Locale('id', 'ID'),
    );
    if (picked == null) return;
    setState(() {
      _selectedDate = DateTime(picked.year, picked.month, picked.day);
    });
    await _loadData();
  }

  Map<String, List<LeaderCheckpointProgressItem>> _groupByUser(
    List<LeaderCheckpointProgressItem> items,
  ) {
    final grouped = <String, List<LeaderCheckpointProgressItem>>{};
    for (final item in items) {
      grouped.putIfAbsent(item.userId, () => []).add(item);
    }
    return grouped;
  }

  List<TeamMember> _filteredMembers() {
    final base = _membersForTeam(_selectedTeamId);
    final query = _searchQuery.trim().toLowerCase();
    if (query.isEmpty) return base;
    return base.where((member) {
      final name = member.name.toLowerCase();
      final externalId = (member.externalId ?? '').toLowerCase();
      return name.contains(query) || externalId.contains(query);
    }).toList();
  }

  Future<void> _createAssignment({
    required String templateId,
    required List<String> userIds,
    required DateTime date,
  }) async {
    setState(() {
      _isAssigning = true;
    });
    try {
      await _teamService.createLeaderCheckpointAssignment(
        templateId: templateId,
        userIds: userIds,
        date: date,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            userIds.length > 1
                ? 'Tugas checkpoint berhasil ditambahkan ke ${userIds.length} karyawan'
                : 'Tugas checkpoint berhasil ditambahkan',
          ),
          backgroundColor: Colors.green,
        ),
      );
      await _loadData();
    } on TeamServiceException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.message), backgroundColor: Colors.red),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(error.toString().replaceAll('Exception: ', '')),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isAssigning = false;
        });
      }
    }
  }

  Future<void> _openAddTaskSheet() async {
    if (_templates.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Template checkpoint belum tersedia'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    var selectedTeamId = _selectedTeamId == 'all'
        ? (widget.teams.isNotEmpty ? widget.teams.first.id : 'all')
        : _selectedTeamId;
    final selectedMemberIds = <String>{};
    LeaderCheckpointTemplateOption? selectedTemplate = _templates.isNotEmpty
        ? _templates.first
        : null;
    DateTime selectedDate = _selectedDate;
    String memberSearch = '';
    bool isSaving = false;

    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            final members = _membersForTeam(selectedTeamId);
            final filteredMembers = members.where((member) {
              final query = memberSearch.trim().toLowerCase();
              if (query.isEmpty) return true;
              return member.name.toLowerCase().contains(query) ||
                  (member.externalId ?? '').toLowerCase().contains(query);
            }).toList();

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
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Tambah Tugas Checkpoint',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.pop(context, false),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Pilih karyawan dan template checkpoint yang akan dipantau.',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    isExpanded: true,
                    value: selectedTeamId == 'all' ? null : selectedTeamId,
                    decoration: const InputDecoration(labelText: 'Team'),
                    items: widget.teams
                        .map(
                          (team) => DropdownMenuItem<String>(
                            value: team.id,
                            child: Text(
                              team.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      setModalState(() {
                        selectedTeamId = value ?? 'all';
                        selectedMemberIds.clear();
                      });
                    },
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    decoration: const InputDecoration(
                      labelText: 'Cari karyawan',
                      hintText: 'Ketik nama / NIK...',
                      prefixIcon: Icon(Icons.search),
                    ),
                    onChanged: (value) {
                      setModalState(() {
                        memberSearch = value;
                      });
                    },
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Text(
                        'Dipilih: ${selectedMemberIds.length}',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Colors.grey.shade700,
                        ),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: filteredMembers.isEmpty
                            ? null
                            : () {
                                setModalState(() {
                                  selectedMemberIds.addAll(
                                    filteredMembers.map((member) => member.id),
                                  );
                                });
                              },
                        child: const Text('Pilih Semua'),
                      ),
                      TextButton(
                        onPressed: selectedMemberIds.isEmpty
                            ? null
                            : () {
                                setModalState(() {
                                  selectedMemberIds.clear();
                                });
                              },
                        child: const Text('Reset'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Container(
                    constraints: const BoxConstraints(maxHeight: 220),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey.shade300),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: filteredMembers.isEmpty
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Text(
                                'Tidak ada karyawan',
                                style: TextStyle(color: Colors.grey.shade600),
                              ),
                            ),
                          )
                        : ListView.builder(
                            shrinkWrap: true,
                            itemCount: filteredMembers.length,
                            itemBuilder: (context, index) {
                              final member = filteredMembers[index];
                              final selected = selectedMemberIds.contains(
                                member.id,
                              );
                              return ListTile(
                                dense: true,
                                onTap: () {
                                  setModalState(() {
                                    if (selected) {
                                      selectedMemberIds.remove(member.id);
                                    } else {
                                      selectedMemberIds.add(member.id);
                                    }
                                  });
                                },
                                leading: Icon(
                                  selected
                                      ? Icons.check_box
                                      : Icons.check_box_outline_blank,
                                  color: selected
                                      ? Colors.blue
                                      : Colors.grey.shade500,
                                  size: 18,
                                ),
                                title: Text(
                                  member.name,
                                  style: const TextStyle(fontSize: 13),
                                ),
                                subtitle: Text(
                                  member.externalId?.isNotEmpty == true
                                      ? member.externalId!
                                      : '-',
                                  style: const TextStyle(fontSize: 11),
                                ),
                              );
                            },
                          ),
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    isExpanded: true,
                    value: selectedTemplate?.id,
                    decoration: const InputDecoration(
                      labelText: 'Template checkpoint',
                    ),
                    items: _templates
                        .map(
                          (template) => DropdownMenuItem<String>(
                            value: template.id,
                            child: Text(
                              template.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      setModalState(() {
                        selectedTemplate = _templates.firstWhere(
                          (item) => item.id == value,
                          orElse: () => _templates.first,
                        );
                      });
                    },
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: () async {
                      final picked = await showDatePicker(
                        context: context,
                        firstDate: DateTime(2020),
                        lastDate: DateTime.now().add(const Duration(days: 365)),
                        initialDate: selectedDate,
                        locale: const Locale('id', 'ID'),
                      );
                      if (picked != null) {
                        setModalState(() {
                          selectedDate = DateTime(
                            picked.year,
                            picked.month,
                            picked.day,
                          );
                        });
                      }
                    },
                    icon: const Icon(Icons.calendar_today),
                    label: Text(
                      'Tanggal tugas: ${DateFormat('dd MMM yyyy', 'id_ID').format(selectedDate)}',
                    ),
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: isSaving
                          ? null
                          : () async {
                              if (selectedMemberIds.isEmpty ||
                                  selectedTemplate == null) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                      'Karyawan dan template wajib dipilih',
                                    ),
                                    backgroundColor: Colors.red,
                                  ),
                                );
                                return;
                              }
                              setModalState(() {
                                isSaving = true;
                              });
                              await _createAssignment(
                                templateId: selectedTemplate!.id,
                                userIds: selectedMemberIds.toList(),
                                date: selectedDate,
                              );
                              if (!mounted || !context.mounted) return;
                              Navigator.of(context).pop(true);
                            },
                      icon: const Icon(Icons.add),
                      label: Text(isSaving ? 'Menyimpan...' : 'Simpan Tugas'),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );

    if (result == true && mounted) {
      await _loadData();
    }
  }

  Widget _buildKpiCard({
    required String title,
    required String value,
    required Color color,
    required IconData icon,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  value,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: color,
                  ),
                ),
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 11,
                    color: color.withValues(alpha: 0.85),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final monitorItems = _monitoringResult?.items ?? [];
    final groupedByUser = _groupByUser(monitorItems);
    final filteredMembers = _filteredMembers();

    int assignedMembers = 0;
    int completedMembers = 0;
    for (final member in filteredMembers) {
      final entries = groupedByUser[member.id] ?? [];
      if (entries.isEmpty) continue;
      assignedMembers += 1;
      final completed = entries.fold<int>(
        0,
        (sum, entry) => sum + entry.completedCount,
      );
      final total = entries.fold<int>(
        0,
        (sum, entry) => sum + entry.totalCount,
      );
      if (total > 0 && completed == total) {
        completedMembers += 1;
      }
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Kelola Tugas Anggota'),
        actions: [
          IconButton(
            tooltip: 'Tambah tugas checkpoint',
            onPressed: _isAssigning ? null : _openAddTaskSheet,
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _loadData,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.blue.shade100),
              ),
              child: Text(
                'Pantau progres checkpoint seluruh anggota tim. Gunakan tombol + di kanan atas untuk menambah tugas checkpoint.',
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.blue.shade800,
                  height: 1.4,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _pickMonitoringDate,
                    icon: const Icon(Icons.calendar_today_outlined),
                    label: Text(
                      DateFormat('dd MMM yyyy', 'id_ID').format(_selectedDate),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  onPressed: _isLoading ? null : _loadData,
                  icon: const Icon(Icons.refresh),
                  tooltip: 'Refresh',
                ),
              ],
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              value: _selectedTeamId,
              decoration: const InputDecoration(labelText: 'Filter Team'),
              items: [
                const DropdownMenuItem<String>(
                  value: 'all',
                  child: Text('Semua Team'),
                ),
                ...widget.teams.map(
                  (team) => DropdownMenuItem<String>(
                    value: team.id,
                    child: Text(team.name),
                  ),
                ),
              ],
              onChanged: (value) {
                if (value == null) return;
                setState(() {
                  _selectedTeamId = value;
                });
              },
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _searchController,
              onChanged: (value) => setState(() => _searchQuery = value),
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: 'Cari anggota (nama / NIK)',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _buildKpiCard(
                    title: 'Total Anggota',
                    value: filteredMembers.length.toString(),
                    color: Colors.blue,
                    icon: Icons.groups,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildKpiCard(
                    title: 'Sedang Berjalan',
                    value: assignedMembers.toString(),
                    color: Colors.orange,
                    icon: Icons.timelapse,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildKpiCard(
                    title: 'Selesai',
                    value: completedMembers.toString(),
                    color: Colors.green,
                    icon: Icons.check_circle,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_isLoading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_error != null)
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.red.shade100),
                ),
                child: Text(
                  _error!,
                  style: TextStyle(color: Colors.red.shade700),
                ),
              )
            else if (filteredMembers.isEmpty)
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: Colors.grey.shade50,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.grey.shade200),
                ),
                child: Text(
                  'Tidak ada anggota untuk filter saat ini',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey.shade600),
                ),
              )
            else
              ...filteredMembers.map((member) {
                final entries = groupedByUser[member.id] ?? [];
                final completed = entries.fold<int>(
                  0,
                  (sum, entry) => sum + entry.completedCount,
                );
                final total = entries.fold<int>(
                  0,
                  (sum, entry) => sum + entry.totalCount,
                );
                final isDone = total > 0 && completed == total;

                return Card(
                  margin: const EdgeInsets.only(bottom: 10),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    member.name,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                      fontSize: 15,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    member.externalId?.isNotEmpty == true
                                        ? member.externalId!
                                        : '-',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.grey.shade600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: isDone
                                    ? Colors.green.shade100
                                    : Colors.blue.shade100,
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                total == 0
                                    ? 'Belum ada tugas'
                                    : '$completed/$total',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: isDone
                                      ? Colors.green.shade800
                                      : Colors.blue.shade800,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        if (entries.isEmpty)
                          Text(
                            'Belum ada checkpoint assignment di tanggal ini',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey.shade600,
                            ),
                          )
                        else
                          ...entries.map((entry) {
                            final pending = entry.progress
                                .where((item) => !item.completed)
                                .toList();
                            return Container(
                              margin: const EdgeInsets.only(bottom: 8),
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: Colors.grey.shade50,
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: Colors.grey.shade200),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          entry.templateName,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w600,
                                            fontSize: 13,
                                          ),
                                        ),
                                      ),
                                      Text(
                                        '${entry.completedCount}/${entry.totalCount}',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: Colors.grey.shade700,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 6),
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(6),
                                    child: LinearProgressIndicator(
                                      value: entry.totalCount == 0
                                          ? 0
                                          : entry.completedCount /
                                                entry.totalCount,
                                      minHeight: 8,
                                      backgroundColor: Colors.grey.shade200,
                                      valueColor: AlwaysStoppedAnimation<Color>(
                                        entry.completedCount ==
                                                    entry.totalCount &&
                                                entry.totalCount > 0
                                            ? Colors.green
                                            : Colors.blue,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    pending.isEmpty
                                        ? 'Semua item checkpoint selesai'
                                        : 'Belum selesai: ${pending.take(2).map((item) => item.name).join(', ')}${pending.length > 2 ? ' +' : ''}',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: pending.isEmpty
                                          ? Colors.green.shade700
                                          : Colors.grey.shade700,
                                    ),
                                  ),
                                ],
                              ),
                            );
                          }),
                      ],
                    ),
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }
}
