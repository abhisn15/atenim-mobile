import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/auth_provider.dart';
import 'otp_verification_screen.dart';

class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key});

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  bool _isLoading = false;

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  Future<void> _handleForgotPassword() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() {
      _isLoading = true;
    });

    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final result = await authProvider.requestPasswordReset(_emailController.text.trim());

    if (mounted) {
      setState(() {
        _isLoading = false;
      });

      if (result['success'] == true) {
        // ✅ Email/NIK terdaftar, lanjut ke halaman OTP
        // ✅ Gunakan email dari backend (jika input NIK, ini adalah email user yang terkait)
        final userEmail = result['email'] as String? ?? _emailController.text.trim();
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => OTPVerificationScreen(email: userEmail),
          ),
        );
      } else {
        // ✅ Email/NIK tidak terdaftar, tampilkan alert dialog
        final errorMessage = authProvider.error ?? 'Gagal mengirim OTP';
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (context) => AlertDialog(
            title: const Text(
              'Email atau NIK Tidak Terdaftar',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: Colors.red,
              ),
            ),
            content: Text(
              errorMessage.contains('tidak terdaftar') 
                ? errorMessage 
                : 'Email atau NIK tidak terdaftar. Silakan perhatikan lagi dan masukkan email/NIK yang benar dan sesuai.',
              style: const TextStyle(fontSize: 14),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.of(context).pop(); // Tutup dialog
                },
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Lupa Password'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 24),
                // Icon
                Center(
                  child: Icon(
                    Icons.lock_reset,
                    size: 80,
                    color: Theme.of(context).primaryColor,
                  ),
                ),
                const SizedBox(height: 24),
                // Title
                Center(
                  child: Text(
                    'Reset Password',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                ),
                const SizedBox(height: 16),
                // Description
                Text(
                  'Masukkan email atau NIK KTP Anda untuk menerima kode OTP verifikasi.',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Colors.grey[600],
                      ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 32),
                // Email Field
                TextFormField(
                  controller: _emailController,
                  keyboardType: TextInputType.text,
                  decoration: InputDecoration(
                    labelText: 'Email atau NIK KTP',
                    hintText: 'contoh: user@email.com atau 3172xxxxxxxxxxxx (16 digit)',
                    prefixIcon: const Icon(Icons.email_outlined),
                    border: const OutlineInputBorder(),
                    hintStyle: TextStyle(
                      fontSize: 14,
                      color: Colors.grey[500],
                    ),
                  ),
                  validator: (value) {
                    if (value == null || value.isEmpty) {
                      return 'Email atau NIK KTP wajib diisi';
                    }
                    // Validasi: harus email (mengandung @) atau NIK (minimal 10 digit angka)
                    final trimmedValue = value.trim();
                    final isEmail = trimmedValue.contains('@');
                    final isNIK = RegExp(r'^\d{10,}$').hasMatch(trimmedValue.replaceAll(RegExp(r'\D'), ''));

                    if (!isEmail && !isNIK) {
                      return 'Masukkan email yang valid atau NIK KTP (minimal 10 digit)';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 8),
                Text(
                  'Kami akan mengirim kode OTP ke email Anda untuk verifikasi.',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey[600],
                  ),
                ),
                const SizedBox(height: 32),
                // Send OTP Button
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _isLoading ? null : _handleForgotPassword,
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                    child: _isLoading
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text(
                            'Kirim Kode OTP',
                            style: TextStyle(fontSize: 16),
                          ),
                  ),
                ),
                const SizedBox(height: 16),
                // Back to Login
                Center(
                  child: TextButton(
                    onPressed: () {
                      Navigator.of(context).pop();
                    },
                    child: const Text('Kembali ke Login'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
