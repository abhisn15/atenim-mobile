import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/activity_provider.dart';
import '../providers/checkpoint_provider.dart';
import '../providers/patrol_provider.dart';

/// Satu pekerjaan yang masih tertunda saat karyawan akan check-out.
class PendingWork {
  final IconData icon;
  final String title;
  final String detail;
  const PendingWork(this.icon, this.title, this.detail);
}

/// Menyegarkan data terkait (maks. 4 dtk; offline/lambat memakai data tersimpan), lalu mengumpulkan
/// pekerjaan yang belum selesai: aktivitas harian, checkpoint/todo, dan ronde patroli.
/// Tidak pernah melempar: bila gagal, daftar dihitung dari data yang ada.
Future<List<PendingWork>> collectPendingWork(BuildContext context) async {
  final activity = Provider.of<ActivityProvider>(context, listen: false);
  final checkpoint = Provider.of<CheckpointProvider>(context, listen: false);
  final patrol = Provider.of<PatrolProvider>(context, listen: false);

  try {
    await Future.wait<void>([
      activity.loadActivities(),
      checkpoint.loadCheckpoint(force: true),
      if (patrol.isQrEnabled) patrol.refresh(),
    ]).timeout(const Duration(seconds: 4));
  } catch (e) {
    debugPrint('[Checkout] penyegaran data sebelum check-out dilewati: $e');
  }

  final items = <PendingWork>[];

  // Aktivitas harian: hanya bila datanya sudah termuat (kalau belum, jangan menuduh).
  if (activity.activityData != null && activity.todayActivity == null) {
    items.add(const PendingWork(
      Icons.assignment_outlined,
      'Aktivitas harian belum dibuat',
      'Belum ada laporan aktivitas untuk hari ini.',
    ));
  }

  // Checkpoint / todo: tiap templat yang belum tuntas.
  if (checkpoint.hasCheckpoint) {
    for (final t in checkpoint.todoPreviews) {
      if (t.totalCount > 0 && t.completedCount < t.totalCount) {
        final next = t.pendingItems.isNotEmpty ? ' Berikutnya: ${t.pendingItems.first.name}.' : '';
        items.add(PendingWork(
          Icons.checklist_rtl_rounded,
          'Checkpoint belum selesai: ${t.templateName}',
          '${t.completedCount} dari ${t.totalCount} selesai.$next',
        ));
      }
    }
  }

  // Patroli: ronde yang sedang berjalan dan belum lengkap, serta scan yang belum terkirim.
  if (patrol.isQrEnabled) {
    final now = DateTime.now();
    for (final round in patrol.activeRounds(now)) {
      final (done, required) = patrol.countOf(round);
      if (required > 0 && done < required) {
        items.add(PendingWork(
          Icons.shield_outlined,
          'Ronde patroli belum lengkap',
          '$done dari $required titik wajib sudah dicek.',
        ));
      }
    }
    if (patrol.pendingCount > 0) {
      items.add(PendingWork(
        Icons.cloud_upload_outlined,
        'Scan patroli belum terkirim',
        '${patrol.pendingCount} scan masih tersimpan di HP dan belum sampai ke server.',
      ));
    }
  }
  return items;
}

/// Konfirmasi check-out bertingkat:
/// - tidak ada yang tertunda: satu konfirmasi biasa;
/// - ada yang tertunda: (1) daftar pekerjaan yang belum selesai, lalu (2) "Apakah Anda yakin?".
/// Mengembalikan true hanya bila karyawan memilih lanjut check-out. Check-out tidak pernah diblokir:
/// karyawan boleh tetap pulang, tetapi harus menyadari pekerjaannya dulu.
Future<bool> confirmCheckOut(BuildContext context) async {
  // Penyegaran data bisa sampai 4 dtk di jaringan lambat: tampilkan indikator hanya bila > 0,35 dtk.
  var loaderShown = false;
  final loaderTimer = Timer(const Duration(milliseconds: 350), () {
    if (!context.mounted) return;
    loaderShown = true;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const PopScope(canPop: false, child: Center(child: CircularProgressIndicator())),
    );
  });
  final pending = await collectPendingWork(context);
  loaderTimer.cancel();
  if (loaderShown && context.mounted) Navigator.of(context, rootNavigator: true).pop();
  if (!context.mounted) return false;

  if (pending.isEmpty) {
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Konfirmasi Check-out'),
        content: const Text('Apakah Anda yakin ingin melanjutkan check-out sekarang?'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Batal')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Ya, Lanjutkan')),
        ],
      ),
    );
    return ok ?? false;
  }

  // Konfirmasi 1: tampilkan pekerjaan yang belum selesai.
  final proceed = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.pending_actions_rounded, size: 32),
      title: const Text('Masih ada pekerjaan yang belum selesai'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final item in pending)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(item.icon, size: 22, color: Theme.of(ctx).colorScheme.primary),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(item.title, style: const TextStyle(fontWeight: FontWeight.w600)),
                            const SizedBox(height: 2),
                            Text(item.detail, style: Theme.of(ctx).textTheme.bodySmall),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Tetap check-out')),
        FilledButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Kembali & selesaikan')),
      ],
    ),
  );
  if (proceed != true || !context.mounted) return false;

  // Konfirmasi 2: "Apakah Anda yakin?"
  final sure = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      icon: Icon(Icons.warning_amber_rounded, size: 32, color: Theme.of(ctx).colorScheme.error),
      title: const Text('Apakah Anda yakin?'),
      content: Text(
        'Masih ada ${pending.length} pekerjaan yang belum selesai. '
        'Setelah check-out, hari kerja Anda tercatat selesai.',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Batal')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('Ya, check-out sekarang'),
        ),
      ],
    ),
  );
  return sure ?? false;
}
