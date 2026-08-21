import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_polyline_points/flutter_polyline_points.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'package:sahay/core/services/places_service.dart';
import 'package:sahay/core/services/safe_routes_service.dart';
import 'package:sahay/models/route_model.dart';
import 'package:sahay/services/demo_route_scorer.dart';
import 'package:sahay/screens/safe_navigation_screen.dart';
import 'package:sahay/utils/safety_factors_helper.dart';

class NavigationScreen extends StatefulWidget {
  final LatLng? initialOrigin;
  final LatLng? initialDestination;
  final String? initialOriginName;
  final String? initialDestinationName;

  const NavigationScreen({
    super.key,
    this.initialOrigin,
    this.initialDestination,
    this.initialOriginName,
    this.initialDestinationName,
  });

  @override
  State<NavigationScreen> createState() => _NavigationScreenState();
}

class _NavigationScreenState extends State<NavigationScreen> {
  final PlacesService _placesService = PlacesService();
  final Set<Polyline> _polylines = {};
  final Set<Marker> _markers = {};
  final Set<Circle> _circles = {};
  final Map<String, BitmapDescriptor> _scoreIconCache = {};

  GoogleMapController? _mapController;
  Position? _currentPosition;
  StreamSubscription<Position>? _positionSub;
  BitmapDescriptor? _userLocationIcon;
  double _lastHeading = 0.0;

  bool _loadingLocation = true;
  bool _loadingRoutes = false;
  bool _showResults = false;
  bool _inputsExpanded = true;

  String _travelMode = 'driving';
  String _originMode = 'current';
  String? _originName;
  String? _destinationName;
  LatLng? _origin;
  LatLng? _destination;

