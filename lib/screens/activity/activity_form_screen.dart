import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:image_picker/image_picker.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'dart:io';
import '../../providers/activity_provider.dart';
import '../../screens/camera/camera_screen.dart';
import '../../config/api_config.dart';
import '../../utils/toast_helper.dart';
import '../../providers/checkpoint_provider.dart';
import '../../widgets/checkpoint_timeline_widget.dart';

class ActivityFormScreen extends StatefulWidget {
  final String? activityId; // If provided, edit mode; otherwise, create mode

  const ActivityFormScreen({super.key, this.activityId});

  @override
  State<ActivityFormScreen> createState() => _ActivityFormScreenState();
}

class _ActivityFormScreenState extends State<ActivityFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _summaryController = TextEditingController();
  List<File> _selectedPhotos = [];
  List<String> _existingPhotoUrls = []; // For edit mode
  bool _isLoadingActivity = false;
  bool _isLoadingCheckpointMode = false;
  String _activityType = 'normal';

  @override
  void initState() {
    super.initState();
    if (widget.activityId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _loadActivity();
      });
    } else {
      _bootstrapCheckpointMode();
    }
  }

  Future<void> _bootstrapCheckpointMode() async {
    setState(() {
      _isLoadingCheckpointMode = true;
    });
    try {
      await Provider.of<CheckpointProvider>(
        context,
        listen: false,
      ).loadCheckpoint(force: true);
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingCheckpointMode = false;
        });
      }
    }
  }

  Future<void> _handleCheckpointComplete(
    String itemId, {
    String? templateId,
    File? photoBefore,
    File? photoAfter,
    List<File>? photosBefore,
    List<File>? photosAfter,
    String? notes,
    double? latitude,
    double? longitude,
    double? accuracy,
  }) async {
    final cp = Provider.of<CheckpointProvider>(context, listen: false);
    final success = await cp.completeItem(
      itemId,
      photoBefore: photoBefore,
      photoAfter: photoAfter,
      photosBefore: photosBefore,
      photosAfter: photosAfter,
      notes: notes,
      latitude: latitude,
      longitude: longitude,
      accuracy: accuracy,
      templateId: templateId,
    );
    if (mounted) {
      if (success) {
        ToastHelper.showSuccess(context, 'Checkpoint selesai!');
      } else {
        ToastHelper.showError(
          context,
          cp.error ?? 'Gagal menyelesaikan checkpoint',
        );
      }
    }
  }

  Future<void> _loadActivity() async {
    setState(() {
      _isLoadingActivity = true;
    });

    final provider = Provider.of<ActivityProvider>(context, listen: false);
    final activity = await provider.getActivityById(widget.activityId!);

    if (activity != null && mounted) {
      setState(() {
        _summaryController.text = activity.summary;
        _existingPhotoUrls = activity.photoUrls ?? [];
        _activityType = (activity.activityType.isNotEmpty
            ? activity.activityType
            : 'normal');
        _isLoadingActivity = false;
      });
    } else {
      if (mounted) {
        setState(() {
          _isLoadingActivity = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(provider.error ?? 'Gagal memuat aktivitas'),
            backgroundColor: Colors.red,
          ),
        );
        Navigator.of(context).pop();
      }
    }
  }

  @override
  void dispose() {
    _summaryController.dispose();
    super.dispose();
  }

  Future<void> _pickPhotoFromCamera() async {
    final photo = await Navigator.push<File>(
      context,
      MaterialPageRoute(
        builder: (_) => const CameraScreen(
          title: 'Ambil Foto Aktivitas',
          preferLowResolution: true,
        ),
      ),
    );

    if (photo != null) {
      setState(() {
        _selectedPhotos.add(photo);
      });
    }
  }

  Future<void> _pickPhotosFromGallery() async {
    final ImagePicker picker = ImagePicker();
    final List<XFile> images = await picker.pickMultiImage();

    if (images.isNotEmpty) {
      setState(() {
        _selectedPhotos.addAll(images.map((xFile) => File(xFile.path)));
      });
    }
  }

  void _removePhoto(int index) {
    setState(() {
      _selectedPhotos.removeAt(index);
    });
  }

  Future<void> _showPhotoPicker() async {
    final result = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: const Text('Ambil Foto'),
              onTap: () => Navigator.pop(context, 'camera'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('Pilih dari Gallery'),
              onTap: () => Navigator.pop(context, 'gallery'),
            ),
            ListTile(
              leading: const Icon(Icons.close),
              title: const Text('Batal'),
              onTap: () => Navigator.pop(context),
            ),
          ],
        ),
      ),
    );

    if (result == 'camera') {
      await _pickPhotoFromCamera();
    } else if (result == 'gallery') {
      await _pickPhotosFromGallery();
    }
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    final activityProvider = Provider.of<ActivityProvider>(
      context,
      listen: false,
    );
    bool success;

    if (widget.activityId != null) {
      // Edit mode
      success = await activityProvider.updateActivity(
        id: widget.activityId!,
        summary: _summaryController.text.trim(),
        activityType: _activityType,
        newPhotos: _selectedPhotos,
        existingPhotoUrls: _existingPhotoUrls,
      );
    } else {
      // Create mode
      success = await activityProvider.submitDailyActivity(
        summary: _summaryController.text.trim(),
        activityType: _activityType,
        photos: _selectedPhotos,
      );
    }

    if (mounted) {
      if (success) {
        final successMessage = activityProvider.successMessage;
        ToastHelper.showSuccess(
          context,
          successMessage ??
              (widget.activityId != null
                  ? 'Aktivitas berhasil diperbarui'
                  : 'Aktivitas berhasil disimpan'),
        );
        Navigator.of(context).pop(true);
      } else {
        ToastHelper.showError(
          context,
          activityProvider.error ?? 'Gagal menyimpan aktivitas',
        );
      }
    }
  }

  void _removeExistingPhoto(int index) {
    setState(() {
      _existingPhotoUrls.removeAt(index);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoadingActivity || _isLoadingCheckpointMode) {
      return Scaffold(
        appBar: AppBar(
          title: Text(
            widget.activityId != null ? 'Edit Aktivitas' : 'Tambah Aktivitas',
          ),
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    // === CHECKPOINT MODE: Read from provider (pre-fetched by home) ===
    final cp = Provider.of<CheckpointProvider>(context);
    final hasAssignedCheckpoint =
        cp.hasCheckpoint || cp.templateStates.isNotEmpty;
    final hasCheckpoint =
        widget.activityId == null &&
        hasAssignedCheckpoint &&
        (cp.template != null || cp.activeTemplateState != null);

    if (hasCheckpoint) {
      final activeState = cp.activeTemplateState;
      if (activeState == null) {
        return Scaffold(
          appBar: AppBar(title: const Text('Checkpoint Hari Ini')),
          body: const Center(child: CircularProgressIndicator()),
        );
      }

      return Scaffold(
        backgroundColor: Colors.grey.shade50,
        appBar: AppBar(
          title: const Text('Checkpoint Hari Ini'),
          centerTitle: true,
          elevation: 0,
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          children: [
            if (cp.hasMultipleTemplates) ...[
              Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.blue.shade50,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.blue.shade100),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Template aktif hari ini: ${cp.templateStates.length}',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Colors.blue.shade800,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: cp.templateStates.map((state) {
                        final selected =
                            state.template.id == cp.activeTemplateId;
                        final done = state.progress
                            .where((item) => item.completed)
                            .length;
                        final total = state.progress.length;
                        return ChoiceChip(
                          label: Text('${state.template.name} ($done/$total)'),
                          selected: selected,
                          onSelected: (_) =>
                              cp.setActiveTemplate(state.template.id),
                          selectedColor: Colors.blue.shade600,
                          labelStyle: TextStyle(
                            color: selected
                                ? Colors.white
                                : Colors.blue.shade800,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                          backgroundColor: Colors.white,
                          side: BorderSide(color: Colors.blue.shade200),
                        );
                      }).toList(),
                    ),
                  ],
                ),
              ),
            ],
            CheckpointTimelineWidget(
              key: ValueKey(activeState.template.id),
              template: activeState.template,
              progress: activeState.progress,
              onComplete:
                  (
                    itemId, {
                    photoBefore,
                    photoAfter,
                    photosBefore,
                    photosAfter,
                    notes,
                    latitude,
                    longitude,
                    accuracy,
                  }) => _handleCheckpointComplete(
                    itemId,
                    templateId: activeState.template.id,
                    photoBefore: photoBefore,
                    photoAfter: photoAfter,
                    photosBefore: photosBefore,
                    photosAfter: photosAfter,
                    notes: notes,
                    latitude: latitude,
                    longitude: longitude,
                    accuracy: accuracy,
                  ),
            ),
          ],
        ),
      );
    }

    // === DEFAULT MODE: Form daily activity biasa ===
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.activityId != null ? 'Edit Aktivitas' : 'Tambah Aktivitas',
        ),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // Jenis Aktivitas
            DropdownButtonFormField<String>(
              value: _activityType,
              decoration: const InputDecoration(
                labelText: 'Jenis Aktivitas',
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(value: 'normal', child: Text('Normal')),
                DropdownMenuItem(value: 'before', child: Text('Before')),
                DropdownMenuItem(value: 'after', child: Text('After')),
              ],
              onChanged: (value) {
                if (value == null) return;
                setState(() {
                  _activityType = value;
                });
              },
            ),
            const SizedBox(height: 16),
            // Keterangan
            TextFormField(
              controller: _summaryController,
              decoration: const InputDecoration(
                labelText: 'Keterangan *',
                hintText: 'Ceritakan apa yang telah Anda kerjakan hari ini...',
                border: OutlineInputBorder(),
              ),
              maxLines: 5,
              validator: (value) {
                if (value == null || value.isEmpty) {
                  return 'Keterangan wajib diisi';
                }
                return null;
              },
            ),
            const SizedBox(height: 16),
            // Photos Section
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.grey[50],
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey[300]!),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Foto Aktivitas (${_existingPhotoUrls.length + _selectedPhotos.length})',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      if (_existingPhotoUrls.isNotEmpty ||
                          _selectedPhotos.isNotEmpty)
                        TextButton.icon(
                          onPressed: () {
                            setState(() {
                              _existingPhotoUrls.clear();
                              _selectedPhotos.clear();
                            });
                          },
                          icon: const Icon(Icons.delete_outline, size: 18),
                          label: const Text(
                            'Hapus Semua',
                            style: TextStyle(fontSize: 12),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (_existingPhotoUrls.isEmpty && _selectedPhotos.isEmpty)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(vertical: 40),
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: Colors.grey[300]!,
                          style: BorderStyle.solid,
                        ),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(
                        children: [
                          Icon(
                            Icons.photo_library,
                            size: 48,
                            color: Colors.grey[400],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Belum ada foto',
                            style: TextStyle(
                              color: Colors.grey[600],
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
                    )
                  else
                    GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            crossAxisSpacing: 8,
                            mainAxisSpacing: 8,
                            childAspectRatio:
                                0.75, // 3/4 ratio for portrait photos
                          ),
                      itemCount:
                          _existingPhotoUrls.length + _selectedPhotos.length,
                      itemBuilder: (context, index) {
                        // Existing photos first
                        if (index < _existingPhotoUrls.length) {
                          final url = _existingPhotoUrls[index];
                          final fullUrl = ApiConfig.getImageUrl(url);
                          return Stack(
                            fit: StackFit.expand,
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: CachedNetworkImage(
                                  imageUrl: fullUrl,
                                  fit: BoxFit.cover,
                                  placeholder: (context, url) => Container(
                                    color: Colors.grey[200],
                                    child: const Center(
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    ),
                                  ),
                                  errorWidget: (context, url, error) =>
                                      Container(
                                        color: Colors.grey[200],
                                        child: Icon(
                                          Icons.broken_image,
                                          color: Colors.grey[400],
                                        ),
                                      ),
                                ),
                              ),
                              Positioned(
                                top: 4,
                                right: 4,
                                child: GestureDetector(
                                  onTap: () => _removeExistingPhoto(index),
                                  child: Container(
                                    padding: const EdgeInsets.all(4),
                                    decoration: const BoxDecoration(
                                      color: Colors.red,
                                      shape: BoxShape.circle,
                                    ),
                                    child: const Icon(
                                      Icons.close,
                                      color: Colors.white,
                                      size: 16,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          );
                        } else {
                          // New photos
                          final photoIndex = index - _existingPhotoUrls.length;
                          return Stack(
                            fit: StackFit.expand,
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Image.file(
                                  _selectedPhotos[photoIndex],
                                  fit: BoxFit.cover,
                                ),
                              ),
                              Positioned(
                                top: 4,
                                right: 4,
                                child: GestureDetector(
                                  onTap: () => _removePhoto(photoIndex),
                                  child: Container(
                                    padding: const EdgeInsets.all(4),
                                    decoration: const BoxDecoration(
                                      color: Colors.red,
                                      shape: BoxShape.circle,
                                    ),
                                    child: const Icon(
                                      Icons.close,
                                      color: Colors.white,
                                      size: 16,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          );
                        }
                      },
                    ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _showPhotoPicker,
                          icon: const Icon(Icons.add_photo_alternate),
                          label: const Text('Tambah Foto'),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            // Submit Button
            Consumer<ActivityProvider>(
              builder: (context, activityProvider, _) {
                return ElevatedButton(
                  onPressed: activityProvider.isLoading ? null : _submit,
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  child: activityProvider.isLoading
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text(
                          'Simpan Aktivitas',
                          style: TextStyle(fontSize: 16),
                        ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
