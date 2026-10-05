import 'package:flutter/material.dart';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../../providers/activity_provider.dart';
import '../../models/activity_model.dart';
import '../../config/api_config.dart';
import '../../widgets/adaptive_image.dart';
import '../../widgets/ui_kit.dart' show EmptyState;
import 'patroli_form_screen.dart';

class PatroliListScreen extends StatefulWidget {
  const PatroliListScreen({super.key});

  @override
  State<PatroliListScreen> createState() => _PatroliListScreenState();
}

class _PatroliListScreenState extends State<PatroliListScreen> {
  // Helper untuk membedakan daily activity dan patroli
  bool _isPatroli(DailyActivity activity) {
    // Use the model's computed isPatroli property
    return activity.isPatroli;
  }
  // Default: bulan ini (tanggal 1 sampai hari ini)
  late DateTime _startDate = _getDefaultStartDate();
  late DateTime _endDate = _getDefaultEndDate();
  int _currentPage = 1;
  final int _itemsPerPage = 10;

  static DateTime _getDefaultStartDate() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, 1);
  }

  static DateTime _getDefaultEndDate() {
    return DateTime.now();
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
    final dateOnly = DateTime(parsedDate.year, parsedDate.month, parsedDate.day);
    final createdOnly = DateTime(createdAt.year, createdAt.month, createdAt.day);
    final diffDays = (createdOnly.difference(dateOnly).inDays).abs();
    if (diffDays <= 1) {
      return createdAt;
    }
    return parsedDate;
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

  @override
  void initState() {
    super.initState();
    // Set default ke bulan ini
    final now = DateTime.now();
    _startDate = DateTime(now.year, now.month, 1);
    _endDate = now;
    
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Provider.of<ActivityProvider>(context, listen: false).loadActivities();
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

    if (picked != null && picked != DateTimeRange(start: _startDate, end: _endDate)) {
      setState(() {
        _startDate = picked.start;
        _endDate = picked.end;
        _currentPage = 1; // Reset to first page
      });
    }
  }

  void _openForm() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => const PatroliFormScreen(),
      ),
    ).then((_) {
      // Refresh list after form submission
      if (!mounted) return;
      Provider.of<ActivityProvider>(context, listen: false).loadActivities();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Laporan Patroli'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: _openForm,
            tooltip: 'Tambah Patroli',
          ),
        ],
      ),
      body: Column(
        children: [
          // Date Range Filter Card
          Container(
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.blue[50],
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.blue[200]!),
            ),
            child: Row(
              children: [
                Icon(Icons.calendar_today, color: Colors.blue[700], size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Rentang Tanggal',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey[600],
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${DateFormat('dd MMM yyyy', 'id_ID').format(_startDate)} - ${DateFormat('dd MMM yyyy', 'id_ID').format(_endDate)}',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Colors.blue[900],
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.edit, color: Colors.blue[700], size: 20),
                  onPressed: () => _selectDateRange(context),
                  tooltip: 'Ubah Rentang Tanggal',
                ),
              ],
            ),
          ),
          // Patroli List
          Expanded(
            child: Consumer<ActivityProvider>(
              builder: (context, activityProvider, _) {
                if (activityProvider.isLoading) {
                  return const Center(child: CircularProgressIndicator());
                }

                if (activityProvider.error != null) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.error_outline, size: 64, color: Colors.red[300]),
                        const SizedBox(height: 16),
                        Text(
                          activityProvider.error!,
                          style: TextStyle(color: Colors.red[700]),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 16),
                        ElevatedButton(
                          onPressed: () {
                            activityProvider.loadActivities();
                          },
                          child: const Text('Coba Lagi'),
                        ),
                      ],
                    ),
                  );
                }

                // Gabungkan todayActivity dengan recentActivities untuk filter patroli
                // (pending activities already merged in ActivityProvider)
                final allActivities = <DailyActivity>[];
                if (activityProvider.todayActivity != null) {
                  allActivities.add(activityProvider.todayActivity!);
                }
                allActivities.addAll(activityProvider.recentActivities);
                debugPrint('[PatroliListScreen] Total activities: ${allActivities.length}');
                
                // Filter activities yang merupakan patroli (bukan daily activity):
                // Menggunakan helper _isPatroli() untuk konsistensi dengan ActivityScreen
                // Kemudian filter berdasarkan tanggal
                final startDateOnly = DateTime(_startDate.year, _startDate.month, _startDate.day);
                final endDateOnly = DateTime(_endDate.year, _endDate.month, _endDate.day).add(const Duration(days: 1));
                
                final patroliList = allActivities.where((activity) {
                  // Filter: hanya tampilkan patroli (bukan daily activity)
                  if (!_isPatroli(activity)) return false;

                  // Filter berdasarkan tanggal
                  final activityDate = _parseActivityDate(activity);
                  if (activityDate == null) return true;
                  final activityDateOnly = DateTime(activityDate.year, activityDate.month, activityDate.day);
                  if (activityDateOnly.isBefore(startDateOnly.subtract(const Duration(days: 1)))) return false;
                  if (activityDateOnly.isAfter(endDateOnly)) return false;

                  return true;
                }).toList();

                debugPrint('[PatroliListScreen] Filtered ${allActivities.length} total activities to ${patroliList.length} patroli activities');

                // Calculate pagination
                final totalItems = patroliList.length;
                final totalPages = totalItems > 0 ? (totalItems / _itemsPerPage).ceil() : 1;
                final startIndex = (_currentPage - 1) * _itemsPerPage;
                final endIndex = startIndex + _itemsPerPage;
                final paginatedPatroliList = totalItems > 0 ? patroliList.sublist(
                  startIndex.clamp(0, totalItems),
                  endIndex.clamp(0, totalItems),
                ) : <DailyActivity>[];

                if (patroliList.isEmpty) {
                  return Center(
                    child: SingleChildScrollView(
                      child: EmptyState(
                        icon: Icons.shield_outlined,
                        title: 'Belum ada laporan patroli',
                        message:
                            'Laporan patroli pada rentang tanggal ini akan muncul di sini. Buat laporan pertama setelah Anda berkeliling.',
                        actionLabel: 'Buat laporan patroli',
                        onAction: _openForm,
                      ),
                    ),
                  );
                }

                return RefreshIndicator(
                  onRefresh: () => activityProvider.loadActivities(),
                  child: Column(
                    children: [
                      Expanded(
                        child: ListView.builder(
                          padding: const EdgeInsets.all(16),
                          itemCount: paginatedPatroliList.length,
                          itemBuilder: (context, index) {
                            final patroli = paginatedPatroliList[index];
                            return Card(
                  margin: const EdgeInsets.only(bottom: 12),
                  child: InkWell(
                    onTap: () {
                      // Show detail
                      _showPatroliDetail(context, patroli);
                    },
                    borderRadius: BorderRadius.circular(12),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                decoration: BoxDecoration(
                                  color: Colors.blue[50],
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  DateFormat('dd MMM yyyy', 'id_ID').format(
                                    _parseActivityDate(patroli) ?? DateTime.now(),
                                  ),
                                  style: TextStyle(
                                    color: Colors.blue[900],
                                    fontWeight: FontWeight.w600,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                              const Spacer(),
                              if (patroli.isLocal)
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: Colors.orange[100],
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.schedule, size: 10, color: Colors.orange[800]),
                                      const SizedBox(width: 4),
                                      Text(
                                        'Pending - Tunggu Koneksi',
                                        style: TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.bold,
                                          color: Colors.orange[800],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              if (patroli.photoUrls != null && patroli.photoUrls!.isNotEmpty)
                                Row(
                                  children: [
                                    Icon(Icons.camera_alt, size: 16, color: Colors.grey[600]),
                                    const SizedBox(width: 4),
                                    Text(
                                      '${patroli.photoUrls!.length} foto',
                                      style: TextStyle(
                                        color: Colors.grey[600],
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          // Tampilkan locationName jika ada, jika tidak gunakan summary
                          Text(
                            (patroli.locationName != null && patroli.locationName!.isNotEmpty)
                                ? patroli.locationName!
                                : patroli.summary,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: Colors.black87,
                            ),
                          ),
                          const SizedBox(height: 8),
                          // Tampilkan deskripsi dari notes (bagian setelah locationName)
                          if (patroli.notes != null && patroli.notes!.isNotEmpty) ...[
                            Builder(
                              builder: (context) {
                                String? description;
                                if (patroli.notes!.contains('📍') && patroli.notes!.contains('\n')) {
                                  description = patroli.notes!.split('\n').skip(1).join('\n').trim();
                                  if (description.isEmpty) description = null;
                                } else if (!patroli.notes!.startsWith('📍')) {
                                  description = patroli.notes!;
                                }
                                
                                if (description != null && description.isNotEmpty) {
                                  return Text(
                                    description,
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: Colors.grey[700],
                                    ),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  );
                                }
                                return const SizedBox.shrink();
                              },
                            ),
                          ],
                          if (patroli.latitude != null && patroli.longitude != null) ...[
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Icon(Icons.location_on, size: 14, color: Colors.grey[600]),
                                const SizedBox(width: 4),
                                Text(
                                  '${patroli.latitude!.toStringAsFixed(6)}, ${patroli.longitude!.toStringAsFixed(6)}',
                                  style: TextStyle(
                                    color: Colors.grey[600],
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                );
                          },
                        ),
                      ),
                      // Pagination (always show if more than itemsPerPage)
                      if (totalItems > _itemsPerPage)
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: Colors.grey[50],
                            border: Border(top: BorderSide(color: Colors.grey[200]!)),
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
                                    style: const TextStyle(fontWeight: FontWeight.bold),
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

  void _showPatroliDetail(BuildContext context, DailyActivity patroli) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        height: MediaQuery.of(context).size.height * 0.8,
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: Colors.grey[200]!)),
              ),
              child: Row(
                children: [
                  const Text(
                    'Detail Patroli',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Date
                    Row(
                      children: [
                        Icon(Icons.calendar_today, size: 16, color: Colors.grey[600]),
                        const SizedBox(width: 8),
                        Text(
                          DateFormat('EEEE, dd MMMM yyyy', 'id_ID').format(
                            _parseActivityDate(patroli) ?? DateTime.now(),
                          ),
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.grey[700],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    // Nama Tempat (locationName atau summary)
                    const Text(
                      'Nama Tempat',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      (patroli.locationName != null && patroli.locationName!.isNotEmpty)
                          ? patroli.locationName!
                          : patroli.summary,
                      style: const TextStyle(
                        fontSize: 14,
                        color: Colors.black87,
                      ),
                    ),
                    // Deskripsi dari notes
                    if (patroli.notes != null && patroli.notes!.isNotEmpty) ...[
                      Builder(
                        builder: (context) {
                          String? description;
                          if (patroli.notes!.contains('📍') && patroli.notes!.contains('\n')) {
                            description = patroli.notes!.split('\n').skip(1).join('\n').trim();
                            if (description.isEmpty) description = null;
                          } else if (!patroli.notes!.startsWith('📍')) {
                            description = patroli.notes!;
                          }
                          
                          if (description != null && description.isNotEmpty) {
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const SizedBox(height: 16),
                                const Text(
                                  'Deskripsi',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.black87,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  description,
                                  style: const TextStyle(
                                    fontSize: 14,
                                    color: Colors.black87,
                                  ),
                                ),
                              ],
                            );
                          }
                          return const SizedBox.shrink();
                        },
                      ),
                    ],
                    // Photos
                    if (patroli.photoUrls != null && patroli.photoUrls!.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      const Text(
                        'Foto',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: Colors.black87,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: patroli.photoUrls!.map((photoUrl) {
                          final isLocal = _isLocalPhotoUrl(photoUrl);
                          final localPath = isLocal ? _resolveLocalPath(photoUrl) : null;
                          final fullUrl = isLocal ? null : ApiConfig.getImageUrl(photoUrl);
                          return GestureDetector(
                            onTap: () {
                              // Show full screen image dengan aspect ratio yang benar
                              showDialog(
                                context: context,
                                builder: (context) => isLocal
                                    ? FullScreenImageDialog.file(
                                        imageFile: File(localPath!),
                                      )
                                    : FullScreenImageDialog.network(
                                        imageUrl: fullUrl!,
                                      ),
                              );
                            },
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: Container(
                                width: 100,
                                height: 133, // 100 * 4/3 untuk portrait (lebih tinggi)
                                child: isLocal
                                    ? Image.file(
                                        File(localPath!),
                                        fit: BoxFit.cover,
                                        errorBuilder: (context, error, stackTrace) {
                                          return Container(
                                            color: Colors.grey[200],
                                            child: const Icon(Icons.broken_image),
                                          );
                                        },
                                      )
                                    : Image.network(
                                        fullUrl!,
                                        fit: BoxFit.cover,
                                        errorBuilder: (context, error, stackTrace) {
                                          return Container(
                                            color: Colors.grey[200],
                                            child: const Icon(Icons.broken_image),
                                          );
                                        },
                                        loadingBuilder: (context, child, loadingProgress) {
                                          if (loadingProgress == null) return child;
                                          return Container(
                                            color: Colors.grey[200],
                                            child: const Center(
                                              child: CircularProgressIndicator(strokeWidth: 2),
                                            ),
                                          );
                                        },
                                      ),
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ],
                    // Location coordinates
                    if (patroli.latitude != null && patroli.longitude != null) ...[
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Icon(Icons.my_location, size: 16, color: Colors.grey[600]),
                          const SizedBox(width: 8),
                          Text(
                            'Koordinat: ${patroli.latitude!.toStringAsFixed(6)}, ${patroli.longitude!.toStringAsFixed(6)}',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey[600],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

}