  List<SafeRoute> _routes = [];
  SafeRoute? _selectedRoute;
  int _selectedRouteIndex = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _initUserIcon();
    _initLocation();
    // Apply initial values if provided
    if (widget.initialOrigin != null) {
      _origin = widget.initialOrigin;
      _originName = widget.initialOriginName ?? 'Start';
    }
    if (widget.initialDestination != null) {
      _destination = widget.initialDestination;
      _destinationName = widget.initialDestinationName ?? 'Destination';
    }
  }

  Future<void> _initUserIcon() async {
    if (_userLocationIcon != null) return;
    try {
      _userLocationIcon = await _createUserLocationBitmap();
      if (mounted) _syncMarkers();
    } catch (_) {
      _userLocationIcon = BitmapDescriptor.defaultMarkerWithHue(
        BitmapDescriptor.hueAzure,
      );
    }
  }

  Future<void> _initLocation() async {
    try {
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
      if (!mounted) return;
      setState(() {
        _currentPosition = position;
        if (_originMode == 'current') {
          _origin = LatLng(position.latitude, position.longitude);
          _originName = 'Current location';
        }
        _loadingLocation = false;
      });
      _syncMarkers();
      _startLocationTracking();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingLocation = false;
        _error = e.toString();
      });
    }
  }

  Future<PlaceLocation?> _choosePlace({
    required String title,
    required String hint,
    bool allowCurrentLocation = true,
  }) async {
    final controller = TextEditingController();
    List<Map<String, String>> suggestions = [];
    bool loading = false;

    return showModalBottomSheet<PlaceLocation?>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (c, setLocal) {
            Future<void> search(String q) async {
              setLocal(() => loading = true);
              final results = await _placesService.getAutocomplete(q);
              setLocal(() {
                suggestions = results;
                loading = false;
              });
            }

            return SafeArea(
              child: Padding(
                padding: EdgeInsets.only(
                  left: 16,
                  right: 16,
                  top: 12,
                  bottom: MediaQuery.of(context).viewInsets.bottom + 16,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 44,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.grey[300],
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Text(
                          title,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const Spacer(),
                        IconButton(
                          onPressed: () => Navigator.pop(sheetContext),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (allowCurrentLocation)
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: _currentPosition == null
                              ? null
                              : () {
                                  Navigator.pop(
                                    sheetContext,
                                    PlaceLocation(
                                      description: 'Current location',
                                      placeId: 'current_location',
                                      latitude: _currentPosition!.latitude,
                                      longitude: _currentPosition!.longitude,
                                    ),
                                  );
                                },
                          icon: const Icon(Icons.my_location),
                          label: const Text('Use current location'),
                        ),
                      ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: controller,
                      onChanged: (t) {
                        if (t.trim().isEmpty) return;
                        search(t);
                      },
                      decoration: InputDecoration(
                        prefixIcon: const Icon(Icons.search),
                        hintText: hint,
                        filled: true,
                        fillColor: Colors.grey[100],
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (loading)
                      const LinearProgressIndicator(minHeight: 3)
                    else if (suggestions.isNotEmpty)
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 280),
                        child: ListView.separated(
                          shrinkWrap: true,
                          itemBuilder: (ctx, i) {
                            final item = suggestions[i];
                            return ListTile(
                              title: Text(item['description'] ?? ''),
                              onTap: () async {
                                final details = await _placesService
                                    .getPlaceDetails(
                                      placeId: item['place_id'] ?? '',
                                      description: item['description'] ?? '',
                                    );
                                if (details != null)
                                  Navigator.pop(sheetContext, details);
                              },
                            );
                          },
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemCount: suggestions.length,
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _syncMarkers() {
    _markers.removeWhere(
      (m) =>
          m.markerId.value == 'origin' ||
          m.markerId.value == 'destination' ||
          m.markerId.value == 'me',
    );
    _circles.clear();

    if (_origin != null) {
      final originIsCurrent =
          _originMode == 'current' && _currentPosition != null;
      _markers.add(
        Marker(
          markerId: const MarkerId('origin'),
          position: _origin!,
          infoWindow: InfoWindow(title: _originName ?? 'Start'),
          icon: originIsCurrent
              ? (_userLocationIcon ??
                    BitmapDescriptor.defaultMarkerWithHue(
                      BitmapDescriptor.hueAzure,
                    ))
              : BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueBlue),
          rotation: originIsCurrent ? _lastHeading : 0,
          flat: originIsCurrent,
          anchor: const Offset(0.5, 0.5),
        ),
      );
      if (originIsCurrent) {
        _circles.add(
          Circle(
            circleId: const CircleId('origin_aura'),
            center: _origin!,
            radius: 18,
            fillColor: const Color(0xFF2563EB).withOpacity(0.18),
            strokeColor: const Color(0xFF2563EB).withOpacity(0.35),
            strokeWidth: 2,
          ),
        );
      }
    }
    if (_destination != null) {
      _markers.add(
        Marker(
          markerId: const MarkerId('destination'),
          position: _destination!,
          infoWindow: InfoWindow(title: _destinationName ?? 'Destination'),
        ),
      );
    }
    if (_currentPosition != null && _originMode != 'current') {
      _circles.add(
        Circle(
          circleId: const CircleId('me_aura'),
          center: LatLng(
            _currentPosition!.latitude,
            _currentPosition!.longitude,
          ),
          radius: 18,
          fillColor: const Color(0xFF2563EB).withOpacity(0.18),
          strokeColor: const Color(0xFF2563EB).withOpacity(0.35),
          strokeWidth: 2,
        ),
      );
      _markers.add(
        Marker(
          markerId: const MarkerId('me'),
          position: LatLng(
            _currentPosition!.latitude,
            _currentPosition!.longitude,
          ),
          icon:
              _userLocationIcon ??
              BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
          rotation: _lastHeading,
          flat: true,
          anchor: const Offset(0.5, 0.5),
        ),
      );
    }
    setState(() {});
  }

  Future<void> _startLocationTracking() async {
    await _positionSub?.cancel();
    _positionSub =
        Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.best,
            distanceFilter: 5,
          ),
        ).listen((position) async {
          if (!mounted) return;
          final heading = _normalizedHeading(position.heading);
          _lastHeading = heading;

          if (_originMode == 'current') {
            _origin = LatLng(position.latitude, position.longitude);
            _originName = 'Current location';
          }

          if (_userLocationIcon == null) {
            try {
              _userLocationIcon = await _createUserLocationBitmap();
            } catch (_) {
              _userLocationIcon = BitmapDescriptor.defaultMarkerWithHue(
                BitmapDescriptor.hueAzure,
              );
            }
          }

          setState(() {
            _currentPosition = position;
          });
          _syncMarkers();
        });
  }

  double _normalizedHeading(double heading) {
    if (!heading.isFinite || heading < 0) return _lastHeading;
    return heading;
  }

  Future<BitmapDescriptor> _createUserLocationBitmap() async {
    const int size = 96;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final center = const Offset(size / 2, size / 2);

    final auraPaint = Paint()
      ..color = const Color(0xFF60A5FA).withOpacity(0.18);
    canvas.drawCircle(center, size * 0.42, auraPaint);

    final glowPaint = Paint()
      ..color = const Color(0xFF2563EB).withOpacity(0.22);
    canvas.drawCircle(center, size * 0.24, glowPaint);

    canvas.drawCircle(
      center,
      size * 0.16,
      Paint()..color = const Color(0xFF2563EB),
    );

    canvas.drawCircle(center, size * 0.07, Paint()..color = Colors.white);

    final picture = recorder.endRecording();
    final img = await picture.toImage(size, size);
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    return BitmapDescriptor.fromBytes(bytes!.buffer.asUint8List());
  }

  Future<BitmapDescriptor> _createScoreBitmap(String text, Color bg) async {
    final int size = 120;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final paint = Paint()..color = bg;
    canvas.drawCircle(Offset(size / 2, size / 2), size / 2.0, paint);
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: Colors.white,
          fontSize: 48,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    tp.layout();
    tp.paint(canvas, Offset((size - tp.width) / 2, (size - tp.height) / 2));
    final picture = recorder.endRecording();
    final img = await picture.toImage(size, size);
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    return BitmapDescriptor.fromBytes(bytes!.buffer.asUint8List());
  }

  Color _getRouteColor(double safetyScore) {
    if (safetyScore > 1.0) return SafetyFactorsHelper.colorForScore(safetyScore);

    if (safetyScore >= 0.65) {
      return Color.lerp(
        const Color(0xFF059669),
        const Color(0xFF10B981),
        (safetyScore - 0.65) / 0.35,
      )!;
    } else if (safetyScore >= 0.35) {
      return Color.lerp(
        const Color(0xFFF59E0B),
        const Color(0xFFEF4444),
        (0.65 - safetyScore) / 0.30,
      )!;
    } else {
      return Color.lerp(
        const Color(0xFFDC2626),
        const Color(0xFFEF4444),
        safetyScore / 0.35,
      )!;
    }
  }

  String _scoreValue(SafeRoute route) {
    if (route.safetyScore > 1.0) {
      return route.safetyScore.toStringAsFixed(1);
    }
    return route.safetyScore.toStringAsFixed(4);
  }

  Future<void> _generatePolylines() async {
    _polylines.clear();
    _markers.removeWhere((m) => m.markerId.value.startsWith('score_'));
    _syncMarkers();

    for (int index = 0; index < _routes.length; index++) {
      final route = _routes[index];
      final decoded = PolylinePoints.decodePolyline(
        route.polylineEncoded,
      ).map((p) => LatLng(p.latitude, p.longitude)).toList();
      if (decoded.isEmpty) continue;
      final color = _getRouteColor(route.safetyScore);
      final selected = index == _selectedRouteIndex;
      _polylines.add(
        Polyline(
          polylineId: PolylineId(route.id),
          points: decoded,
          color: color.withOpacity(selected ? 1.0 : 0.78),
          width: selected ? 8 : 5,
          geodesic: true,
          consumeTapEvents: true,
          onTap: () => _selectRoute(index),
        ),
      );

      try {
        final mid = decoded[(decoded.length / 2).floor()];
        final scoreText = _scoreValue(route);
        final key = '${_scoreValue(route)}|${route.riskBucket}';
        BitmapDescriptor icon;
        if (_scoreIconCache.containsKey(key)) {
          icon = _scoreIconCache[key]!;
        } else {
          final bg = _getRouteColor(route.safetyScore);
          await Future.delayed(const Duration(milliseconds: 1));
          icon = await _createScoreBitmap(scoreText, bg);
          _scoreIconCache[key] = icon;
        }
        _markers.add(
          Marker(
            markerId: MarkerId('score_${route.id}'),
            position: mid,
            icon: icon,
            infoWindow: InfoWindow(
              title: 'Score: $scoreText',
              snippet: route.explanation,
            ),
            onTap: () => _showWhyThisScoreModal(route),
          ),
        );
      } catch (_) {}
    }
    setState(() {});
  }

  void _showWhyThisScoreModal(SafeRoute route) {
    showDialog(
      context: context,
      builder: (c) => WhyThisScoreModal(route: route),
    );
  }

  Future<void> _scoreRoutes() async {
    if (_origin == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Choose a starting point first.')),
      );
      return;
    }
    if (_destination == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Choose a destination first.')),
      );
      return;
    }

    setState(() {
      _loadingRoutes = true;
      _error = null;
      _showResults = true;
    });

    try {
      final response = await SafeRoutesService.scoreRoutes(
        originLat: _origin!.latitude,
        originLng: _origin!.longitude,
        destLat: _destination!.latitude,
        destLng: _destination!.longitude,
        travelMode: _travelMode,
      );
      if (!response.success)
        throw Exception(response.meta.error ?? 'Failed to fetch routes');
      final demoRoutes = DemoRouteScorer.scoreSafeRoutesForUi(response.routes);
      if (!mounted) return;
      setState(() {
        _routes = demoRoutes;
        _selectedRouteIndex = 0;
        _selectedRoute = _routes.isNotEmpty ? _routes.first : null;
        _inputsExpanded = false;
        _loadingRoutes = false;
      });
      await _generatePolylines();
      await _fitCamera();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loadingRoutes = false;
      });
    }
  }

  Future<void> _recenterRoutes() async {
    await _fitCamera();
  }

  Future<void> _selectRoute(int index) async {
    setState(() {
      _selectedRouteIndex = index;
      _selectedRoute = _routes[index];
    });
    await _generatePolylines();
  }

  void _startNavigation() {
    if (_origin == null || _destination == null) return;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SafeNavigationScreen(
          origin: _origin!,
          destination: _destination!,
          originName: _originName,
          destinationName: _destinationName,
        ),
      ),
    );
  }

  void _toggleInputsExpanded() {
    setState(() {
      _inputsExpanded = !_inputsExpanded;
    });
  }

  void _hideResultsPanel() {
    setState(() {
      _showResults = false;
    });
  }

  void _showResultsPanel() {
    setState(() {
      _showResults = true;
    });
  }

  Future<void> _pickOrigin() async {
    final result = await _choosePlace(
      title: 'Choose origin',
      hint: 'Search origin',
    );
    if (!mounted || result == null) return;
    setState(() {
      _origin = LatLng(result.latitude, result.longitude);
      _originName = result.description;
      _originMode = result.placeId == 'current_location' ? 'current' : 'place';
    });
    _syncMarkers();
  }

  Future<void> _pickDestination() async {
    final result = await _choosePlace(
      title: 'Choose destination',
      hint: 'Search destination',
    );
    if (!mounted || result == null) return;
    setState(() {
      _destination = LatLng(result.latitude, result.longitude);
      _destinationName = result.description;
    });
    _syncMarkers();
  }

  Future<void> _fitCamera() async {
    if (_mapController == null || _origin == null || _destination == null)
      return;
    try {
      final minLat = math.min(_origin!.latitude, _destination!.latitude);
      final maxLat = math.max(_origin!.latitude, _destination!.latitude);
      final minLng = math.min(_origin!.longitude, _destination!.longitude);
      final maxLng = math.max(_origin!.longitude, _destination!.longitude);
      await _mapController!.animateCamera(
        CameraUpdate.newLatLngBounds(
          LatLngBounds(
            southwest: LatLng(minLat, minLng),
            northeast: LatLng(maxLat, maxLng),
          ),
          120,
        ),
      );
    } catch (_) {}
  }

  Color _routeColor(String bucket) {
    switch (bucket) {
      case 'SAFE':
        return const Color(0xFF16A34A);
      case 'MODERATE':
        return const Color(0xFFF59E0B);
      case 'DANGEROUS':
        return const Color(0xFFEF4444);
      default:
        return Colors.grey;
    }
  }

  String _routeLabel(String bucket) {
    switch (bucket) {
      case 'SAFE':
        return 'Safest Route';
      case 'MODERATE':
        return 'Moderate Safety';
      case 'DANGEROUS':
        return 'Least Safe';
      default:
        return 'Route';
    }
  }

  @override
  void dispose() {
    _mapController?.dispose();
    _positionSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cameraTarget =
        _origin ??
        (_currentPosition == null
            ? const LatLng(20.5937, 78.9629)
            : LatLng(_currentPosition!.latitude, _currentPosition!.longitude));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Safe Routes'),
        backgroundColor: const Color(0xFFF7F3EA),
        foregroundColor: const Color(0xFF1F2937),
        elevation: 0,
      ),
      body: Stack(
        children: [
          Positioned.fill(
            child: _loadingLocation && _currentPosition == null
                ? const Center(child: CircularProgressIndicator())
                : GoogleMap(
                    initialCameraPosition: CameraPosition(
                      target: cameraTarget,
                      zoom: _origin == null ? 13 : 15,
                    ),
                    onMapCreated: (c) => _mapController = c,
                    markers: _markers,
                    circles: _circles,
                    polylines: _polylines,
                    myLocationEnabled: false,
                    myLocationButtonEnabled: true,
                    zoomControlsEnabled: false,
                  ),
          ),
          Positioned(
            left: 12,
            right: 12,
            top: 10,
            child: SafeArea(
              bottom: false,
              child: AnimatedCrossFade(
                duration: const Duration(milliseconds: 220),
                crossFadeState: _inputsExpanded
                    ? CrossFadeState.showFirst
                    : CrossFadeState.showSecond,
                firstChild: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFDF9F2),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: const Color(0xFFE9DEC8)),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.06),
                        blurRadius: 16,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: InkWell(
                              onTap: _pickOrigin,
                              borderRadius: BorderRadius.circular(16),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 12,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(
                                    color: Colors.grey.shade300,
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    Container(
                                      width: 34,
                                      height: 34,
                                      decoration: const BoxDecoration(
                                        color: Color(0xFFE6F0FF),
                                        shape: BoxShape.circle,
                                      ),
                                      child: const Icon(
                                        Icons.trip_origin,
                                        color: Color(0xFF2563EB),
                                        size: 18,
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            'Starting point',
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: Colors.grey.shade600,
                                            ),
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            _originName ?? 'Choose start',
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              fontSize: 14,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: InkWell(
                              onTap: _pickDestination,
                              borderRadius: BorderRadius.circular(16),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 12,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(
                                    color: Colors.grey.shade300,
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    Container(
                                      width: 34,
                                      height: 34,
                                      decoration: const BoxDecoration(
                                        color: Color(0xFFFFECEA),
                                        shape: BoxShape.circle,
                                      ),
                                      child: const Icon(
                                        Icons.location_on,
                                        color: Color(0xFFDC2626),
                                        size: 18,
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            'Destination',
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: Colors.grey.shade600,
                                            ),
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            _destinationName ??
                                                'Choose destination',
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              fontSize: 14,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Travel mode',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Colors.grey.shade700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          ChoiceChip(
                            label: const Text('Car'),
                            selected: _travelMode == 'driving',
                            onSelected: (_) =>
                                setState(() => _travelMode = 'driving'),
                          ),
                          ChoiceChip(
                            label: const Text('Bus'),
                            selected: _travelMode == 'transit',
                            onSelected: (_) =>
                                setState(() => _travelMode = 'transit'),
                          ),
                          ChoiceChip(
                            label: const Text('Walk'),
                            selected: _travelMode == 'walking',
                            onSelected: (_) =>
                                setState(() => _travelMode = 'walking'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: _loadingRoutes ? null : _scoreRoutes,
                              icon: _loadingRoutes
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        color: Colors.white,
                                        strokeWidth: 2.3,
                                      ),
                                    )
                                  : const Icon(Icons.route),
                              label: Text(
                                _loadingRoutes
                                    ? 'Finding routes'
                                    : 'Show routes',
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFFF59E0B),
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                  vertical: 14,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          _error!,
                          style: const TextStyle(color: Colors.red),
                        ),
                      ],
                    ],
                  ),
                ),
                secondChild: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFDF9F2),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: const Color(0xFFE9DEC8)),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.06),
                        blurRadius: 16,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Row(
                          children: [
                            Container(
                              width: 34,
                              height: 34,
                              decoration: const BoxDecoration(
                                color: Color(0xFFE6F0FF),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.trip_origin,
                                color: Color(0xFF2563EB),
                                size: 18,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _originName ?? 'Choose start',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Row(
                          children: [
                            Container(
                              width: 34,
                              height: 34,
                              decoration: const BoxDecoration(
                                color: Color(0xFFFFECEA),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.location_on,
                                color: Color(0xFFDC2626),
                                size: 18,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _destinationName ?? 'Choose destination',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        onPressed: _toggleInputsExpanded,
                        icon: const Icon(Icons.edit),
                        tooltip: 'Edit locations',
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            right: 12,
            top: 180,
            child: FloatingActionButton.small(
              heroTag: 'recenter_routes',
              onPressed: _recenterRoutes,
              backgroundColor: Colors.white,
              foregroundColor: const Color(0xFF5B3E2B),
              child: const Icon(Icons.center_focus_strong),
            ),
          ),
          if (_showResults)
            DraggableScrollableSheet(
              initialChildSize: 0.38,
              minChildSize: 0.16,
              maxChildSize: 0.82,
              builder: (context, scrollController) {
                return Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(24),
                      topRight: Radius.circular(24),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.12),
                        blurRadius: 18,
                        offset: const Offset(0, -4),
                      ),
                    ],
                  ),
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: Row(
                          children: [
                            const SizedBox(width: 12),
                            Expanded(
                              child: Center(
                                child: Container(
                                  width: 42,
                                  height: 4,
                                  decoration: BoxDecoration(
                                    color: Colors.grey.shade300,
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                ),
                              ),
                            ),
                            IconButton(
                              onPressed: _hideResultsPanel,
                              icon: const Icon(Icons.close),
                              tooltip: 'Close routes',
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: ListView(
                          controller: scrollController,
                          padding: const EdgeInsets.fromLTRB(12, 4, 12, 18),
                          children: [
                            if (_routes.isEmpty)
                              const Padding(
                                padding: EdgeInsets.only(top: 16),
                                child: Center(child: Text('No routes')),
                              )
                            else
                              ..._routes.asMap().entries.map((e) {
                                final idx = e.key;
                                final route = e.value;
                                final sel = _selectedRouteIndex == idx;
                                final color = _getRouteColor(route.safetyScore);
                                final scoreValue = _scoreValue(route);
                                return Padding(
                                  padding: const EdgeInsets.only(bottom: 8),
                                  child: InkWell(
                                    onTap: () => _selectRoute(idx),
                                    child: Container(
                                      padding: const EdgeInsets.all(12),
                                      decoration: BoxDecoration(
                                        color: sel
                                            ? color.withOpacity(0.08)
                                            : Colors.white,
                                        borderRadius: BorderRadius.circular(14),
                                        border: Border.all(
                                          color: sel
                                              ? color
                                              : Colors.grey.shade300,
                                          width: sel ? 2 : 1,
                                        ),
                                      ),
                                      child: Row(
                                        children: [
                                          Container(
                                            width: 56,
                                            height: 56,
                                            decoration: BoxDecoration(
                                              color: color,
                                              shape: BoxShape.circle,
                                            ),
                                            child: Center(
                                              child: Text(
                                                scoreValue,
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 18,
                                                  fontWeight: FontWeight.w800,
                                                ),
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 12),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  SafetyFactorsHelper
                                                      .labelForScore(
                                                        route.safetyScore,
                                                      ),
                                                  style: const TextStyle(
                                                    fontWeight: FontWeight.w700,
                                                  ),
                                                ),
                                                const SizedBox(height: 4),
                                                Text(
                                                  '${(route.distanceM / 1000).toStringAsFixed(1)} km â€¢ ${(route.durationS / 60).toStringAsFixed(0)} min',
                                                  style: const TextStyle(
                                                    color: Colors.grey,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          const Icon(
                                            Icons.chevron_right,
                                            color: Colors.grey,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                );
                              }),
                            if (_selectedRoute != null) ...[
                              const SizedBox(height: 8),
                              SizedBox(
                                width: double.infinity,
                                child: ElevatedButton.icon(
                                  onPressed: _startNavigation,
                                  icon: const Icon(Icons.navigation),
                                  label: const Text('Start Navigation'),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          if (!_showResults && _routes.isNotEmpty)
            Positioned(
              left: 12,
              bottom: 14,
              child: SafeArea(
                top: false,
                child: ElevatedButton.icon(
                  onPressed: _showResultsPanel,
                  icon: const Icon(Icons.route),
                  label: const Text('Show routes'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFF59E0B),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}



