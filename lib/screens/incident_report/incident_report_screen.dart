import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../config/api_config.dart';
import '../../services/incident_report_service.dart';
import '../../widgets/motion.dart';
import '../../widgets/photo_gallery_viewer.dart';
import '../../widgets/ui_kit.dart';
import 'incident_report_form_screen.dart';

class IncidentReportScreen extends StatefulWidget {
  const IncidentReportScreen({super.key});

  @override
  State<IncidentReportScreen> createState() => _IncidentReportScreenState();
}

class _IncidentReportScreenState extends State<IncidentReportScreen> {
  final IncidentReportService _service = IncidentReportService();
  List<IncidentReportItem> _items = [];
  int _page = 1;
  int _totalPages = 1;
  int _total = 0;
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;

  Future<void> _load({bool refresh = false}) async {
    if (!mounted) return;
    final pageToLoad = refresh ? 1 : (_page + 1);
    if (refresh) {
      setState(() {
        _loading = _items.isEmpty; // data lama tetap tampil saat ditarik untuk dimuat ulang
        _error = null;
      });
    } else {
      setState(() => _loadingMore = true);
    }
    try {
      final result = await _service.getMyReports(page: pageToLoad, limit: 20);
      if (!mounted) return;
      setState(() {
        if (refresh) {
          _items = result.data;
          _page = 1;
        } else {
          _items = [..._items, ...result.data];
          _page = pageToLoad;
        }
        _totalPages = result.totalPages;
        _total = result.total;
        _loading = false;
        _loadingMore = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadingMore = false;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  void _loadMore() {
    if (_loadingMore || _loading || _page >= _totalPages || _items.isEmpty) return;
    _load(refresh: false);
  }

  Future<void> _openForm() async {
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const IncidentReportFormScreen()),
    );
    if (saved == true && mounted) _load(refresh: true);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load(refresh: true));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Laporan Kejadian')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openForm,
        icon: const Icon(Icons.add),
        label: const Text('Buat laporan'),
      ),
      body: RefreshIndicator(
        onRefresh: () => _load(refresh: true),
        child: NotificationListener<ScrollNotification>(
          onNotification: (n) {
            if (n.metrics.pixels >= n.metrics.maxScrollExtent - 320) _loadMore();
            return false;
          },
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
            children: [FadeSwitcher(child: _buildBody())],
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading && _items.isEmpty) {
      return Column(
        key: const ValueKey('memuat'),
        children: const [
          SkeletonListCard(),
          SizedBox(height: 12),
          SkeletonListCard(),
          SizedBox(height: 12),
          SkeletonListCard(),
        ],
      );
    }
    if (_error != null && _items.isEmpty) {
      return ErrorState(
        key: const ValueKey('galat'),
        title: 'Laporan tidak bisa dimuat',
        message:
            'Periksa koneksi internet Anda, lalu coba lagi. Laporan yang sudah Anda kirim tetap aman di server.',
        onRetry: () => _load(refresh: true),
      );
    }
    if (_items.isEmpty) {
      return EmptyState(
        key: const ValueKey('kosong'),
        icon: Icons.assignment_outlined,
        title: 'Belum ada laporan kejadian',
        message:
            'Catat kejadian di lokasi kerja beserta foto buktinya. Laporan Anda akan tampil di sini dan bisa dibaca atasan.',
        actionLabel: 'Buat laporan pertama',
        onAction: _openForm,
      );
    }

    final widgets = <Widget>[];
    String? currentMonth;
    var animIndex = 0;
    for (final item in _items) {
      final date = DateTime.tryParse(item.reportDate);
      final month = date != null
          ? DateFormat('MMMM yyyy', 'id_ID').format(date)
          : 'Tanggal tidak diketahui';
      if (month != currentMonth) {
        currentMonth = month;
        widgets.add(SectionHeader(title: month));
      }
      widgets.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: FadeSlideIn(
            key: ValueKey('laporan-${item.id}'),
            delay: Motion.stagger(animIndex++),
            child: _ReportCard(item: item),
          ),
        ),
      );
    }

