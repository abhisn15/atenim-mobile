import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../../providers/request_provider.dart';
import '../../widgets/adaptive_image.dart' as adaptive_image;
import 'request_form_screen.dart';

class RequestsScreen extends StatefulWidget {
  const RequestsScreen({super.key});

  @override
  State<RequestsScreen> createState() => _RequestsScreenState();
}

class _RequestsScreenState extends State<RequestsScreen> {
  // Default: bulan ini (tanggal 1 sampai hari ini)
  late DateTime _startDate = _getDefaultStartDate();
  late DateTime _endDate = _getDefaultEndDate();
  String? _selectedStatus;
  String? _selectedType;
  int _currentPage = 1;
  final int _itemsPerPage = 10;

  static DateTime _getDefaultStartDate() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, 1);
  }

  static DateTime _getDefaultEndDate() {
    return DateTime.now();
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
      Provider.of<RequestProvider>(context, listen: false).loadRequests();
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

  Color _getStatusColor(String status) {
    switch (status.toLowerCase()) {
      case 'approved':
        return Colors.green;
      case 'rejected':
        return Colors.red;
      case 'pending':
        return Colors.orange;
      case 'berlangsung':
        return Colors.blue;
      default:
        return Colors.grey;
    }
  }

  IconData _getStatusIcon(String status) {
    switch (status.toLowerCase()) {
      case 'approved':
        return Icons.check_circle;
      case 'rejected':
        return Icons.cancel;
      case 'pending':
        return Icons.access_time;
      case 'berlangsung':
        return Icons.event;
      default:
        return Icons.help;
    }
  }

  String _getTypeLabel(String type) {
    switch (type.toLowerCase()) {
      case 'izin':
        return 'Izin';
      case 'cuti':
        return 'Cuti';
      case 'sakit':
      case 'sick': // Handle both "sakit" and "sick" for compatibility
        return 'Sakit';
      default:
        return type;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Leave Request'),
        actions: [
          if (_selectedStatus != null || _selectedType != null)
            IconButton(
              icon: const Icon(Icons.filter_alt),
              onPressed: () => _showStatusTypeFilterDialog(context),
              tooltip: 'Filter Status & Tipe',
            ),
          IconButton(
            icon: const Icon(Icons.date_range),
            onPressed: () => _selectDateRange(context),
            tooltip: 'Pilih Rentang Tanggal',
          ),
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: () async {
              final result = await Navigator.push<bool>(
                context,
                MaterialPageRoute(
                  builder: (_) => const RequestFormScreen(),
                ),
              );
              if (result == true && mounted) {
                Provider.of<RequestProvider>(context, listen: false)
                    .loadRequests();
              }
            },
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
          // Status & Type Filter Chips (if selected)
          if (_selectedStatus != null || _selectedType != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (_selectedStatus != null)
                    Chip(
                      label: Text('Status: ${_selectedStatus!.toUpperCase()}'),
                      onDeleted: () {
                        setState(() {
                          _selectedStatus = null;
                          _currentPage = 1;
                        });
                      },
                      deleteIcon: const Icon(Icons.close, size: 18),
                    ),
                  if (_selectedType != null)
                    Chip(
                      label: Text('Tipe: ${_getTypeLabel(_selectedType!)}'),
                      onDeleted: () {
                        setState(() {
                          _selectedType = null;
                          _currentPage = 1;
                        });
                      },
                      deleteIcon: const Icon(Icons.close, size: 18),
                    ),
                ],
              ),
            ),
          // Request List
          Expanded(
            child: Consumer<RequestProvider>(
              builder: (context, requestProvider, _) {
                if (requestProvider.isLoading) {
                  return const Center(child: CircularProgressIndicator());
                }

                if (requestProvider.error != null) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.error_outline, size: 64, color: Colors.red[300]),
                        const SizedBox(height: 16),
                        Text(
                          requestProvider.error!,
                          style: TextStyle(color: Colors.red[700]),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 16),
                        ElevatedButton(
                          onPressed: () {
                            requestProvider.loadRequests();
                          },
                          child: const Text('Coba Lagi'),
                        ),
                      ],
                    ),
                  );
                }

                final requests = requestProvider.requests;

                // Apply filters
                final filteredRequests = requests.where((request) {
                  // Filter by date range (check if request overlaps with selected date range)
                  final requestStartDate = DateTime.parse(request.startDate);
                  final requestEndDate = DateTime.parse(request.endDate);
                  
                  // Request overlaps if: requestStartDate <= _endDate AND requestEndDate >= _startDate
                  if (requestStartDate.isAfter(_endDate.add(const Duration(days: 1))) || 
                      requestEndDate.isBefore(_startDate)) {
                    return false;
                  }
                  
                  // Filter by status
                  if (_selectedStatus != null && request.status.toLowerCase() != _selectedStatus!.toLowerCase()) {
                    return false;
                  }
                  
                  // Filter by type
                  if (_selectedType != null && request.type.toLowerCase() != _selectedType!.toLowerCase()) {
                    return false;
                  }
                  
                  return true;
                }).toList();

                // Calculate pagination
                final totalItems = filteredRequests.length;
                final totalPages = totalItems > 0 ? (totalItems / _itemsPerPage).ceil() : 1;
                final startIndex = (_currentPage - 1) * _itemsPerPage;
                final endIndex = startIndex + _itemsPerPage;
                final paginatedRequests = filteredRequests.sublist(
                  startIndex.clamp(0, totalItems),
                  endIndex.clamp(0, totalItems),
                );

                if (filteredRequests.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.request_quote_outlined, size: 64, color: Colors.grey[400]),
                  const SizedBox(height: 16),
                  Text(
                    'Belum ada request',
                    style: TextStyle(color: Colors.grey[600]),
                  ),
                  const SizedBox(height: 24),
                  ElevatedButton.icon(
                    onPressed: () async {
                      final result = await Navigator.push<bool>(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const RequestFormScreen(),
                        ),
                      );
                      if (result == true && mounted) {
                        requestProvider.loadRequests();
                      }
                    },
                    icon: const Icon(Icons.add),
                    label: const Text('Buat Request'),
                  ),
                ],
              ),
            );
          }

                return RefreshIndicator(
                  onRefresh: () => requestProvider.loadRequests(),
                  child: Column(
                    children: [
                      Expanded(
                        child: ListView(
                          padding: const EdgeInsets.all(16),
                          children: paginatedRequests.map((request) => Card(
                                margin: const EdgeInsets.only(bottom: 8),
                                child: Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      // Header with type, status, and dates
                                      Row(
                                        children: [
                                          CircleAvatar(
                                            radius: 16,
                                            backgroundColor: _getStatusColor(request.status).withOpacity(0.2),
                                            child: Icon(
                                              _getStatusIcon(request.status),
                                              color: _getStatusColor(request.status),
                                              size: 16,
                                            ),
                                          ),
                                          const SizedBox(width: 12),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  _getTypeLabel(request.type),
                                                  style: const TextStyle(
                                                    fontWeight: FontWeight.w500,
                                                    fontSize: 16,
                                                  ),
                                                ),
                                                Text(
                                                  '${DateFormat('dd MMM yyyy').format(DateTime.parse(request.startDate))} - ${DateFormat('dd MMM yyyy').format(DateTime.parse(request.endDate))}',
                                                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                                                ),
                                              ],
                                            ),
                                          ),
                                          Chip(
                                            label: Text(request.status.toUpperCase()),
                                            backgroundColor: _getStatusColor(request.status).withOpacity(0.2),
                                            labelStyle: TextStyle(
                                              color: _getStatusColor(request.status),
                                              fontSize: 10,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 8),
                                      // Reason
                                      Text(request.reason),
                                      // Photos (if any)
                                      if (request.photoUrls != null && request.photoUrls!.isNotEmpty) ...[
                                        const SizedBox(height: 12),
                                        SizedBox(
                                          height: 80,
                                          child: ListView.builder(
                                            scrollDirection: Axis.horizontal,
                                            itemCount: request.photoUrls!.length,
                                            itemBuilder: (context, index) {
                                              final photoUrl = request.photoUrls![index];
                                              return Container(
                                                width: 80,
                                                height: 80,
                                                margin: const EdgeInsets.only(right: 8),
                                                decoration: BoxDecoration(
                                                  border: Border.all(color: Colors.grey[300]!),
                                                  borderRadius: BorderRadius.circular(8),
                                                ),
                                                child: ClipRRect(
                                                  borderRadius: BorderRadius.circular(8),
                                                  child: adaptive_image.AdaptiveImage.network(
                                                    photoUrl,
                                                    fit: BoxFit.cover,
                                                    errorBuilder: (context, error, stackTrace) {
                                                      return Container(
                                                        color: Colors.grey[100],
                                                        child: const Icon(
                                                          Icons.broken_image,
                                                          color: Colors.grey,
                                                        ),
                                                      );
                                                    },
                                                  ),
                                                ),
                                              );
                                            },
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              )).toList(),
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

  Future<void> _showStatusTypeFilterDialog(BuildContext context) async {
    String? tempStatus = _selectedStatus;
    String? tempType = _selectedType;

    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Filter Request'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Status',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  value: tempStatus,
                  decoration: const InputDecoration(
                    labelText: 'Pilih Status',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('Semua')),
                    const DropdownMenuItem(value: 'pending', child: Text('Pending')),
                    const DropdownMenuItem(value: 'approved', child: Text('Approved')),
                    const DropdownMenuItem(value: 'rejected', child: Text('Rejected')),
                    const DropdownMenuItem(value: 'berlangsung', child: Text('Berlangsung')),
                  ],
                  onChanged: (value) {
                    setDialogState(() {
                      tempStatus = value;
                    });
                  },
                ),
                const SizedBox(height: 16),
                const Text(
                  'Tipe',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  value: tempType,
                  decoration: const InputDecoration(
                    labelText: 'Pilih Tipe',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('Semua')),
                    const DropdownMenuItem(value: 'izin', child: Text('Izin')),
                    const DropdownMenuItem(value: 'cuti', child: Text('Cuti')),
                    const DropdownMenuItem(value: 'sakit', child: Text('Sakit')),
                  ],
                  onChanged: (value) {
                    setDialogState(() {
                      tempType = value;
                    });
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                setDialogState(() {
                  tempStatus = null;
                  tempType = null;
                });
              },
              child: const Text('Reset'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Batal'),
            ),
            ElevatedButton(
              onPressed: () {
                setState(() {
                  _selectedStatus = tempStatus;
                  _selectedType = tempType;
                  _currentPage = 1; // Reset to first page
                });
                Navigator.pop(context);
              },
              child: const Text('Terapkan'),
            ),
          ],
        ),
      ),
    );
  }
}

