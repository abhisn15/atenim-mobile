import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'dart:io';
import '../../services/incident_report_service.dart';
import '../../utils/toast_helper.dart';
import '../../widgets/motion.dart';
import '../../widgets/ui_kit.dart';
import '../camera/camera_screen.dart';

class IncidentReportFormScreen extends StatefulWidget {
  const IncidentReportFormScreen({super.key});

  @override
  State<IncidentReportFormScreen> createState() => _IncidentReportFormScreenState();
}

class _IncidentReportFormScreenState extends State<IncidentReportFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _descController = TextEditingController();
  DateTime _reportDate = DateTime.now();
  final List<File> _photos = [];
  bool _submitting = false;

  bool get _hasContent => _descController.text.trim().isNotEmpty || _photos.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _descController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _descController.dispose();
    super.dispose();
  }

  Future<void> _pickFromCamera() async {
    final photo = await Navigator.push<File>(
      context,
      MaterialPageRoute(
        builder: (_) => const CameraScreen(
          title: 'Foto Kejadian',
          preferLowResolution: true,
        ),
      ),
    );
    if (photo != null && mounted) {
      setState(() => _photos.add(photo));
    }
  }

  Future<void> _pickFromGallery() async {
    final picker = ImagePicker();
    final list = await picker.pickMultiImage();
    if (list.isEmpty || !mounted) return;
    setState(() {
      _photos.addAll(list.map((x) => File(x.path)));
    });
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _reportDate,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      locale: const Locale('id', 'ID'),
    );
    if (picked != null && mounted) setState(() => _reportDate = picked);
  }

  Future<void> _submit() async {
    if (_submitting) return;
    if (_formKey.currentState?.validate() != true) return;
    setState(() => _submitting = true);
    try {
      final service = IncidentReportService();
      await service.submit(
        reportDate: _reportDate,
        description: _descController.text.trim(),
        photos: _photos,
      );
      if (!mounted) return;
      ToastHelper.showSuccess(context, 'Laporan kejadian berhasil disimpan');
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      // Isian dan foto tetap ada supaya bisa dikirim ulang.
      ToastHelper.showError(
        context,
        '${e.toString().replaceFirst('Exception: ', '')}. Isian Anda masih tersimpan, coba kirim lagi.',
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _confirmDiscard() async {
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Buang laporan ini?'),
        content: Text(
          _photos.isEmpty
              ? 'Deskripsi yang sudah Anda tulis akan hilang.'
              : 'Deskripsi dan ${_photos.length} foto yang sudah Anda pilih akan hilang.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Lanjut mengisi'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red[800]),
            child: const Text('Buang laporan'),
          ),
        ],
      ),
    );
    if (discard == true && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_hasContent || _submitting,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _confirmDiscard();
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Buat Laporan Kejadian')),
        body: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              const _FieldLabel('Tanggal kejadian'),
              AtenimCard(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                onTap: _submitting ? null : _pickDate,
                child: SizedBox(
                  height: 56,
                  child: Row(
                    children: [
                      Icon(Icons.calendar_today_outlined, size: 20, color: AtenimUi.brand),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          DateFormat('EEEE, d MMMM yyyy', 'id_ID').format(_reportDate),
                          style: TextStyle(fontSize: 16, color: AtenimUi.ink),
                        ),
                      ),
                      Icon(Icons.expand_more, color: Colors.grey[700]),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              const _FieldLabel('Deskripsi kejadian'),
              TextFormField(
                controller: _descController,
                enabled: !_submitting,
                minLines: 4,
                maxLines: 8,
                textCapitalization: TextCapitalization.sentences,
                keyboardType: TextInputType.multiline,
                decoration: InputDecoration(
                  hintText: 'Apa yang terjadi, di mana, dan siapa yang terlibat?',
                  filled: true,
                  fillColor: Colors.white,
                  contentPadding: const EdgeInsets.all(14),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AtenimUi.radiusControl),
                    borderSide: BorderSide(color: Colors.grey[300]!),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AtenimUi.radiusControl),
                    borderSide: BorderSide(color: Colors.grey[300]!),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AtenimUi.radiusControl),
                    borderSide: BorderSide(color: AtenimUi.brand, width: 2),
                  ),
                ),
                validator: (v) {
                  if (v == null || v.trim().isEmpty) {
                    return 'Tuliskan dulu apa yang terjadi';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  const Expanded(child: _FieldLabel('Foto bukti')),
                  if (_photos.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        '${_photos.length} foto',
                        style: TextStyle(fontSize: 13, color: AtenimUi.inkSoft),
                      ),
                    ),
                ],
              ),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _submitting ? null : _pickFromCamera,
                      icon: const Icon(Icons.photo_camera_outlined, size: 20),
                      label: const Text('Kamera'),
                      style: _pickerStyle,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _submitting ? null : _pickFromGallery,
                      icon: const Icon(Icons.photo_library_outlined, size: 20),
                      label: const Text('Galeri'),
                      style: _pickerStyle,
                    ),
                  ),
                ],
              ),
              if (_photos.isNotEmpty) ...[
                const SizedBox(height: 12),
                SizedBox(
                  height: 104,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    itemCount: _photos.length,
                    itemBuilder: (context, i) {
                      final file = _photos[i];
                      return FadeSlideIn(
                        key: ValueKey(file.path),
                        dy: 6,
                        child: Padding(
                          padding: const EdgeInsets.only(right: 10),
                          child: SizedBox(
                            width: 104,
                            height: 104,
                            child: Stack(
                              children: [
                                Positioned.fill(
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(AtenimUi.radiusControl),
                                    child: Image.file(file, fit: BoxFit.cover),
                                  ),
                                ),
                                Positioned(
                                  top: 0,
                                  right: 0,
                                  child: IconButton(
                                    tooltip: 'Hapus foto ${i + 1}',
                                    onPressed: _submitting
                                        ? null
                                        : () => setState(() => _photos.remove(file)),
                                    icon: const Icon(Icons.close, size: 18, color: Colors.white),
                                    style: IconButton.styleFrom(
                                      backgroundColor: Colors.black54,
                                      minimumSize: const Size(48, 48),
                                      tapTargetSize: MaterialTapTargetSize.padded,
                                      padding: const EdgeInsets.all(4),
                                    ),
                                  ),
                                ),
                              ],
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
        ),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: FilledButton(
              onPressed: _submitting ? null : _submit,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AtenimUi.radiusControl),
                ),
              ),
              child: _submitting
                  ? const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
                        ),
                        SizedBox(width: 12),
                        Text('Menyimpan laporan...'),
                      ],
                    )
                  : const Text('Simpan laporan'),
            ),
          ),
        ),
      ),
    );
  }

  static final ButtonStyle _pickerStyle = OutlinedButton.styleFrom(
    minimumSize: const Size(0, 52),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AtenimUi.radiusControl),
    ),
  );
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 2, bottom: 8),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w700,
          color: AtenimUi.ink,
        ),
      ),
    );
  }
}