    return Column(
      key: const ValueKey('isi'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
          child: Text(
            _total > _items.length
                ? 'Menampilkan ${_items.length} dari $_total laporan'
                : '$_total laporan',
            style: TextStyle(fontSize: 13, color: AtenimUi.inkSoft),
          ),
        ),
        ...widgets,
        if (_loadingMore)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Center(
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
            ),
          ),
        if (_error != null && !_loadingMore)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Center(
              child: TextButton.icon(
                onPressed: _loadMore,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Gagal memuat laporan berikutnya. Coba lagi'),
              ),
            ),
          ),
      ],
    );
  }
}

/// Satu laporan. Deskripsi panjang dipotong 3 baris dan bisa dibuka dengan mengetuk kartu.
class _ReportCard extends StatefulWidget {
  const _ReportCard({required this.item});

  final IncidentReportItem item;

  @override
  State<_ReportCard> createState() => _ReportCardState();
}

class _ReportCardState extends State<_ReportCard> {
  bool _expanded = false;

  bool get _isLong {
    final text = widget.item.description;
    return text.length > 120 || '\n'.allMatches(text).length >= 3;
  }

  String _createdLabel(String? iso) {
    if (iso == null || iso.isEmpty) return '';
    final dt = DateTime.tryParse(iso)?.toLocal();
    if (dt == null) return '';
    return 'Dibuat ${DateFormat('d MMM yyyy, HH:mm', 'id_ID').format(dt)}';
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final date = DateTime.tryParse(item.reportDate);
    final created = _createdLabel(item.createdAt);

    return AtenimCard(
      padding: const EdgeInsets.all(14),
      onTap: _isLong ? () => setState(() => _expanded = !_expanded) : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              DateTile(date: date),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      date != null
                          ? DateFormat('EEEE, d MMMM yyyy', 'id_ID').format(date)
                          : item.reportDate,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: AtenimUi.ink,
                      ),
                    ),
                    if (created.isNotEmpty)
                      Text(
                        created,
                        style: TextStyle(fontSize: 12, color: AtenimUi.inkSoft),
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          AnimatedSize(
            duration: Motion.reduced(context) ? Duration.zero : Motion.quick,
            curve: Motion.easeOut,
            alignment: Alignment.topCenter,
            child: Text(
              item.description,
              maxLines: _expanded ? null : 3,
              overflow: _expanded ? TextOverflow.visible : TextOverflow.ellipsis,
              style: TextStyle(fontSize: 14, color: Colors.grey[800], height: 1.45),
            ),
          ),
          if (_isLong) ...[
            const SizedBox(height: 6),
            Text(
              _expanded ? 'Ringkas' : 'Selengkapnya',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AtenimUi.brand,
              ),
            ),
          ],
          if (item.photoUrls.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              '${item.photoUrls.length} foto',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AtenimUi.inkSoft,
              ),
            ),
            const SizedBox(height: 6),
            SizedBox(
              height: 72,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: item.photoUrls.length,
                itemBuilder: (_, i) {
                  final url = ApiConfig.getImageUrl(item.photoUrls[i]);
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Semantics(
                      button: true,
                      label: 'Buka foto ${i + 1} dari ${item.photoUrls.length}',
                      child: GestureDetector(
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => PhotoGalleryViewer(
                                imageUrls: item.photoUrls,
                                initialIndex: i,
                                urlResolver: (u) => ApiConfig.getImageUrl(u),
                              ),
                            ),
                          );
                        },
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: CachedNetworkImage(
                            imageUrl: url,
                            width: 72,
                            height: 72,
                            fit: BoxFit.cover,
                            fadeInDuration: const Duration(milliseconds: 180),
                            placeholder: (context, url) =>
                                Container(width: 72, height: 72, color: Colors.grey[200]),
                            errorWidget: (context, url, error) => Container(
                              width: 72,
                              height: 72,
                              color: Colors.grey[100],
                              child: Icon(Icons.broken_image_outlined, color: Colors.grey[600]),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ],
      ),
    );
  }
}
