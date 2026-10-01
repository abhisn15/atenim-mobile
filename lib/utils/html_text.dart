import '../config/api_config.dart';

/// Isi notifikasi dari admin berupa HTML (<p>, <img src=...>). Notifikasi sistem dan snackbar tidak
/// merender HTML, jadi tag harus dibuang dan gambar diambil terpisah.

final RegExp _tagPattern = RegExp(r'<[^>]*>');
final RegExp _blockClose = RegExp(r'</(p|div|li|h[1-6]|tr)>|<br\s*/?>', caseSensitive: false);
final RegExp _entityPattern = RegExp(r'&(#x[0-9a-fA-F]+|#\d+|[a-zA-Z]+);');
final RegExp _imgSrcPattern = RegExp(
  r'''<img\b[^>]*?\bsrc\s*=\s*["']([^"']+)["']''',
  caseSensitive: false,
);

const Map<String, String> _namedEntities = {
  'nbsp': ' ',
  'amp': '&',
  'lt': '<',
  'gt': '>',
  'quot': '"',
  'apos': "'",
};

String _decodeEntities(String text) {
  return text.replaceAllMapped(_entityPattern, (match) {
    final code = match.group(1)!;
    if (code.startsWith('#')) {
      final isHex = code.length > 1 && (code[1] == 'x' || code[1] == 'X');
      final value = int.tryParse(isHex ? code.substring(2) : code.substring(1), radix: isHex ? 16 : 10);
      if (value == null || value <= 0 || value > 0x10FFFF) return match.group(0)!;
      return String.fromCharCode(value);
    }
    return _namedEntities[code.toLowerCase()] ?? match.group(0)!;
  });
}

/// Teks polos dari HTML: tag dibuang, spasi dirapikan. Isi yang sudah teks biasa tidak berubah.
String htmlToPlainText(String html) {
  final withoutBlocks = html.replaceAll(_blockClose, ' ');
  final withoutTags = withoutBlocks.replaceAll(_tagPattern, '');
  return _decodeEntities(withoutTags).replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// Alamat gambar pertama di HTML, sudah dilengkapi alamat server bila relatif. Null bila tidak ada.
String? firstHtmlImageUrl(String html) {
  final match = _imgSrcPattern.firstMatch(html);
  if (match == null) return null;
  final src = _decodeEntities(match.group(1)!).trim();
  if (src.isEmpty) return null;
  final resolved = ApiConfig.getImageUrl(src);
  return resolved.startsWith('http') ? resolved : null;
}

/// True bila HTML memuat tag gambar (dipakai untuk teks pengganti saat isi hanya gambar).
bool htmlHasImage(String html) => _imgSrcPattern.hasMatch(html) || html.toLowerCase().contains('<img');
