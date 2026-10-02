import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../models/shift_assignment_model.dart';
import '../../models/shift_model.dart';
import '../../providers/auth_provider.dart';
import '../../services/shift_schedule_service.dart';
import '../../widgets/shimmer_loading.dart';

class MyShiftScreen extends StatefulWidget {
  const MyShiftScreen({super.key});

  @override
  State<MyShiftScreen> createState() => _MyShiftScreenState();
}

class _MyShiftScreenState extends State<MyShiftScreen> {
  final ShiftScheduleService _service = ShiftScheduleService();
  bool _isLoading = false;
  String? _error;
  List<ShiftAssignment> _assignments = [];
  late DateTime _startDate;
  late DateTime _endDate;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _startDate = DateTime(now.year, now.month, 1);
    _endDate = DateTime(now.year, now.month + 1, 0);
    _loadData();
  }

  Future<void> _loadData() async {
    if (_isLoading) return;
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final data = await _service.getMyShiftAssignments(
        startDate: _startDate,
        endDate: _endDate,
      );
      if (!mounted) return;
      setState(() {
        _assignments = data;
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

  Map<String, List<ShiftAssignment>> _groupAssignmentsByDate() {
    final map = <String, List<ShiftAssignment>>{};
    for (final assignment in _assignments) {
      final key = assignment.date;
      map.putIfAbsent(key, () => []);
      map[key]!.add(assignment);
    }
    return map;
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

  Color _shiftColor(DailyShift? shift) {
    if (shift?.color == null || shift!.color!.isEmpty) {
      return Colors.blue;
    }
    return Color(int.parse('FF${shift.color!.replaceAll('#', '')}', radix: 16));
  }

  int? _parseTimeToMinutes(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    final parts = value.split(':');
    if (parts.length < 2) return null;
    final hour = int.tryParse(parts[0]);
    final minute = int.tryParse(parts[1]);
    if (hour == null || minute == null) return null;
    return (hour * 60) + minute;
  }

  String _resolveBreakPreviewStatus(DailyShift? shift) {
    if (shift == null ||
        shift.hasBreak != true ||
        shift.breakStartTime == null ||
        shift.breakEndTime == null) {
      return 'Tanpa istirahat';
    }

    final now = DateTime.now();
    final nowMinutes = (now.hour * 60) + now.minute;
    final startMinutes = _parseTimeToMinutes(shift.startTime);
    final endMinutes = _parseTimeToMinutes(shift.endTime);
    final breakStartMinutes = _parseTimeToMinutes(shift.breakStartTime);
    final breakEndMinutes = _parseTimeToMinutes(shift.breakEndTime);
    if (startMinutes == null ||
        endMinutes == null ||
        breakStartMinutes == null ||
        breakEndMinutes == null) {
      return 'Jadwal istirahat';
    }

    var normalizedNow = nowMinutes;
    var normalizedBreakStart = breakStartMinutes;
    var normalizedBreakEnd = breakEndMinutes;
    final overnight = endMinutes <= startMinutes;
    if (overnight && normalizedNow < startMinutes) {
      normalizedNow += 1440;
    }
    if (overnight && normalizedBreakStart < startMinutes) {
      normalizedBreakStart += 1440;
    }
    if (overnight && normalizedBreakEnd < startMinutes) {
      normalizedBreakEnd += 1440;
    }
    if (normalizedBreakEnd <= normalizedBreakStart) {
      normalizedBreakEnd += 1440;
    }

    if (normalizedNow < normalizedBreakStart) return 'Berikutnya';
    if (normalizedNow >= normalizedBreakStart &&
        normalizedNow < normalizedBreakEnd) {
      return 'Sedang berlangsung';
    }
    return 'Selesai';
  }

  @override
  Widget build(BuildContext context) {
    final user = Provider.of<AuthProvider>(context, listen: false).user;
    final dateFormatter = DateFormat('dd MMM yyyy', 'id_ID');
    final groupedAssignments = _groupAssignmentsByDate();
    final rangeDates = _buildDateRange();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Shift Saya'),
      ),
      body: RefreshIndicator(
        onRefresh: _loadData,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _buildHeaderCard(user?.name ?? '-', user?.team ?? '-', user?.title ?? '-', user?.photoUrl, user?.avatarColor),
            const SizedBox(height: 16),
            _buildDateFilterCard(dateFormatter),
            const SizedBox(height: 16),
            if (_isLoading)
              _buildLoadingSkeleton()
            else if (_error != null)
              _buildErrorCard()
            else
              ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: rangeDates.length,
                separatorBuilder: (_, __) => const SizedBox(height: 12),
                itemBuilder: (context, index) {
                  final date = rangeDates[index];
                  final key = DateFormat('yyyy-MM-dd').format(date);
                  final assignments = groupedAssignments[key] ?? [];
                  return _buildShiftDayCard(date, assignments);
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildLoadingSkeleton() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSkeletonCard(),
        const SizedBox(height: 12),
        _buildSkeletonCard(),
        const SizedBox(height: 12),
        _buildSkeletonCard(),
      ],
    );
  }

  Widget _buildSkeletonCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ShimmerLoading(width: 120, height: 14, borderRadius: BorderRadius.circular(6)),
          const SizedBox(height: 10),
          ShimmerLoading(width: double.infinity, height: 80, borderRadius: BorderRadius.circular(12)),
        ],
      ),
    );
  }

  Widget _buildHeaderCard(String name, String team, String title, String? photoUrl, String? avatarColor) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          _buildAvatar(photoUrl, avatarColor, name),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                Text(
                  [team, title].where((item) => item.trim().isNotEmpty).join(' - '),
                  style: TextStyle(color: Colors.grey[600], fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAvatar(String? photoUrl, String? avatarColor, String name) {
    if (photoUrl != null && photoUrl.isNotEmpty) {
      return CircleAvatar(
        radius: 24,
        backgroundImage: NetworkImage(photoUrl),
      );
    }
    final initials = name
        .split(' ')
        .where((part) => part.isNotEmpty)
        .map((part) => part[0])
        .take(2)
        .join()
        .toUpperCase();
    final bgColor = avatarColor != null && avatarColor.isNotEmpty
        ? Color(int.parse(avatarColor.replaceAll('#', '0xFF')))
        : Colors.blue;
    return CircleAvatar(
      radius: 24,
      backgroundColor: bgColor,
      child: Text(
        initials,
        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
      ),
    );
  }

  Widget _buildDateFilterCard(DateFormat dateFormatter) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.blue[50],
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.blue[200]!),
      ),
      child: Row(
        children: [
          Icon(Icons.date_range, color: Colors.blue[700]),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Rentang Tanggal', style: TextStyle(fontSize: 12, color: Colors.grey[600])),
                const SizedBox(height: 4),
                Text(
                  '${dateFormatter.format(_startDate)} - ${dateFormatter.format(_endDate)}',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Colors.blue[900],
                  ),
                ),
              ],
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

  Widget _buildShiftDayCard(DateTime date, List<ShiftAssignment> assignments) {
    final dayName = DateFormat('EEE', 'id_ID').format(date);
    final dayNumber = DateFormat('dd').format(date);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey[300]!),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.blue[50],
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.blue[100]!),
                ),
                child: Text(
                  dayName,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Colors.blue[800],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                dayNumber,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (assignments.isEmpty)
            _buildEmptyShiftCard()
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: assignments.map((assignment) {
                final shift = assignment.dailyShift;
                return Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: _shiftColor(shift).withOpacity(0.12),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: _shiftColor(shift).withOpacity(0.35)),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 8,
                        height: 36,
                        decoration: BoxDecoration(
                          color: _shiftColor(shift),
                          borderRadius: BorderRadius.circular(6),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              shift?.name ?? 'Shift',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: _shiftColor(shift),
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${shift?.startTime ?? '-'} - ${shift?.endTime ?? '-'}',
                              style: TextStyle(fontSize: 12, color: Colors.grey[700]),
                            ),
                            if (shift?.hasBreak == true &&
                                shift?.breakStartTime != null &&
                                shift?.breakEndTime != null) ...[
                              const SizedBox(height: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 6,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.white.withOpacity(0.7),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: _shiftColor(shift).withOpacity(0.20),
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      Icons.free_breakfast_outlined,
                                      size: 15,
                                      color: _shiftColor(shift),
                                    ),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Text(
                                        'Istirahat ${shift!.breakStartTime} - ${shift.breakEndTime}',
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: Colors.grey[800],
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                    Text(
                                      _resolveBreakPreviewStatus(shift),
                                      style: TextStyle(
                                        fontSize: 10,
                                        color: _shiftColor(shift),
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
        ],
      ),
    );
  }

  Widget _buildEmptyShiftCard() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey[300]!, style: BorderStyle.solid),
        color: Colors.grey[50],
      ),
      child: Text(
        'Tidak ada shift',
        style: TextStyle(fontSize: 12, color: Colors.grey[600]),
        textAlign: TextAlign.center,
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
            _error ?? 'Gagal memuat jadwal shift',
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
}
