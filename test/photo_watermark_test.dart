import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:fms_mobile/utils/photo_watermark.dart';
import 'package:image/image.dart' as img;

/// Foto sintetis mirip hasil kamera: gradien dengan sedikit derau (derau membuat kompresi realistis, bukan terlalu mudah).
File _fotoUji(Directory dir, int w, int h) {
  final rnd = math.Random(7);
  final image = img.Image(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final n = rnd.nextInt(18);
      image.setPixelRgb(x, y, (x * 255 ~/ w + n).clamp(0, 255), (y * 255 ~/ h + n).clamp(0, 255), (128 + n).clamp(0, 255));
    }
  }
  final f = File('${dir.path}/uji_${w}x$h.jpg');
  f.writeAsBytesSync(img.encodeJpg(image, quality: 90));
  return f;
}

void main() {
  testWidgets('stempel menghasilkan JPEG kecil dengan dimensi asli dipertahankan', (tester) async {
    final dir = Directory.systemTemp.createTempSync('stempel_uji');
    addTearDown(() => dir.deleteSync(recursive: true));
    await tester.runAsync(() async {
      final sumber = _fotoUji(dir, 480, 640);
      final hasil = await PhotoWatermark.stamp(sumber, [
        'TPM-01 · RUANGAN IT',
        '02 Okt 2026 13:01:54 WIB',
        '-6.263124, 106.798833 (±14 m)',
        'Petugas: Uji Karyawan A',
        'TANPA SCAN QR',
      ]);
      expect(hasil.path.endsWith('_wm.jpg'), isTrue, reason: 'harus JPEG, bukan PNG');
      expect(sumber.existsSync(), isFalse, reason: 'berkas asli tanpa stempel harus dihapus');
      final bytes = hasil.readAsBytesSync();
      final dekode = img.decodeJpg(bytes)!;
      expect(dekode.width, 480);
      expect(dekode.height, 640);
      // ignore: avoid_print
      print('ukuran hasil bertanda: ${(bytes.length / 1024).round()} KB');
      expect(bytes.length, lessThan(300 * 1024));
    });
  });

  testWidgets('foto lebih besar dari maxSide diperkecil, tanpa lines tidak diubah', (tester) async {
    final dir = Directory.systemTemp.createTempSync('stempel_uji2');
    addTearDown(() => dir.deleteSync(recursive: true));
    await tester.runAsync(() async {
      final besar = _fotoUji(dir, 2000, 1500);
      final hasil = await PhotoWatermark.stamp(besar, ['TPM-01'], maxSide: 1280);
      final dekode = img.decodeJpg(hasil.readAsBytesSync())!;
      expect(math.max(dekode.width, dekode.height), 1280);

      final kecil = _fotoUji(dir, 100, 100);
      final sama = await PhotoWatermark.stamp(kecil, const []);
      expect(sama.path, kecil.path, reason: 'tanpa baris stempel, berkas dikembalikan apa adanya');
    });
  });
}
