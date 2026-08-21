import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:google_maps_flutter/google_maps_flutter.dart';

class HeatmapPoint {
  final double lat;
  final double lng;
  final int weight;

  const HeatmapPoint({
    required this.lat,
    required this.lng,
    required this.weight,
  });
}

class HeatmapTileProvider implements TileProvider {
  final List<HeatmapPoint> points;
  final double radiusMeters;
  final int? maxWeight;

  HeatmapTileProvider({
    required this.points,
    this.radiusMeters = 150,
    this.maxWeight,
  });

  static const int _tileSize = 256;

  static double _lngToX(double lng, int zoom) {
    return (lng + 180) / 360 * (1 << zoom) * _tileSize;
  }

  static double _latToY(double lat, int zoom) {
    final sinLat = sin(lat * pi / 180);
    return (0.5 - log((1 + sinLat) / (1 - sinLat)) / (4 * pi)) *
        (1 << zoom) *
        _tileSize;
  }

  static double _metersToPixels(double meters, double lat, int zoom) {
    const earthCircumference = 40075016.686;
    final metersPerPixel = earthCircumference *
        cos(lat * pi / 180) /
        (pow(2, zoom) * _tileSize);
    return meters / metersPerPixel;
  }

  static ui.Color _heatColor(double t) {
    if (t < 0.25) {
      final s = t / 0.25;
      return ui.Color.fromARGB(
        (s * 180).toInt(),
        (80 + s * 175).toInt(),
        220,
        80,
      );
    } else if (t < 0.55) {
      final s = (t - 0.25) / 0.30;
      return ui.Color.fromARGB(
        (180 + s * 50).toInt(),
        255,
        (220 - s * 120).toInt(),
        (80 - s * 80).toInt(),
      );
    } else if (t < 0.80) {
      final s = (t - 0.55) / 0.25;
      return ui.Color.fromARGB(
        (230 + s * 25).toInt(),
        255,
        (100 - s * 100).toInt(),
        0,
      );
    } else {
      final s = (t - 0.80) / 0.20;
      return ui.Color.fromARGB(
        255,
        (255 - s * 55).toInt(),
        0,
        (s * 60).toInt(),
      );
    }
  }

  @override
  Future<Tile> getTile(int x, int y, int? zoom) async {
    final z = zoom ?? 15;
    final int effectiveMax =
        maxWeight ?? points.fold(1, (int m, p) => max(m, p.weight));

    final tileOriginX = x * _tileSize;
    final tileOriginY = y * _tileSize;

    // Filter relevant points first, then compute radius per point
    final relevant = points.where((p) {
      final rPx = _metersToPixels(radiusMeters, p.lat, z);
      final px = _lngToX(p.lng, z);
      final py = _latToY(p.lat, z);
      return px >= tileOriginX - rPx &&
          px <= tileOriginX + _tileSize + rPx &&
          py >= tileOriginY - rPx &&
          py <= tileOriginY + _tileSize + rPx;
    }).toList();

    if (relevant.isEmpty) return TileProvider.noTile;

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(
      recorder,
      ui.Rect.fromLTWH(0, 0, _tileSize.toDouble(), _tileSize.toDouble()),
    );

    for (final p in relevant) {
      final px = _lngToX(p.lng, z) - tileOriginX;
      final py = _latToY(p.lat, z) - tileOriginY;
      final t = (p.weight / effectiveMax).clamp(0.0, 1.0);
      final rPx = _metersToPixels(radiusMeters, p.lat, z);

      final gradient = ui.Gradient.radial(
        ui.Offset(px, py),
        rPx,
        [_heatColor(t), _heatColor(t).withOpacity(0)],
        [0.0, 1.0],
      );

      canvas.drawCircle(
        ui.Offset(px, py),
        rPx,
        ui.Paint()
          ..shader = gradient
          ..blendMode = ui.BlendMode.plus,
      );
    }

    final picture = recorder.endRecording();
    final img = await picture.toImage(_tileSize, _tileSize);
    final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
    if (byteData == null) return TileProvider.noTile;
    return Tile(_tileSize, _tileSize, Uint8List.view(byteData.buffer));
  }
}

