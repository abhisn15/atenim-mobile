import 'package:flutter/material.dart';
import 'package:in_app_review/in_app_review.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _kRatingShownKey = 'app_rating_shown';
const _kCheckoutCountKey = 'app_checkout_count';

class AppRatingDialog {
  /// Panggil setelah checkout berhasil.
  /// Hanya tampil SEKALI (checkout pertama yang sukses).
  static Future<void> maybeShowAfterCheckout(BuildContext context) async {
    try {
      final prefs = await SharedPreferences.getInstance();

      final alreadyShown = prefs.getBool(_kRatingShownKey) ?? false;
      if (alreadyShown) return;

      final count = (prefs.getInt(_kCheckoutCountKey) ?? 0) + 1;
      await prefs.setInt(_kCheckoutCountKey, count);

      // Tampilkan di checkout pertama
      if (count != 1) return;

      await prefs.setBool(_kRatingShownKey, true);

      if (!context.mounted) return;

      // Delay sebentar agar UI checkout selesai transisi
      await Future.delayed(const Duration(milliseconds: 800));
      if (!context.mounted) return;

      await _showCustomRatingDialog(context);
    } catch (e) {
      debugPrint('[AppRating] Error: $e');
    }
  }

  static Future<void> _showCustomRatingDialog(BuildContext context) async {
    int selectedStars = 0;
    String feedback = '';

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setState) {
            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
              contentPadding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.blue.withOpacity(0.08),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.star_rounded,
                      color: Colors.amber,
                      size: 48,
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Bagaimana pengalaman\nAnda menggunakan MMS?',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF1E293B),
                      height: 1.3,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Beri rating untuk membantu kami meningkatkan aplikasi',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      color: Colors.grey[600],
                    ),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: List.generate(5, (index) {
                      final starNum = index + 1;
                      return GestureDetector(
                        onTap: () => setState(() => selectedStars = starNum),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: Icon(
                            selectedStars >= starNum
                                ? Icons.star_rounded
                                : Icons.star_outline_rounded,
                            color: selectedStars >= starNum
                                ? Colors.amber
                                : Colors.grey[300],
                            size: 44,
                          ),
                        ),
                      );
                    }),
                  ),
                  if (selectedStars > 0) ...[
                    const SizedBox(height: 16),
                    TextField(
                      maxLines: 2,
                      maxLength: 200,
                      onChanged: (v) => feedback = v,
                      decoration: InputDecoration(
                        hintText: selectedStars >= 4
                            ? 'Ceritakan yang Anda suka... (opsional)'
                            : 'Apa yang bisa kami perbaiki? (opsional)',
                        hintStyle: TextStyle(
                          fontSize: 13,
                          color: Colors.grey[400],
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: Colors.grey[300]!),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: Colors.grey[300]!),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: Colors.blue),
                        ),
                        contentPadding: const EdgeInsets.all(12),
                        counterText: '',
                      ),
                    ),
                  ],
                ],
              ),
              actionsPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              actions: [
                Row(
                  children: [
                    Expanded(
                      child: TextButton(
                        onPressed: () => Navigator.pop(ctx, null),
                        child: Text(
                          'Nanti Saja',
                          style: TextStyle(color: Colors.grey[600]),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 2,
                      child: ElevatedButton(
                        onPressed: selectedStars > 0
                            ? () => Navigator.pop(ctx, {
                                  'stars': selectedStars,
                                  'feedback': feedback,
                                })
                            : null,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blue,
                          foregroundColor: Colors.white,
                          disabledBackgroundColor: Colors.grey[200],
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        child: const Text(
                          'Kirim Rating',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            );
          },
        );
      },
    );

    if (result == null) return;

    final stars = result['stars'] as int? ?? 0;

    // Kalau rating >= 4, coba tampilkan in-app review (store mengikuti platform).
    if (stars >= 4) {
      try {
        final inAppReview = InAppReview.instance;
        if (await inAppReview.isAvailable()) {
          await inAppReview.requestReview();
        }
      } catch (e) {
        debugPrint('[AppRating] In-app review error: $e');
      }
    }

    debugPrint('[AppRating] User rated $stars stars, feedback: ${result['feedback']}');
  }
}
