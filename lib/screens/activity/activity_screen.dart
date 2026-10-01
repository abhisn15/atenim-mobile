import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'dart:io';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../../providers/activity_provider.dart';
import '../../providers/checkpoint_provider.dart';
import 'activity_form_screen.dart';
import '../team/team_tasks_screen.dart';
import '../../models/activity_model.dart';
import '../../models/team_task_model.dart';
import '../../config/api_config.dart';
import '../../services/team_service.dart';
import '../../widgets/motion.dart';
import '../../widgets/ui_kit.dart';

class ActivityScreen extends StatefulWidget {
  const ActivityScreen({super.key});

  @override
  State<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends State<ActivityScreen> {
  // Helper untuk membedakan daily activity dan patroli
  bool _isPatroli(DailyActivity activity) {
    // Use the model's computed isPatroli property
    return activity.isPatroli;
  }

  bool _hasCheckpointHistory(DailyActivity activity) {
    final hasTemplateId =
        (activity.checkpointTemplateId ?? '').trim().isNotEmpty;
    final hasCheckpointItems =
        activity.checkpoints != null && activity.checkpoints!.isNotEmpty;
    final summary = activity.summary.toLowerCase();
    final hasSummaryHint = summary.contains('checkpoint progress');
    return hasTemplateId || hasCheckpointItems || hasSummaryHint;
  }

  bool _isTaskEvidenceActivity(DailyActivity activity) {
    final summary = activity.summary.trim();
    return RegExp(
          r'\[TASK:[^\]]+\]',
          caseSensitive: false,
        ).hasMatch(summary) ||
        summary.toLowerCase().contains('penyelesaian tugas');
  }

  bool _isLeaderManualTaskActivity(DailyActivity activity) {
    if (!_isTaskEvidenceActivity(activity)) return false;
    return activity.summary.toLowerCase().contains('penyelesaian tugas');
  }

  bool _isCheckpointActivity(DailyActivity activity) {
    return _isPatroli(activity) ||
        _hasCheckpointHistory(activity) ||
        _isTaskEvidenceActivity(activity);
  }

  String _displaySummary(DailyActivity activity) {
    if (_isTaskEvidenceActivity(activity)) {
      final withoutMarker = activity.summary
          .replaceFirst(
            RegExp(r'^\[TASK:[^\]]+\]\s*', caseSensitive: false),
            '',
          )
          .trim();
      return withoutMarker
          .replaceFirst(
            RegExp(r'^penyelesaian tugas:\s*', caseSensitive: false),
            '',
          )
          .trim();
    }

    if (activity.checkpoints != null && activity.checkpoints!.isNotEmpty) {
      final total = activity.checkpoints!.length;
      final done = activity.checkpoints!.where((item) => item.completed).length;
      if (done >= total) {
        return 'Checkpoint completed: $done/$total';
      }
      return 'Checkpoint progress: $done/$total';
    }

    final withoutMarker = activity.summary
        .replaceFirst(
          RegExp(r'^\[TASK:[^\]]+\]\s*', caseSensitive: false),
          '',
        )
        .trim();
    return withoutMarker
        .replaceFirst(
          RegExp(r'^penyelesaian tugas:\s*', caseSensitive: false),
          '',
        )
        .trim();
  }

  // Default: bulan ini (tanggal 1 sampai hari ini)
  late DateTime _startDate = _getDefaultStartDate();
  late DateTime _endDate = _getDefaultEndDate();
  int _currentPage = 1;
  final int _itemsPerPage = 10;
  final TeamService _teamService = TeamService();
  List<TeamTask> _manualTasks = [];
  bool _isLoadingManualTasks = false;
  String? _expandedActivityId;

  static DateTime _getDefaultStartDate() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, 1);
  }

  static DateTime _getDefaultEndDate() {
    return DateTime.now();
  }

  Widget _buildCheckpointTodayCard(CheckpointProvider checkpointProvider) {
    final previews = checkpointProvider.todoPreviews;
    final manualTasks = _getOpenManualTasks();
    final totalDone = previews.fold<int>(
      0,
      (sum, preview) => sum + preview.completedCount,
    );
    final totalItems = previews.fold<int>(
      0,
      (sum, preview) => sum + preview.totalCount,
    );
    final totalPending = previews.fold<int>(
      0,
      (sum, preview) => sum + preview.pendingItems.length,
    );
    final allCheckpointDone = totalItems > 0 && totalPending == 0;
    final allCompleted = allCheckpointDone && manualTasks.isEmpty;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.green.shade100),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.checklist_rtl, size: 18, color: Colors.green),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  allCompleted
                      ? 'Checkpoint Completed'
                      : 'Daftar Checkpoint Hari Ini',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                '$totalDone/$totalItems',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Colors.green.shade800,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.refresh, size: 18),
                onPressed: () async {
                  await checkpointProvider.loadCheckpoint(force: true);
                  if (!mounted) return;
                  await _loadManualTasks(silent: true);
                },
                tooltip: 'Refresh checkpoint',
              ),
            ],
          ),
          if (previews.isEmpty)
            Text(
              'Belum ada template checkpoint aktif hari ini',
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            )
          else if (allCompleted) ...[
            Text(
              'Semua checkpoint hari ini selesai. Hasilnya ada di list Checkpoint Activity.',
              style: TextStyle(
                fontSize: 12,
                color: Colors.green.shade700,
                fontWeight: FontWeight.w600,
              ),
            ),
          ] else ...[
            Text(
              totalPending > 0
                  ? '$totalPending item checkpoint belum selesai'
                  : 'Semua checkpoint hari ini sudah selesai',
              style: TextStyle(
                fontSize: 12,
                color: totalPending > 0
                    ? Colors.orange.shade700
                    : Colors.green.shade700,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            ...previews.map((preview) {
              final pending = preview.pendingItems;
              return Container(
                margin: const EdgeInsets.only(top: 8),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: Colors.grey[50],
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.grey[200]!),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            preview.templateName,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Text(
                          '${preview.completedCount}/${preview.totalCount}',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: Colors.grey.shade700,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    if (pending.isEmpty)
                      Text(
                        'Selesai',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.green.shade700,
                          fontWeight: FontWeight.w600,
                        ),
                      )
                    else ...[
                      ...pending
                          .take(2)
                          .map(
                            (item) => Padding(
                              padding: const EdgeInsets.only(bottom: 2),
                              child: Text(
                                '- ${item.name}',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey.shade700,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                      if (pending.length > 2)
                        Text(
                          '+${pending.length - 2} item lain',
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.grey.shade600,
                          ),
                        ),
                    ],
                  ],
                ),
              );
            }),
            if (_isLoadingManualTasks)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  'Memuat tugas manual...',
                  style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                ),
              )
            else ...[
              const SizedBox(height: 10),
              Text(
                'Tugas Manual Team Leader',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: Colors.blueGrey.shade700,
                ),
              ),
              const SizedBox(height: 6),
              if (manualTasks.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'Belum ada tugas manual aktif',
                    style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                  ),
                )
              else ...[
                ...manualTasks.take(3).map((task) {
                  final dueLabel = task.dueDate == null
                      ? 'Tanpa deadline'
                      : DateFormat(
                          'dd MMM yyyy',
                          'id_ID',
                        ).format(task.dueDate!.toLocal());
                  return Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      '- ${task.title} ($dueLabel)',
                      style: TextStyle(fontSize: 11, color: Colors.grey[700]),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  );
                }),
                if (manualTasks.length > 3)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      '+${manualTasks.length - 3} tugas manual lainnya',
                      style: TextStyle(fontSize: 10, color: Colors.grey[600]),
                    ),
                  ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: _openMyManualTasks,
                    icon: const Icon(Icons.open_in_new, size: 16),
                    label: const Text('Buka & kerjakan tugas manual'),
                  ),
                ),
              ],
            ],
          ],
        ],
      ),
    );
  }

  DateTime? _parseActivityDate(DailyActivity activity) {
    final parsedDate = DateTime.tryParse(activity.date);
    final createdAt = activity.createdAt.isNotEmpty
        ? DateTime.tryParse(activity.createdAt)?.toLocal()
        : null;
    if (parsedDate == null) {
      return createdAt;
    }
    if (createdAt == null) {
      return parsedDate;
    }
    final dateOnly = DateTime(
      parsedDate.year,
      parsedDate.month,
      parsedDate.day,
    );
    final createdOnly = DateTime(
      createdAt.year,
      createdAt.month,
      createdAt.day,
    );
    final diffDays = (createdOnly.difference(dateOnly).inDays).abs();
    if (diffDays <= 1) {
      return createdAt;
    }
    return parsedDate;
  }

  String _formatActivityTypeLabel(String? value) {
    switch ((value ?? 'normal').toLowerCase()) {
      case 'before':
        return 'Sebelum shift';
      case 'after':
        return 'Sesudah shift';
      default:
        return 'Aktivitas biasa';
    }
  }

  String? _formatActivityTime(DailyActivity activity) {
    if (activity.createdAt.isNotEmpty) {
      final createdAt = DateTime.tryParse(activity.createdAt)?.toLocal();
      if (createdAt != null) {
        return DateFormat('HH:mm').format(createdAt);
      }
    }
    final dateValue = activity.date;
    if (dateValue.contains('T') || dateValue.contains(':')) {
      final parsed = DateTime.tryParse(dateValue)?.toLocal();
      if (parsed != null) {
        return DateFormat('HH:mm').format(parsed);
      }
    }
    return null;
  }

  bool _isLocalPhotoUrl(String url) {
    return url.startsWith('file://');
  }

  String _resolveLocalPath(String url) {
    if (!url.startsWith('file://')) {
      return url;
    }
    try {
      return Uri.parse(url).toFilePath();
    } catch (_) {
      return url.replaceFirst('file://', '');
    }
  }

  bool _isTaskOpenStatus(String status) {
    return status == 'todo' || status == 'in_progress';
  }

  List<TeamTask> _getOpenManualTasks() {
    return _manualTasks
        .where((task) => _isTaskOpenStatus(task.status))
        .toList();
  }

  Future<void> _loadManualTasks({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _isLoadingManualTasks = true;
      });
    }
    try {
      final tasks = await _teamService.getMyOpenTasks(limit: 100);
      if (!mounted) return;
      setState(() {
        _manualTasks = tasks;
        _isLoadingManualTasks = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _manualTasks = [];
        _isLoadingManualTasks = false;
      });
    }
  }

  Future<void> _openMyManualTasks() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const TeamTasksScreen(
          isLeader: false,
          teams: [],
          membersByTeam: {},
        ),
      ),
    );
    if (!mounted) return;
    await Provider.of<ActivityProvider>(context, listen: false).loadActivities();
    await Provider.of<CheckpointProvider>(
      context,
      listen: false,
    ).loadCheckpoint(force: true);
    if (!mounted) return;
    await _loadManualTasks(silent: true);
  }

  Future<void> _openActivityFormFlow() async {
    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const ActivityFormScreen()),
    );
    if (result == true && mounted) {
      Provider.of<ActivityProvider>(context, listen: false).loadActivities();
      await Provider.of<CheckpointProvider>(
        context,
        listen: false,
      ).loadCheckpoint(force: true);
      if (!mounted) return;
      await _loadManualTasks(silent: true);
    }
  }

  Future<void> _openAddAction({required bool hasAssignedCheckpoint}) async {
    final hasOpenManualTasks = _getOpenManualTasks().isNotEmpty;
    if (!hasAssignedCheckpoint || !hasOpenManualTasks) {
      await _openActivityFormFlow();
      return;
    }

    if (!mounted) return;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.checklist_rtl),
              title: const Text('Isi Checkpoint Hari Ini'),
              subtitle: const Text('Lanjutkan checklist checkpoint'),
              onTap: () => Navigator.of(sheetContext).pop('checkpoint'),
            ),
            ListTile(
              leading: const Icon(Icons.assignment_turned_in_outlined),
              title: const Text('Kerjakan Tugas Manual'),
              subtitle: const Text('Buka tugas dari Team Leader'),
              onTap: () => Navigator.of(sheetContext).pop('manual'),
            ),
          ],
        ),
      ),
    );

    if (!mounted || action == null) return;
    if (action == 'manual') {
      await _openMyManualTasks();
      return;
    }
    await _openActivityFormFlow();
  }

  @override
  void initState() {
    super.initState();
    // Set default ke bulan ini
    final now = DateTime.now();
    _startDate = DateTime(now.year, now.month, 1);
    _endDate = now;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final activityProvider = Provider.of<ActivityProvider>(
        context,
        listen: false,
      );
      final checkpointProvider = Provider.of<CheckpointProvider>(
        context,
        listen: false,
      );

      activityProvider.loadActivities();
      checkpointProvider.loadCheckpoint(force: true).then((_) {
        if (!mounted) return;
        _loadManualTasks(silent: true);
      });
    });
  }

  Future<void> _selectDateRange(BuildContext context) async {
    final DateTimeRange? picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
      initialDateRange: DateTimeRange(start: _startDate, end: _endDate),
      locale: const Locale('id', 'ID'),
      helpText: 'Pilih Rentang Tanggal',
      cancelText: 'Batal',
      confirmText: 'Pilih',
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: ColorScheme.light(
              primary: Theme.of(context).primaryColor,
              onPrimary: Colors.white,
              surface: Colors.white,
              onSurface: Colors.black87,
            ),
          ),
          child: child!,
        );
      },
    );

    if (picked != null &&
        picked != DateTimeRange(start: _startDate, end: _endDate)) {
      setState(() {
        _startDate = picked.start;
        _endDate = picked.end;
        _currentPage = 1; // Reset to first page
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final checkpointProvider = Provider.of<CheckpointProvider>(context);
    final isResolvingCheckpointMode = !checkpointProvider.hasFetchedOnce;
    if (isResolvingCheckpointMode) {
      return Scaffold(
        appBar: AppBar(title: const Text('Aktivitas')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: const [
            SkeletonListCard(),
            SizedBox(height: 12),
            SkeletonListCard(),
            SizedBox(height: 12),
            SkeletonListCard(),
          ],
        ),
      );
    }

    final hasAssignedCheckpoint =
        checkpointProvider.hasCheckpoint ||
        checkpointProvider.templateStates.isNotEmpty;
    final effectiveViewMode = hasAssignedCheckpoint ? 'checkpoint' : 'daily';

    return Scaffold(
      appBar: AppBar(
        title: Text(
          effectiveViewMode == 'checkpoint'
              ? 'Aktivitas Checkpoint'
              : 'Aktivitas',
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: hasAssignedCheckpoint ? 'Isi checkpoint' : 'Tambah aktivitas',
            onPressed: () async {
              if (hasAssignedCheckpoint) {
                await Provider.of<CheckpointProvider>(
                  context,
                  listen: false,
                ).loadCheckpoint(force: true);
              }
              if (!mounted) return;
              await _openAddAction(
                hasAssignedCheckpoint: hasAssignedCheckpoint,
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          if (hasAssignedCheckpoint)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AtenimUi.brandSoft,
                  borderRadius: BorderRadius.circular(AtenimUi.radiusControl),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline, size: 18, color: Colors.blue[800]),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Checkpoint aktif untuk Anda. Input aktivitas manual disembunyikan.',
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.35,
                          color: Colors.blue[900],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: DateRangeBar(
              start: _startDate,
              end: _endDate,
              onRange: (start, end) => setState(() {
                _startDate = start;
                _endDate = end;
                _currentPage = 1;
              }),
              onPickCustom: () => _selectDateRange(context),
            ),
          ),
          if (effectiveViewMode == 'checkpoint')
            _buildCheckpointTodayCard(checkpointProvider),
          // Activity List
          Expanded(
            child: Consumer<ActivityProvider>(
              builder: (context, activityProvider, _) {
                debugPrint(
                  '[ActivityScreen] Consumer rebuilding - isLoading: ${activityProvider.isLoading}, error: ${activityProvider.error}',
                );
                // Data yang sudah tampil tidak diganti kerangka saat dimuat ulang.
                if (activityProvider.isLoading &&
                    activityProvider.recentActivities.isEmpty &&
                    activityProvider.todayActivity == null) {
                  return ListView(
                    padding: const EdgeInsets.all(16),
                    children: const [
                      SkeletonListCard(),
                      SizedBox(height: 12),
                      SkeletonListCard(),
                      SizedBox(height: 12),
                      SkeletonListCard(),
                    ],
                  );
                }

                if (activityProvider.error != null) {
                  return SingleChildScrollView(
                    child: ErrorState(
                      title: 'Aktivitas tidak bisa dimuat',
                      message:
                          'Periksa koneksi internet Anda, lalu coba lagi. Aktivitas yang belum terkirim tetap tersimpan di HP.',
                      onRetry: () => activityProvider.loadActivities(),
                    ),
                  );
                }

                final recent = activityProvider.recentActivities;
                final today = activityProvider.todayActivity;
                debugPrint(
                  '[ActivityScreen] Provider data - today: ${today?.summary}, recent: ${recent.length}',
                );

                // Filter aktivitas berdasarkan tanggal
                final startDateOnly = DateTime(
                  _startDate.year,
                  _startDate.month,
                  _startDate.day,
                );
                final endDateOnly = DateTime(
                  _endDate.year,
                  _endDate.month,
                  _endDate.day,
                ).add(const Duration(days: 1));

                // Combine all activities first (pending activities already merged in ActivityProvider)
                final allActivities = <DailyActivity>[];
                if (today != null) {
                  allActivities.add(today);
                  debugPrint(
                    '[ActivityScreen] Today activity: ${today.summary}, type: ${today.type}, isPatroli: ${today.isPatroli}',
                  );
                }
                allActivities.addAll(recent);

                final activitiesByMode = allActivities.where((activity) {
                  final checkpoint = _isCheckpointActivity(activity);
                  return effectiveViewMode == 'checkpoint'
                      ? checkpoint
                      : !checkpoint;
                }).toList();
                debugPrint(
                  '[ActivityScreen] Total activities: ${allActivities.length}, mode=$effectiveViewMode, result=${activitiesByMode.length}',
                );

                // Filter by date range
                final allFilteredActivities = activitiesByMode.where((
                  activity,
                ) {
                  try {
                    final activityDate = _parseActivityDate(activity);
                    if (activityDate == null) {
                      return true;
                    }
                    final activityDateOnly = DateTime(
                      activityDate.year,
                      activityDate.month,
                      activityDate.day,
                    );
                    return activityDateOnly.isAfter(
                          startDateOnly.subtract(const Duration(days: 1)),
                        ) &&
                        activityDateOnly.isBefore(endDateOnly);
                  } catch (e) {
                    return false;
                  }
                }).toList();

                // Calculate pagination
                final totalItems = allFilteredActivities.length;
                final totalPages = totalItems > 0
                    ? (totalItems / _itemsPerPage).ceil()
                    : 1;
                final startIndex = (_currentPage - 1) * _itemsPerPage;
                final endIndex = startIndex + _itemsPerPage;
                final paginatedActivities = totalItems > 0
                    ? allFilteredActivities.sublist(
                        startIndex.clamp(0, totalItems),
                        endIndex.clamp(0, totalItems),
                      )
                    : <DailyActivity>[];

                // Separate today and recent for display
                DailyActivity? paginatedToday;
                List<DailyActivity> paginatedRecent = [];

                if (paginatedActivities.isNotEmpty) {
                  // Check if first item is today
                  if (today != null &&
                      paginatedActivities.first.id == today.id) {
                    paginatedToday = paginatedActivities.first;
                    paginatedRecent = paginatedActivities.skip(1).toList();
                  } else {
                    paginatedRecent = paginatedActivities;
                  }
                }

                if (allFilteredActivities.isEmpty) {
                  return SingleChildScrollView(
                    child: EmptyState(
                      icon: Icons.assignment_outlined,
                      title: effectiveViewMode == 'checkpoint'
                          ? 'Belum ada data checkpoint'
                          : 'Belum ada aktivitas',
                      message: effectiveViewMode == 'checkpoint'
                          ? 'Checkpoint yang Anda isi pada rentang tanggal ini akan tampil di sini. Coba perluas rentang tanggalnya.'
                          : 'Aktivitas yang Anda catat pada rentang tanggal ini akan tampil di sini. Coba perluas rentang tanggalnya, atau catat aktivitas baru.',
                      actionLabel: effectiveViewMode == 'checkpoint'
                          ? 'Isi Checkpoint'
                          : 'Tambah Aktivitas',
                      onAction: () async {
                        if (effectiveViewMode == 'checkpoint') {
                          await Provider.of<CheckpointProvider>(
                            context,
                            listen: false,
                          ).loadCheckpoint(force: true);
                        }
                        if (!context.mounted) return;
                        final result = await Navigator.push<bool>(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const ActivityFormScreen(),
                          ),
                        );
                        if (result == true && mounted) {
                          activityProvider.loadActivities();
                          await Provider.of<CheckpointProvider>(
                            context,
                            listen: false,
                          ).loadCheckpoint(force: true);
                          if (!mounted) return;
                          await _loadManualTasks(silent: true);
                        }
                      },
                    ),
                  );
                }

                return RefreshIndicator(
                  onRefresh: () async {
                    await activityProvider.loadActivities();
                    if (effectiveViewMode == 'checkpoint') {
                      await Provider.of<CheckpointProvider>(
                        context,
                        listen: false,
                      ).loadCheckpoint(force: true);
                      if (!mounted) return;
                      await _loadManualTasks(silent: true);
                    }
                  },
                  child: Column(
                    children: [
                      Expanded(
                        child: NotificationListener<UserScrollNotification>(
                          onNotification: (notification) {
                            if (notification.direction != ScrollDirection.idle &&
                                _expandedActivityId != null) {
                              setState(() {
                                _expandedActivityId = null;
                              });
                            }
                            return false;
                          },
                          child: ListView(
                            padding: const EdgeInsets.all(16),
                            children: [
                              if (paginatedToday != null) ...[
                                FadeSlideIn(
                                  key: ValueKey('act-${paginatedToday.id}'),
                                  child: _buildActivityCard(
                                    context,
                                    paginatedToday,
                                    isToday: true,
                                  ),
                                ),
                                const SizedBox(height: 16),
                              ],
                              if (paginatedRecent.isNotEmpty) ...[
                                Text(
                                  effectiveViewMode == 'checkpoint'
                                      ? 'Riwayat Checkpoint'
                                      : 'Riwayat',
                                  style: Theme.of(context).textTheme.titleMedium
                                      ?.copyWith(fontWeight: FontWeight.bold),
                                ),
                                const SizedBox(height: 8),
                                for (var i = 0; i < paginatedRecent.length; i++)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 8),
                                    child: FadeSlideIn(
                                      key: ValueKey('act-${paginatedRecent[i].id}'),
                                      delay: Motion.stagger(i + 1),
                                      child: _buildActivityCard(
                                        context,
                                        paginatedRecent[i],
                                      ),
                                    ),
                                  ),
                              ],
                            ],
                          ),
                        ),
                      ),
                      // Pagination (always show if more than itemsPerPage)
                      if (totalItems > _itemsPerPage)
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: Colors.grey[50],
                            border: Border(
                              top: BorderSide(color: Colors.grey[200]!),
                            ),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'Menampilkan ${startIndex + 1}-${endIndex.clamp(0, totalItems)} dari $totalItems',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey[600],
                                ),
                              ),
                              Row(
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.chevron_left),
                                    onPressed: _currentPage > 1
                                        ? () {
                                            setState(() {
                                              _currentPage--;
                                            });
                                          }
                                        : null,
                                  ),
                                  Text(
                                    '$_currentPage / $totalPages',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.chevron_right),
                                    onPressed: _currentPage < totalPages
                                        ? () {
                                            setState(() {
                                              _currentPage++;
                                            });
                                          }
                                        : null,
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActivityCard(
    BuildContext context,
    DailyActivity activity, {
    bool isToday = false,
  }) {
    final isCheckpoint = _isCheckpointActivity(activity);
    final isTaskEvidence = _isTaskEvidenceActivity(activity);
    final isLeaderManualTask = _isLeaderManualTaskActivity(activity);
    final summaryText = _displaySummary(activity);
    final activityDate = _parseActivityDate(activity);
    final activityDateLabel = activityDate != null
        ? DateFormat('EEEE, d MMMM yyyy', 'id_ID').format(activityDate)
        : (activity.date.isNotEmpty ? activity.date : 'Tanggal tidak tersedia');
    final activityTimeLabel = _formatActivityTime(activity);
    final isExpanded = _expandedActivityId == activity.id;
    return AtenimCard(
      padding: EdgeInsets.zero,
      borderColor: isToday ? Colors.blue[100] : null,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        shape: const Border(),
        collapsedShape: const Border(),
        key: ValueKey(
          'activity-${activity.id}-${isExpanded ? "open" : "closed"}',
        ),
        initiallyExpanded: isExpanded,
        onExpansionChanged: (expanded) {
          setState(() {
            if (expanded) {
              _expandedActivityId = activity.id;
            } else if (_expandedActivityId == activity.id) {
              _expandedActivityId = null;
            }
          });
        },
        leading: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: AtenimUi.brandSoft,
                borderRadius: BorderRadius.circular(AtenimUi.radiusControl),
              ),
              child: Icon(
                isCheckpoint ? Icons.checklist_rtl : Icons.assignment_outlined,
                color: AtenimUi.brand,
                size: 22,
              ),
            ),
            // Titik hijau = sudah dilihat atasan (status nyata dari server).
            if (activity.isRead == true)
              Positioned(
                right: -2,
                top: -2,
                child: Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: Colors.green[600],
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2),
                  ),
                ),
              ),
          ],
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              isToday ? 'Hari ini' : activityDateLabel,
              style: TextStyle(
                fontSize: 15,
                fontWeight: isToday ? FontWeight.w800 : FontWeight.w700,
                color: AtenimUi.ink,
              ),
            ),
            if (activityTimeLabel != null)
              Text(
                activityTimeLabel,
                style: TextStyle(fontSize: 12, color: AtenimUi.inkSoft),
              ),
            // "Aktivitas biasa" tidak ditampilkan di kartu: hanya tipe khusus yang bermakna.
            if (!isCheckpoint &&
                !isTaskEvidence &&
                const ['before', 'after'].contains(activity.activityType.toLowerCase()))
              Text(
                _formatActivityTypeLabel(activity.activityType),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Colors.blue[800],
                ),
              ),
            if (isLeaderManualTask ||
                activity.isLocal ||
                (activity.isRead == true && (activity.viewsCount ?? 0) > 0))
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    if (isLeaderManualTask)
                      const StatusPill(
                        label: 'Tugas manual dari leader',
                        tone: Tone.info,
                      ),
                    if (activity.isLocal)
                      const StatusPill(
                        label: 'Menunggu koneksi',
                        tone: Tone.warning,
                        icon: Icons.schedule,
                      ),
                    if (activity.isRead == true && (activity.viewsCount ?? 0) > 0)
                      StatusPill(
                        label: 'Dilihat ${activity.viewsCount}',
                        tone: Tone.success,
                        icon: Icons.visibility_outlined,
                      ),
                  ],
                ),
              ),
          ],
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            summaryText,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 14, color: AtenimUi.inkSoft, height: 1.35),
          ),
        ),
        trailing: activity.isLocal || isCheckpoint || isTaskEvidence
            ? const SizedBox.shrink()
            : PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert),
                onSelected: (value) async {
                  if (value == 'edit') {
                    final result = await Navigator.push<bool>(
                      context,
                      MaterialPageRoute(
                        builder: (_) =>
                            ActivityFormScreen(activityId: activity.id),
                      ),
                    );
                    if (result == true && mounted) {
                      Provider.of<ActivityProvider>(
                        context,
                        listen: false,
                      ).loadActivities();
                    }
                  } else if (value == 'delete') {
                    final confirm = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('Hapus Aktivitas'),
                        content: const Text(
                          'Apakah Anda yakin ingin menghapus aktivitas ini?',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context, false),
                            child: const Text('Batal'),
                          ),
                          TextButton(
                            onPressed: () => Navigator.pop(context, true),
                            style: TextButton.styleFrom(
                              foregroundColor: Colors.red,
                            ),
                            child: const Text('Hapus'),
                          ),
                        ],
                      ),
                    );
                    if (confirm == true && mounted) {
                      final provider = Provider.of<ActivityProvider>(
                        context,
                        listen: false,
                      );
                      final success = await provider.deleteActivity(
                        activity.id,
                      );
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              success
                                  ? 'Aktivitas berhasil dihapus'
                                  : provider.error ??
                                        'Gagal menghapus aktivitas',
                            ),
                            backgroundColor: success
                                ? Colors.green
                                : Colors.red,
                          ),
                        );
                      }
                    }
                  }
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(
                    value: 'edit',
                    child: Row(
                      children: [
                        Icon(Icons.edit, size: 20),
                        SizedBox(width: 8),
                        Text('Edit'),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'delete',
                    child: Row(
                      children: [
                        Icon(Icons.delete, size: 20, color: Colors.red),
                        SizedBox(width: 8),
                        Text('Hapus', style: TextStyle(color: Colors.red)),
                      ],
                    ),
                  ),
                ],
              ),
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!isCheckpoint && !isTaskEvidence)
                  _buildInfoRow(
                    'Jenis',
                    _formatActivityTypeLabel(activity.activityType),
                  ),
                if (isLeaderManualTask)
                  _buildInfoRow('Label', 'Tugas manual dari leader'),
                _buildInfoRow('Keterangan', summaryText),
                if (isCheckpoint &&
                    activity.checkpoints != null &&
                    activity.checkpoints!.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _buildCheckpointTimeline(context, activity.checkpoints!),
                ],
                if (isLeaderManualTask) ...[
                  const SizedBox(height: 8),
                  _buildManualTaskTimeline(
                    context,
                    activity: activity,
                    summaryText: summaryText,
                  ),
                ] else if (activity.photoUrls != null &&
                    activity.photoUrls!.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  _buildActivityPhotoSection(
                    context,
                    title: 'Foto Bukti',
                    photoUrls: activity.photoUrls!,
                  ),
                ],
              ],
            ),
          ),
        ],
        ),
      ),
    );
  }

  Widget _buildActivityPhotoSection(
    BuildContext context, {
    required String title,
    required List<String> photoUrls,
  }) {
    final sanitized = photoUrls
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList();
    if (sanitized.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: List.generate(sanitized.length, (index) {
            final url = sanitized[index];
            final isLocal = _isLocalPhotoUrl(url);
            final localPath = isLocal ? _resolveLocalPath(url) : null;
            final fullUrl = isLocal ? null : ApiConfig.getImageUrl(url);
            return GestureDetector(
              onTap: () =>
                  _showPhotoGallery(context, sanitized, initialIndex: index),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  width: 120,
                  height: 160,
                  color: Colors.grey[100],
                  child: isLocal
                      ? Image.file(
                          File(localPath!),
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) {
                            return Container(
                              color: Colors.grey[200],
                              child: Icon(
                                Icons.broken_image,
                                color: Colors.grey[400],
                              ),
                            );
                          },
                        )
                      : Image.network(
                          fullUrl!,
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) {
                            return Container(
                              color: Colors.grey[200],
                              child: Icon(
                                Icons.broken_image,
                                color: Colors.grey[400],
                              ),
                            );
                          },
                          loadingBuilder: (context, child, loadingProgress) {
                            if (loadingProgress == null) return child;
                            return Container(
                              color: Colors.grey[200],
                              child: const Center(
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ),
            );
          }),
        ),
      ],
    );
  }

  Widget _buildCheckpointTimeline(
    BuildContext context,
    List<SecurityCheckpoint> checkpoints,
  ) {
    final items = [...checkpoints];
    items.sort((a, b) {
      final orderA = a.order ?? 9999;
      final orderB = b.order ?? 9999;
      if (orderA != orderB) return orderA.compareTo(orderB);
      return a.name.compareTo(b.name);
    });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Timeline Checkpoint',
          style: TextStyle(
            fontWeight: FontWeight.w700,
            color: Colors.blueGrey[800],
          ),
        ),
        const SizedBox(height: 8),
        ...List.generate(items.length, (index) {
          final item = items[index];
          final isLast = index == items.length - 1;
          return _buildCheckpointTimelineItem(context, item, isLast: isLast);
        }),
      ],
    );
  }

  Widget _buildManualTaskTimeline(
    BuildContext context, {
    required DailyActivity activity,
    required String summaryText,
  }) {
    final activityTime = _formatActivityTime(activity);
    final hasPhotos = activity.photoUrls != null && activity.photoUrls!.isNotEmpty;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 28,
          child: Column(
            children: [
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: Colors.blue[500],
                  shape: BoxShape.circle,
                ),
              ),
              Container(
                width: 2,
                height: hasPhotos ? 110 : 52,
                color: Colors.blue.withValues(alpha: 0.3),
              ),
            ],
          ),
        ),
        Expanded(
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.blue.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.blue.withValues(alpha: 0.3)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Timeline Tugas Manual',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: Colors.blue[800],
                  ),
                ),
                if (activityTime != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    'Waktu submit: $activityTime',
                    style: TextStyle(fontSize: 11, color: Colors.grey[700]),
                  ),
                ],
                const SizedBox(height: 6),
                Text(
                  summaryText,
                  style: TextStyle(fontSize: 12, color: Colors.grey[800]),
                ),
                if (hasPhotos) ...[
                  const SizedBox(height: 8),
                  _buildActivityPhotoSection(
                    context,
                    title: 'Bukti Tugas Manual',
                    photoUrls: activity.photoUrls!,
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCheckpointTimelineItem(
    BuildContext context,
    SecurityCheckpoint checkpoint, {
    required bool isLast,
  }) {
    final itemTime = checkpoint.timestamp != null
        ? DateTime.tryParse(checkpoint.timestamp!)?.toLocal()
        : null;
    final timeLabel = itemTime != null
        ? DateFormat('dd MMM yyyy • HH:mm', 'id_ID').format(itemTime)
        : null;
    final note = (checkpoint.notes ?? checkpoint.photoReason ?? '').trim();
    final beforePhotos = checkpoint.beforePhotos;
    final afterPhotos = checkpoint.afterPhotos;
    final hasAnyPhotos = beforePhotos.isNotEmpty || afterPhotos.isNotEmpty;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 28,
          child: Column(
            children: [
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: checkpoint.completed ? Colors.green : Colors.grey[400],
                  shape: BoxShape.circle,
                ),
              ),
              if (!isLast)
                Container(
                  width: 2,
                  height: 96,
                  color: Colors.grey[300],
                ),
            ],
          ),
        ),
        Expanded(
          child: Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: checkpoint.completed
                  ? Colors.green.withValues(alpha: 0.06)
                  : Colors.grey.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: checkpoint.completed
                    ? Colors.green.withValues(alpha: 0.35)
                    : Colors.grey.withValues(alpha: 0.3),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        checkpoint.name,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                        ),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(20),
                        color: checkpoint.completed
                            ? Colors.green.withValues(alpha: 0.14)
                            : Colors.orange.withValues(alpha: 0.16),
                      ),
                      child: Text(
                        checkpoint.completed ? 'Selesai' : 'Belum selesai',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: checkpoint.completed
                              ? Colors.green[700]
                              : Colors.orange[700],
                        ),
                      ),
                    ),
                  ],
                ),
                if (timeLabel != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    timeLabel,
                    style: TextStyle(fontSize: 11, color: Colors.grey[700]),
                  ),
                ],
                if (note.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    note,
                    style: TextStyle(fontSize: 12, color: Colors.grey[800]),
                  ),
                ],
                if (hasAnyPhotos) ...[
                  const SizedBox(height: 8),
                  if (beforePhotos.isNotEmpty)
                    _buildCheckpointPhotoStrip(
                      context,
                      label: 'Before',
                      photoUrls: beforePhotos,
                    ),
                  if (afterPhotos.isNotEmpty) ...[
                    if (beforePhotos.isNotEmpty) const SizedBox(height: 8),
                    _buildCheckpointPhotoStrip(
                      context,
                      label: 'After',
                      photoUrls: afterPhotos,
                    ),
                  ],
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCheckpointPhotoStrip(
    BuildContext context, {
    required String label,
    required List<String> photoUrls,
  }) {
    final sanitized = photoUrls
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList();
    if (sanitized.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$label (${sanitized.length})',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: Colors.grey[700],
          ),
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: List.generate(sanitized.length, (index) {
            final rawUrl = sanitized[index];
            final isLocal = _isLocalPhotoUrl(rawUrl);
            final localPath = isLocal ? _resolveLocalPath(rawUrl) : null;
            final fullUrl = isLocal ? null : ApiConfig.getImageUrl(rawUrl);
            return GestureDetector(
              onTap: () =>
                  _showPhotoGallery(context, sanitized, initialIndex: index),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 76,
                  height: 76,
                  child: isLocal
                      ? Image.file(File(localPath!), fit: BoxFit.cover)
                      : Image.network(
                          fullUrl!,
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) => Container(
                            color: Colors.grey[200],
                            child: Icon(
                              Icons.broken_image,
                              size: 18,
                              color: Colors.grey[500],
                            ),
                          ),
                        ),
                ),
              ),
            );
          }),
        ),
      ],
    );
  }

  void _showPhotoGallery(
    BuildContext context,
    List<String> photoUrls, {
    int initialIndex = 0,
  }) {
    if (photoUrls.isEmpty) return;
    showDialog(
      context: context,
      builder: (_) => _ActivityPhotoGalleryDialog(
        photoUrls: photoUrls,
        initialIndex: initialIndex,
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: TextStyle(
                color: Colors.grey[700],
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}

class _ActivityPhotoGalleryDialog extends StatefulWidget {
  final List<String> photoUrls;
  final int initialIndex;

  const _ActivityPhotoGalleryDialog({
    required this.photoUrls,
    this.initialIndex = 0,
  });

  @override
  State<_ActivityPhotoGalleryDialog> createState() =>
      _ActivityPhotoGalleryDialogState();
}

class _ActivityPhotoGalleryDialogState extends State<_ActivityPhotoGalleryDialog> {
  late final PageController _pageController;
  late int _currentIndex;

  @override
  void initState() {
    super.initState();
    final safeIndex = widget.initialIndex
        .clamp(0, widget.photoUrls.length - 1)
        .toInt();
    _currentIndex = safeIndex;
    _pageController = PageController(initialPage: safeIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  bool _isLocal(String value) => value.startsWith('file://');

  String _localPath(String value) {
    try {
      return Uri.parse(value).toFilePath();
    } catch (_) {
      return value.replaceFirst('file://', '');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: EdgeInsets.zero,
      backgroundColor: Colors.black.withValues(alpha: 0.92),
      child: Stack(
        children: [
          PageView.builder(
            controller: _pageController,
            itemCount: widget.photoUrls.length,
            onPageChanged: (value) => setState(() => _currentIndex = value),
            itemBuilder: (context, index) {
              final raw = widget.photoUrls[index];
              final isLocal = _isLocal(raw);
              final networkUrl = isLocal ? null : ApiConfig.getImageUrl(raw);
              return InteractiveViewer(
                minScale: 0.6,
                maxScale: 4.0,
                child: Center(
                  child: isLocal
                      ? Image.file(
                          File(_localPath(raw)),
                          fit: BoxFit.contain,
                          errorBuilder: (context, error, stackTrace) =>
                              const Icon(
                            Icons.broken_image,
                            color: Colors.white70,
                            size: 64,
                          ),
                        )
                      : Image.network(
                          networkUrl!,
                          fit: BoxFit.contain,
                          loadingBuilder: (context, child, progress) {
                            if (progress == null) return child;
                            return const Center(
                              child: CircularProgressIndicator(
                                color: Colors.white,
                              ),
                            );
                          },
                          errorBuilder: (context, error, stackTrace) =>
                              const Icon(
                            Icons.broken_image,
                            color: Colors.white70,
                            size: 64,
                          ),
                        ),
                ),
              );
            },
          ),
          Positioned(
            top: MediaQuery.of(context).padding.top + 10,
            left: 14,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                '${_currentIndex + 1}/${widget.photoUrls.length}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          Positioned(
            top: MediaQuery.of(context).padding.top + 2,
            right: 6,
            child: IconButton(
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(
                Icons.close,
                color: Colors.white,
                size: 30,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
