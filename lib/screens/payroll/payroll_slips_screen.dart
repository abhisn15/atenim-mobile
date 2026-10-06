import 'dart:async';
import '../../widgets/ui_kit.dart' show EmptyState;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../models/payroll_slip_model.dart';
import '../../services/payroll_slip_service.dart';

class PayrollSlipsScreen extends StatefulWidget {
  const PayrollSlipsScreen({super.key});

  @override
  State<PayrollSlipsScreen> createState() => _PayrollSlipsScreenState();
}

class _PayrollSlipsScreenState extends State<PayrollSlipsScreen> {
  final PayrollSlipService _payrollSlipService = PayrollSlipService();
  final TextEditingController _searchController = TextEditingController();
  final DateFormat _createdAtFormat = DateFormat('dd MMM yyyy, HH:mm', 'id_ID');
  static const int _pageSize = 20;
  Timer? _searchDebounce;

  bool _isLoading = true;
  String? _error;
  List<PayrollSlip> _slips = [];
  int _page = 1;
  int _totalPages = 0;
  int _totalItems = 0;
  DateTime? _periodStartDate;
  DateTime? _periodEndDate;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    _loadPayrollSlips();
  }

  @override
  void dispose() {
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    _searchDebounce?.cancel();
    super.dispose();
  }

  String? _toDateParam(DateTime? date) {
    if (date == null) return null;
    final year = date.year.toString().padLeft(4, '0');
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '$year-$month-$day';
  }

  void _onSearchChanged() {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      _loadPayrollSlips(targetPage: 1);
    });
  }

  Future<void> _loadPayrollSlips({int? targetPage}) async {
    final nextPage = targetPage ?? _page;
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final result = await _payrollSlipService.getPayrollSlips(
        page: nextPage,
        limit: _pageSize,
        search: _searchController.text,
        periodStart: _toDateParam(_periodStartDate),
        periodEnd: _toDateParam(_periodEndDate),
      );
      if (!mounted) return;
      setState(() {
        _slips = result.items;
        _page = result.page;
        _totalPages = result.totalPages;
        _totalItems = result.total;
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

  String _formatFileSize(int bytes) {
    if (bytes <= 0) return '-';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  String _formatCreatedAt(DateTime? value) {
    if (value == null) return '-';
    return _createdAtFormat.format(value.toLocal());
  }

  Future<void> _openSlip(PayrollSlip slip) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _PayrollSlipWebViewScreen(
          slip: slip,
          payrollSlipService: _payrollSlipService,
        ),
      ),
    );
  }

  Future<void> _pickDate({required bool isStart}) async {
    final initial = isStart
        ? (_periodStartDate ?? DateTime.now())
        : (_periodEndDate ?? _periodStartDate ?? DateTime.now());
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2018, 1, 1),
      lastDate: DateTime(2100, 12, 31),
      helpText: isStart ? 'Pilih tanggal awal' : 'Pilih tanggal akhir',
    );
    if (picked == null || !mounted) return;
    setState(() {
      if (isStart) {
        _periodStartDate = picked;
        if (_periodEndDate != null && _periodEndDate!.isBefore(picked)) {
          _periodEndDate = picked;
        }
      } else {
        _periodEndDate = picked;
        if (_periodStartDate != null && _periodStartDate!.isAfter(picked)) {
          _periodStartDate = picked;
        }
      }
    });
    await _loadPayrollSlips(targetPage: 1);
  }

  static bool _isMaintenanceMessage(String message) {
    final m = message.toLowerCase();
    return m.contains('perbaikan') || m.contains('maintenance');
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null && _isMaintenanceMessage(_error!)) {
      // Layanan sedang diperbaiki: ini keadaan yang diketahui, bukan galat, jadi tampil netral
      // tanpa tombol Coba Lagi (mengulang tidak akan mengubah apa pun).
      return Center(
        child: SingleChildScrollView(
          child: EmptyState(
            icon: Icons.construction_outlined,
            title: 'Slip gaji belum tersedia',
            message: _error!,
          ),
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.error_outline,
                size: 48,
                color: Colors.redAccent,
              ),
              const SizedBox(height: 12),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.redAccent),
              ),
              const SizedBox(height: 12),
              ElevatedButton.icon(
                onPressed: _loadPayrollSlips,
                icon: const Icon(Icons.refresh),
                label: const Text('Coba Lagi'),
              ),
            ],
          ),
        ),
      );
    }

    if (_slips.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('Belum ada slip gaji.', textAlign: TextAlign.center),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () => _loadPayrollSlips(targetPage: _page),
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: _slips.length + 1,
        separatorBuilder: (context, index) => const SizedBox(height: 2),
        itemBuilder: (context, index) {
          if (index == _slips.length) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _page > 1
                          ? () => _loadPayrollSlips(targetPage: _page - 1)
                          : null,
                      icon: const Icon(Icons.chevron_left),
                      label: const Text('Sebelumnya'),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Halaman $_page / ${_totalPages <= 0 ? 1 : _totalPages}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        Text(
                          'Total $_totalItems data',
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: (_totalPages > 0 && _page < _totalPages)
                          ? () => _loadPayrollSlips(targetPage: _page + 1)
                          : null,
                      icon: const Icon(Icons.chevron_right),
                      label: const Text('Berikutnya'),
                    ),
                  ),
                ],
              ),
            );
          }

          final slip = _slips[index];
          return Card(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: ListTile(
              leading: const CircleAvatar(
                child: Icon(Icons.receipt_long_outlined),
              ),
              title: Text(
                slip.displayPeriod,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Versi ${slip.version}'),
                  Text('Ukuran: ${_formatFileSize(slip.fileSize)}'),
                  Text('Dibuat: ${_formatCreatedAt(slip.createdAt)}'),
                ],
              ),
              trailing: IconButton(
                tooltip: 'Lihat Slip',
                icon: const Icon(Icons.visibility_outlined),
                onPressed: () => _openSlip(slip),
              ),
              onTap: () => _openSlip(slip),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    String formatDateLabel(DateTime? date) {
      if (date == null) return 'Pilih tanggal';
      return DateFormat('dd MMM yyyy', 'id_ID').format(date);
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Slip Gaji'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _loadPayrollSlips,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              controller: _searchController,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: 'Cari periode atau nama file...',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchController.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Hapus pencarian',
                        icon: const Icon(Icons.close),
                        onPressed: () {
                          _searchController.clear();
                          _loadPayrollSlips(targetPage: 1);
                        },
                      ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _pickDate(isStart: true),
                    icon: const Icon(Icons.event_outlined, size: 18),
                    label: Text('Dari: ${formatDateLabel(_periodStartDate)}'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _pickDate(isStart: false),
                    icon: const Icon(Icons.event_available_outlined, size: 18),
                    label: Text('Sampai: ${formatDateLabel(_periodEndDate)}'),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: (_periodStartDate != null || _periodEndDate != null)
                    ? () async {
                        setState(() {
                          _periodStartDate = null;
                          _periodEndDate = null;
                        });
                        await _loadPayrollSlips(targetPage: 1);
                      }
                    : null,
                icon: const Icon(Icons.restart_alt),
                label: const Text('Reset rentang tanggal'),
              ),
            ),
          ),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }
}

