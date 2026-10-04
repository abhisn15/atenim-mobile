import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// Nomor HP ke bentuk internasional tanpa "+" (mis. 6281234567890), atau null bila bukan nomor yang masuk akal.
/// Menerima "0812-3456-7890", "+62 812 3456 7890", "62812...", dan "812..." (ditulis tanpa 0). Data HRIS sering
/// berisi "-" atau teks kosong untuk nomor yang belum diisi; itu menghasilkan null.
String? normalizeIndonesianPhone(String? raw) {
  if (raw == null) return null;
  final cleaned = raw.replaceAll(RegExp(r'[^0-9+]'), '');
  final hasPlus = cleaned.startsWith('+');
  final digits = cleaned.replaceAll('+', '');
  if (digits.isEmpty) return null;

  final String international;
  if (digits.startsWith('62')) {
    international = digits;
  } else if (digits.startsWith('0')) {
    international = '62${digits.substring(1)}';
  } else if (digits.startsWith('8')) {
    international = '62$digits';
  } else if (hasPlus) {
    international = digits; // nomor luar negeri yang ditulis lengkap dengan "+"
  } else {
    return null;
  }
  // E.164 paling panjang 15 digit; nomor seluler Indonesia dengan kode negara paling pendek sekitar 10 digit
  if (international.length < 10 || international.length > 15) return null;
  return international;
}

Uri? whatsappUri(String? phone, {String? message}) {
  final number = normalizeIndonesianPhone(phone);
  if (number == null) return null;
  final text = (message ?? '').trim();
  // Spasi ditulis %20 (bukan "+" seperti Uri.https): begitu contoh resmi tautan WhatsApp, aman di semua versi aplikasinya
  return Uri.parse(text.isEmpty ? 'https://wa.me/$number' : 'https://wa.me/$number?text=${Uri.encodeComponent(text)}');
}

Uri? telUri(String? phone) {
  final number = normalizeIndonesianPhone(phone);
  if (number == null) return null;
  return Uri(scheme: 'tel', path: '+$number');
}

/// Alasan leader menghubungi anggota; menentukan kalimat pembuka di WhatsApp.
enum ContactReason { notCheckedIn, late, outside, general }

/// Pesan awal WhatsApp yang sopan dan netral: bertanya, bukan menuduh. Leader tetap bisa mengubahnya sebelum dikirim.
String contactMessage({required String memberName, required String leaderName, ContactReason reason = ContactReason.general}) {
  final first = memberName.trim().split(RegExp(r'\s+')).first;
  final greeting = first.isEmpty ? 'Halo' : 'Halo $first';
  final from = leaderName.trim().isEmpty ? '' : ', saya ${leaderName.trim()}';
  switch (reason) {
    case ContactReason.notCheckedIn:
      return '$greeting$from. Hari ini kamu belum tercatat check-in. Ada kendala?';
    case ContactReason.late:
      return '$greeting$from. Hari ini kamu tercatat terlambat check-in. Ada kendala?';
    case ContactReason.outside:
      return '$greeting$from. Sistem mencatat kamu berada di luar area site saat jam kerja. Ada kendala?';
    case ContactReason.general:
      return '$greeting$from. ';
  }
}

Future<void> _open(BuildContext context, Uri? uri, String failedMessage) async {
  final messenger = ScaffoldMessenger.of(context);
  void failed() => messenger.showSnackBar(SnackBar(content: Text(failedMessage), behavior: SnackBarBehavior.floating));
  if (uri == null) {
    failed();
    return;
  }
  try {
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok) failed();
  } catch (_) {
    failed();
  }
}

Future<void> openWhatsApp(BuildContext context, {required String? phone, String? message}) =>
    _open(context, whatsappUri(phone, message: message), 'WhatsApp tidak bisa dibuka. Cek nomor HP anggota.');

Future<void> callPhone(BuildContext context, {required String? phone}) =>
    _open(context, telUri(phone), 'Panggilan tidak bisa dimulai. Cek nomor HP anggota.');
