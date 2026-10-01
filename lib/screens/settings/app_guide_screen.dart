import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';

import '../../config/api_config.dart';
import '../../services/api_service.dart';

/// Panduan aplikasi (manual book PDF karyawan) dari server. Salinan disimpan di HP supaya tetap bisa
/// dibuka tanpa sinyal; versi baru hanya diunduh bila berkas di server berubah (If-Modified-Since).
class AppGuideScreen extends StatefulWidget {
  const AppGuideScreen({super.key});

  @override
  State<AppGuideScreen> createState() => _AppGuideScreenState();
}

class _AppGuideScreenState extends State<AppGuideScreen> {
  static const _slug = 'karyawan';
  static const _prefKey = 'manual_karyawan_last_modified';

  File? _file;
  String? _lastModified;
  bool _loading = true;
  bool _checking = false;
  String? _error;
  String? _note;
  int _viewerKey = 0;

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<File> _cacheFile() async {
    final dir = Directory('${(await getApplicationDocumentsDirectory()).path}/manual');
    if (!await dir.exists()) await dir.create(recursive: true);
    return File('${dir.path}/panduan-atenim-karyawan.pdf');
  }

  Future<void> _open() async {
    final cached = await _cacheFile();
    final prefs = await SharedPreferences.getInstance();
    if (await cached.exists() && await cached.length() > 0) {
      setState(() {
        _file = cached;
        _lastModified = prefs.getString(_prefKey);
        _loading = false;
      });
    }
    await _refresh(force: _file == null);
  }

  /// Ambil versi terbaru dari server. force = abaikan salinan di HP.
  Future<void> _refresh({bool force = false}) async {
    if (_checking) return;
    setState(() {
      _checking = true;
      _error = null;
      if (_file == null) _loading = true;
    });
    try {
      final prefs = await SharedPreferences.getInstance();
      final since = force ? null : prefs.getString(_prefKey);
      final response = await ApiService().get(
        ApiConfig.manual(_slug),
        responseType: ResponseType.bytes,
        headers: since != null ? {'If-Modified-Since': since} : null,
      );
      if (!mounted) return;
      if (response.statusCode == 304) {
        setState(() => _note = null);
        return;
      }
      final data = response.data;
      final bytes = data is List<int> ? data : null;
      final isPdf = bytes != null && bytes.length > 4 && bytes[0] == 0x25 && bytes[1] == 0x50 && bytes[2] == 0x44 && bytes[3] == 0x46;
      if (response.statusCode != 200 || !isPdf) {
        throw Exception(response.statusCode == 404 ? 'Panduan belum tersedia di server.' : 'Gagal mengunduh panduan (kode ${response.statusCode}).');
      }
      final target = await _cacheFile();
      await target.writeAsBytes(bytes, flush: true);
      final lastModified = response.headers.value('last-modified');
      if (lastModified != null) await prefs.setString(_prefKey, lastModified);
      if (!mounted) return;
      final hadFile = _file != null;
      setState(() {
        _file = target;
        _lastModified = lastModified;
        _note = null;
        _viewerKey++;
      });
      if (hadFile) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Panduan diperbarui ke versi terbaru')));
      }
    } catch (e) {
      if (!mounted) return;
      final message = e is DioException
          ? 'Tidak ada koneksi ke server.'
          : e.toString().replaceFirst('Exception: ', '');
      setState(() {
        if (_file != null) {
          _note = 'Menampilkan salinan di HP. $message';
        } else {
          _error = message;
        }
      });
    } finally {
      if (mounted) {
        setState(() {
          _checking = false;
          _loading = false;
        });
      }
    }
  }

  String? get _updatedLabel {
    final raw = _lastModified;
    if (raw == null) return null;
    try {
      final date = HttpDate.parse(raw).toLocal();
      return 'Versi ${DateFormat('d MMMM yyyy', 'id_ID').format(date)}';
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Panduan Aplikasi'),
        actions: [
          IconButton(
            tooltip: 'Periksa versi terbaru',
            onPressed: _checking ? null : () => _refresh(force: true),
            icon: _checking
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading && _file == null) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Mengunduh panduan...'),
          ],
        ),
      );
    }
    final file = _file;
    if (file == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.menu_book_outlined, size: 48, color: Colors.grey[600]),
              const SizedBox(height: 12),
              Text(
                _error ?? 'Panduan belum bisa dibuka.',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 15, height: 1.4),
              ),
              const SizedBox(height: 16),
              FilledButton(onPressed: () => _refresh(force: true), child: const Text('Coba lagi')),
            ],
          ),
        ),
      );
    }
    final label = _updatedLabel;
    return Column(
      children: [
        if (_note != null || label != null)
          Container(
            width: double.infinity,
            color: _note != null ? Colors.amber[50] : Colors.grey[100],
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              _note ?? label!,
              style: TextStyle(fontSize: 12.5, color: _note != null ? Colors.brown[800] : Colors.grey[800]),
            ),
          ),
        Expanded(
          child: SfPdfViewer.file(
            file,
            key: ValueKey(_viewerKey),
            canShowScrollHead: true,
            onDocumentLoadFailed: (details) {
              setState(() => _note = 'Berkas panduan rusak. Ketuk tombol muat ulang di kanan atas.');
            },
          ),
        ),
      ],
    );
  }
}
