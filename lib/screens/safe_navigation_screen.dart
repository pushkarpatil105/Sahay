import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:flutter_polyline_points/flutter_polyline_points.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:geolocator/geolocator.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'dart:async';
import 'dart:ui' as ui;
import '../core/services/directions_service.dart';
import '../models/route_model.dart';
import '../core/services/safe_routes_service.dart';
import '../services/demo_route_scorer.dart';
import '../utils/safety_factors_helper.dart';

class SafeNavigationScreen extends StatefulWidget {
  final LatLng origin;
  final LatLng destination;
  final String? originName;
  final String? destinationName;

  const SafeNavigationScreen({
    Key? key,
    required this.origin,
    required this.destination,
    this.originName,
    this.destinationName,
  }) : super(key: key);

  @override
  State<SafeNavigationScreen> createState() => _SafeNavigationScreenState();
}

class _SafeNavigationScreenState extends State<SafeNavigationScreen> {
  GoogleMapController? _mapController;
  final Set<Polyline> _polylines = {};
  final Set<Marker> _markers = {};
  List<SafeRoute> _routes = [];
  bool _isLoading = true;
  String? _error;
  SafeRoute? _selectedRoute;
  int? _selectedRouteIndex;
  String _travelMode = 'driving';
  // Navigation state
  bool _navigating = false;
  Position? _currentPosition;
  StreamSubscription<Position>? _positionSub;
  final DirectionsService _directions = DirectionsService();
  final FlutterTts _tts = FlutterTts();
  List<NavigationStep> _navSteps = [];
  int _currentStepIndex = 0;
  BitmapDescriptor? _arrowIcon;
  bool _routesPanelOpen = true;
  final Set<Circle> _reportCircles = {};
  final Set<Marker> _reportMarkers = {};
  Circle? _userLocationCircle;
  RouteModel? _activeNavigationRoute;
  double _lastHeading = 0.0;
  bool _voiceNavigationEnabled = true;
  bool _ttsReady = false;
  final Map<int, Set<int>> _announcedStepThresholds = {};
  String? _lastSpokenInstruction;

  @override
  void initState() {
    super.initState();
    _initializeTts();
    _initializeMap();
    _fetchSafeRoutes();
  }

  Future<void> _initializeTts() async {
    try {
      await _tts.awaitSpeakCompletion(true);
      await _tts.setLanguage('en-IN');
      await _tts.setSpeechRate(0.47);
      await _tts.setPitch(1.0);
      await _tts.setVolume(1.0);
      _ttsReady = true;
    } catch (e) {
      debugPrint('TTS init failed: $e');
      _ttsReady = false;
    }
  }

