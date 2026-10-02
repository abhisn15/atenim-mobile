import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:image/image.dart' as img;

/// Stempel yang dibakar ke piksel foto saat dipotret: titik, jam, koordinat GPS, dan nama petugas.
///
/// Dibakar di HP (bukan di server) supaya tetap ada pada foto antrean offline dan tidak bisa dilepas dengan
/// memotong metadata. Stempel ini tidak membuktikan apa pun sendirian (aplikasi yang dimodifikasi bisa
/// memalsukannya); bukti yang dipercaya tetap data server (jam terima, lokasi tercatat, bendera tinjauan)
/// yang ditampilkan di samping foto di web.
class PhotoWatermark {
  PhotoWatermark._();

  static const List<String> _bulan = [
    'Jan', 'Feb', 'Mar', 'Apr', 'Mei', 'Jun', 'Jul', 'Agu', 'Sep', 'Okt', 'Nov', 'Des',
  ];

  static String _dua(int n) => n.toString().padLeft(2, '0');

  /// "02 Okt 2026 03:48:12 WIB"
  static String formatMoment(DateTime moment) {
    final local = moment.toLocal();
    final zone = local.timeZoneName;
    return '${_dua(local.day)} ${_bulan[local.month - 1]} ${local.year} '
        '${_dua(local.hour)}:${_dua(local.minute)}:${_dua(local.second)}'
        '${zone.isEmpty ? '' : ' $zone'}';
  }

  /// "-6.263124, 106.805000 (±12 m)" atau penjelasan bila GPS tidak ada.
  static String formatLocation({double? latitude, double? longitude, double? accuracy, bool mocked = false}) {
    if (latitude == null || longitude == null) return 'Lokasi GPS tidak tersedia';
    final acc = accuracy == null ? '' : ' (±${accuracy.round()} m)';
    return '${latitude.toStringAsFixed(6)}, ${longitude.toStringAsFixed(6)}$acc${mocked ? ' · LOKASI PALSU' : ''}';
  }

  /// Menulis [lines] di pita gelap pada tepi bawah foto dan menyimpannya sebagai berkas baru (PNG),
  /// lalu menghapus berkas asli supaya tidak ada salinan tanpa stempel. Bila gagal di langkah mana pun,
  /// foto asli dikembalikan apa adanya: foto tanpa stempel lebih baik daripada foto hilang.
  static Future<File> stamp(File source, List<String> lines, {int maxSide = 1280, int jpegQuality = 82}) async {
    final visible = lines.where((l) => l.trim().isNotEmpty).toList();
    if (visible.isEmpty) return source;
    ui.Image? decoded;
    ui.Image? result;
    try {
      final bytes = await source.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      decoded = frame.image;
      codec.dispose();

      final scale = math.min(1.0, maxSide / math.max(decoded.width, decoded.height));
      final outW = (decoded.width * scale).round();
      final outH = (decoded.height * scale).round();

      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder, ui.Rect.fromLTWH(0, 0, outW.toDouble(), outH.toDouble()));
      canvas.drawImageRect(
        decoded,
        ui.Rect.fromLTWH(0, 0, decoded.width.toDouble(), decoded.height.toDouble()),
        ui.Rect.fromLTWH(0, 0, outW.toDouble(), outH.toDouble()),
        ui.Paint()..filterQuality = ui.FilterQuality.medium,
      );

      final fontSize = math.max(13.0, outW * 0.03);
      final pad = fontSize * 0.6;
      final painters = <TextPainter>[];
      for (var i = 0; i < visible.length; i++) {
        final painter = TextPainter(
          text: TextSpan(
            text: visible[i],
            style: TextStyle(
              color: const Color(0xFFFFFFFF),
              fontSize: i == 0 ? fontSize * 1.1 : fontSize,
              fontWeight: i == 0 ? FontWeight.w700 : FontWeight.w500,
              height: 1.2,
            ),
          ),
          textDirection: TextDirection.ltr,
          maxLines: 2,
          ellipsis: '…',
        )..layout(maxWidth: outW - pad * 2);
        painters.add(painter);
      }
      final textHeight = painters.fold<double>(0, (sum, p) => sum + p.height);
      final barHeight = textHeight + pad * 2;
      canvas.drawRect(
        ui.Rect.fromLTWH(0, outH - barHeight, outW.toDouble(), barHeight),
        ui.Paint()..color = const Color(0xB3000000),
      );
      var y = outH - barHeight + pad;
      for (final painter in painters) {
        painter.paint(canvas, ui.Offset(pad, y));
        y += painter.height;
      }

      final picture = recorder.endRecording();
      result = await picture.toImage(outW, outH);
      picture.dispose();
      final dot = source.path.lastIndexOf('.');
      final base = dot > 0 ? source.path.substring(0, dot) : source.path;

      // JPEG (puluhan KB) alih-alih PNG (ratusan KB): foto patroli diunggah lewat kuota seluler petugas.
      // Encode di isolate terpisah supaya layar tidak tersendat di HP kelas bawah. PNG hanya cadangan.
      File target;
      Uint8List? jpeg;
      try {
        final raw = await result.toByteData(format: ui.ImageByteFormat.rawRgba);
        if (raw != null) {
          jpeg = await compute(
            _encodeJpeg,
            _RawFrame(raw.buffer.asUint8List(raw.offsetInBytes, raw.lengthInBytes), outW, outH, jpegQuality),
          );
        }
      } catch (e) {
        debugPrint('[PhotoWatermark] encode JPEG gagal, pakai PNG: $e');
      }
      if (jpeg != null && jpeg.isNotEmpty) {
        target = File('${base}_wm.jpg');
        await target.writeAsBytes(jpeg, flush: true);
      } else {
        final png = await result.toByteData(format: ui.ImageByteFormat.png);
        if (png == null) return source;
        target = File('${base}_wm.png');
        await target.writeAsBytes(png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes), flush: true);
      }
      if (target.path != source.path) {
        try {
          await source.delete();
        } catch (_) {
          // berkas asli tidak bisa dihapus: tidak fatal, berkas bertempel yang dipakai
        }
      }
      return target;
    } catch (e) {
      debugPrint('[PhotoWatermark] gagal menempel stempel, pakai foto asli: $e');
      return source;
    } finally {
      decoded?.dispose();
      result?.dispose();
    }
  }
}

/// Bingkai piksel mentah (RGBA) yang dikirim ke isolate untuk di-encode.
class _RawFrame {
  const _RawFrame(this.rgba, this.width, this.height, this.quality);
  final Uint8List rgba;
  final int width;
  final int height;
  final int quality;
}

Uint8List _encodeJpeg(_RawFrame frame) {
  final image = img.Image.fromBytes(
    width: frame.width,
    height: frame.height,
    bytes: frame.rgba.buffer,
    bytesOffset: frame.rgba.offsetInBytes,
    numChannels: 4,
    order: img.ChannelOrder.rgba,
  );
  return Uint8List.fromList(img.encodeJpg(image, quality: frame.quality));
}
