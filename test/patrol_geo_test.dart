import 'package:flutter_test/flutter_test.dart';
import 'package:fms_mobile/utils/patrol_geo.dart';

// Titik uji: -6.2631, 106.7988. 0.0001 derajat lintang ≈ 11,1 m.
const _lat = -6.2631;
const _lng = 106.7988;

PatrolGeoCheck _eval({
  double? lat,
  double? lng,
  double? accuracy,
  int radius = 20,
  String mode = 'required',
  bool mocked = false,
  double? pointLat = _lat,
  double? pointLng = _lng,
}) =>
    PatrolGeoCheck.evaluate(
      pointLat: pointLat,
      pointLng: pointLng,
      radiusMeters: radius,
      gpsMode: mode,
      lat: lat,
      lng: lng,
      accuracy: accuracy,
      mocked: mocked,
    );

void main() {
  test('jarak haversine masuk akal (0,0001 derajat lintang ≈ 11 m)', () {
    final d = PatrolGeoCheck.distanceBetween(_lat, _lng, _lat + 0.0001, _lng);
    expect(d, inInclusiveRange(10.5, 11.7));
  });

  test('di titik: d <= r dan akurasi baik', () {
    final c = _eval(lat: _lat + 0.00005, lng: _lng, accuracy: 10);
    expect(c.state, PatrolGeoState.atPoint);
    expect(c.willBeFlaggedHeavy, isFalse);
  });

  test('di tepi: d - a <= r tetapi d > r (tanda ringan)', () {
    // d ≈ 27 m, r = 20, a = 12 -> d - a = 15 <= 20
    final c = _eval(lat: _lat + 0.000243, lng: _lng, accuracy: 12);
    expect(c.state, PatrolGeoState.edge);
    expect(c.willBeFlaggedHeavy, isFalse);
  });

  test('jelas di luar radius: ditandai berat', () {
    // d ≈ 111 m, a = 10, r = 20
    final c = _eval(lat: _lat + 0.001, lng: _lng, accuracy: 10);
    expect(c.state, PatrolGeoState.outside);
    expect(c.willBeFlaggedHeavy, isTrue);
    expect(c.distanceM, inInclusiveRange(105, 118));
  });

  test('GPS lemah (akurasi > 30 m) tidak dinilai jaraknya sebagai di luar', () {
    final c = _eval(lat: _lat + 0.001, lng: _lng, accuracy: 100);
    expect(c.state, PatrolGeoState.weakGps);
    expect(c.willBeFlaggedHeavy, isFalse);
  });

  test('tanpa fix: noFix; mode none atau titik tanpa koordinat: notEvaluated', () {
    expect(_eval().state, PatrolGeoState.noFix);
    expect(_eval(mode: 'none', lat: _lat, lng: _lng, accuracy: 5).state, PatrolGeoState.notEvaluated);
    expect(_eval(pointLat: null, pointLng: null, lat: _lat, lng: _lng, accuracy: 5).state, PatrolGeoState.notEvaluated);
  });

  test('lokasi palsu selalu ditandai berat walau di titik', () {
    final c = _eval(lat: _lat, lng: _lng, accuracy: 5, mocked: true);
    expect(c.state, PatrolGeoState.atPoint);
    expect(c.willBeFlaggedHeavy, isTrue);
  });

  test('pembacaan lama (lebih dari 90 detik) ditandai stale', () {
    final now = DateTime(2026, 10, 2, 13, 0, 0);
    final c = PatrolGeoCheck.evaluate(
      pointLat: _lat,
      pointLng: _lng,
      radiusMeters: 20,
      gpsMode: 'required',
      lat: _lat,
      lng: _lng,
      accuracy: 5,
      fixTime: now.subtract(const Duration(minutes: 5)),
      now: now,
    );
    expect(c.stale, isTrue);
  });
}
