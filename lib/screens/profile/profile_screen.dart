import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/patrol_provider.dart';
import '../../providers/auth_provider.dart';
import '../../screens/camera/camera_screen.dart';
import '../../services/profile_service.dart';
import '../../services/offline_storage_service.dart';
import '../../services/team_service.dart';
import '../../config/api_config.dart';
import '../../models/user_model.dart';
import '../../models/team_model.dart';
import '../../app_keys.dart' show navigatorKey;
import 'dart:io';

class ProfileScreen extends StatefulWidget {
  final bool startInEditMode;
  
  const ProfileScreen({super.key, this.startInEditMode = false});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen>
    with TickerProviderStateMixin {
  final ProfileService _profileService = ProfileService();
  final TeamService _teamService = TeamService();
  final _formKey = GlobalKey<FormState>();
  bool _isEditing = false;
  bool _isUpdating = false;
  File? _photoFile;
  bool _teamLoading = false;
  List<TeamSummary> _myTeams = [];
  List<TeamSummary> _leaderTeams = [];

  // Controllers
  late TextEditingController _nameController;
  late TextEditingController _emailController;
  late TextEditingController _titleController;
  late TextEditingController _teamController;
  late TextEditingController _nikController;
  late TextEditingController _phoneController;
  late TextEditingController _bpjsKesController;
  late TextEditingController _bpjsKetController;
  late TextEditingController _tempatLahirController;
  late TextEditingController _tanggalLahirController;
  late TextEditingController _namaRekeningController;
  late TextEditingController _noRekeningController;
  late TextEditingController _pemilikRekeningController;
  late TextEditingController _newPasswordController;
  late TextEditingController _confirmPasswordController;

  // Animation controllers
  late AnimationController _fadeController;
  late AnimationController _slideController;
  late Animation<double> _fadeAnimation;
  late Animation<Offset> _slideAnimation;

  // Avatar colors
  final List<String> _avatarColors = [
    '#1d4ed8', // blue
    '#7c3aed', // violet
    '#dc2626', // red
    '#ea580c', // orange
    '#ca8a04', // yellow
    '#16a34a', // green
    '#0891b2', // cyan
    '#db2777', // pink
    '#9333ea', // purple
    '#059669', // emerald
  ];

  String? _selectedAvatarColor;
  String? _photoPreview;

  @override
  void initState() {
    super.initState();
    
    // Initialize animation controllers
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _slideController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );

    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _fadeController, curve: Curves.easeInOut),
    );
    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, 0.1),
      end: Offset.zero,
    ).animate(
      CurvedAnimation(parent: _slideController, curve: Curves.easeOutCubic),
    );

    // Initialize controllers with empty values (will be set from user data)
    _nameController = TextEditingController();
    _emailController = TextEditingController();
    _titleController = TextEditingController();
    _teamController = TextEditingController();
    _nikController = TextEditingController();
    _phoneController = TextEditingController();
    _bpjsKesController = TextEditingController();
    _bpjsKetController = TextEditingController();
    _tempatLahirController = TextEditingController();
    _tanggalLahirController = TextEditingController();
    _namaRekeningController = TextEditingController();
    _noRekeningController = TextEditingController();
    _pemilikRekeningController = TextEditingController();
    _newPasswordController = TextEditingController();
    _confirmPasswordController = TextEditingController();

    // Start in edit mode if requested
    if (widget.startInEditMode) {
      _isEditing = true;
    }

    // Initialize form immediately if user data is available
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        final authProvider = Provider.of<AuthProvider>(context, listen: false);
        final user = authProvider.user;
        if (user != null) {
          _initializeForm(user);
        }
        _loadTeamInfo();
      }
    });

    // Start animations
    _fadeController.forward();
    _slideController.forward();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _titleController.dispose();
    _teamController.dispose();
    _newPasswordController.dispose();
    _confirmPasswordController.dispose();
    _nikController.dispose();
    _phoneController.dispose();
    _bpjsKesController.dispose();
    _bpjsKetController.dispose();
    _tempatLahirController.dispose();
    _tanggalLahirController.dispose();
    _namaRekeningController.dispose();
    _noRekeningController.dispose();
    _pemilikRekeningController.dispose();
    _fadeController.dispose();
    _slideController.dispose();
    super.dispose();
  }

  void _initializeForm(User user) {
    // Always set name, even if empty (will show '-' in display)
    _nameController.text = user.name;
    _emailController.text = user.email.isNotEmpty ? user.email : '';
    _titleController.text = user.title ?? '';
    _teamController.text = user.team ?? '';
    _selectedAvatarColor = user.avatarColor ?? '#1d4ed8';
    _photoPreview = user.photoUrl;
    _nikController.text = user.externalId;
    _phoneController.text = user.phone ?? '';
    _bpjsKesController.text = user.bpjsKesehatan ?? '';
    _bpjsKetController.text = user.bpjsKetenagakerjaan ?? '';
    _tempatLahirController.text = user.tempatLahir ?? '';
    _tanggalLahirController.text = user.tanggalLahir ?? '';
    _namaRekeningController.text = user.namaRekening ?? '';
    _noRekeningController.text = user.noRekening ?? '';
    _pemilikRekeningController.text = user.pemilikRekening ?? '';
    // Reset password fields
    _newPasswordController.clear();
    _confirmPasswordController.clear();
  }

  Future<void> _loadTeamInfo() async {
    if (_teamLoading) return;
    _teamLoading = true;
    try {
      final teams = await _teamService.getMyTeamsWithMembers();
      if (!mounted) return;
      setState(() {
        _myTeams = teams;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _myTeams = [];
      });
    }

    try {
      final leaderTeams = await _teamService.getLeaderTeams();
      if (!mounted) return;
      setState(() {
        _leaderTeams = leaderTeams;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _leaderTeams = [];
      });
    } finally {
      _teamLoading = false;
    }
  }

  Future<void> _pickPhoto() async {
    final photo = await Navigator.push<File>(
      context,
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) =>
            const CameraScreen(
              title: 'Ambil Foto Profil',
              preferLowResolution: true,
            ),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(opacity: animation, child: child);
        },
        transitionDuration: const Duration(milliseconds: 300),
      ),
    );

    if (photo != null && mounted) {
      setState(() {
        _photoFile = photo;
        _photoPreview = photo.path;
      });
    }
  }

  Future<void> _saveProfile() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() {
      _isUpdating = true;
    });

    // Validasi password jika diisi
    final newPassword = _newPasswordController.text.trim();
    final confirmPassword = _confirmPasswordController.text.trim();
    
    // Jika salah satu field password diisi, maka keduanya harus diisi dan cocok
    if (newPassword.isNotEmpty || confirmPassword.isNotEmpty) {
      if (newPassword.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Password baru wajib diisi jika ingin mengganti password'),
            backgroundColor: Colors.red,
          ),
        );
        setState(() {
          _isUpdating = false;
        });
        return;
      }
      
      if (confirmPassword.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Konfirmasi password wajib diisi'),
            backgroundColor: Colors.red,
          ),
        );
        setState(() {
          _isUpdating = false;
        });
        return;
      }
      
      // ✅ Validasi sederhana: hanya cek password dan konfirmasi cocok, tanpa persyaratan kompleks
      if (newPassword != confirmPassword) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Konfirmasi password tidak cocok'),
            backgroundColor: Colors.red,
          ),
        );
        setState(() {
          _isUpdating = false;
        });
        return;
      }
    }

    final result = await _profileService.updateProfile(
      name: _nameController.text.trim(),
      email: _emailController.text.trim(),
      title: _titleController.text.trim(),
      team: _teamController.text.trim().isEmpty
          ? null
          : _teamController.text.trim(),
      avatarColor: _selectedAvatarColor,
      photo: _photoFile,
      newPassword: newPassword.isNotEmpty ? newPassword : null, // Hanya kirim jika diisi
      externalId: _nikController.text.trim().isEmpty ? null : _nikController.text.trim(),
      phone: _phoneController.text.trim().isEmpty ? null : _phoneController.text.trim(),
      bpjsKesehatan: _bpjsKesController.text.trim().isEmpty ? null : _bpjsKesController.text.trim(),
      bpjsKetenagakerjaan: _bpjsKetController.text.trim().isEmpty ? null : _bpjsKetController.text.trim(),
      tempatLahir: _tempatLahirController.text.trim().isEmpty ? null : _tempatLahirController.text.trim(),
      tanggalLahir: _tanggalLahirController.text.trim().isEmpty ? null : _tanggalLahirController.text.trim(),
      namaRekening: _namaRekeningController.text.trim().isEmpty ? null : _namaRekeningController.text.trim(),
      noRekening: _noRekeningController.text.trim().isEmpty ? null : _noRekeningController.text.trim(),
      pemilikRekening: _pemilikRekeningController.text.trim().isEmpty ? null : _pemilikRekeningController.text.trim(),
    );

    if (mounted) {
      setState(() {
        _isUpdating = false;
      });

      if (result['success'] == true) {
        // Reload user data
        await Provider.of<AuthProvider>(context, listen: false).refreshUser();
        
        setState(() {
          _isEditing = false;
          _photoFile = null;
          _newPasswordController.clear();
          _confirmPasswordController.clear();
        });

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Row(
                children: [
                  Icon(Icons.check_circle, color: Colors.white),
                  SizedBox(width: 8),
                  Text('Profile berhasil diperbarui'),
                ],
              ),
              backgroundColor: Colors.green,
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Row(
                children: [
                  const Icon(Icons.error, color: Colors.white),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      result['message'] ?? 'Gagal memperbarui profile',
                    ),
                  ),
                ],
              ),
              backgroundColor: Colors.red,
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          );
        }
      }
    }
  }

  void _cancelEdit() {
    final user = Provider.of<AuthProvider>(context, listen: false).user;
    if (user != null) {
      _initializeForm(user);
    }
    setState(() {
      _isEditing = false;
      _photoFile = null;
      _photoPreview = user?.photoUrl;
      _newPasswordController.clear();
      _confirmPasswordController.clear();
    });
  }

  Future<void> _handleLogout() async {
    // Get AuthProvider before showing dialog to avoid context issues after dialog closes
    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    // Logout menghapus antrean offline, jadi beri tahu dulu kalau masih ada isinya
    final unsent = await OfflineStorageService().countUnsentReports();
    if (!mounted) return;
    // Scan Patroli QR memakai antrean sendiri di berkas: tidak terhapus saat logout, tetapi baru terkirim setelah
    // akun yang sama masuk lagi dan ada sinyal. Pengguna perlu tahu itu.
    final patrolPending = context.read<PatrolProvider>().pendingCount;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        title: const Row(
          children: [
            Icon(Icons.logout, color: Colors.red),
            SizedBox(width: 8),
            Text('Logout'),
          ],
        ),
        content: unsent > 0
            ? Text(
                'Masih ada $unsent laporan (absen, aktivitas, atau patroli) yang belum terkirim ke server. '
                'Kalau logout sekarang, laporan itu terhapus dari HP ini.\n\n'
                'Sambungkan internet dan tunggu sampai terkirim, baru logout.',
                style: TextStyle(color: Colors.red[800]),
              )
            : patrolPending > 0
                ? Text(
                    '$patrolPending scan patroli belum terkirim. Scan itu tetap tersimpan di HP dan akan terkirim '
                    'otomatis setelah Anda masuk lagi dengan akun yang sama dan ada sinyal.'
                    '\n\nApakah Anda yakin ingin logout?',
                  )
                : const Text('Apakah Anda yakin ingin logout?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Batal'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: Text(unsent > 0 ? 'Tetap Logout' : 'Logout'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      await authProvider.logout();
      
      // Use navigatorKey for safer navigation after logout
      // Wait a bit to ensure state is updated
      await Future.delayed(const Duration(milliseconds: 100));
      
      final navContext = navigatorKey.currentContext;
      if (navContext != null && mounted) {
        Navigator.of(navContext).pushNamedAndRemoveUntil('/login', (route) => false);
      } else if (mounted) {
        // Fallback: try using original context if navigatorKey is not available
        Navigator.of(context).pushNamedAndRemoveUntil('/login', (route) => false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[50],
      appBar: AppBar(
        elevation: 0,
        title: const Text(
          'Profil',
          style: TextStyle(
            fontWeight: FontWeight.bold,
          ),
        ),
        centerTitle: true,
        actions: [
          Consumer<AuthProvider>(
            builder: (context, authProvider, _) {
              final user = authProvider.user;
              if (user == null) return const SizedBox.shrink();

              if (!_isEditing) {
                return IconButton(
                  icon: const Icon(Icons.edit),
                  onPressed: () {
                    _initializeForm(user);
                    setState(() {
                      _isEditing = true;
                    });
                  },
                  tooltip: 'Edit Profile',
                );
              }
              return const SizedBox.shrink();
            },
          ),
        ],
      ),
      body: Consumer<AuthProvider>(
        builder: (context, authProvider, _) {
          final user = authProvider.user;
          if (user == null) {
            return const Center(child: CircularProgressIndicator());
          }

          // Initialize form immediately when user data is available
          // Always initialize to ensure form is synced with user data
          if (_nameController.text.isEmpty || _nameController.text != user.name) {
            _initializeForm(user);
          }
          
          // Also ensure form is initialized if in edit mode
          if (_isEditing && (_nameController.text.isEmpty || _nameController.text != user.name)) {
            _initializeForm(user);
          }

          return FadeTransition(
            opacity: _fadeAnimation,
            child: SlideTransition(
              position: _slideAnimation,
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: 20),
                      // Profile Photo Section
                      _buildProfilePhotoSection(user),
                      const SizedBox(height: 32),
                      // Profile Form Section
                      if (_isEditing) ...[
                        _buildEditForm(),
                      ] else ...[
                        _buildProfileInfo(user),
                      ],
                      const SizedBox(height: 24),
                      // Logout Button
                      _buildLogoutButton(),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildProfilePhotoSection(User user) {
    return Center(
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0.0, end: 1.0),
        duration: const Duration(milliseconds: 600),
        curve: Curves.elasticOut,
        builder: (context, value, child) {
          return Transform.scale(
            scale: value,
            child: child,
          );
        },
        child: Stack(
          children: [
            Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: _getColorFromHex(_selectedAvatarColor ?? user.avatarColor ?? '#1d4ed8'),
                  width: 4,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.1),
                    blurRadius: 20,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: CircleAvatar(
                radius: 70,
                backgroundColor: Colors.grey[200],
                backgroundImage: _photoPreview != null
                    ? (_photoPreview!.startsWith('http')
                        ? NetworkImage(ApiConfig.getImageUrl(_photoPreview!))
                        : FileImage(File(_photoPreview!)) as ImageProvider)
                    : null,
                child: _photoPreview == null
                    ? Text(
                        user.name[0].toUpperCase(),
                        style: TextStyle(
                          fontSize: 56,
                          fontWeight: FontWeight.bold,
                          color: _getColorFromHex(
                              _selectedAvatarColor ?? user.avatarColor ?? '#1d4ed8'),
                        ),
                      )
                    : null,
              ),
            ),
            if (_isEditing)
              Positioned(
                bottom: 0,
                right: 0,
                child: GestureDetector(
                  onTap: _pickPhoto,
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Theme.of(context).primaryColor,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 3),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.2),
                          blurRadius: 8,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.camera_alt,
                      color: Colors.white,
                      size: 24,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildProfileInfo(User user) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: const Duration(milliseconds: 400),
      builder: (context, value, child) {
        return Opacity(
          opacity: value,
          child: Transform.translate(
            offset: Offset(0, 20 * (1 - value)),
            child: child,
          ),
        );
      },
      child: Card(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildInfoRow(
                icon: Icons.person,
                label: 'Nama',
                value: user.name,
              ),
              const Divider(height: 32),
              _buildInfoRow(
                icon: Icons.email,
                label: 'Email',
                value: user.email,
              ),
              if (user.title != null && user.title!.isNotEmpty) ...[
                const Divider(height: 32),
                _buildInfoRow(
                  icon: Icons.work,
                  label: 'Jabatan',
                  value: user.title!,
                ),
              ],
              if (user.team != null && user.team!.isNotEmpty) ...[
                const Divider(height: 32),
                _buildInfoRow(
                  icon: Icons.group,
                  label: 'Team',
                  value: user.team!,
                ),
              ],
              if (_myTeams.isNotEmpty) ...[
                const Divider(height: 32),
                _buildInfoRow(
                  icon: Icons.groups,
                  label: 'Team Saya',
                  value: _myTeams.map((t) => t.name).toSet().join(', '),
                ),
                const Divider(height: 32),
                _buildInfoRow(
                  icon: Icons.person_outline,
                  label: 'Team Leader',
                  value: _myTeams
                      .map((t) => t.leaderName)
                      .where((name) => name.isNotEmpty)
                      .toSet()
                      .join(', '),
                ),
              ],
              if (_leaderTeams.isNotEmpty) ...[
                const Divider(height: 32),
                _buildInfoRow(
                  icon: Icons.star,
                  label: 'Team Dipimpin',
                  value: _leaderTeams.map((t) => t.name).toSet().join(', '),
                ),
              ],
              const Divider(height: 32),
              _buildInfoRow(
                icon: Icons.badge,
                label: 'ID Karyawan',
                value: user.employeeId ?? '',
              ),
              const Divider(height: 32),
              _buildInfoRow(
                icon: Icons.location_on,
                label: 'Site',
                value: (user.site?.name?.isNotEmpty ?? false)
                    ? user.site!.name
                    : (user.siteId ?? ''),
              ),
              const Divider(height: 32),
              _buildInfoRow(
                icon: Icons.security,
                label: 'Role',
                value: user.role,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInfoRow({
    required IconData icon,
    required String label,
    required String value,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.blue[50],
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, size: 20, color: Colors.blue[700]),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.grey[600],
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                value.isNotEmpty ? value : '-',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: Colors.black87,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildEditForm() {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: const Duration(milliseconds: 400),
      builder: (context, value, child) {
        return Opacity(
          opacity: value,
          child: Transform.translate(
            offset: Offset(0, 20 * (1 - value)),
            child: child,
          ),
        );
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Name Field
          _buildTextField(
            controller: _nameController,
            label: 'Nama Lengkap',
            icon: Icons.person,
            validator: (value) {
              if (value == null || value.trim().isEmpty) {
                return 'Nama wajib diisi';
              }
              return null;
            },
          ),
          const SizedBox(height: 20),
          // Email Field
          _buildTextField(
            controller: _emailController,
            label: 'Email',
            icon: Icons.email,
            keyboardType: TextInputType.emailAddress,
            validator: (value) {
              if (value == null || value.trim().isEmpty) {
                return 'Email wajib diisi';
              }
              if (!RegExp(r'^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$',
                      caseSensitive: false)
                  .hasMatch(value)) {
                return 'Format email tidak valid';
              }
              return null;
            },
          ),
          const SizedBox(height: 20),
          // Title Field
          _buildTextField(
            controller: _titleController,
            label: 'Jabatan',
            icon: Icons.work,
            validator: (value) {
              if (value == null || value.trim().isEmpty) {
                return 'Jabatan wajib diisi';
              }
              return null;
            },
          ),
          const SizedBox(height: 20),
          // NIK KTP (External ID)
          _buildTextField(
            controller: _nikController,
            label: 'NIK KTP',
            icon: Icons.badge,
            validator: (value) {
              if (value == null || value.trim().isEmpty) {
                return 'NIK wajib diisi';
              }
              return null;
            },
          ),
          const SizedBox(height: 20),
          // Phone
          _buildTextField(
            controller: _phoneController,
            label: 'No. HP',
            icon: Icons.phone,
            keyboardType: TextInputType.phone,
          ),
          const SizedBox(height: 20),
          // BPJS Kesehatan
          _buildTextField(
            controller: _bpjsKesController,
            label: 'BPJS Kesehatan',
            icon: Icons.health_and_safety,
          ),
          const SizedBox(height: 20),
          // BPJS Ketenagakerjaan
          _buildTextField(
            controller: _bpjsKetController,
            label: 'BPJS Ketenagakerjaan',
            icon: Icons.health_and_safety_outlined,
          ),
          const SizedBox(height: 20),
          // Tempat Lahir
          _buildTextField(
            controller: _tempatLahirController,
            label: 'Tempat Lahir',
            icon: Icons.location_city,
          ),
          const SizedBox(height: 20),
          // Tanggal Lahir
          GestureDetector(
            onTap: () async {
              final now = DateTime.now();
              final initial = (_tanggalLahirController.text.isNotEmpty)
                  ? DateTime.tryParse(_tanggalLahirController.text) ?? now
                  : now;
              final picked = await showDatePicker(
                context: context,
                initialDate: initial,
                firstDate: DateTime(1950),
                lastDate: DateTime(now.year + 1),
              );
              if (picked != null) {
                _tanggalLahirController.text = picked.toIso8601String().split('T').first;
                setState(() {});
              }
            },
            child: AbsorbPointer(
              child: _buildTextField(
                controller: _tanggalLahirController,
                label: 'Tanggal Lahir',
                icon: Icons.calendar_today,
              ),
            ),
          ),
          const SizedBox(height: 20),
          // Nama Rekening
          _buildTextField(
            controller: _namaRekeningController,
            label: 'Nama Rekening',
            icon: Icons.account_box,
          ),
          const SizedBox(height: 20),
          // Nomor Rekening
          _buildTextField(
            controller: _noRekeningController,
            label: 'Nomor Rekening',
            icon: Icons.numbers,
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: 20),
          // Pemilik Rekening
          _buildTextField(
            controller: _pemilikRekeningController,
            label: 'Pemilik Rekening',
            icon: Icons.person_pin_circle,
          ),
          const SizedBox(height: 20),
          // Team Field
          _buildTextField(
            controller: _teamController,
            label: 'Team (Opsional)',
            icon: Icons.group,
          ),
          const SizedBox(height: 20),
          // Password Fields
          _buildPasswordField(
            controller: _newPasswordController,
            label: 'Password Baru (Opsional)',
            icon: Icons.lock,
            hintText: 'Kosongkan jika tidak ingin ganti password',
          ),
          const SizedBox(height: 20),
          _buildPasswordField(
            controller: _confirmPasswordController,
            label: 'Konfirmasi Password Baru',
            icon: Icons.lock_outline,
            hintText: 'Kosongkan jika tidak ingin ganti password',
          ),
          const SizedBox(height: 24),
          // Avatar Color Picker
          _buildAvatarColorPicker(),
          const SizedBox(height: 32),
          // Action Buttons
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _isUpdating ? null : _cancelEdit,
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text('Batal'),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                flex: 2,
                child: ElevatedButton(
                  onPressed: _isUpdating ? null : _saveProfile,
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    elevation: 2,
                  ),
                  child: _isUpdating
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.save, size: 20),
                            SizedBox(width: 8),
                            Text('Simpan Perubahan'),
                          ],
                        ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    TextInputType? keyboardType,
    String? Function(String?)? validator,
  }) {
    return TextFormField(
      controller: controller,
      keyboardType: keyboardType,
      validator: validator,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon, color: Colors.blue[700]),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.grey[300]!),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.grey[300]!),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Theme.of(context).primaryColor, width: 2),
        ),
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      ),
    );
  }

  Widget _buildPasswordField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    String? hintText,
  }) {
    return TextFormField(
      controller: controller,
      obscureText: true,
      decoration: InputDecoration(
        labelText: label,
        hintText: hintText,
        prefixIcon: Icon(icon, color: Colors.blue[700]),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.grey[300]!),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.grey[300]!),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Theme.of(context).primaryColor, width: 2),
        ),
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      ),
    );
  }

  Widget _buildAvatarColorPicker() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.palette, size: 20, color: Colors.grey[700]),
            const SizedBox(width: 8),
            Text(
              'Warna Avatar',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: Colors.grey[700],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: _avatarColors.map((color) {
            final isSelected = _selectedAvatarColor == color;
            return GestureDetector(
              onTap: () {
                setState(() {
                  _selectedAvatarColor = color;
                });
              },
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: 0.0, end: isSelected ? 1.0 : 0.0),
                duration: const Duration(milliseconds: 200),
                builder: (context, value, child) {
                  return Transform.scale(
                    scale: 1.0 + (value * 0.1),
                    child: child,
                  );
                },
                child: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: _getColorFromHex(color),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: isSelected ? Colors.black : Colors.grey[300]!,
                      width: isSelected ? 3 : 2,
                    ),
                    boxShadow: isSelected
                        ? [
                            BoxShadow(
                              color: _getColorFromHex(color).withValues(alpha: 0.4),
                              blurRadius: 8,
                              spreadRadius: 2,
                            ),
                          ]
                        : null,
                  ),
                  child: isSelected
                      ? const Icon(Icons.check, color: Colors.white, size: 24)
                      : null,
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }

  Widget _buildLogoutButton() {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: const Duration(milliseconds: 500),
      builder: (context, value, child) {
        return Opacity(
          opacity: value,
          child: child,
        );
      },
      child: ElevatedButton.icon(
        onPressed: _handleLogout,
        icon: const Icon(Icons.logout),
        label: const Text('Logout'),
        style: ElevatedButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 16),
          backgroundColor: Colors.red,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          elevation: 2,
        ),
      ),
    );
  }

  Color _getColorFromHex(String hexColor) {
    final hexCode = hexColor.replaceAll('#', '');
    return Color(int.parse('FF$hexCode', radix: 16));
  }
}
