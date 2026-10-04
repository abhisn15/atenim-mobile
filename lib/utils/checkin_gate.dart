import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/attendance_model.dart';
import '../providers/attendance_provider.dart';
import '../providers/auth_provider.dart';

/// Untuk apa karyawan perlu sudah check-in.
enum CheckInPurpose { activity, patrol }

class CheckInGate {
  const CheckInGate({required this.allowed, this.title = '', this.message = ''});

  final bool allowed;
  final String title;
  final String message;
}

const _presentStatuses = {'present', 'late', 'remote'};
const _blockedByServerStatuses = {'leave', 'sick', 'absent'};

/// Aturan penahan di depan (server tetap penjaga terakhir):
/// - aktivitas: harus sudah check-in hari ini (sudah pulang pun boleh, supaya laporan setelah pulang tidak terhalang);
///   absen yang masih terbuka dari kemarin (shift malam) ikut dihitung karena server membawanya ke "hari ini";
/// - patroli: harus sedang check-in, karena patroli hanya dihitung selama bertugas.
/// Data absen yang belum termuat tidak menahan siapa pun, dan status cuti/sakit/absen diserahkan ke pesan server.
/// Akun supervisor dibebaskan ([isSupervisor]): akun itu khusus mengawasi, absennya lewat akun karyawan.
CheckInGate evaluateCheckInGate({
  required bool loaded,
  required List<AttendanceRecord> todayRecords,
  required CheckInPurpose purpose,
  bool isSupervisor = false,
}) {
  if (isSupervisor || !loaded) return const CheckInGate(allowed: true);
  if (todayRecords.any((r) => _blockedByServerStatuses.contains(r.status.toLowerCase()))) {
    return const CheckInGate(allowed: true);
  }
  switch (purpose) {
    case CheckInPurpose.activity:
      final ok = todayRecords.any((r) => r.checkIn != null || _presentStatuses.contains(r.status.toLowerCase()));
      if (ok) return const CheckInGate(allowed: true);
      return const CheckInGate(
        allowed: false,
        title: 'Check-in dulu',
        message: 'Aktivitas hanya bisa dibuat setelah Anda check-in. Buka tab Home dan tekan Check-In, lalu buat aktivitasnya.',
      );
    case CheckInPurpose.patrol:
      final ok = todayRecords.any((r) => r.checkIn != null && r.checkOut == null);
      if (ok) return const CheckInGate(allowed: true);
      return const CheckInGate(
        allowed: false,
        title: 'Check-in dulu',
        message: 'Patroli hanya dihitung saat Anda sedang check-in. Buka beranda dan tekan Check-In, lalu mulai patroli.',
      );
  }
}

/// True bila boleh lanjut. Bila belum check-in, menampilkan penjelasan singkat dan mengembalikan false.
/// [onGoHome] dipakai layar yang dibuka di atas beranda (mis. Patroli) untuk menyediakan tombol langsung ke beranda.
bool ensureCheckedIn(BuildContext context, CheckInPurpose purpose, {VoidCallback? onGoHome}) {
  final attendance = context.read<AttendanceProvider>();
  final gate = evaluateCheckInGate(
    loaded: attendance.attendanceData != null,
    todayRecords: attendance.todayRecords,
    purpose: purpose,
    isSupervisor: context.read<AuthProvider>().user?.role == 'supervisor',
  );
  if (gate.allowed) return true;
  showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      icon: const Icon(Icons.login, size: 32),
      title: Text(gate.title),
      content: Text(gate.message),
      actions: [
        TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Mengerti')),
        if (onGoHome != null)
          FilledButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              onGoHome();
            },
            child: const Text('Ke beranda'),
          ),
      ],
    ),
  );
  return false;
}
