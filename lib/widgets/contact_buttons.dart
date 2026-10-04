import 'package:flutter/material.dart';

import '../utils/phone_contact.dart';

/// Tombol telepon dan WhatsApp untuk menghubungi anggota. Tidak menampilkan apa pun bila nomornya belum diisi
/// atau tidak valid, supaya tidak ada tombol yang pasti gagal.
class ContactButtons extends StatelessWidget {
  const ContactButtons({
    super.key,
    required this.phone,
    required this.memberName,
    required this.leaderName,
    this.reason = ContactReason.general,
  });

  final String? phone;
  final String memberName;
  final String leaderName;
  final ContactReason reason;

  @override
  Widget build(BuildContext context) {
    if (normalizeIndonesianPhone(phone) == null) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: 'Telepon $memberName',
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          icon: const Icon(Icons.call_outlined),
          onPressed: () => callPhone(context, phone: phone),
        ),
        IconButton(
          tooltip: 'WhatsApp $memberName',
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          icon: const Icon(Icons.chat_outlined),
          onPressed: () => openWhatsApp(
            context,
            phone: phone,
            message: contactMessage(memberName: memberName, leaderName: leaderName, reason: reason),
          ),
        ),
      ],
    );
  }
}
