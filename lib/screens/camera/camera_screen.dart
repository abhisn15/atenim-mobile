import 'dart:io';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';

class CameraScreen extends StatefulWidget {
  final String title;
  final bool allowGallery;
  final bool preferLowResolution;

  /// Preset kamera yang dipakai pertama. Bila diisi, menggantikan pilihan dari [preferLowResolution]; jika kamera gagal
  /// dibuka dengan preset ini, jatuh ke ResolutionPreset.low (HP kelas bawah).
  final ResolutionPreset? preset;

  const CameraScreen({
    super.key,
    required this.title,
    this.allowGallery = true,
    this.preferLowResolution = false,
    this.preset,
  });

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen>
    with WidgetsBindingObserver {
  CameraController? _controller;
  List<CameraDescription>? _cameras;
  bool _isCapturing = false;
  int _currentCameraIndex = 0;
  bool _isFlashOn = false;
  final ImagePicker _imagePicker = ImagePicker();
  bool _isCameraReady = false;
  bool _isDisposing = false;
  bool _isInitializing = false;
  bool _deferDispose = false;
  bool _hasPermission = false;
  String? _errorMessage;

  void _showSnackBar(String message,
      {Color? backgroundColor, Duration? duration, SnackBarAction? action}) {
    if (!mounted || _isDisposing) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _isDisposing) {
        return;
      }
      final messenger = ScaffoldMessenger.maybeOf(context);
      if (messenger == null) {
        return;
      }
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: backgroundColor,
          duration: duration ?? const Duration(seconds: 3),
          action: action,
        ),
      );
    });
  }

  String _formatCameraError(String error) {
    final lower = error.toLowerCase();
    if (lower.contains('no supported surface combination') ||
        lower.contains('illegalargumentexception')) {
      return 'Kamera tidak kompatibel dengan mode ini. Coba gunakan Kamera Sistem atau ganti perangkat.';
    }
    if (lower.contains('permission')) {
      return 'Izin kamera ditolak. Aktifkan izin kamera di pengaturan.';
    }
    return error.replaceAll('Exception: ', '');
  }

  Future<void> _captureUsingSystemCamera() async {
    if (_isDisposing || _isCapturing) {
      return;
    }
    try {
      final preferred = (_cameras != null &&
              _cameras!.isNotEmpty &&
              _cameras![_currentCameraIndex].lensDirection == CameraLensDirection.front)
          ? CameraDevice.front
          : CameraDevice.rear;
      final picked = await _imagePicker.pickImage(
        source: ImageSource.camera,
        preferredCameraDevice: preferred,
        imageQuality: widget.preferLowResolution ? 60 : 80,
      );
      if (!mounted) {
        return;
      }
      if (picked != null) {
        Navigator.of(context).pop(File(picked.path));
      }
    } catch (e) {
      debugPrint('Error opening system camera: $e');
      if (!mounted) return;
      _showSnackBar(
        'Gagal membuka kamera sistem: $e',
        backgroundColor: Colors.red,
      );
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkPermissionAndInitialize();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _disposeCamera();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Prevent lifecycle operations if already disposing or not mounted
    if (!mounted || _isDisposing) {
      return;
    }

    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      if (_isCapturing || (_controller?.value.isTakingPicture ?? false)) {
        _deferDispose = true;
        return;
      }
      // Dispose camera safely
      try {
        _disposeCamera();
      } catch (e) {
        debugPrint('Error disposing camera on lifecycle pause: $e');
      }
    } else if (state == AppLifecycleState.resumed) {
      // Only reinitialize if we had permission before and not currently initializing
      if (_hasPermission &&
          !_isInitializing &&
          !_isDisposing &&
          (_controller == null || !_controller!.value.isInitialized)) {
        // Add small delay to prevent rapid re-initialization
        Future.delayed(const Duration(milliseconds: 100), () {
          if (mounted && !_isDisposing && !_isInitializing) {
            _checkPermissionAndInitialize();
          }
        });
      }
    }
  }

  Future<void> _checkPermissionAndInitialize() async {
    if (_isInitializing || _isDisposing || !mounted) {
      return;
    }

    try {
      // Check camera permission first
      final status = await Permission.camera.status;

      if (!status.isGranted) {
        final result = await Permission.camera.request();
        if (!result.isGranted) {
          if (mounted) {
            _showSnackBar(
              'Izin kamera diperlukan untuk mengambil foto',
              duration: const Duration(seconds: 3),
            );
            // Close screen if permission denied
            Future.delayed(const Duration(milliseconds: 500), () {
              if (mounted) {
                Navigator.of(context).pop();
              }
            });
          }
          return;
        }
      }

      _hasPermission = true;
      await _initializeCamera();
    } catch (e) {
      debugPrint('Error checking permission: $e');
      if (mounted) {
        _showSnackBar(
          'Gagal memeriksa izin kamera: $e',
          duration: const Duration(seconds: 3),
        );
      }
    }
  }

  Future<void> _initializeCamera() async {
    if (_isInitializing || _isDisposing || !mounted) {
      return;
    }

    _isInitializing = true;
    _errorMessage = null;

    if (mounted) {
      setState(() {
        _isCameraReady = false;
        _errorMessage = null;
      });
    }

    try {
      // Dispose existing controller if any
      if (_controller != null) {
        try {
          if (_controller!.value.isInitialized) {
            await _controller!.dispose();
          }
        } catch (e) {
          debugPrint('Error disposing old controller: $e');
        }
        _controller = null;
      }

      _cameras = await availableCameras();

      if (_cameras == null || _cameras!.isEmpty) {
        throw Exception('Tidak ada kamera yang tersedia');
      }

      // Set kamera depan sebagai default untuk selfie
      _currentCameraIndex = _findFrontCameraIndex();

      // Try different resolution presets for device compatibility
      // Start with LOW for low-end devices (Redmi 5A) to prevent OOM
      // Fallback to medium if low fails, then try high as last resort
      final presets = widget.preset != null
          ? [widget.preset!, if (widget.preset != ResolutionPreset.low) ResolutionPreset.low]
          : widget.preferLowResolution
          ? [ResolutionPreset.low] // Force low resolution for low-end devices
          : [
              ResolutionPreset.medium,
              ResolutionPreset.low,
              ResolutionPreset.high,
            ];
      Exception? lastError;
      bool initialized = false;

      for (final preset in presets) {
        if (!mounted || _isDisposing) {
          return;
        }

        try {
          debugPrint('Trying to initialize camera with preset: $preset');

          _controller = CameraController(
            _cameras![_currentCameraIndex],
            preset,
            enableAudio: false,
          );

          // Add timeout to prevent hanging
          await _controller!.initialize().timeout(
            const Duration(seconds: 15),
            onTimeout: () {
              throw Exception(
                'Timeout saat menginisialisasi kamera dengan preset $preset',
              );
            },
          );

          // Verify controller is still valid after initialization
          if (!mounted || _isDisposing || _controller == null) {
            await _disposeCamera();
            return;
          }

          // Verify camera is actually ready
          if (!_controller!.value.isInitialized) {
            throw Exception('Kamera tidak terinisialisasi dengan benar');
          }

          initialized = true;
          debugPrint('Camera initialized successfully with preset: $preset');
          break;
        } catch (e) {
          debugPrint('Failed to initialize with preset $preset: $e');
          lastError = e is Exception ? e : Exception(e.toString());

          // Dispose failed controller
          try {
            if (_controller != null) {
              await _controller!.dispose();
            }
          } catch (disposeError) {
            debugPrint('Error disposing failed controller: $disposeError');
          }
          _controller = null;

          // Wait a bit before trying next preset
          await Future.delayed(const Duration(milliseconds: 300));
        }
      }

      if (!initialized) {
        final lastErrorMessage = lastError?.toString().toLowerCase() ?? '';
        if (lastErrorMessage.contains('no supported surface combination') ||
            lastErrorMessage.contains('illegalargumentexception')) {
          try {
            debugPrint('Retrying camera with JPEG format fallback...');
            _controller = CameraController(
              _cameras![_currentCameraIndex],
              ResolutionPreset.low,
              enableAudio: false,
              imageFormatGroup: ImageFormatGroup.jpeg,
            );
            await _controller!.initialize().timeout(
              const Duration(seconds: 15),
              onTimeout: () {
                throw Exception('Timeout saat fallback kamera JPEG');
              },
            );
            if (_controller!.value.isInitialized) {
              initialized = true;
            }
          } catch (e) {
            lastError = e is Exception ? e : Exception(e.toString());
          }
        }
      }

      if (!initialized) {
        throw lastError ??
            Exception('Gagal menginisialisasi kamera dengan semua preset');
      }

      // Set initial flash mode
      try {
        await _controller!.setFlashMode(FlashMode.off);
      } catch (e) {
        debugPrint('Error setting flash mode: $e');
        // Continue even if flash fails
      }

      if (mounted && !_isDisposing) {
        setState(() {
          _isCameraReady = true;
          _errorMessage = null;
        });
      }
    } catch (e) {
      debugPrint('Error initializing camera: $e');
      final errorMsg = _formatCameraError(e.toString());

      if (mounted && !_isDisposing) {
        setState(() {
          _errorMessage = errorMsg;
          _isCameraReady = false;
        });

        _showSnackBar(
          'Gagal mengakses kamera: $errorMsg',
          duration: const Duration(seconds: 5),
          action: SnackBarAction(
            label: 'Coba Lagi',
            textColor: Colors.white,
            onPressed: () {
              _initializeCamera();
            },
          ),
        );
      }
    } finally {
      _isInitializing = false;
    }
  }

  int _findFrontCameraIndex() {
    for (int i = 0; i < _cameras!.length; i++) {
      if (_cameras![i].lensDirection == CameraLensDirection.front) {
        return i;
      }
    }
    return 0; // Fallback ke kamera pertama jika tidak ada depan
  }

  Future<void> _switchCamera() async {
    if (_cameras == null ||
        _cameras!.length < 2 ||
        _isInitializing ||
        _isDisposing ||
        _isCapturing ||
        (_controller?.value.isTakingPicture ?? false) ||
        !mounted) {
      return;
    }

    if (_controller == null || !_controller!.value.isInitialized) {
      return;
    }

    _isInitializing = true;

    try {
      if (mounted) {
        setState(() {
          _isCameraReady = false;
        });
      }

      // Dispose current controller safely with additional checks
      final oldController = _controller;
      _controller = null;

      try {
        if (oldController != null &&
            oldController.value.isInitialized &&
            !_isDisposing) {
          // Add timeout to prevent hanging
          await oldController.dispose().timeout(
            const Duration(seconds: 3),
            onTimeout: () {
              debugPrint('Timeout disposing camera during switch');
            },
          );
        }
      } catch (e) {
        debugPrint('Error disposing old controller during switch: $e');
      }

      // Wait longer to ensure camera is fully released
      await Future.delayed(const Duration(milliseconds: 500));

      if (!mounted || _isDisposing) {
        return;
      }

      _currentCameraIndex = (_currentCameraIndex + 1) % _cameras!.length;

      // Try medium preset first for better compatibility
      _controller = CameraController(
        _cameras![_currentCameraIndex],
        widget.preset ??
            (widget.preferLowResolution ? ResolutionPreset.low : ResolutionPreset.medium),
        enableAudio: false,
      );

      await _controller!.initialize().timeout(
        const Duration(seconds: 15),
        onTimeout: () {
          throw Exception('Timeout saat mengganti kamera');
        },
      );

      if (!mounted || _isDisposing || _controller == null) {
        await _disposeCamera();
        return;
      }

      // Reset flash saat ganti kamera - with error handling
      try {
        if (_controller!.value.isInitialized) {
          await _controller!.setFlashMode(FlashMode.off);
        }
      } catch (e) {
        debugPrint('Error setting flash mode after switch: $e');
      }

      if (mounted && !_isDisposing) {
        setState(() {
          _isCameraReady = true;
          _isFlashOn = false;
        });
      }
    } catch (e) {
      debugPrint('Error switching camera: $e');
      if (mounted && !_isDisposing) {
        // Don't show snackbar for camera switch errors to avoid spam
        // Coba inisialisasi ulang
        await _initializeCamera();
      }
    } finally {
      _isInitializing = false;
    }
  }

  Future<void> _toggleFlash() async {
    if (_controller == null ||
        !_controller!.value.isInitialized ||
        _isDisposing ||
        _isInitializing ||
        !mounted) {
      return;
    }

    try {
      // Double check controller is still valid
      if (_controller == null || !_controller!.value.isInitialized) {
        return;
      }

      if (_isFlashOn) {
        await _controller!.setFlashMode(FlashMode.off);
        if (mounted && !_isDisposing) {
          setState(() => _isFlashOn = false);
        }
      } else {
        await _controller!.setFlashMode(FlashMode.torch);
        if (mounted && !_isDisposing) {
          setState(() => _isFlashOn = true);
        }
      }
    } catch (e) {
      debugPrint('Error toggling flash: $e');
      // Don't show snackbar for flash errors as they are common
    }
  }

  Future<void> _capturePhoto() async {
    if (_controller == null ||
        !_controller!.value.isInitialized ||
        _isCapturing ||
        _isDisposing ||
        _isInitializing ||
        !mounted) {
      return;
    }
    if (_controller!.value.isTakingPicture) {
      return;
    }

    if (mounted) {
      setState(() => _isCapturing = true);
    }

    try {
      // Double check controller is still valid before taking picture
      if (_controller == null ||
          !_controller!.value.isInitialized ||
          _isDisposing) {
        throw Exception('Camera tidak tersedia');
      }

      // Add timeout to prevent hanging
      final image = await _controller!.takePicture().timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          throw Exception('Timeout saat mengambil foto');
        },
      );

      if (!mounted || _isDisposing) {
        return;
      }

      final file = File(image.path);

      // Verify file exists
      if (!await file.exists()) {
        throw Exception('File foto tidak ditemukan');
      }

      // Dispose camera dengan safety checks
      try {
        await _disposeCamera();
      } catch (e) {
        debugPrint('Error disposing camera after capture: $e');
      }

      if (mounted) {
        // Pop dengan delay untuk memastikan camera sudah di-dispose
        await Future.delayed(const Duration(milliseconds: 300));
        if (mounted && !_isDisposing) {
          Navigator.of(context).pop(file);
        }
      }
    } catch (e) {
      debugPrint('Error capturing photo: $e');
      if (mounted && !_isDisposing) {
        setState(() => _isCapturing = false);
        _showSnackBar(
          'Gagal mengambil foto: $e',
          duration: const Duration(seconds: 2),
        );
      }
      if (_deferDispose) {
        try {
          await _disposeCamera();
        } catch (disposeError) {
          debugPrint(
            'Error disposing camera after capture error: $disposeError',
          );
        }
      }
    }
  }

  Future<void> _pickFromGallery() async {
    if (_isDisposing || !mounted) {
      return;
    }

    try {
      // Dispose camera before opening gallery to free resources
      await _disposeCamera();

      final image = await _imagePicker
          .pickImage(source: ImageSource.gallery)
          .timeout(
            const Duration(seconds: 30),
            onTimeout: () {
              throw Exception('Timeout saat memilih foto dari galeri');
            },
          );

      if (image != null && mounted && !_isDisposing) {
        final file = File(image.path);
        if (await file.exists()) {
          Navigator.of(context).pop(file);
        } else {
          throw Exception('File foto tidak ditemukan');
        }
      }
    } catch (e) {
      debugPrint('Error picking image: $e');
      if (mounted && !_isDisposing) {
        _showSnackBar(
          'Gagal memilih foto: $e',
          duration: const Duration(seconds: 2),
        );
      }
    }
  }

  Future<void> _disposeCamera() async {
    if (_isDisposing) {
      return;
    }
    if (_controller?.value.isTakingPicture ?? false) {
      _deferDispose = true;
      return;
    }

    _isDisposing = true;
    _isInitializing = false;

    try {
      final controller = _controller;
      _controller = null;

      if (controller != null) {
        try {
          // Check if controller is still valid before disposing
          if (controller.value.isInitialized && !_isDisposing) {
            await controller.dispose().timeout(
              const Duration(seconds: 5),
              onTimeout: () {
                debugPrint('Timeout disposing camera controller');
              },
            );
          }
        } catch (e) {
          debugPrint('Error disposing camera: $e');
          // Don't try to dispose again to avoid further crashes
          // Just log and continue
        }
      }
    } catch (e) {
      debugPrint('Error in disposeCamera: $e');
    } finally {
      _deferDispose = false;
      if (mounted) {
        setState(() {
          _isCameraReady = false;
        });
      }
      _isDisposing = false;
    }
  }

  // Helper method untuk mendapatkan ukuran responsive
  double _getResponsiveSize(BuildContext context, double baseSize) {
    final screenWidth = MediaQuery.of(context).size.width;
    final textScale = MediaQuery.of(context).textScaleFactor;

    // Adjust untuk device kecil (lebar < 360)
    if (screenWidth < 360) {
      return baseSize * 0.85;
    }

    // Adjust untuk text scale yang besar
    if (textScale > 1.3) {
      return baseSize / textScale;
    }

    return baseSize;
  }

  // Build camera preview dengan scaling yang benar untuk full screen tanpa distorsi
  Widget _buildCameraPreview() {
    // Add safety checks to prevent crashes
    if (_controller == null ||
        !_controller!.value.isInitialized ||
        _isDisposing) {
      return Container(color: Colors.black);
    }

    try {
      final size = MediaQuery.of(context).size;
      var scale = size.aspectRatio * _controller!.value.aspectRatio;

      // To prevent scaling down, invert the value
      if (scale < 1) scale = 1 / scale;

      return ClipRect(
        child: Transform.scale(
          scale: scale,
          child: Center(child: CameraPreview(_controller!)),
        ),
      );
    } catch (e) {
      debugPrint('Error building camera preview: $e');
      return Container(color: Colors.black);
    }
  }

  // Helper untuk padding responsive
  EdgeInsets _getResponsivePadding(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final textScale = MediaQuery.of(context).textScaleFactor;

    double horizontal = 20;
    double vertical = 16;

    if (screenWidth < 360) {
      horizontal = 12;
      vertical = 12;
    } else if (screenWidth < 400) {
      horizontal = 16;
      vertical = 14;
    }

    // Kurangi padding jika text scale besar
    if (textScale > 1.3) {
      horizontal *= 0.9;
      vertical *= 0.9;
    }

    return EdgeInsets.symmetric(horizontal: horizontal, vertical: vertical);
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final screenWidth = mediaQuery.size.width;

    // Check if camera is ready and controller is valid
    bool isCameraValid = false;
    if (!_isDisposing && !_isInitializing) {
      try {
        isCameraValid =
            _isCameraReady &&
            _controller != null &&
            _controller!.value.isInitialized &&
            !_controller!.value.hasError;
      } catch (e) {
        // Controller might be disposed or in invalid state, treat as invalid
        isCameraValid = false;
        debugPrint('Error checking camera validity: $e');
      }
    }

    // Ukuran button yang responsive
    final buttonSize = _getResponsiveSize(context, 44);
    final iconSize = _getResponsiveSize(context, 24);
    final captureButtonSize = _getResponsiveSize(context, 80);
    final captureIconSize = _getResponsiveSize(context, 40);
    final bottomButtonSize = _getResponsiveSize(context, 60);
    final bottomIconSize = _getResponsiveSize(context, 28);

    // Font size yang responsive
    final titleFontSize = _getResponsiveSize(context, 18);

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            // Full screen camera preview dengan aspect ratio yang benar
            if (isCameraValid)
              Positioned.fill(child: _buildCameraPreview())
            else
              Positioned.fill(
                child: Container(
                  color: Colors.black,
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (_errorMessage != null) ...[
                          // Error state - show error message and retry button
                          const Icon(
                            Icons.error_outline,
                            color: Colors.white,
                            size: 64,
                          ),
                          const SizedBox(height: 24),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 32),
                            child: Column(
                              children: [
                                Text(
                                  _errorMessage!,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 14,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                                const SizedBox(height: 24),
                                ElevatedButton(
                                  onPressed: _isInitializing
                                      ? null
                                      : _initializeCamera,
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.white,
                                    foregroundColor: Colors.black,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 32,
                                      vertical: 12,
                                    ),
                                  ),
                                  child: _isInitializing
                                      ? const SizedBox(
                                          width: 20,
                                          height: 20,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            valueColor:
                                                AlwaysStoppedAnimation<Color>(
                                                  Colors.black,
                                                ),
                                          ),
                                        )
                                      : const Text('Coba Lagi'),
                                ),
                                const SizedBox(height: 12),
                                if (!_isInitializing)
                                  OutlinedButton(
                                    onPressed: _captureUsingSystemCamera,
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: Colors.white,
                                      side: const BorderSide(color: Colors.white),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 24,
                                        vertical: 10,
                                      ),
                                    ),
                                    child: const Text('Gunakan Kamera Sistem'),
                                  ),
                              ],
                            ),
                          ),
                        ] else ...[
                          // Loading state - show loading indicator
                          const CircularProgressIndicator(color: Colors.white),
                          const SizedBox(height: 24),
                          const Text(
                            'Menginisialisasi kamera...',
                            style: TextStyle(color: Colors.white, fontSize: 14),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),

            // Top controls
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Container(
                padding: _getResponsivePadding(context),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.black.withOpacity(0.7), Colors.transparent],
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    // Tombol Close
                    GestureDetector(
                      onTap: () => Navigator.of(context).pop(),
                      child: Container(
                        width: buttonSize,
                        height: buttonSize,
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.5),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.close,
                          color: Colors.white,
                          size: iconSize,
                        ),
                      ),
                    ),

                    // Title - menggunakan Flexible dan FittedBox untuk mencegah overflow
                    Flexible(
                      child: Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: screenWidth < 360 ? 4 : 8,
                        ),
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            widget.title,
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: titleFontSize,
                              fontWeight: FontWeight.w500,
                            ),
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ),

                    // Tombol Flash (hanya untuk kamera belakang)
                    if (_cameras != null &&
                        _cameras!.isNotEmpty &&
                        _cameras![_currentCameraIndex].lensDirection ==
                            CameraLensDirection.back)
                      GestureDetector(
                        onTap: _toggleFlash,
                        child: Container(
                          width: buttonSize,
                          height: buttonSize,
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.5),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            _isFlashOn ? Icons.flash_on : Icons.flash_off,
                            color: Colors.white,
                            size: iconSize,
                          ),
                        ),
                      )
                    else
                      SizedBox(width: buttonSize),
                  ],
                ),
              ),
            ),

            // Bottom controls
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                padding: EdgeInsets.symmetric(
                  vertical: _getResponsiveSize(context, 40),
                  horizontal: _getResponsiveSize(context, 24),
                ),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Colors.black.withOpacity(0.8)],
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Baris pertama untuk tombol gallery, capture, dan switch camera
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        // Tombol Gallery (kiri)
                        if (widget.allowGallery)
                          GestureDetector(
                            onTap: _pickFromGallery,
                            child: Container(
                              width: bottomButtonSize,
                              height: bottomButtonSize,
                              decoration: BoxDecoration(
                                color: Colors.black.withOpacity(0.5),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                Icons.photo_library,
                                color: Colors.white,
                                size: bottomIconSize,
                              ),
                            ),
                          )
                        else
                          SizedBox(
                            width: bottomButtonSize,
                            height: bottomButtonSize,
                          ),

                        // Spacer untuk memusatkan tombol capture
                        const Expanded(child: SizedBox()),

                        // Tombol Capture (tengah)
                        GestureDetector(
                          onTap: _isCapturing ? null : _capturePhoto,
                          child: Container(
                            width: captureButtonSize,
                            height: captureButtonSize,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.white,
                              border: Border.all(
                                color: Colors.white.withOpacity(0.8),
                                width: _getResponsiveSize(context, 5),
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withOpacity(0.3),
                                  blurRadius: 10,
                                  spreadRadius: 2,
                                ),
                              ],
                            ),
                            child: _isCapturing
                                ? Padding(
                                    padding: EdgeInsets.all(
                                      _getResponsiveSize(context, 20),
                                    ),
                                    child: const CircularProgressIndicator(
                                      strokeWidth: 3,
                                      valueColor: AlwaysStoppedAnimation<Color>(
                                        Colors.black,
                                      ),
                                    ),
                                  )
                                : Center(
                                    child: Icon(
                                      Icons.camera_alt,
                                      color: Colors.black,
                                      size: captureIconSize,
                                    ),
                                  ),
                          ),
                        ),

                        // Spacer untuk memusatkan tombol capture
                        const Expanded(child: SizedBox()),

                        // Tombol Switch Camera (kanan)
                        if (_cameras != null && _cameras!.length > 1)
                          GestureDetector(
                            onTap: _switchCamera,
                            child: Container(
                              width: bottomButtonSize,
                              height: bottomButtonSize,
                              decoration: BoxDecoration(
                                color: Colors.black.withOpacity(0.5),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                Icons.flip_camera_ios,
                                color: Colors.white,
                                size: bottomIconSize,
                              ),
                            ),
                          )
                        else
                          SizedBox(
                            width: bottomButtonSize,
                            height: bottomButtonSize,
                          ),
                      ],
                    ),

                    // Spasi bawah untuk menghindari notch - responsive
                    SizedBox(height: _getResponsiveSize(context, 20)),
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
