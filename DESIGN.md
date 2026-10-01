# Arah desain Atenim

Aplikasi HP **Atenim** (Atenim Workforce) untuk karyawan lapangan: cleaning service, security, dan
layanan lain. Dipakai untuk absen, aktivitas, izin, dan patroli. Kebanyakan dibuka sebentar, di
lapangan, sering dengan satu tangan dan sinyal lemah. Web admin/supervisor bernama MMS (terpisah).

## Keputusan pemilik (Abhi, 30 Sep 2026)

Arah yang dipilih: **"Tenang & fokus"**.

- **Satu aksi utama per layar.** Di Home, Check-In atau Check-Out adalah tombol terbesar dan ada
  di atas, sebelum informasi lain.
- **Status hari ini jelas**: sudah check-in atau belum, sedang bekerja, atau selesai.
- **Warna sedikit.** Biru Atenim untuk aksi dan identitas. Hijau, merah, dan kuning/oranye hanya
  untuk status (hadir, tidak hadir, terlambat), bukan hiasan.
- **Satu bahasa: Indonesia.** Istilah yang sudah umum di lapangan tetap dipakai apa adanya:
  "Check-in", "Check-out", "Scan", "Shift".
- **Absen dengan QR**: QR tampil di layar absen (tablet/HP di lokasi, misalnya lobi) dan berganti tiap 30 detik; karyawan
  scan dari aplikasi lewat tombol "Check-in dengan QR" / "Check-out dengan QR" di bawah tombol
  utama. Tombol ini hanya muncul bila site punya layar absen aktif.

## Catatan implementasi (bukan keputusan pemilik, boleh diubah)

Dipakai saat Home ditata ulang 30 Sep 2026:

- Biru Atenim: `Colors.blue[700]` (#1976D2), sama dengan header dan seed tema.
- Teks utama `Colors.grey[900]`, teks pendukung `Colors.grey[700]` (kontras cukup di atas putih).
- Latar halaman #F6F7F9; kartu putih, sudut 16, garis `Colors.grey[200]`, tanpa bayangan tebal.
- Tombol utama penuh lebar, sudut 12; tombol kedua bergaris biru, tinggi minimal 48.
- Rincian shift hanya tampil saat sedang bekerja atau bila shift lebih dari satu, supaya info
  shift tidak diulang.

## Belum diputuskan

- Huruf/font khusus merek.
- Logo, ikon aplikasi, dan ilustrasi baru.
- Mode gelap.
- Motif atau elemen identitas selain warna biru.
- Penataan ulang layar Request, Patroli, Slip Gaji, Pengaturan, dan Profil (yang lain sudah, lihat di bawah).

## Keputusan pemilik (Abhi, 1 Okt 2026): Absensi, Aktivitas, Laporan Kejadian, Team, dan gerak

Permintaan: perbagus tampilan layar Absensi, Aktivitas, Laporan Kejadian, dan Team, lebih halus dan
cantik dari sisi animasi, dengan arah "Tenang & fokus" tetap berlaku. Home mendapat dashboard yang lebih
informatif: **KPI kehadiran** bulan ini dan **timeline kegiatan hari ini** di bawahnya.

- **Gerak (MOTION 2)**: elemen masuk memudar sambil naik sedikit (320 ms, ease-out), sekali saat pertama
  tampil, bukan tiap data diperbarui; daftar bertahap maksimal 6 langkah x 45 ms; kartu yang bisa diketuk
  menyusut 100 ms saat ditekan; pindah layar memakai FadeForwards. Hanya opacity dan transform. Tidak ada
  gerak berulang kecuali kerangka pemuatan (berhenti saat data datang). Bila animasi dimatikan di sistem
  (`MediaQuery.disableAnimations`), semua langsung tampil di keadaan akhir. Kodenya di `lib/widgets/motion.dart`.
- **Komponen bersama** di `lib/widgets/ui_kit.dart`: `AtenimCard`, `StatusPill`, `SectionHeader`,
  `EmptyState`, `ErrorState`, `SkeletonBox`, `DateRangeBar`, `DateTile`. Layar baru memakai ini, bukan
  `Card` bawaan.
- **Warna status** memakai pasangan yang sudah diukur kontrasnya >= 4,5:1 (`toneColors`). Oranye bawaan
  `orange[900]` hanya 3,46:1, jadi peringatan memakai `#9A3412` (6,66:1).
- **Bahasa**: status tampil sebagai "Hadir", "Terlambat", "Tidak hadir", "Izin", "Sakit", "Remote",
  bukan nilai mentah server (`PRESENT`, `LATE`).
- **Keadaan kosong dan galat** menyebut sebabnya dan satu langkah berikutnya. Data yang sudah tampil tidak
  diganti kerangka saat ditarik untuk dimuat ulang.
- **Angka hanya yang nyata**: ringkasan dan KPI dihitung dari catatan yang dimuat, dan ditulis "-" bila
  belum ada bahan hitung. Persentase "Tepat waktu" = hari hadir tanpa terlambat dibagi hari hadir.
  Rata-rata jam masuk sengaja tidak ditampilkan karena shift malam merusak rata-ratanya.
- **Notifikasi dari admin**: isi HTML tidak boleh tampil sebagai tag. Server mengirim teks bersih + URL gambar
  terpisah; aplikasi menampilkan gambar di snackbar dan notifikasi sistem.
