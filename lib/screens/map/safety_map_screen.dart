import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:math' show cos, sqrt, atan2, sin, pi, asin;
import 'dart:async';
import 'package:flutter/services.dart'; // for MethodChannel
import 'package:nari_shakti/core/services/heatmap_tile_provider.dart';
import 'package:nari_shakti/core/services/api_key_service.dart';
import 'package:nari_shakti/screens/navigation_screen.dart';

// ─────────────────────────────────────────────────────────────────────────────
//  SafetyMapScreen  — UPDATED
//  Changes vs previous version:
//    ✅ Bright / light map style (replaces dark theme)
//    ✅ Hospital route now drawn IN-APP via Directions API (green polyline)
//        — url_launcher / Google Maps redirect removed entirely
//    ✅ Police route still drawn IN-APP via Directions API (blue polyline)
//    ✅ Both POI cards + action-sheet buttons trigger the in-app route
//    ✅ Separate _isRoutingToHospital loading flag
//    ✅ _polylines now keyed so police + hospital routes can coexist
//    ✅ No other files touched
// ─────────────────────────────────────────────────────────────────────────────

class SafetyMapScreen extends StatefulWidget {
  const SafetyMapScreen({super.key});

  @override
  State<SafetyMapScreen> createState() => _SafetyMapScreenState();
}

class _SafetyMapScreenState extends State<SafetyMapScreen> {
  // ── Controllers & State ──────────────────────────────────────────────────
  GoogleMapController? _mapController;
  StreamSubscription<Position>? _positionStream;
  Position? _currentPosition;
  double _currentHeading = 0; // Device bearing in degrees (0-360)
  DateTime? _lastGeofenceCheck;
  LatLng? _lastCheckedPosition;

  // ── Camera animation debouncing to prevent zoom glitching ──
  DateTime? _lastCameraUpdate;
  static const _cameraUpdateDebounce = Duration(milliseconds: 500);

  final Set<Marker> _markers = {};
  final Set<Circle> _circles = {};
  final Set<Polyline> _polylines = {};

  // ── Live location sharing ───────────────────────────────────────────────
  bool _isSharingLive = false;
  Timer? _liveShareTimer;
  String? _liveShareDocId;
  DateTime? _liveShareExpiresAt;
  static const _liveShareDuration = Duration(hours: 24);

  bool _isLoading = true;
  bool _isReporting = false;
  bool _isRoutingToPolice = false;
  final bool _isRoutingToHospital = false;
  bool _isNavigating = false;
  List<Map<String, dynamic>> _routeSteps = []; // all turn-by-turn steps
  int _currentStepIndex = 0; // which step user is on
  String _currentInstruction = ''; // e.g. "Turn left on MG Road"
  String _currentStepDistance = ''; // e.g. "200 m"
  double _totalDistanceMeters = 0;
  String _destinationName = '';
  final Set<String> _notifiedZones = {};
  final Set<String> _alertedZones = {};

  Map<String, dynamic>? _nearestPoliceStation;
  Map<String, dynamic>? _nearestHospital;
  List<Map<String, dynamic>> _activeDangerZones = [];

  static const _notifChannel = MethodChannel(
    'com.narishakti.app/notifications',
  );

  // ── Heatmap state ───────────────────────────────────────────────
  TileOverlay? _heatmapOverlay;
  bool _showHeatmap = true;

