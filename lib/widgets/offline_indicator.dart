import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../providers/connectivity_provider.dart';

/// Pita peringatan saat HP tanpa koneksi. Muncul/hilang 200 ms (tinggi + opacity), tanpa gerak bila
/// pengguna mematikan animasi. Latar oranye tua #9A3412 dengan teks putih (7,9:1; oranye bawaan hanya 2,2:1).
/// Berada di bawah status bar (SafeArea) dan membuat ikon status bar terang selama tampil.
class OfflineIndicator extends StatelessWidget {
  const OfflineIndicator({super.key});

  static const Color _bg = Color(0xFF9A3412);

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.of(context).disableAnimations;
    return Consumer<ConnectivityProvider>(
      builder: (context, connectivityProvider, _) {
        final offline = !connectivityProvider.isConnected;
        return AnimatedSize(
          duration: reduceMotion ? Duration.zero : const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: AnimatedSwitcher(
            duration: reduceMotion ? Duration.zero : const Duration(milliseconds: 200),
            child: offline
                ? const _OfflineBanner(key: ValueKey('offline'))
                : const SizedBox(key: ValueKey('online'), width: double.infinity),
          ),
        );
      },
    );
  }
}

class _OfflineBanner extends StatelessWidget {
  const _OfflineBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Semantics(
        liveRegion: true,
        container: true,
        label: 'Tidak ada koneksi internet. Menampilkan data terakhir yang tersimpan.',
        child: Material(
          color: OfflineIndicator._bg,
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  Padding(
                    padding: EdgeInsets.only(top: 1),
                    child: Icon(Icons.wifi_off, color: Colors.white, size: 20),
                  ),
                  SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Tidak ada koneksi',
                          style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w700),
                        ),
                        SizedBox(height: 2),
                        Text(
                          'Yang tampil adalah data terakhir tersimpan. Absen, aktivitas, dan patroli disimpan di HP lalu dikirim otomatis saat sinyal kembali.',
                          style: TextStyle(color: Colors.white, fontSize: 12, height: 1.3),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
