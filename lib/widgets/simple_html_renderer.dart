import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../config/api_config.dart';

/// Lightweight HTML renderer for notification body.
/// Supports: <b>, <strong>, <i>, <em>, <br>, <p>, <h3>, <ul>/<ol>/<li>,
///           <img src>, <a href>, <hr>
class SimpleHtmlRenderer extends StatelessWidget {
  final String html;
  final TextStyle? baseStyle;
  final double? maxImageHeight;

  const SimpleHtmlRenderer({
    super.key,
    required this.html,
    this.baseStyle,
    this.maxImageHeight = 250,
  });

  @override
  Widget build(BuildContext context) {
    final style = baseStyle ??
        const TextStyle(
          fontSize: 14,
          color: Color(0xFF334155),
          height: 1.6,
        );

    final widgets = _parseHtml(html, style, context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: widgets,
    );
  }

  List<Widget> _parseHtml(
      String rawHtml, TextStyle style, BuildContext context) {
    final List<Widget> result = [];
    final cleaned = rawHtml
        .replaceAll(RegExp(r'<br\s*/?>'), '\n')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>');

    final blockRegex = RegExp(
      r'<img[^>]+src="([^"]+)"[^>]*>|<hr\s*/?>',
      caseSensitive: false,
    );

    int cursor = 0;
    for (final match in blockRegex.allMatches(cleaned)) {
      if (match.start > cursor) {
        _appendTextAsWidget(
          result,
          cleaned.substring(cursor, match.start).trim(),
          style,
        );
      }

      final token = match.group(0) ?? '';
      final imageUrl = match.group(1);
      if (imageUrl != null && imageUrl.isNotEmpty) {
        result.add(_buildImage(imageUrl));
      } else if (RegExp(r'<hr\s*/?>', caseSensitive: false).hasMatch(token)) {
        result.add(
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Divider(color: Colors.grey[300], height: 1),
          ),
        );
      }

      cursor = match.end;
    }

    if (cursor < cleaned.length) {
      _appendTextAsWidget(result, cleaned.substring(cursor).trim(), style);
    }

    return result;
  }

  void _appendTextAsWidget(
    List<Widget> result,
    String text,
    TextStyle style,
  ) {
    if (text.isEmpty) return;

    // Admin kadang kirim URL gambar langsung di textarea (tanpa <img> tag).
    final directImageUrl = _extractDirectImageUrl(text);
    if (directImageUrl != null) {
      result.add(_buildImage(directImageUrl));
      return;
    }

    final spans = _parseInlineHtml(text, style);
    if (spans.isNotEmpty) {
      result.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: RichText(text: TextSpan(children: spans)),
        ),
      );
    }
  }

  String? _extractDirectImageUrl(String text) {
    final trimmed = text.trim();
    final singleUrl = RegExp(r'^https?://\S+$', caseSensitive: false);
    if (!singleUrl.hasMatch(trimmed)) return null;

    final likelyImage = RegExp(
      r'\.(png|jpe?g|gif|webp|bmp|heic|heif)(\?.*)?$',
      caseSensitive: false,
    );

    // Render as image when URL clearly points to image,
    // or when it's a single direct URL (common backend image links).
    if (likelyImage.hasMatch(trimmed) || !trimmed.contains(' ')) {
      return trimmed;
    }
    return null;
  }

  Widget _buildImage(String url) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: CachedNetworkImage(
          // Gambar dari penyimpanan lokal server berupa alamat relatif (/uploads/...); jadikan alamat lengkap.
          imageUrl: ApiConfig.getImageUrl(url),
          maxHeightDiskCache: 500,
          fit: BoxFit.cover,
          width: double.infinity,
          placeholder: (_, __) => Container(
            height: 120,
            color: Colors.grey[200],
            child: const Center(
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
          errorWidget: (_, __, ___) => Container(
            height: 80,
            color: Colors.grey[100],
            child: Center(
              child: Icon(Icons.broken_image, color: Colors.grey[400], size: 32),
            ),
          ),
        ),
      ),
    );
  }

  List<InlineSpan> _parseInlineHtml(String text, TextStyle baseStyle) {
    final List<InlineSpan> spans = [];

    // Strip block tags, keep inline
    var cleaned = text
        .replaceAll(RegExp(r'</?p[^>]*>'), '\n')
        .replaceAll(RegExp(r'</?div[^>]*>'), '\n')
        .replaceAll(RegExp(r'</?h[1-6][^>]*>'), '\n')
        .replaceAll(RegExp(r'</?ul[^>]*>'), '\n')
        .replaceAll(RegExp(r'</?ol[^>]*>'), '\n')
        .replaceAll(RegExp(r'<li[^>]*>'), '• ')
        .replaceAll(RegExp(r'</li>'), '\n')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();

    // Process inline tags
    final tagRegex = RegExp(
      r'<(b|strong|i|em|a)([^>]*)>(.*?)</\1>',
      caseSensitive: false,
      dotAll: true,
    );

    int lastEnd = 0;
    for (final match in tagRegex.allMatches(cleaned)) {
      if (match.start > lastEnd) {
        final before = cleaned.substring(lastEnd, match.start);
        if (before.isNotEmpty) {
          spans.add(TextSpan(text: before, style: baseStyle));
        }
      }

      final tag = match.group(1)!.toLowerCase();
      final attrs = match.group(2) ?? '';
      final content = match.group(3) ?? '';

      if (tag == 'b' || tag == 'strong') {
        spans.add(TextSpan(
          text: _stripTags(content),
          style: baseStyle.copyWith(fontWeight: FontWeight.bold),
        ));
      } else if (tag == 'i' || tag == 'em') {
        spans.add(TextSpan(
          text: _stripTags(content),
          style: baseStyle.copyWith(fontStyle: FontStyle.italic),
        ));
      } else if (tag == 'a') {
        final hrefMatch = RegExp(r'href="([^"]+)"').firstMatch(attrs);
        final href = hrefMatch?.group(1);
        spans.add(TextSpan(
          text: _stripTags(content),
          style: baseStyle.copyWith(
            color: Colors.blue,
            decoration: TextDecoration.underline,
          ),
          recognizer: href != null
              ? (TapGestureRecognizer()
                ..onTap = () {
                  try {
                    launchUrl(Uri.parse(href),
                        mode: LaunchMode.externalApplication);
                  } catch (_) {}
                })
              : null,
        ));
      }

      lastEnd = match.end;
    }

    if (lastEnd < cleaned.length) {
      final remaining = cleaned.substring(lastEnd);
      if (remaining.trim().isNotEmpty) {
        spans.add(TextSpan(text: remaining, style: baseStyle));
      }
    }

    if (spans.isEmpty && cleaned.isNotEmpty) {
      spans.add(TextSpan(text: cleaned, style: baseStyle));
    }

    return spans;
  }

  String _stripTags(String text) {
    return text.replaceAll(RegExp(r'<[^>]+>'), '');
  }
}
