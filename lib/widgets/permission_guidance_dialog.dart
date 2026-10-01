import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

class PermissionGuidanceDialog extends StatelessWidget {
  final String title;
  final String message;
  final String? settingsButtonText;
  final String? cancelButtonText;

  const PermissionGuidanceDialog({
    Key? key,
    this.title = 'Izin Lokasi Diperlukan',
    required this.message,
    this.settingsButtonText = 'Buka Pengaturan',
    this.cancelButtonText = 'Nanti',
  }) : super(key: key);

  static Future<void> show(
    BuildContext context, {
    String title = 'Izin Lokasi Diperlukan',
    required String message,
    String? settingsButtonText = 'Buka Pengaturan',
    String? cancelButtonText = 'Nanti',
  }) {
    return showDialog(
      context: context,
      barrierDismissible: false, // User must choose
      builder: (context) => PermissionGuidanceDialog(
        title: title,
        message: message,
        settingsButtonText: settingsButtonText,
        cancelButtonText: cancelButtonText,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.location_on, color: Theme.of(context).primaryColor),
          SizedBox(width: 8),
          Expanded(child: Text(title)),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              message,
              style: TextStyle(fontSize: 14, height: 1.5),
            ),
            SizedBox(height: 16),
            Container(
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.blue.shade200),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '📍 Langkah-langkah:',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                      color: Colors.blue.shade800,
                    ),
                  ),
                  SizedBox(height: 8),
                  Text(
                    '1. Buka Pengaturan → Aplikasi → Atenim\n'
                    '2. Pilih "Izin" → "Lokasi"\n'
                    '3. Pilih "Izinkan sepanjang waktu"\n'
                    '4. Kembali ke aplikasi dan coba lagi',
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.4,
                      color: Colors.blue.shade700,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(
            cancelButtonText!,
            style: TextStyle(color: Colors.grey.shade600),
          ),
        ),
        ElevatedButton(
          onPressed: () async {
            Navigator.of(context).pop(); // Close dialog first

            try {
              await openAppSettings();
            } catch (e) {
              // If openAppSettings fails, show manual instructions
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Tidak dapat membuka pengaturan otomatis. Buka pengaturan secara manual.'),
                  duration: Duration(seconds: 5),
                ),
              );
            }
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: Theme.of(context).primaryColor,
            foregroundColor: Colors.white,
          ),
          child: Text(settingsButtonText!),
        ),
      ],
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
    );
  }
}