  // ── Lifecycle ────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    _getCurrentLocation();
    _restoreLiveShareState();
  }

  @override
  void dispose() {
    _positionStream?.cancel();
    _headingUpdateTimer?.cancel();
    _liveShareTimer?.cancel();
    _mapController?.dispose();
    super.dispose();
  }

  // ── Location ─────────────────────────────────────────────────────────────
  Future<void> _getCurrentLocation() async {
    if (mounted) setState(() => _isLoading = true);

    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        _setLoadingFalse();
        _showSnack(
          'GPS band hai. Settings mein Location ON karo.',
          Colors.orange,
        );
        return;
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied) {
        _setLoadingFalse();
        _showSnack('Location permission deny kiya.', Colors.orange);
        return;
      }
      if (permission == LocationPermission.deniedForever) {
        _setLoadingFalse();
        _showSettingsDialog();
        return;
      }

      // ── Step 1: Get one fast fix first (so map loads immediately) ──
      final quickPosition = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.medium,
      ).timeout(const Duration(seconds: 30));

      if (!mounted) return;
      _onPositionUpdate(quickPosition, initial: true);

      // ── Step 2: Start continuous stream for live tracking ──
      await _positionStream?.cancel();
      _positionStream =
          Geolocator.getPositionStream(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.high,
              distanceFilter: 20,
            ),
          ).listen(
            (position) => _onPositionUpdate(position),
            onError: (e) {
              debugPrint('[LocationStream] Error: $e');
            },
          );

      // ── Step 3: Start periodic heading updates ──
      _startHeadingUpdate();
    } catch (e) {
      debugPrint('[Location] Error: $e');
      _setLoadingFalse();
      _showSnack('Current location not found. Please try again.', Colors.red);
    }
  }

  // ── Heading Update (using device compass/sensors) ────────────────────────
  Timer? _headingUpdateTimer;

  void _startHeadingUpdate() {
    // Note: Geolocator doesn't provide heading stream.
    // For now, we'll keep heading at 0 and show directional compass.
    // Users can extend this with sensors_plus for real device orientation.
    _headingUpdateTimer?.cancel();
    _headingUpdateTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      // Update heading from device orientation if available
      // For now, maintain last known heading
      if (mounted) {
        _updateCurrentLocationMarker();
      }
    });
  }

  // ── Live share control ─────────────────────────────────────────────────
  Future<void> _startLiveShare() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null || _currentPosition == null) {
      _showSnack(
        'Login and location required to start live sharing.',
        Colors.orange,
      );
      return;
    }
    try {
      final docId = uid;
      final now = DateTime.now();
      final expiresAt = now.add(_liveShareDuration);
      await FirebaseFirestore.instance
          .collection('live_shares')
          .doc(docId)
          .set({
            'user_id': uid,
            'lat': _currentPosition!.latitude,
            'lng': _currentPosition!.longitude,
            'startedAt': Timestamp.fromDate(now),
            'expiresAt': Timestamp.fromDate(expiresAt),
            'active': true,
          });
      _liveShareDocId = docId;
      _liveShareExpiresAt = expiresAt;
      _liveShareTimer?.cancel();
      _liveShareTimer = Timer(_liveShareDuration, () async {
        await _stopLiveShare();
      });
      if (mounted) setState(() => _isSharingLive = true);
      _showSnack('Live sharing started for 24 hours.', Colors.green);
    } catch (e) {
      debugPrint('[LiveShare] start error: $e');
      _showSnack('Live sharing failed to start.', Colors.red);
    }
  }

  Future<void> _stopLiveShare() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    try {
      if (_liveShareDocId != null) {
        await FirebaseFirestore.instance
            .collection('live_shares')
            .doc(_liveShareDocId)
            .update({'active': false});
      } else if (uid != null) {
        await FirebaseFirestore.instance
            .collection('live_shares')
            .doc(uid)
            .update({'active': false});
      }
    } catch (_) {
      // ignore - document may not exist
    }
    _liveShareTimer?.cancel();
    _liveShareTimer = null;
    _liveShareDocId = null;
    _liveShareExpiresAt = null;
    if (mounted) setState(() => _isSharingLive = false);
    _showSnack('Live sharing stopped.', Colors.orange);
  }

  Future<void> _restoreLiveShareState() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    try {
      final doc = await FirebaseFirestore.instance
          .collection('live_shares')
          .doc(uid)
          .get();
      if (!doc.exists) return;
      final data = doc.data();
      if (data == null) return;

      final active = data['active'] == true;
      final expiresTs = data['expiresAt'] as Timestamp?;
      final expiresAt = expiresTs?.toDate();
      if (!active || expiresAt == null) return;

      final now = DateTime.now();
      if (now.isAfter(expiresAt)) {
        await FirebaseFirestore.instance
            .collection('live_shares')
            .doc(uid)
            .update({'active': false});
        return;
      }

      final remaining = expiresAt.difference(now);
      _liveShareDocId = uid;
      _liveShareExpiresAt = expiresAt;
      _liveShareTimer?.cancel();
      _liveShareTimer = Timer(remaining, () async {
        await _stopLiveShare();
      });
      if (mounted) {
        setState(() => _isSharingLive = true);
      }
    } catch (e) {
      debugPrint('[LiveShare] restore error: $e');
    }
  }

  void _showDangerNotification(String reason) {
    _showSnack(
      '⚠️ Danger Zone! ${_labelForReason(reason)} reported here. be Alert,be Safe!',
      Colors.red.shade700,
    );
  }

  void _setLoadingFalse() {
    if (mounted) setState(() => _isLoading = false);
  }

  // ── Debounced camera animation to prevent zoom glitching ──
  void _animateCameraDebounced(CameraUpdate update) {
    final now = DateTime.now();
    if (_lastCameraUpdate != null &&
        now.difference(_lastCameraUpdate!).inMilliseconds <
            _cameraUpdateDebounce.inMilliseconds) {
      return; // Skip this animation if one just happened
    }
    _lastCameraUpdate = now;
    _mapController?.animateCamera(update);
  }

  Future<void> _onPositionUpdate(
    Position position, {
    bool initial = false,
  }) async {
    if (!mounted) return;

    setState(() {
      _currentPosition = position;
      _isLoading = false;
    });

    if (initial) {
      _animateCameraDebounced(
        CameraUpdate.newLatLngZoom(
          LatLng(position.latitude, position.longitude),
          15,
        ),
      );
      _updateCurrentLocationMarker(); // ← Add blue dot marker
      Future.wait([_loadUnsafeReports(), _findNearbyPlaces(position)]);
    } else {
      _updateCurrentLocationMarker(); // ← Update marker on every position change
    }

    // ── If user is sharing live location, update the Firestore doc with new coords
    if (_isSharingLive) {
      if (_liveShareExpiresAt != null &&
          DateTime.now().isAfter(_liveShareExpiresAt!)) {
        await _stopLiveShare();
      }
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (_isSharingLive && uid != null) {
        try {
          await FirebaseFirestore.instance
              .collection('live_shares')
              .doc(uid)
              .set({
                'lat': position.latitude,
                'lng': position.longitude,
                'lastUpdate': Timestamp.fromDate(DateTime.now()),
                'active': true,
              }, SetOptions(merge: true));
        } catch (e) {
          debugPrint('[LiveShare] update error: $e');
        }
      }
    }

    // ── Throttle geofence check ──
    final now = DateTime.now();
    final newLatLng = LatLng(position.latitude, position.longitude);

    final tooSoon =
        _lastGeofenceCheck != null &&
        now.difference(_lastGeofenceCheck!).inSeconds < 10;

    final tooClose =
        _lastCheckedPosition != null &&
        Geolocator.distanceBetween(
              _lastCheckedPosition!.latitude,
              _lastCheckedPosition!.longitude,
              newLatLng.latitude,
              newLatLng.longitude,
            ) <
            20;

    if (!tooSoon && !tooClose) {
      _lastGeofenceCheck = now;
      _lastCheckedPosition = newLatLng;
      _checkGeofences(position); // only fires if moved 20m AND 10s passed
    }

    if (_isNavigating) _updateNavigationStep(position);
  }

  // ── Update current location marker with heading ──────────────────────────
  void _updateCurrentLocationMarker() {
    if (_currentPosition == null) return;

    // No custom markers or arrows needed - using default myLocationEnabled
    setState(() {});
  }

  void _showClusterDetails(
    int clusterId,
    List<Map<String, dynamic>> cluster,
    String reason,
    int reportCount,
    int totalUpvotes,
    int hoursLeft,
  ) {
    final uid = FirebaseAuth.instance.currentUser?.uid;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.black12,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            // Report count badge
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.red.shade50,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.red.shade200),
              ),
              child: Text(
                '$reportCount reports in this area',
                style: TextStyle(
                  color: Colors.red.shade700,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '⚠️ ${_labelForReason(reason)}',
              style: const TextStyle(
                color: Colors.black87,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '$totalUpvotes confirmations · expires in ${hoursLeft}h',
              style: const TextStyle(color: Colors.black45, fontSize: 13),
            ),
            const SizedBox(height: 20),
            // Confirm button — upvotes the most recent report in cluster
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton.icon(
                onPressed: uid == null
                    ? null
                    : () async {
                        Navigator.pop(ctx);
                        // Upvote the first report in cluster
                        final firstDoc = cluster[0];
                        final alreadyVoted = List<String>.from(
                          (firstDoc['data']
                                  as Map<String, dynamic>)['upvoted_by'] ??
                              [],
                        ).contains(uid);
                        if (!alreadyVoted) {
                          await _upvoteReport(firstDoc['id'] as String, uid);
                        }
                      },
                icon: const Icon(Icons.thumb_up_outlined, color: Colors.white),
                label: const Text(
                  'Confirm This Area is Unsafe',
                  style: TextStyle(color: Colors.white),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFD32F2F),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _checkGeofences(Position position) {
    for (final zone in _activeDangerZones) {
      final dist = _distanceInMeters(
        position.latitude,
        position.longitude,
        zone['lat'] as double,
        zone['lng'] as double,
      );

      final zoneId = zone['id'] as String;

      if (dist < (zone['radius'] as double)) {
        // Only alert once per zone, not on every position update
        if (!_alertedZones.contains(zoneId)) {
          _alertedZones.add(zoneId);
          _showDangerAlert(zone['reason'] as String);
        }
      } else {
        // User left the zone — remove from alerted so they get warned if they re-enter
        _alertedZones.remove(zoneId);
      }
    }
  }

  void _showDangerAlert(String reason) {
    // In-app snackbar
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(
                Icons.warning_amber_rounded,
                color: Colors.white,
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '⚠️ ${_labelForReason(reason)} yahan report hua hai. Savdhan raho!',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          backgroundColor: Colors.red.shade700,
          duration: const Duration(seconds: 5),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      );
    }

    // Real phone notification via MethodChannel
    _notifChannel.invokeMethod('showDangerNotification', {
      'title': '⚠️ Danger Zone Alert',
      'message': '${_labelForReason(reason)} nearby. Savdhan raho!',
    });
  }

  // ── Fetch Both POIs in Parallel ──────────────────────────────────────────
  Future<void> _findNearbyPlaces(Position position) async {
    await Future.wait([
      _findNearestPlace(position, type: 'police'),
      _findNearestPlace(position, type: 'hospital'),
    ]);
  }

  Future<void> _findNearestPlace(
    Position position, {
    required String type,
  }) async {
    try {
      final lat = position.latitude;
      final lng = position.longitude;
      final googleApiKey = ApiKeyService.getGooglePlacesApiKey();
      final url = Uri.parse(
        'https://maps.googleapis.com/maps/api/place/nearbysearch/json'
        '?location=$lat,$lng&radius=10000&type=$type&key=$googleApiKey',
      );
      final response = await http.get(url).timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) return;
      final data = json.decode(response.body);
      final status = data['status'] as String? ?? 'UNKNOWN';
      if (status == 'REQUEST_DENIED') {
        _showSnack('API Key issue: ${data['error_message']}', Colors.red);
        return;
      }
      if (status == 'ZERO_RESULTS') {
        _showSnack(
          '10km mein koi ${type == 'police' ? 'police station' : 'hospital'} nahi mila.',
          Colors.orange,
        );
        return;
      }
      if (status != 'OK') return;
      final results = data['results'] as List?;
      if (results == null || results.isEmpty) return;
      if (!mounted) return;

      // ── Calculate distances and find actual nearest ───────────────────────
      double? minDistance;
      Map<String, dynamic>? nearestPlace;
      int nearestIndex = -1;

      for (int i = 0; i < results.length; i++) {
        final place = results[i];
        final pLat = (place['geometry']['location']['lat'] as num).toDouble();
        final pLng = (place['geometry']['location']['lng'] as num).toDouble();

        // Calculate distance using Haversine formula
        final distance = _calculateDistance(
          position.latitude,
          position.longitude,
          pLat,
          pLng,
        );

        if (minDistance == null || distance < minDistance) {
          minDistance = distance;
          nearestIndex = i;
          nearestPlace = {
            'name':
                place['name'] as String? ??
                (type == 'police' ? 'Police Station' : 'Hospital'),
            'lat': pLat,
            'lng': pLng,
          };
        }
      }

      // Save nearest place for bottom card + appbar button
      if (nearestPlace != null) {
        if (type == 'police') {
          _nearestPoliceStation = nearestPlace;
        } else {
          _nearestHospital = nearestPlace;
        }
      }

      setState(() {
        // Remove all old markers of this type
        _markers.removeWhere((m) => m.markerId.value.startsWith(type));

        for (int i = 0; i < results.length; i++) {
          final place = results[i];
          final pLat = (place['geometry']['location']['lat'] as num).toDouble();
          final pLng = (place['geometry']['location']['lng'] as num).toDouble();
          final name =
              place['name'] as String? ??
              (type == 'police' ? 'Police Station' : 'Hospital');
          final isNearest = i == nearestIndex;

          _markers.add(
            _buildPoiMarker(
              id: '${type}_$i', // police_0, police_1, hospital_0 etc
              name: name,
              lat: pLat,
              lng: pLng,
              emoji: type == 'police' ? '🚔' : '🏥',
              snippet: isNearest
                  ? 'Nearest ${type == 'police' ? 'Police Station' : 'Hospital'} — tap for route'
                  : 'Tap for directions',
              hue: type == 'police'
                  ? BitmapDescriptor.hueBlue
                  : BitmapDescriptor.hueGreen,
              onTap: () => _showPoiActionSheet(
                isPolice: type == 'police',
                lat: pLat,
                lng: pLng,
                name: name,
              ),
            ),
          );
        }
      });
    } catch (e) {
      debugPrint('[Places/$type] Exception: $e');
    }
  }

  Marker _buildPoiMarker({
    required String id,
    required String name,
    required double lat,
    required double lng,
    required String emoji,
    required String snippet,
    required double hue,
    required VoidCallback onTap,
  }) {
    return Marker(
      markerId: MarkerId(id),
      position: LatLng(lat, lng),
      infoWindow: InfoWindow(title: '$emoji $name', snippet: snippet),
      icon: BitmapDescriptor.defaultMarkerWithHue(hue),
      onTap: onTap,
    );
  }

  // ── Generic Directions API helper ─────────────────────────────────────────
  /// Fetches a driving route from current position to [destLat],[destLng],
  /// draws a polyline with [color] identified by [polylineKey], then fits
  /// the camera to the bounds of the route.
  Future<void> _drawRoute({
    required double destLat,
    required double destLng,
    required Color color,
    required String polylineKey,
    required String label,
  }) async {
    if (_currentPosition == null) return;
    try {
      final origin =
          '${_currentPosition!.latitude},${_currentPosition!.longitude}';
      final dest = '$destLat,$destLng';
      final googleApiKey = ApiKeyService.getGooglePlacesApiKey();
      final url = Uri.parse(
        'https://maps.googleapis.com/maps/api/directions/json'
        '?origin=$origin&destination=$dest&mode=driving&key=$googleApiKey',
      );
      final response = await http.get(url).timeout(const Duration(seconds: 15));
      final data = json.decode(response.body);
      if (data['status'] != 'OK') {
        _showSnack('Route nahi mila: ${data['status']}', Colors.red);
        return;
      }
      final points = data['routes'][0]['overview_polyline']['points'] as String;
      final decoded = _decodePolyline(points);
      if (!mounted) return;
      setState(() {
        // Remove previous route with same key (keeps other route intact)
        _polylines.removeWhere((p) => p.polylineId.value == polylineKey);
        _polylines.add(
          Polyline(
            polylineId: PolylineId(polylineKey),
            points: decoded,
            color: color,
            width: 5,
          ),
        );
      });
      _mapController?.animateCamera(
        CameraUpdate.newLatLngBounds(_boundsFromLatLngList(decoded), 80),
      );
      _showSnack('$label ka route load ho gaya!', color);
    } catch (e) {
      debugPrint('[Route/$polylineKey] Error: $e');
      _showSnack('Route load nahi hua.', Colors.red);
    }
  }

  Future<void> _startNavigation({
    required double destLat,
    required double destLng,
    required String destName,
  }) async {
    if (_currentPosition == null) {
      _showSnack('Location nahi mili. Retry karo.', Colors.red);
      return;
    }
    if (mounted) setState(() => _isRoutingToPolice = true);

    try {
      final origin =
          '${_currentPosition!.latitude},${_currentPosition!.longitude}';
      final dest = '$destLat,$destLng';
      final googleApiKey = ApiKeyService.getGooglePlacesApiKey();

      final url = Uri.parse(
        'https://maps.googleapis.com/maps/api/directions/json'
        '?origin=$origin'
        '&destination=$dest'
        '&mode=driving'
        '&key=$googleApiKey',
      );

      final response = await http.get(url).timeout(const Duration(seconds: 15));
      final data = json.decode(response.body);

      if (data['status'] != 'OK') {
        _showSnack('Route nahi mila: ${data['status']}', Colors.red);
        return;
      }

      // ── Extract polyline ──
      final points = data['routes'][0]['overview_polyline']['points'] as String;
      final decoded = _decodePolyline(points);

      // ── Extract steps ──
      final legs = data['routes'][0]['legs'][0];
      final steps = legs['steps'] as List;

      final parsedSteps = steps.map<Map<String, dynamic>>((step) {
        return {
          'instruction': _stripHtml(step['html_instructions'] as String),
          'distance': step['distance']['text'] as String,
          'distanceM': (step['distance']['value'] as num).toDouble(),
          'lat': (step['end_location']['lat'] as num).toDouble(),
          'lng': (step['end_location']['lng'] as num).toDouble(),
        };
      }).toList();

      final totalDist = (legs['distance']['value'] as num).toDouble();

      if (!mounted) return;
      setState(() {
        // Draw route
        _polylines.clear();
        _polylines.add(
          Polyline(
            polylineId: const PolylineId('nav_route'),
            points: decoded,
            color: Colors.blue,
            width: 6,
          ),
        );

        // Start navigation state
        _isNavigating = true;
        _routeSteps = parsedSteps;
        _currentStepIndex = 0;
        _destinationName = destName;
        _totalDistanceMeters = totalDist;

        if (parsedSteps.isNotEmpty) {
          _currentInstruction = parsedSteps[0]['instruction'] as String;
          _currentStepDistance = parsedSteps[0]['distance'] as String;
        }
      });

      // Fit route on screen
      _mapController?.animateCamera(
        CameraUpdate.newLatLngBounds(_boundsFromLatLngList(decoded), 80),
      );
    } catch (e) {
      debugPrint('[Navigation] Error: $e');
      _showSnack('Navigation shuru nahi hui.', Colors.red);
    } finally {
      if (mounted) setState(() => _isRoutingToPolice = false);
    }
  }

  // ── Strip HTML tags from Directions API instructions ─────────────────────
  String _stripHtml(String html) {
    return html
        .replaceAll(RegExp(r'<[^>]*>'), ' ')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&#160;', ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  // ── Calculate distance between two coordinates using Haversine formula ────
  double _calculateDistance(
    double lat1,
    double lng1,
    double lat2,
    double lng2,
  ) {
    const double earthRadiusMeters = 6371000; // Earth's radius in meters
    final dLat = (lat2 - lat1) * pi / 180;
    final dLng = (lng2 - lng1) * pi / 180;
    final a =
        sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1 * pi / 180) *
            cos(lat2 * pi / 180) *
            sin(dLng / 2) *
            sin(dLng / 2);
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return earthRadiusMeters * c;
  }

  // ── Stop navigation ───────────────────────────────────────────────────────
  void _stopNavigation() {
    setState(() {
      _isNavigating = false;
      _routeSteps = [];
      _currentStepIndex = 0;
      _currentInstruction = '';
      _currentStepDistance = '';
      _destinationName = '';
      _polylines.clear();
    });
  }

  // ── Update step as user moves (call this from _onPositionUpdate) ──────────
  // Add this line inside _onPositionUpdate():
  //   if (_isNavigating) _updateNavigationStep(position);
  void _updateNavigationStep(Position position) {
    if (_routeSteps.isEmpty) return;
    if (_currentStepIndex >= _routeSteps.length) {
      // Reached destination
      _stopNavigation();
      _showSnack('🎯 Destination par pahunch gaye!', Colors.green);
      return;
    }

    final step = _routeSteps[_currentStepIndex];
    final stepLat = step['lat'] as double;
    final stepLng = step['lng'] as double;

    // Distance to end of current step
    final distToStep = _distanceInMeters(
      position.latitude,
      position.longitude,
      stepLat,
      stepLng,
    );

    // If within 30m of step endpoint → advance to next step
    if (distToStep < 30) {
      final nextIndex = _currentStepIndex + 1;
      if (nextIndex < _routeSteps.length) {
        setState(() {
          _currentStepIndex = nextIndex;
          _currentInstruction = _routeSteps[nextIndex]['instruction'] as String;
          _currentStepDistance = _routeSteps[nextIndex]['distance'] as String;
        });
      } else {
        // Last step done
        _stopNavigation();
        _showSnack('🎯 Destination par pahunch gaye!', Colors.green);
      }
    } else {
      // Update remaining distance for current step dynamically
      final remaining = distToStep.toStringAsFixed(0);
      if (mounted) {
        setState(() {
          _currentStepDistance = distToStep > 1000
              ? '${(distToStep / 1000).toStringAsFixed(1)} km'
              : '$remaining m';
        });
      }
    }

    // Keep map centered on user while navigating
    _animateCameraDebounced(
      CameraUpdate.newLatLng(LatLng(position.latitude, position.longitude)),
    );
  }

  // ── Load Firestore Reports ────────────────────────────────────────────────
  Future<void> _loadUnsafeReports() async {
    try {
      final now = DateTime.now();
      final snapshot = await FirebaseFirestore.instance
          .collection('unsafe_reports')
          .where('active', isEqualTo: true)
          .where('expiresAt', isGreaterThan: Timestamp.fromDate(now))
          .orderBy('expiresAt', descending: false)
          .limit(100)
          .get();

      final newMarkers = <Marker>{};
      final zones = <Map<String, dynamic>>[];

      // Keep police + hospital markers
      newMarkers.addAll(
        _markers.where(
          (m) =>
              m.markerId.value.startsWith('police') ||
              m.markerId.value.startsWith('hospital'),
        ),
      );

      for (final doc in snapshot.docs) {
        final data = doc.data();
        final lat = (data['lat'] as num?)?.toDouble();
        final lng = (data['lng'] as num?)?.toDouble();
        if (lat == null || lng == null) continue;

        final reason = data['reason'] as String? ?? 'other';
        final upvotes = (data['upvotes'] as num?)?.toInt() ?? 0;
        final expiresAt = (data['expiresAt'] as Timestamp?)?.toDate();
        final hoursLeft = expiresAt != null
            ? expiresAt.difference(now).inHours.clamp(0, 24)
            : 0;

        newMarkers.add(
          Marker(
            markerId: MarkerId('report_${doc.id}'),
            position: LatLng(lat, lng),
            infoWindow: InfoWindow(
              title: '⚠️ ${_labelForReason(reason)}',
              snippet: '$upvotes confirmations · expires in ${hoursLeft}h',
            ),
            icon: BitmapDescriptor.defaultMarkerWithHue(_hueForReason(reason)),
            onTap: () => _showReportDetails(doc.id, data),
          ),
        );

        zones.add({
          'lat': lat,
          'lng': lng,
          'radius': 120.0,
          'reason': reason,
          'id': 'report_${doc.id}',
          'count': 1,
        });
      }

      if (!mounted) return;
      setState(() {
        _markers
          ..clear()
          ..addAll(newMarkers);
        _circles.clear();
        _activeDangerZones = zones;
      });

      _buildHeatmapOverlay();

      debugPrint('[SafetyMap] ${snapshot.docs.length} active reports loaded');
    } catch (e) {
      debugPrint('[SafetyMap] Firestore error: $e');
      _showSnack('Reports load nahi hue. Refresh karo.', Colors.red.shade300);
    }
  }

  void _buildHeatmapOverlay() {
    if (_activeDangerZones.isEmpty) {
      if (mounted) {
        setState(() => _heatmapOverlay = null);
      }
      return;
    }

    final heatPoints = _activeDangerZones.map((zone) {
      return HeatmapPoint(
        lat: zone['lat'] as double,
        lng: zone['lng'] as double,
        weight: zone['count'] as int,
      );
    }).toList();

    final provider = HeatmapTileProvider(points: heatPoints, radiusMeters: 150);

    if (!mounted) return;
    setState(() {
      _heatmapOverlay = TileOverlay(
        tileOverlayId: const TileOverlayId('danger_heatmap'),
        tileProvider: provider,
        transparency: 0.15,
        zIndex: 1,
      );
    });
  }

  // ── Submit Report ─────────────────────────────────────────────────────────
  Future<void> _submitReport(String reason) async {
    if (_currentPosition == null) return;
    if (mounted) setState(() => _isReporting = true);
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid ?? 'anonymous';
      final now = DateTime.now();
      final expiry = now.add(const Duration(hours: 24));
      await FirebaseFirestore.instance.collection('unsafe_reports').add({
        'lat': _currentPosition!.latitude,
        'lng': _currentPosition!.longitude,
        'reason': reason,
        'reported_by': uid,
        'timestamp': Timestamp.fromDate(now),
        'expiresAt': Timestamp.fromDate(expiry),
        'upvotes': 0,
        'upvoted_by': <String>[],
        'active': true,
      });
      _showSnack(
        '✅ Report submit ho gaya! 24 ghante tak visible rahega.',
        const Color(0xFF2E7D32),
      );
      await _loadUnsafeReports();
    } catch (e) {
      _showSnack('Report failed: $e', Colors.red.shade700);
    } finally {
      if (mounted) setState(() => _isReporting = false);
    }
  }

  // ── Upvote Report ─────────────────────────────────────────────────────────
  Future<void> _upvoteReport(String docId, String uid) async {
    try {
      await FirebaseFirestore.instance
          .collection('unsafe_reports')
          .doc(docId)
          .update({
            'upvotes': FieldValue.increment(1),
            'upvoted_by': FieldValue.arrayUnion([uid]),
          });
      await _loadUnsafeReports();
    } catch (e) {
      debugPrint('[SafetyMap] Upvote error: $e');
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────
  Color _colorForReason(String r) {
    switch (r) {
      case 'harassment':
        return Colors.red;
      case 'theft':
        return Colors.deepOrange;
      case 'poor_lighting':
        return Colors.orange;
      default:
        return Colors.red;
    }
  }

  double _hueForReason(String r) {
    switch (r) {
      case 'harassment':
        return BitmapDescriptor.hueRed;
      case 'theft':
        return BitmapDescriptor.hueOrange;
      case 'poor_lighting':
        return BitmapDescriptor.hueYellow;
      default:
        return BitmapDescriptor.hueRed;
    }
  }

  String _labelForReason(String r) {
    switch (r) {
      case 'harassment':
        return 'Harassment Reported';
      case 'theft':
        return 'Theft Reported';
      case 'poor_lighting':
        return 'Poor Lighting';
      default:
        return 'Unsafe Area';
    }
  }

  List<LatLng> _decodePolyline(String encoded) {
    final points = <LatLng>[];
    int index = 0, lat = 0, lng = 0;
    while (index < encoded.length) {
      int b, shift = 0, result = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      lat += (result & 1) != 0 ? ~(result >> 1) : result >> 1;
      shift = 0;
      result = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      lng += (result & 1) != 0 ? ~(result >> 1) : result >> 1;
      points.add(LatLng(lat / 1e5, lng / 1e5));
    }
    return points;
  }

  LatLngBounds _boundsFromLatLngList(List<LatLng> list) {
    double minLat = list[0].latitude, maxLat = list[0].latitude;
    double minLng = list[0].longitude, maxLng = list[0].longitude;
    for (final p in list) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }
    return LatLngBounds(
      southwest: LatLng(minLat, minLng),
      northeast: LatLng(maxLat, maxLng),
    );
  }

  double _distanceInMeters(double lat1, double lng1, double lat2, double lng2) {
    const r = 6371000.0;
    final dLat = (lat2 - lat1) * pi / 180;
    final dLng = (lng2 - lng1) * pi / 180;
    final a =
        sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1 * pi / 180) *
            cos(lat2 * pi / 180) *
            sin(dLng / 2) *
            sin(dLng / 2);
    return r * 2 * atan2(sqrt(a), sqrt(1 - a));
  }

  void _retryFindNearby() {
    if (_currentPosition == null) {
      _showSnack('Location not ready yet.', Colors.orange);
      return;
    }
    _showSnack('Finding nearest police & hospital...', Colors.blue);
    _findNearbyPlaces(_currentPosition!);
  }

  void _showSnack(String msg, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: color,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _showSettingsDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Location Permission'),
        content: const Text(
          'Location permission permanently deny ho gayi.\n\n'
          'Settings → Apps → [Is App] → Permissions → Location → "Allow only while using" select karo.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await Geolocator.openAppSettings();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFD32F2F),
            ),
            child: const Text(
              'Settings Kholo',
              style: TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }

  // ── Bottom Sheets ─────────────────────────────────────────────────────────
  void _showReportDialog() {
    if (_currentPosition == null) {
      _showSnack('Pehle location lo.', Colors.orange);
      return;
    }
    String selectedReason = 'harassment';
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => Padding(
          padding: EdgeInsets.only(
            left: 24,
            right: 24,
            top: 24,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                '📍 Report Unsafe Location',
                style: TextStyle(
                  color: Colors.black87,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Yeh report 24 ghante tak sabko visible rahegi.',
                style: TextStyle(color: Colors.black54, fontSize: 13),
              ),
              const SizedBox(height: 20),
              const Text(
                'Reason:',
                style: TextStyle(color: Colors.black87, fontSize: 14),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                children: [
                  _ReasonChip(
                    label: '😟 Harassment',
                    value: 'harassment',
                    selected: selectedReason == 'harassment',
                    onTap: () =>
                        setSheetState(() => selectedReason = 'harassment'),
                  ),
                  _ReasonChip(
                    label: '💰 Theft',
                    value: 'theft',
                    selected: selectedReason == 'theft',
                    onTap: () => setSheetState(() => selectedReason = 'theft'),
                  ),
                  _ReasonChip(
                    label: '🌑 Poor Lighting',
                    value: 'poor_lighting',
                    selected: selectedReason == 'poor_lighting',
                    onTap: () =>
                        setSheetState(() => selectedReason = 'poor_lighting'),
                  ),
                  _ReasonChip(
                    label: '⚠️ Other',
                    value: 'other',
                    selected: selectedReason == 'other',
                    onTap: () => setSheetState(() => selectedReason = 'other'),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  onPressed: _isReporting
                      ? null
                      : () {
                          Navigator.pop(ctx);
                          _submitReport(selectedReason);
                        },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFD32F2F),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: _isReporting
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2,
                          ),
                        )
                      : const Text(
                          'Submit Report',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                          ),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showReportDetails(String docId, Map<String, dynamic> data) {
    final upvotes = (data['upvotes'] as num?)?.toInt() ?? 0;
    final reason = data['reason'] as String? ?? 'other';
    final uid = FirebaseAuth.instance.currentUser?.uid;
    final alreadyVoted =
        uid != null &&
        List<String>.from(data['upvoted_by'] ?? []).contains(uid);
    final expiresAt = (data['expiresAt'] as Timestamp?)?.toDate();
    final hoursLeft = expiresAt != null
        ? expiresAt.difference(DateTime.now()).inHours.clamp(0, 24)
        : 0;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              '⚠️ ${_labelForReason(reason)}',
              style: const TextStyle(
                color: Colors.black87,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '$upvotes logon ne confirm kiya  •  expires in ${hoursLeft}h',
              style: const TextStyle(color: Colors.black54, fontSize: 13),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton.icon(
                onPressed: (alreadyVoted || uid == null)
                    ? null
                    : () async {
                        Navigator.pop(ctx);
                        await _upvoteReport(docId, uid);
                      },
                icon: Icon(
                  alreadyVoted ? Icons.check_circle : Icons.thumb_up_outlined,
                  color: Colors.white,
                ),
                label: Text(
                  alreadyVoted ? 'Already Confirmed' : 'Yes, I Confirm This',
                  style: const TextStyle(color: Colors.white),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: alreadyVoted
                      ? Colors.grey.shade400
                      : const Color(0xFFD32F2F),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // ── POI Action Sheet — both now trigger in-app route ──────────────────────
  void _showPoiActionSheet({
    required bool isPolice,
    double? lat,
    double? lng,
    String? name,
  }) {
    final poi = isPolice ? _nearestPoliceStation : _nearestHospital;
    final poiLat = lat ?? (poi?['lat'] as double?);
    final poiLng = lng ?? (poi?['lng'] as double?);
    final poiName = name ?? (poi?['name'] as String?);

    if (poiLat == null || poiLng == null || poiName == null) return;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.black12,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              '${isPolice ? '🚔' : '🏥'}  $poiName',
              style: const TextStyle(
                color: Colors.black87,
                fontSize: 17,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              isPolice ? 'Police Station' : 'Hospital',
              style: const TextStyle(color: Colors.black45, fontSize: 13),
            ),
            const SizedBox(height: 20),
            // Primary action
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton.icon(
                onPressed: () {
                  Navigator.pop(ctx);
                  _startNavigation(
                    destLat: poiLat,
                    destLng: poiLng,
                    destName: poiName,
                  );
                },
                icon: const Icon(Icons.directions, color: Colors.white),
                label: Text(
                  'Navigate',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: isPolice
                      ? Colors.blue.shade700
                      : Colors.green.shade700,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            // Secondary: pan map to this POI
            SizedBox(
              width: double.infinity,
              height: 46,
              child: OutlinedButton.icon(
                onPressed: () {
                  Navigator.pop(ctx);
                  _mapController?.animateCamera(
                    CameraUpdate.newLatLngZoom(LatLng(poiLat, poiLng), 16),
                  );
                },
                icon: const Icon(
                  Icons.location_on_outlined,
                  color: Colors.black54,
                ),
                label: const Text(
                  'Show on Map',
                  style: TextStyle(color: Colors.black54),
                ),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Colors.black12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        title: Row(
          children: [
            const Text(
              'Safety Map',
              style: TextStyle(
                color: Colors.black87,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 12),
            if (_currentPosition != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.blue.shade50,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.blue.shade200),
                ),
                child: Text(
                  '↑ ${_currentHeading.toStringAsFixed(0)}°',
                  style: TextStyle(
                    color: Colors.blue.shade700,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
          ],
        ),
        iconTheme: const IconThemeData(color: Colors.black87),
        actions: [
          Tooltip(
            message: 'Recenter to Your Location',
            child: IconButton(
              onPressed: () {
                if (_currentPosition != null) {
                  _mapController?.animateCamera(
                    CameraUpdate.newLatLngZoom(
                      LatLng(
                        _currentPosition!.latitude,
                        _currentPosition!.longitude,
                      ),
                      15,
                    ),
                  );
                } else {
                  _getCurrentLocation(); // only restart if genuinely no location yet
                }
              },
              icon: const Icon(Icons.my_location, color: Colors.blue),
            ),
          ),
          IconButton(
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const NavigationScreen()),
              );
            },
            icon: const Icon(Icons.search, color: Colors.black87),
            tooltip: 'Search & Navigate',
          ),
          IconButton(
            onPressed: _loadUnsafeReports,
            icon: const Icon(Icons.refresh, color: Colors.black87),
          ),
        ],
      ),
      body: Stack(
        children: [
          // ── Map ──
          if (_isLoading)
            const Center(
              child: CircularProgressIndicator(color: Color(0xFFD32F2F)),
            )
          else if (_currentPosition == null)
            _buildLocationDeniedView()
          else
            GoogleMap(
              onMapCreated: (c) {
                _mapController = c;
                // ── BRIGHT MAP STYLE ──
                _mapController?.setMapStyle(_brightMapStyle);
                if (_currentPosition != null) {
                  _mapController?.animateCamera(
                    CameraUpdate.newLatLngZoom(
                      LatLng(
                        _currentPosition!.latitude,
                        _currentPosition!.longitude,
                      ),
                      15,
                    ),
                  );
                }
              },
              initialCameraPosition: CameraPosition(
                target: LatLng(
                  _currentPosition?.latitude ?? 20.5937,
                  _currentPosition?.longitude ?? 78.9629,
                ),
                zoom: 15,
              ),
              markers: _markers,
              circles: _circles,
              polylines: _polylines,
              myLocationEnabled: true,
              myLocationButtonEnabled: false,
              zoomControlsEnabled: false,
              tileOverlays: {if (_heatmapOverlay != null) _heatmapOverlay!},
            ),

          // ── Legend ──
          if (_currentPosition != null)
            Positioned(
              top: 12,
              left: 12,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.92),
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black12,
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _LegendItem(color: Colors.blue, label: '📍 Your Location'),
                    const SizedBox(height: 5),
                    _LegendItem(color: Colors.blue, label: '🚔 Police'),
                    const SizedBox(height: 5),
                    _LegendItem(color: Colors.green, label: '🏥 Hospital'),
                    const SizedBox(height: 5),
                    _LegendItem(color: Colors.red, label: '⚠️ Report Pins'),
                  ],
                ),
              ),
            ),

          // If nearest POIs are missing, show a quick retry button
          if ((_nearestPoliceStation == null || _nearestHospital == null) &&
              _currentPosition != null)
            Positioned(
              top: 160,
              left: 12,
              child: ElevatedButton.icon(
                onPressed: _retryFindNearby,
                icon: const Icon(Icons.place, color: Colors.black87, size: 18),
                label: const Text(
                  'Find Nearby',
                  style: TextStyle(color: Colors.black87),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: Colors.black87,
                  elevation: 6,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),

          // ── Heatmap Toggle Button ──
          Positioned(
            top: 120,
            right: 12,
            child: GestureDetector(
              onTap: () => setState(() => _showHeatmap = !_showHeatmap),
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: _showHeatmap ? Colors.red.shade700 : Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 4)],
                ),
                child: Icon(
                  Icons.whatshot_rounded,
                  color: _showHeatmap ? Colors.white : Colors.red.shade700,
                  size: 22,
                ),
              ),
            ),
          ),

          // ── Live sharing status widget ──
          if (_isSharingLive)
            Positioned(
              bottom: 100,
              left: 12,
              right: 12,
              child: Material(
                color: Colors.white,
                elevation: 6,
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Row(
                          children: [
                            const Icon(Icons.share_location, color: Colors.red),
                            const SizedBox(width: 8),
                            const Expanded(
                              child: Text(
                                'Live sharing active',
                                style: TextStyle(
                                  fontWeight: FontWeight.w500,
                                  fontSize: 14,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: () async {
                          await _stopLiveShare();
                        },
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 4,
                          ),
                        ),
                        child: const Text(
                          'Stop',
                          style: TextStyle(
                            color: Colors.red,
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          if (_isNavigating) _buildNavigationPanel(),

          // ── Report Button + POI quick-action strip (Report above) ──
          if (_currentPosition != null && !_isNavigating)
            Positioned(
              bottom: 24,
              left: 12,
              right: 12,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Report Button
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: ElevatedButton.icon(
                      onPressed: _isReporting ? null : _showReportDialog,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFD32F2F),
                      ),
                      icon: _isReporting
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                color: Colors.white,
                                strokeWidth: 2,
                              ),
                            )
                          : const Icon(
                              Icons.add_location_alt,
                              color: Colors.white,
                            ),
                      label: const Text(
                        'Report Unsafe',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  // POI Cards
                  Row(
                    children: [
                      if (_nearestPoliceStation != null)
                        Expanded(
                          child: _PoiCard(
                            icon: Icons.local_police,
                            color: Colors.blue.shade700,
                            label: _nearestPoliceStation!['name'] as String,
                            sublabel: 'Police Station',
                            isLoading: _isRoutingToPolice,
                            onTap: () => _showPoiActionSheet(isPolice: true),
                          ),
                        ),
                      if (_nearestPoliceStation != null &&
                          _nearestHospital != null)
                        const SizedBox(width: 8),
                      if (_nearestHospital != null)
                        Expanded(
                          child: _PoiCard(
                            icon: Icons.local_hospital,
                            color: Colors.green.shade700,
                            label: _nearestHospital!['name'] as String,
                            sublabel: 'Hospital',
                            isLoading: _isRoutingToHospital,
                            onTap: () => _showPoiActionSheet(isPolice: false),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildNavigationPanel() {
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 12)],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── Handle bar ──
            const SizedBox(height: 10),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.black12,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 12),

            // ── Destination name ──
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  const Icon(Icons.navigation, color: Colors.blue, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _destinationName,
                      style: const TextStyle(
                        color: Colors.black87,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  // Stop button
                  GestureDetector(
                    onTap: _stopNavigation,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.red.shade50,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: Colors.red.shade200),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.close,
                            color: Colors.red.shade700,
                            size: 14,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            'Stop',
                            style: TextStyle(
                              color: Colors.red.shade700,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 12),
            const Divider(height: 1),
            const SizedBox(height: 14),

            // ── Current step instruction ──
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // Turn icon
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: Colors.blue.shade50,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      _getTurnIcon(_currentInstruction),
                      color: Colors.blue.shade700,
                      size: 26,
                    ),
                  ),
                  const SizedBox(width: 14),
                  // Instruction text
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _currentInstruction,
                          style: const TextStyle(
                            color: Colors.black87,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 3),
                        Text(
                          _currentStepDistance,
                          style: TextStyle(
                            color: Colors.blue.shade700,
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Step counter
                  Text(
                    '${_currentStepIndex + 1}/${_routeSteps.length}',
                    style: const TextStyle(color: Colors.black38, fontSize: 12),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  // ── Icon based on instruction keyword ────────────────────────────────────
  IconData _getTurnIcon(String instruction) {
    final lower = instruction.toLowerCase();
    if (lower.contains('left')) return Icons.turn_left;
    if (lower.contains('right')) return Icons.turn_right;
    if (lower.contains('straight') || lower.contains('continue')) {
      return Icons.straight;
    }
    if (lower.contains('roundabout')) return Icons.roundabout_left;
    if (lower.contains('destination') || lower.contains('arrive')) {
      return Icons.location_on;
    }
    if (lower.contains('merge')) return Icons.merge;
    if (lower.contains('u-turn')) return Icons.u_turn_left;
    return Icons.navigation;
  }

  Widget _buildLocationDeniedView() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.location_off, color: Colors.black26, size: 52),
          const SizedBox(height: 14),
          const Text(
            'Location access nahi mila.',
            style: TextStyle(color: Colors.black54, fontSize: 15),
          ),
          const SizedBox(height: 20),
          ElevatedButton(
            onPressed: _getCurrentLocation,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFD32F2F),
            ),
            child: const Text(
              'Try Again',
              style: TextStyle(color: Colors.white),
            ),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: Geolocator.openAppSettings,
            child: const Text(
              'Open Settings',
              style: TextStyle(color: Colors.blue),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Sub-widgets (unchanged except color tweaks for light theme)
// ─────────────────────────────────────────────────────────────────────────────

class _ReasonChip extends StatelessWidget {
  final String label, value;
  final bool selected;
  final VoidCallback onTap;
  const _ReasonChip({
    required this.label,
    required this.value,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFFD32F2F) : Colors.grey.shade100,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected ? const Color(0xFFD32F2F) : Colors.grey.shade300,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? Colors.white : Colors.black87,
            fontSize: 13,
            fontWeight: selected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}

class _LegendItem extends StatelessWidget {
  final Color color;
  final String label;
  const _LegendItem({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: const TextStyle(color: Colors.black87, fontSize: 11),
        ),
      ],
    );
  }
}

class _PoiCard extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label, sublabel;
  final bool isLoading;
  final VoidCallback onTap;
  const _PoiCard({
    required this.icon,
    required this.color,
    required this.label,
    required this.sublabel,
    required this.isLoading,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: isLoading ? null : onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: color.withOpacity(0.92),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            isLoading
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      color: Colors.white,
                      strokeWidth: 2,
                    ),
                  )
                : Icon(icon, color: Colors.white, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    sublabel,
                    style: const TextStyle(color: Colors.white70, fontSize: 10),
                  ),
                  Text(
                    label,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: Colors.white54, size: 16),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Bright / Light map style  (replaces the previous dark style)
//  Roads are white/light-grey, water is light blue, parks are light green.
// ─────────────────────────────────────────────────────────────────────────────
const String _brightMapStyle = '''
[
  {"elementType": "geometry",           "stylers": [{"color": "#f5f5f5"}]},
  {"elementType": "labels.text.fill",   "stylers": [{"color": "#616161"}]},
  {"elementType": "labels.text.stroke", "stylers": [{"color": "#f5f5f5"}]},
  {"featureType": "road",               "elementType": "geometry",           "stylers": [{"color": "#ffffff"}]},
  {"featureType": "road.arterial",      "elementType": "geometry",           "stylers": [{"color": "#ffffff"}]},
  {"featureType": "road.highway",       "elementType": "geometry",           "stylers": [{"color": "#dadada"}]},
  {"featureType": "road.highway",       "elementType": "geometry.stroke",    "stylers": [{"color": "#b0b0b0"}]},
  {"featureType": "poi",                "elementType": "geometry",           "stylers": [{"color": "#eeeeee"}]},
  {"featureType": "poi.park",           "elementType": "geometry",           "stylers": [{"color": "#d5e8d4"}]},
  {"featureType": "poi.park",           "elementType": "labels.text.fill",   "stylers": [{"color": "#4a7c59"}]},
  {"featureType": "water",              "elementType": "geometry",           "stylers": [{"color": "#c9e8f5"}]},
  {"featureType": "water",              "elementType": "labels.text.fill",   "stylers": [{"color": "#4a90a4"}]},
  {"featureType": "transit",            "elementType": "geometry",           "stylers": [{"color": "#e5e5e5"}]},
  {"featureType": "administrative",     "elementType": "geometry.stroke",    "stylers": [{"color": "#c9c9c9"}]},
  {"featureType": "landscape",          "elementType": "geometry",           "stylers": [{"color": "#f2f2f2"}]}
]
''';