  void _initializeMap() {
    _markers.clear();
    _markers.addAll([
      Marker(
        markerId: const MarkerId('origin'),
        position: widget.origin,
        infoWindow: InfoWindow(title: widget.originName ?? 'Starting Point'),
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueBlue),
      ),
      Marker(
        markerId: const MarkerId('destination'),
        position: widget.destination,
        infoWindow: InfoWindow(title: widget.destinationName ?? 'Destination'),
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
      ),
    ]);
  }

  String _formatScore(SafeRoute route) {
    if (route.safetyScore > 1.0) {
      return route.safetyScore.toStringAsFixed(1);
    }
    return route.safetyScore.toStringAsFixed(4);
  }

  Future<void> _fetchSafeRoutes({bool allowRetry = true}) async {
    try {
      setState(() {
        _isLoading = true;
        _error = null;
      });

      final response = await SafeRoutesService.scoreRoutes(
        originLat: widget.origin.latitude,
        originLng: widget.origin.longitude,
        destLat: widget.destination.latitude,
        destLng: widget.destination.longitude,
        travelMode: _travelMode,
      );

      if (!response.success) {
        throw Exception(response.meta.error ?? 'Failed to fetch routes');
      }

      final demoRoutes = DemoRouteScorer.scoreSafeRoutesForUi(response.routes);

      setState(() {
        _routes = demoRoutes;
        if (_routes.isNotEmpty) {
          _selectedRoute = _routes[0];
          _selectedRouteIndex = 0;
          _generatePolylines();
        }
        _isLoading = false;
      });

      if (_routes.isNotEmpty) {
        _animateCameraToFitRoutes();
      }
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
      print('Error fetching routes: $e');
      if (e.toString().contains('Backend not found')) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'Backend not reachable yet. Retrying auto-detect.',
                ),
                duration: Duration(seconds: 2),
              ),
            );
          }
        });
        if (allowRetry) {
          await SafeRoutesService.clearCachedBackendUrl();
          await _fetchSafeRoutes(allowRetry: false);
        }
      }
    }
  }

  /// Get color based on safety score with smooth gradient
  Color _getRouteColor(double safetyScore) {
    if (safetyScore > 1.0) return SafetyFactorsHelper.colorForScore(safetyScore);

    // Green (SAFE): 0.65-1.0 -> #10B981
    // Yellow (MODERATE): 0.35-0.65 -> #F59E0B
    // Red (DANGEROUS): 0.0-0.35 -> #EF4444
    if (safetyScore >= 0.65) {
      // Green gradient: darker at 0.65, lighter at 1.0
      return Color.lerp(
        const Color(0xFF059669), // Darker green
        const Color(0xFF10B981), // Regular green
        (safetyScore - 0.65) / 0.35,
      )!;
    } else if (safetyScore >= 0.35) {
      // Yellow gradient: red at 0.35, yellow at 0.65
      return Color.lerp(
        const Color(0xFFF59E0B), // Yellow
        const Color(0xFFEF4444), // Red
        (0.65 - safetyScore) / 0.30,
      )!;
    } else {
      // Red gradient: darker at 0.0, lighter at 0.35
      return Color.lerp(
        const Color(0xFFDC2626), // Darker red
        const Color(0xFFEF4444), // Regular red
        safetyScore / 0.35,
      )!;
    }
  }

  void _generatePolylines() {
    _polylines.clear();

    for (int idx = 0; idx < _routes.length; idx++) {
      final route = _routes[idx];
      try {
        final polylinePoints = PolylinePoints.decodePolyline(
          route.polylineEncoded,
        );
        final points = polylinePoints
            .map((p) => LatLng(p.latitude, p.longitude))
            .toList();

        final color = _getRouteColor(route.safetyScore);
        final isSelected = _selectedRouteIndex == idx;

        _polylines.add(
          Polyline(
            polylineId: PolylineId(route.id),
            points: points,
            color: color,
            width: isSelected ? 8 : 5,
            geodesic: true,
          ),
        );
      } catch (e) {
        print('Error decoding polyline for route ${route.id}: $e');
      }
    }
  }

  Future<void> _animateCameraToFitRoutes() async {
    if (_routes.isEmpty) return;

    try {
      await Future.delayed(const Duration(milliseconds: 500));
      final firstRoute = _routes.first;
      final polylinePoints = PolylinePoints.decodePolyline(
        firstRoute.polylineEncoded,
      );

      if (polylinePoints.isEmpty) return;

      double minLat = polylinePoints.first.latitude;
      double maxLat = polylinePoints.first.latitude;
      double minLng = polylinePoints.first.longitude;
      double maxLng = polylinePoints.first.longitude;

      for (final point in polylinePoints) {
        minLat = math.min(minLat, point.latitude);
        maxLat = math.max(maxLat, point.latitude);
        minLng = math.min(minLng, point.longitude);
        maxLng = math.max(maxLng, point.longitude);
      }

      final bounds = LatLngBounds(
        southwest: LatLng(minLat, minLng),
        northeast: LatLng(maxLat, maxLng),
      );

      await _mapController?.animateCamera(
        CameraUpdate.newLatLngBounds(bounds, 150),
      );
    } catch (e) {
      print('Error animating camera: $e');
    }
  }

  void _selectRoute(int index) {
    setState(() {
      _selectedRouteIndex = index;
      _selectedRoute = _routes[index];
      _generatePolylines();
    });
    if (_navigating) {
      // Restart navigation using current location towards the newly selected route's destination
      _beginNavigationProcedure();
    }
  }

  void _showWhyThisScoreModal(SafeRoute route) {
    showDialog(
      context: context,
      builder: (context) => WhyThisScoreModal(route: route),
    );
  }

  void _startNavigation() {
    if (_selectedRoute == null) return;
    // Close the routes panel and begin navigation
    setState(() {
      _routesPanelOpen = false;
    });
    _beginNavigationProcedure();
    // Load recent unsafe reports to display on map while navigating
    _loadUnsafeReports();
  }

  Future<void> _focusCameraOnUser(
    Position position, {
    bool animate = true,
  }) async {
    if (_mapController == null) return;
    final heading = _normalizedHeading(position.heading);
    _lastHeading = heading;
    final camera = CameraPosition(
      target: LatLng(position.latitude, position.longitude),
      zoom: 19,
      bearing: heading,
      tilt: 55,
    );
    try {
      if (animate) {
        await _mapController!.animateCamera(
          CameraUpdate.newCameraPosition(camera),
        );
      } else {
        await _mapController!.moveCamera(
          CameraUpdate.newCameraPosition(camera),
        );
      }
    } catch (_) {}
  }

  double _normalizedHeading(double heading) {
    if (!heading.isFinite || heading < 0) return _lastHeading;
    return heading;
  }

  Widget _buildNavMetricChip({
    required IconData icon,
    required String label,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: color.withOpacity(0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withOpacity(0.22)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _beginNavigationProcedure() async {
    try {
      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
      if (!mounted) return;
      setState(() {
        _currentPosition = pos;
        _navigating = true;
        _currentStepIndex = 0;
      });
      await _focusCameraOnUser(pos, animate: false);

      // Fetch detailed directions (with steps) from current location to destination
      final origin = LatLng(pos.latitude, pos.longitude);
      final dest = widget.destination;
      final route = await _directions.getRouteBetweenCoords(origin, dest);
      if (route == null) {
        debugPrint(
          '⚠️ DirectionsService returned null — check API key/network',
        );
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not fetch navigation steps')),
        );
        return;
      }

      setState(() {
        _navSteps = route.steps;
        _activeNavigationRoute = route;
        _currentStepIndex = 0;
        _announcedStepThresholds.clear();
        _lastSpokenInstruction = null;
      });

      await _speakCurrentGuidance(force: true, currentPosition: origin);

      // Show active navigation polyline
      setState(() {
        _polylines.clear();
        _polylines.add(
          Polyline(
            polylineId: const PolylineId('nav_active'),
            points: route.polylinePoints,
            color: Colors.blue,
            width: 6,
            geodesic: true,
          ),
        );
      });

      _positionSub?.cancel();
      _positionSub =
          Geolocator.getPositionStream(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.best,
              distanceFilter: 5,
            ),
          ).listen((p) async {
            if (!mounted) return;
            final curr = LatLng(p.latitude, p.longitude);
            final heading = _normalizedHeading(p.heading);
            _lastHeading = heading;
            // Ensure arrow icon is prepared
            if (_arrowIcon == null) {
              try {
                _arrowIcon = await _createArrowBitmap();
              } catch (_) {
                _arrowIcon = BitmapDescriptor.defaultMarkerWithHue(
                  BitmapDescriptor.hueAzure,
                );
              }
            }

            setState(() {
              _currentPosition = p;
              _markers.removeWhere((m) => m.markerId.value == 'me');
              _userLocationCircle = Circle(
                circleId: const CircleId('me_aura'),
                center: curr,
                radius: 20,
                fillColor: const Color(0xFF2563EB).withOpacity(0.16),
                strokeColor: const Color(0xFF1D4ED8).withOpacity(0.30),
                strokeWidth: 2,
              );
              _markers.add(
                Marker(
                  markerId: const MarkerId('me'),
                  position: curr,
                  icon:
                      _arrowIcon ??
                      BitmapDescriptor.defaultMarkerWithHue(
                        BitmapDescriptor.hueAzure,
                      ),
                  rotation: heading,
                  flat: true,
                  anchor: const Offset(0.5, 0.5),
                ),
              );
            });

            await _focusCameraOnUser(p);

            // Advance step if close to endLocation
            if (_navSteps.isNotEmpty && _currentStepIndex < _navSteps.length) {
              final step = _navSteps[_currentStepIndex];
              final dx = (curr.latitude - step.endLocation.latitude) * 111000;
              final dy = (curr.longitude - step.endLocation.longitude) * 111000;
              final dist = math.sqrt(dx * dx + dy * dy);
              if (dist < 25) {
                setState(() => _currentStepIndex = _currentStepIndex + 1);
                _announcedStepThresholds.remove(_currentStepIndex - 1);
                await _speakCurrentGuidance(force: true, currentPosition: curr);
              }

              await _speakCurrentGuidance(currentPosition: curr);

              // ===== ENHANCED: Deviation detection with new safe route suggestion =====
              // If user deviates from route by >40m, fetch new safe routes and suggest safest
              final nearestDist = _distanceToPolyline(
                curr,
                route.polylinePoints,
              );
              if (nearestDist > 40) {
                print(
                  '[SafeNavigation] 🚨 User deviation detected: ${nearestDist.toStringAsFixed(0)}m off route',
                );

                // Show visual deviation alert
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Row(
                        children: [
                          const Icon(
                            Icons.warning_amber,
                            color: Color(0xFFEF4444),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'You have deviated from the route (${nearestDist.toStringAsFixed(0)}m)',
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                      backgroundColor: const Color(0xFFFEE2E2),
                      behavior: SnackBarBehavior.floating,
                      duration: const Duration(seconds: 5),
                    ),
                  );
                }

                // Fetch new safe routes from current location
                try {
                  print(
                    '[SafeNavigation] Fetching new safe routes from current location...',
                  );
                  final newSafeRoutes = await SafeRoutesService.scoreRoutes(
                    originLat: curr.latitude,
                    originLng: curr.longitude,
                    destLat: dest.latitude,
                    destLng: dest.longitude,
                    travelMode: _travelMode,
                  );

                  if (newSafeRoutes.success &&
                      newSafeRoutes.routes.isNotEmpty) {
                    // Get the safest route (first in the list, already sorted)
                    final safestRoute = DemoRouteScorer.scoreSafeRoutesForUi(
                      newSafeRoutes.routes,
                    ).first;
                    print(
                      '[SafeNavigation] ✅ New safest route found: ${safestRoute.riskBucket} (Score: ${_formatScore(safestRoute)})',
                    );

                    // Get detailed navigation for the new safest route
                    final newRoute = await _directions.getRouteBetweenCoords(
                      curr,
                      dest,
                    );

                    if (newRoute != null) {
                      setState(() {
                        _navSteps = newRoute.steps;
                        _activeNavigationRoute = newRoute;
                        _currentStepIndex = 0;
                        _announcedStepThresholds.clear();
                        _lastSpokenInstruction = null;
                        _selectedRoute = safestRoute;

                        // Update polylines with new route color
                        _polylines.clear();
                        final safetyColor = _getRouteColor(
                          safestRoute.safetyScore,
                        );
                        _polylines.add(
                          Polyline(
                            polylineId: const PolylineId('nav_active'),
                            points: newRoute.polylinePoints,
                            color: safetyColor,
                            width: 8,
                            geodesic: true,
                          ),
                        );
                      });

                      // Show reroute success message
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Row(
                              children: [
                                const Icon(
                                  Icons.check_circle,
                                  color: Color(0xFF10B981),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Text(
                                        'New Route Found',
                                        style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      Text(
                                        '${SafetyFactorsHelper.labelForScore(safestRoute.safetyScore)} • Score: ${_formatScore(safestRoute)}',
                                        style: const TextStyle(fontSize: 12),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            backgroundColor: const Color(0xFFF0FDF4),
                            behavior: SnackBarBehavior.floating,
                            duration: const Duration(seconds: 4),
                          ),
                        );
                      }
                      await _speakCurrentGuidance(
                        force: true,
                        currentPosition: curr,
                      );
                    }
                  }
                } catch (e) {
                  print('[SafeNavigation] Error fetching new routes: $e');
                  // Fallback to simple reroute using directions service
                  final newRoute = await _directions.getRouteBetweenCoords(
                    curr,
                    dest,
                  );
                  if (newRoute != null) {
                    setState(() {
                      _navSteps = newRoute.steps;
                      _activeNavigationRoute = newRoute;
                      _currentStepIndex = 0;
                      _announcedStepThresholds.clear();
                      _lastSpokenInstruction = null;
                      _polylines.clear();
                      _polylines.add(
                        Polyline(
                          polylineId: const PolylineId('nav_active'),
                          points: newRoute.polylinePoints,
                          color: Colors.blue,
                          width: 8,
                          geodesic: true,
                        ),
                      );
                    });
                    await _speakCurrentGuidance(
                      force: true,
                      currentPosition: curr,
                    );
                  }
                }
              }
            }
          });
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Navigation error: $e')));
    }
  }

  double _distanceToPolyline(LatLng point, List<LatLng> poly) {
    if (poly.isEmpty) return double.infinity;
    double minDist = double.infinity;
    for (final p in poly) {
      final dx = (point.latitude - p.latitude) * 111000;
      final dy = (point.longitude - p.longitude) * 111000;
      final d = math.sqrt(dx * dx + dy * dy);
      if (d < minDist) minDist = d;
    }
    return minDist;
  }

  double _haversineDistanceMeters(LatLng a, LatLng b) {
    const R = 6371000; // meters
    final lat1 = a.latitude * math.pi / 180.0;
    final lat2 = b.latitude * math.pi / 180.0;
    final dLat = (b.latitude - a.latitude) * math.pi / 180.0;
    final dLon = (b.longitude - a.longitude) * math.pi / 180.0;
    final x =
        math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1) *
            math.cos(lat2) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    final c = 2 * math.atan2(math.sqrt(x), math.sqrt(1 - x));
    return R * c;
  }

  Future<void> _speak(String text) async {
    if (!_voiceNavigationEnabled || !_ttsReady || text.trim().isEmpty) return;
    if (_lastSpokenInstruction == text) return;
    _lastSpokenInstruction = text;
    try {
      await _tts.stop();
      await _tts.speak(text);
    } catch (e) {
      debugPrint('TTS speak failed: $e');
    }
  }

  String _voiceInstruction(String instruction) {
    final lower = instruction.toLowerCase();
    if (lower.contains('slight left')) return 'slight left';
    if (lower.contains('slight right')) return 'slight right';
    if (lower.contains('keep left')) return 'keep left';
    if (lower.contains('keep right')) return 'keep right';
    if (lower.contains('turn left')) return 'turn left';
    if (lower.contains('turn right')) return 'turn right';
    if (lower.contains('left')) return 'left';
    if (lower.contains('right')) return 'right';
    if (lower.contains('u-turn') || lower.contains('uturn')) {
      return 'make a U-turn';
    }
    if (lower.contains('destination')) return 'you have arrived';
    if (lower.contains('continue') || lower.contains('straight')) {
      return 'continue straight';
    }
    return instruction.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  int _voiceThresholdBucket(double remainingMeters) {
    if (remainingMeters <= 0) return 0;
    if (remainingMeters <= 20) return 20;
    if (remainingMeters <= 50) return 50;
    if (remainingMeters <= 100) return 100;
    if (remainingMeters <= 200) return 200;
    return 0;
  }

  Future<void> _speakCurrentGuidance({
    bool force = false,
    LatLng? currentPosition,
  }) async {
    if (!_voiceNavigationEnabled || _navSteps.isEmpty) return;
    if (_currentStepIndex >= _navSteps.length) return;

    final step = _navSteps[_currentStepIndex];
    final position =
        currentPosition ??
        (_currentPosition == null
            ? null
            : LatLng(_currentPosition!.latitude, _currentPosition!.longitude));
    if (position == null) return;

    final remainingMeters = _haversineDistanceMeters(
      position,
      step.endLocation,
    );
    final bucket = _voiceThresholdBucket(remainingMeters);
    final announced = _announcedStepThresholds.putIfAbsent(
      _currentStepIndex,
      () => <int>{},
    );

    if (!force && bucket == 0) return;
    if (!force && bucket != 0 && announced.contains(bucket)) return;

    final direction = _voiceInstruction(step.instruction);
    final speech = (bucket == 0 || remainingMeters <= 20)
        ? (direction == 'you have arrived' ? direction : 'Now $direction')
        : 'In ${bucket} meters, $direction';

    if (bucket != 0) {
      announced.add(bucket);
    }

    await _speak(speech);
  }

  Future<BitmapDescriptor> _createArrowBitmap() async {
    const int size = 96;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final center = const Offset(size / 2, size / 2);

    final auraPaint = Paint()
      ..color = const Color(0xFF60A5FA).withOpacity(0.18);
    canvas.drawCircle(center, size * 0.42, auraPaint);

    final glowPaint = Paint()
      ..color = const Color(0xFF2563EB).withOpacity(0.24);
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

  Future<void> _loadUnsafeReports() async {
    try {
      _reportCircles.clear();
      _reportMarkers.clear();
      final now = DateTime.now();
      final cutoff = now.subtract(const Duration(hours: 24));
      final snap = await FirebaseFirestore.instance
          .collection('unsafe_reports')
          .where('active', isEqualTo: true)
          .where('reported_at', isGreaterThan: cutoff)
          .get();

      for (final doc in snap.docs) {
        final data = doc.data();
        final lat = (data['lat'] as num?)?.toDouble();
        final lng = (data['lng'] as num?)?.toDouble();
        if (lat == null || lng == null) continue;
        final center = LatLng(lat, lng);

        // Add a translucent red circle
        _reportCircles.add(
          Circle(
            circleId: CircleId('report_${doc.id}'),
            center: center,
            radius: 120,
            fillColor: Colors.red.withOpacity(0.18),
            strokeColor: Colors.red.withOpacity(0.6),
            strokeWidth: 2,
          ),
        );

        // Add a small marker for tap interactions
        _reportMarkers.add(
          Marker(
            markerId: MarkerId('r_${doc.id}'),
            position: center,
            icon: BitmapDescriptor.defaultMarkerWithHue(
              BitmapDescriptor.hueRed,
            ),
            onTap: () {
              // show details as snackbar for now
              final reason = data['reason'] ?? 'Reported';
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(SnackBar(content: Text('Report: $reason')));
            },
          ),
        );
      }

      setState(() {});
    } catch (e) {
      debugPrint('Error loading reports: $e');
    }
  }

  Future<void> _openInGoogleMaps() async {
    if (_selectedRoute == null) return;

    final origin = widget.origin;
    final dest = widget.destination;

    final uri = Uri.parse(
      'https://www.google.com/maps/dir/?api=1&origin=${origin.latitude},${origin.longitude}&destination=${dest.latitude},${dest.longitude}&travelmode=driving',
    );

    try {
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open Google Maps')),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Error opening maps: $e')));
    }
  }

  void _retryFetchRoutes() {
    _fetchSafeRoutes();
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async => true,
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: Colors.white,
          elevation: 1,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.black87),
            onPressed: () => Navigator.pop(context),
          ),
          title: const Text(
            'Safe Routes',
            style: TextStyle(
              color: Colors.black87,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          actions: [
            IconButton(
              icon: const Icon(
                Icons.emergency_share,
                color: Colors.red,
                size: 28,
              ),
              onPressed: () {},
            ),
            IconButton(
              icon: const Icon(Icons.person, color: Colors.black87),
              onPressed: () {},
            ),
            const SizedBox(width: 8),
          ],
        ),
        body: _isLoading
            ? const Center(
                child: CircularProgressIndicator(color: Color(0xFF6B46C1)),
              )
            : _error != null
            ? Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(
                      Icons.error_outline,
                      size: 60,
                      color: Colors.red,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Error: $_error',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 14),
                    ),
                    const SizedBox(height: 20),
                    ElevatedButton(
                      onPressed: _retryFetchRoutes,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF6B46C1),
                      ),
                      child: const Text(
                        'Retry',
                        style: TextStyle(color: Colors.white),
                      ),
                    ),
                  ],
                ),
              )
            : Stack(
                children: [
                  GoogleMap(
                    onMapCreated: (controller) => _mapController = controller,
                    initialCameraPosition: CameraPosition(
                      target: widget.origin,
                      zoom: 12,
                    ),
                    polylines: _polylines,
                    markers: _markers.union(_reportMarkers),
                    circles: {
                      ..._reportCircles,
                      if (_userLocationCircle != null) _userLocationCircle!,
                    },
                    myLocationButtonEnabled: true,
                    myLocationEnabled: false,
                    zoomControlsEnabled: false,
                  ),
                  if (_navigating && _navSteps.isNotEmpty)
                    // Navigation status panel
                    Positioned(
                      left: 14,
                      right: 14,
                      bottom: 114,
                      child: Material(
                        color: Colors.transparent,
                        elevation: 8,
                        borderRadius: BorderRadius.circular(22),
                        child: Container(
                          decoration: BoxDecoration(
                            color: const Color(0xFFF9FBFF),
                            borderRadius: BorderRadius.circular(22),
                            border: Border.all(color: const Color(0xFFDCEBFF)),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 12,
                            ),
                            child: Row(
                              children: [
                                Container(
                                  width: 42,
                                  height: 42,
                                  decoration: BoxDecoration(
                                    color: const Color(
                                      0xFF2563EB,
                                    ).withOpacity(0.12),
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(
                                    Icons.navigation,
                                    color: Color(0xFF2563EB),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        _currentStepIndex < _navSteps.length
                                            ? _navSteps[_currentStepIndex]
                                                  .instruction
                                            : 'You have arrived',
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w800,
                                          fontSize: 15,
                                        ),
                                      ),
                                      const SizedBox(height: 6),
                                      Wrap(
                                        spacing: 10,
                                        runSpacing: 6,
                                        children: [
                                          _buildNavMetricChip(
                                            icon: Icons.straighten,
                                            label:
                                                _activeNavigationRoute
                                                    ?.distance ??
                                                (_currentPosition != null
                                                    ? '${(_haversineDistanceMeters(LatLng(_currentPosition!.latitude, _currentPosition!.longitude), widget.destination) / 1000).toStringAsFixed(1)} km'
                                                    : '--'),
                                            color: const Color(0xFF0F766E),
                                          ),
                                          _buildNavMetricChip(
                                            icon: Icons.schedule,
                                            label:
                                                _activeNavigationRoute
                                                    ?.duration ??
                                                '--',
                                            color: const Color(0xFF7C3AED),
                                          ),
                                          _buildNavMetricChip(
                                            icon: Icons.alt_route,
                                            label:
                                                '${_currentStepIndex + 1}/${_navSteps.length}',
                                            color: const Color(0xFF2563EB),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  // Bottom sheet with route cards (toggleable)
                  if (_routesPanelOpen)
                    DraggableScrollableSheet(
                      initialChildSize: 0.35,
                      minChildSize: 0.25,
                      maxChildSize: 0.7,
                      builder: (context, scrollController) {
                        return Container(
                          decoration: const BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.only(
                              topLeft: Radius.circular(20),
                              topRight: Radius.circular(20),
                            ),
                          ),
                          child: ListView(
                            controller: scrollController,
                            padding: const EdgeInsets.all(16),
                            children: [
                              // Handle bar
                              Center(
                                child: Container(
                                  width: 40,
                                  height: 4,
                                  decoration: BoxDecoration(
                                    color: Colors.grey[300],
                                    borderRadius: BorderRadius.circular(2),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 16),
                              // Route cards
                              ..._routes.asMap().entries.map((entry) {
                                final index = entry.key;
                                final route = entry.value;
                                final isSelected = _selectedRouteIndex == index;

                                // Get colors based on safety score
                                final color = _getRouteColor(route.safetyScore);
                                final bgColor = color.withOpacity(0.08);

                                // Determine rank badge text
                                final rankBadgeText =
                                    SafetyFactorsHelper.labelForScore(
                                  route.safetyScore,
                                );

                                return Padding(
                                  padding: const EdgeInsets.only(bottom: 12.0),
                                  child: GestureDetector(
                                    onTap: () => _selectRoute(index),
                                    child: Container(
                                      padding: const EdgeInsets.all(16),
                                      decoration: BoxDecoration(
                                        border: Border.all(
                                          color: isSelected
                                              ? color
                                              : Colors.grey[300]!,
                                          width: isSelected ? 2.5 : 1,
                                        ),
                                        borderRadius: BorderRadius.circular(16),
                                        color: isSelected
                                            ? bgColor
                                            : Colors.white,
                                        boxShadow: isSelected
                                            ? [
                                                BoxShadow(
                                                  color: color.withOpacity(0.2),
                                                  blurRadius: 12,
                                                  offset: const Offset(0, 4),
                                                ),
                                              ]
                                            : [],
                                      ),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          // Header row with score badge
                                          Row(
                                            mainAxisAlignment:
                                                MainAxisAlignment.spaceBetween,
                                            children: [
                                              // Safety score circle
                                              Container(
                                                width: 70,
                                                height: 70,
                                                decoration: BoxDecoration(
                                                  color: color,
                                                  shape: BoxShape.circle,
                                                  boxShadow: [
                                                    BoxShadow(
                                                      color: color.withOpacity(
                                                        0.4,
                                                      ),
                                                      blurRadius: 8,
                                                      offset: const Offset(
                                                        0,
                                                        2,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                                child: Column(
                                                  mainAxisAlignment:
                                                      MainAxisAlignment.center,
                                                  children: [
                                                    Text(
                                                      route.safetyScore
                                                          .toStringAsFixed(
                                                            route.safetyScore >
                                                                    1.0
                                                                ? 1
                                                                : 4,
                                                          ),
                                                      style: const TextStyle(
                                                        fontSize: 24,
                                                        fontWeight:
                                                            FontWeight.bold,
                                                        color: Colors.white,
                                                      ),
                                                    ),
                                                    const Text(
                                                      'Score',
                                                      style: TextStyle(
                                                        fontSize: 10,
                                                        color: Colors.white70,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                              // Route info
                                              Expanded(
                                                child: Padding(
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                        horizontal: 14,
                                                      ),
                                                  child: Column(
                                                    crossAxisAlignment:
                                                        CrossAxisAlignment
                                                            .start,
                                                    children: [
                                                      // Rank badge
                                                      Container(
                                                        padding:
                                                            const EdgeInsets.symmetric(
                                                              horizontal: 10,
                                                              vertical: 4,
                                                            ),
                                                        decoration: BoxDecoration(
                                                          color: color
                                                              .withOpacity(
                                                                0.15,
                                                              ),
                                                          borderRadius:
                                                              BorderRadius.circular(
                                                                6,
                                                              ),
                                                          border: Border.all(
                                                            color: color
                                                                .withOpacity(
                                                                  0.3,
                                                                ),
                                                          ),
                                                        ),
                                                        child: Text(
                                                          rankBadgeText,
                                                          style: TextStyle(
                                                            fontWeight:
                                                                FontWeight.bold,
                                                            fontSize: 11,
                                                            color: color,
                                                          ),
                                                        ),
                                                      ),
                                                      const SizedBox(height: 6),
                                                      // Distance and duration
                                                      Text(
                                                        '${route.durationMin.toStringAsFixed(0)} min • ${route.distanceKm.toStringAsFixed(1)} km',
                                                        style: TextStyle(
                                                          fontSize: 13,
                                                          color:
                                                              Colors.grey[700],
                                                          fontWeight:
                                                              FontWeight.w600,
                                                        ),
                                                      ),
                                                      // Risk probability
                                                      const SizedBox(height: 4),
                                                      Text(
                                                        'Risk: ${(route.riskProbability * 100).toStringAsFixed(2)}%',
                                                        style: TextStyle(
                                                          fontSize: 12,
                                                          color:
                                                              Colors.grey[600],
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              ),
                                              // Selection indicator
                                              if (isSelected)
                                                Icon(
                                                  Icons.check_circle,
                                                  color: color,
                                                  size: 28,
                                                ),
                                            ],
                                          ),
                                          const SizedBox(height: 12),
                                          // Explanation text
                                          Container(
                                            padding: const EdgeInsets.all(10),
                                            decoration: BoxDecoration(
                                              color: color.withOpacity(0.05),
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                              border: Border.all(
                                                color: color.withOpacity(0.15),
                                              ),
                                            ),
                                            child: Text(
                                              route.explanation,
                                              style: TextStyle(
                                                fontSize: 12,
                                                color: Colors.grey[700],
                                                height: 1.4,
                                              ),
                                              maxLines: 3,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                          // Action buttons (only when selected)
                                          if (isSelected) ...[
                                            const SizedBox(height: 12),
                                            SizedBox(
                                              width: double.infinity,
                                              child: OutlinedButton.icon(
                                                onPressed: () =>
                                                    _showWhyThisScoreModal(
                                                      route,
                                                    ),
                                                icon: const Icon(
                                                  Icons.info_outline,
                                                ),
                                                label: const Text(
                                                  'Why this score?',
                                                ),
                                                style: OutlinedButton.styleFrom(
                                                  foregroundColor: color,
                                                  side: BorderSide(
                                                    color: color,
                                                  ),
                                                  shape: RoundedRectangleBorder(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          10,
                                                        ),
                                                  ),
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                        vertical: 12,
                                                      ),
                                                ),
                                              ),
                                            ),
                                            const SizedBox(height: 8),
                                            SizedBox(
                                              width: double.infinity,
                                              child: OutlinedButton.icon(
                                                onPressed: _openInGoogleMaps,
                                                icon: const Icon(Icons.map),
                                                label: const Text(
                                                  'Open in Google Maps',
                                                ),
                                                style: OutlinedButton.styleFrom(
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                        vertical: 12,
                                                      ),
                                                  shape: RoundedRectangleBorder(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          10,
                                                        ),
                                                  ),
                                                ),
                                              ),
                                            ),
                                            const SizedBox(height: 8),
                                            SizedBox(
                                              width: double.infinity,
                                              child: ElevatedButton(
                                                onPressed: _startNavigation,
                                                style: ElevatedButton.styleFrom(
                                                  backgroundColor: color,
                                                  shape: RoundedRectangleBorder(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          10,
                                                        ),
                                                  ),
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                        vertical: 14,
                                                      ),
                                                ),
                                                child: const Text(
                                                  'Start Navigation',
                                                  style: TextStyle(
                                                    color: Colors.white,
                                                    fontWeight: FontWeight.w700,
                                                    fontSize: 15,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                  ),
                                );
                              }).toList(),
                            ],
                          ),
                        );
                      },
                    ),
                  if (!_routesPanelOpen)
                    Positioned(
                      left: 14,
                      bottom: 18,
                      child: SafeArea(
                        top: false,
                        child: ElevatedButton.icon(
                          onPressed: () =>
                              setState(() => _routesPanelOpen = true),
                          icon: const Icon(Icons.route),
                          label: const Text('All safe routes'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF0F766E),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 14,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(18),
                            ),
                            elevation: 5,
                          ),
                        ),
                      ),
                    ),
                  Positioned(
                    right: 14,
                    bottom: 18,
                    child: SafeArea(
                      top: false,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          FloatingActionButton.small(
                            heroTag: 'recenter_nav',
                            onPressed: () async {
                              if (_currentPosition == null) return;
                              await _focusCameraOnUser(
                                _currentPosition!,
                                animate: true,
                              );
                            },
                            backgroundColor: Colors.white,
                            foregroundColor: const Color(0xFF2563EB),
                            child: const Icon(Icons.my_location),
                          ),
                          const SizedBox(height: 10),
                          FloatingActionButton.small(
                            heroTag: 'routes_refresh',
                            onPressed: () =>
                                setState(() => _routesPanelOpen = true),
                            backgroundColor: Colors.white,
                            foregroundColor: const Color(0xFF0F766E),
                            child: const Icon(Icons.layers_outlined),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _mapController?.dispose();
    _tts.stop();
    super.dispose();
  }
}

class WhyThisScoreModal extends StatelessWidget {
  final SafeRoute route;

  const WhyThisScoreModal({super.key, required this.route});

  String _scoreValue() {
    if (route.safetyScore > 1.0) {
      return route.safetyScore.toStringAsFixed(1);
    }
    return route.safetyScore.toStringAsFixed(4);
  }

  @override
  Widget build(BuildContext context) {
    final colors = {
      'SAFE': const Color(0xFF10B981),
      'MODERATE': const Color(0xFFF59E0B),
      'DANGEROUS': const Color(0xFFEF4444),
    };
    final color = colors[route.riskBucket] ?? Colors.grey;
    final factors = SafetyFactorsHelper.factorsForRoute(route);

    return AlertDialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Why this score?',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
                GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: const Icon(Icons.close),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: color.withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: color),
              ),
              child: Column(
                children: [
                  Text(
                    _scoreValue(),
                    style: TextStyle(
                      fontSize: 36,
                      fontWeight: FontWeight.bold,
                      color: color,
                    ),
                  ),
                  Text(
                    'Route score • ${SafetyFactorsHelper.modalLabelForScore(route.safetyScore)}',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: color,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    route.explanation,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Reasons behind this score',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: Colors.grey[800],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Column(
              children: factors
                  .map(
                    (factor) => Padding(
                      padding: const EdgeInsets.only(bottom: 9),
                      child: Row(
                        children: [
                          Icon(Icons.check_circle, color: color, size: 18),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              factor.title,
                              style: TextStyle(
                                color: Colors.grey[850],
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          Text(
                            factor.value,
                            style: TextStyle(
                              color: const Color(0xFF059669),
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                  .toList(),
            ),
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey.shade50,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.grey.shade200),
              ),
              child: Text(
                'This score reflects route factors such as danger reports, incident density, isolation, nearby activity, and time-of-day risk.',
                style: TextStyle(fontSize: 12, color: Colors.grey[700]),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
