import 'dart:math' as math;

/// Penilaian lokasi scan di HP, meniru aturan server (`evaluateScanLocation` di lib/patrol/geo.ts) supaya petugas
/// tahu SEBELUM menyimpan bahwa scan-nya akan ditandai. HP tidak pernah memblokir scan karena GPS; keputusan
/// akhir tetap di server dan SPV.
///
/// d = jarak fix ke titik, a = akurasi fix, r = radius titik, B = batas akurasi.
enum PatrolGeoState {
  /// Titik tanpa koordinat atau tanpa pengecekan GPS.
  notEvaluated,

  /// Belum ada lokasi GPS.
  noFix,

  /// Akurasi lebih buruk dari batas, jarak tidak bisa dinilai.
  weakGps,

  /// d <= r: di titik.
  atPoint,

  /// d - a <= r: di tepi radius (tanda ringan).
  edge,

  /// d - a > r: jelas di luar radius (tanda berat, menunggu tinjauan SPV).
  outside,
}

class PatrolGeoCheck {
  const PatrolGeoCheck({
    required this.state,
    this.distanceM,
    this.radiusM,
    this.accuracyM,
    this.mocked = false,
    this.stale = false,
  });

  final PatrolGeoState state;
  final double? distanceM;
  final int? radiusM;
  final double? accuracyM;
  final bool mocked;

  /// Lokasi berasal dari pembacaan lama (bukan fix baru), jadi mungkin bukan posisi sekarang.
  final bool stale;

  /// Scan hampir pasti ditandai berat dan masuk antrean tinjauan SPV.
  bool get willBeFlaggedHeavy => mocked || state == PatrolGeoState.outside;

  static const double accuracyLimitMeters = 30;
  static const int defaultRadiusMeters = 30;
  static const Duration staleAfter = Duration(seconds: 90);

  /// Jarak dua titik di bumi (meter), rumus haversine.
  static double distanceBetween(double lat1, double lng1, double lat2, double lng2) {
    const earth = 6371000.0;
    double rad(double d) => d * math.pi / 180;
    final dLat = rad(lat2 - lat1);
    final dLng = rad(lng2 - lng1);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(rad(lat1)) * math.cos(rad(lat2)) * math.sin(dLng / 2) * math.sin(dLng / 2);
    return earth * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }

  /// [gpsMode]: required | if_available | none. [fixTime] = waktu fix dibaca (untuk mendeteksi pembacaan lama).
  static PatrolGeoCheck evaluate({
    required double? pointLat,
    required double? pointLng,
    required int? radiusMeters,
    required String gpsMode,
    double? lat,
    double? lng,
    double? accuracy,
    bool mocked = false,
    DateTime? fixTime,
    DateTime? now,
  }) {
    final r = radiusMeters ?? defaultRadiusMeters;
    final stale = fixTime != null && (now ?? DateTime.now()).difference(fixTime) > staleAfter;
    final hasFix = lat != null && lng != null;
    final pointHasCoords = pointLat != null && pointLng != null;

    if (gpsMode == 'none' || !pointHasCoords) {
      return PatrolGeoCheck(state: PatrolGeoState.notEvaluated, radiusM: pointHasCoords ? r : null, mocked: mocked);
    }
    if (!hasFix) {
      return PatrolGeoCheck(state: PatrolGeoState.noFix, radiusM: r, mocked: mocked);
    }
    final d = distanceBetween(pointLat, pointLng, lat, lng);
    final a = accuracy != null && accuracy >= 0 ? accuracy : double.infinity;
    if (a > accuracyLimitMeters) {
      return PatrolGeoCheck(
        state: PatrolGeoState.weakGps,
        distanceM: d,
        radiusM: r,
        accuracyM: a.isFinite ? a : null,
        mocked: mocked,
        stale: stale,
      );
    }
    final PatrolGeoState state;
    if (d <= r) {
      state = PatrolGeoState.atPoint;
    } else if (d - a <= r) {
      state = PatrolGeoState.edge;
    } else {
      state = PatrolGeoState.outside;
    }
    return PatrolGeoCheck(state: state, distanceM: d, radiusM: r, accuracyM: a, mocked: mocked, stale: stale);
  }
}
