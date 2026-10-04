/// Pengenal toko aplikasi.
///
/// [appStoreId] adalah Apple ID numerik dari App Store Connect
/// (App Information → General Information → Apple ID), contoh '6741234567'.
/// Selama masih kosong, tombol "buka di App Store" di iOS memakai pencarian nama aplikasi.
class StoreConfig {
  static const String appStoreId = '';

  static Uri get appStoreUri => appStoreId.isNotEmpty
      ? Uri.parse('https://apps.apple.com/app/id$appStoreId')
      : Uri.parse('https://apps.apple.com/id/search?term=Atenim');
}