class _PayrollSlipWebViewScreen extends StatefulWidget {
  final PayrollSlip slip;
  final PayrollSlipService payrollSlipService;

  const _PayrollSlipWebViewScreen({
    required this.slip,
    required this.payrollSlipService,
  });

  @override
  State<_PayrollSlipWebViewScreen> createState() =>
      _PayrollSlipWebViewScreenState();
}

class _PayrollSlipWebViewScreenState extends State<_PayrollSlipWebViewScreen> {
  WebViewController? _webViewController;
  String? _error;
  bool _isPageLoading = true;

  @override
  void initState() {
    super.initState();
    _initWebView();
  }

  Future<void> _initWebView() async {
    setState(() {
      _error = null;
      _webViewController = null;
      _isPageLoading = true;
    });

    try {
      final url = await widget.payrollSlipService.getPayrollSlipWebViewUrl(
        widget.slip,
      );
      final controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(const Color(0xFFFFFFFF))
        ..setNavigationDelegate(
          NavigationDelegate(
            onPageStarted: (_) {
              if (!mounted) return;
              setState(() {
                _isPageLoading = true;
              });
            },
            onPageFinished: (_) {
              if (!mounted) return;
              setState(() {
                _isPageLoading = false;
              });
            },
            onWebResourceError: (error) {
              if (!mounted) return;
              setState(() {
                _error = error.description.isEmpty
                    ? 'Gagal memuat slip gaji di webview.'
                    : error.description;
                _isPageLoading = false;
              });
            },
          ),
        )
        ..loadRequest(Uri.parse(url));

      if (!mounted) return;
      setState(() {
        _webViewController = controller;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceAll('Exception: ', '');
        _isPageLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Slip ${widget.slip.displayPeriod}'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: () {
              final controller = _webViewController;
              if (controller != null) {
                controller.reload();
              } else {
                _initWebView();
              }
            },
          ),
        ],
      ),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.error_outline,
                      size: 48,
                      color: Colors.redAccent,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.redAccent),
                    ),
                    const SizedBox(height: 12),
                    ElevatedButton.icon(
                      onPressed: _initWebView,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Coba Lagi'),
                    ),
                  ],
                ),
              ),
            )
          : _webViewController == null
          ? const Center(child: CircularProgressIndicator())
          : Stack(
              children: [
                WebViewWidget(controller: _webViewController!),
                if (_isPageLoading)
                  const Center(child: CircularProgressIndicator()),
              ],
            ),
    );
  }
}
