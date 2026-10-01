import '../models/user_model.dart' show User;

/// Posisi petugas keamanan (menu Patroli). Sama dengan daftar kata kunci di server
/// (lib/security-position.ts), bukan mengikuti flag checkpoint site.
bool isSecurityPosition(User? user) {
  final positionName = user?.position?.name;
  if (positionName == null || positionName.trim().isEmpty) return false;
  final lower = positionName.toLowerCase();
  return lower.contains('security') ||
      lower.contains('satpam') ||
      lower.contains('guard') ||
      lower.contains('penjaga') ||
      lower.contains('patrol');
}
