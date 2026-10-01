import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/auth_provider.dart';
import '../../providers/patrol_provider.dart';
import 'patroli_list_screen.dart';
import 'patrol_qr_home_screen.dart';

/// Menu Patroli: site dengan Patroli QR memakai ronde + scan stiker; site lain tetap laporan patroli bebas.
class PatroliScreen extends StatefulWidget {
  const PatroliScreen({super.key});

  @override
  State<PatroliScreen> createState() => _PatroliScreenState();
}

class _PatroliScreenState extends State<PatroliScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final userId = context.read<AuthProvider>().user?.id;
      if (userId != null) context.read<PatrolProvider>().ensureUser(userId);
    });
  }

  @override
  Widget build(BuildContext context) {
    final siteUsesQr = context.select<AuthProvider, bool>((a) => a.user?.site?.hasFeature('patrolQr') ?? false);
    return Consumer<PatrolProvider>(
      builder: (context, patrol, _) {
        if (patrol.isQrEnabled) return const PatrolQrHomeScreen();
        final firstLoad = patrol.pack == null && (patrol.initializing || patrol.loadingPack);
        if (firstLoad && siteUsesQr) {
          return Scaffold(
            appBar: AppBar(title: const Text('Patroli')),
            body: const Center(child: CircularProgressIndicator()),
          );
        }
        // Site Patroli QR, tetapi paket belum pernah terunduh dan sekarang tanpa sinyal
        if (siteUsesQr && patrol.pack == null && patrol.packError != null) {
          return Scaffold(
            appBar: AppBar(title: const Text('Patroli')),
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.cloud_off, size: 56, color: Colors.grey[600]),
                    const SizedBox(height: 12),
                    const Text(
                      'Paket patroli belum terunduh. Sambungkan internet sekali untuk mengunduhnya; '
                      'setelah itu patroli bisa berjalan tanpa sinyal.',
                      textAlign: TextAlign.center,
                      style: TextStyle(height: 1.4),
                    ),
                    const SizedBox(height: 8),
                    Text(patrol.packError!, textAlign: TextAlign.center, style: TextStyle(color: Colors.grey[700], fontSize: 13)),
                    const SizedBox(height: 16),
                    FilledButton(onPressed: patrol.refresh, child: const Text('Coba lagi')),
                  ],
                ),
              ),
            ),
          );
        }
        return const PatroliListScreen();
      },
    );
  }
}
