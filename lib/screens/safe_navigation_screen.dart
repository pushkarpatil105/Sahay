import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:sahay/core/services/directions_service.dart';
import 'package:sahay/models/navigation_route.dart';

/// Normal turn-by-turn navigation using one Google Directions route only.
class SafeNavigationScreen extends StatefulWidget {
  final LatLng origin;
  final LatLng destination;
  final String? originName;
  final String? destinationName;
  final String travelMode;
  const SafeNavigationScreen({super.key, required this.origin, required this.destination, this.originName, this.destinationName, this.travelMode = 'driving'});
  @override State<SafeNavigationScreen> createState() => _SafeNavigationScreenState();
}

class _SafeNavigationScreenState extends State<SafeNavigationScreen> {
  final _directions = DirectionsService();
  final _tts = FlutterTts();
  GoogleMapController? _map;
  StreamSubscription<Position>? _positions;
  NavigationRoute? _route;
  Position? _current;
  bool _loading = true;
  bool _rerouting = false;
  String? _error;
  int _stepIndex = 0;
  String? _lastSpoken;
  bool _voiceEnabled = true;

  @override void initState() { super.initState(); _initTts(); _loadRoute(widget.origin); _trackGps(); }
  Future<void> _initTts() async { try { await _tts.setLanguage('en-IN'); await _tts.setSpeechRate(.47); } catch (_) {} }
  Future<void> _loadRoute(LatLng origin) async {
    if (mounted) setState(() { _loading = true; _error = null; });
    final result = await _directions.getRouteBetweenCoords(origin, widget.destination, widget.travelMode);
    if (!mounted) return;
    if (result == null || result.polylinePoints.isEmpty) { setState(() { _loading = false; _rerouting = false; _error = 'Google Maps could not find a route.'; }); return; }
    setState(() { _route = result; _loading = false; _rerouting = false; _stepIndex = 0; _lastSpoken = null; });
    _fitRoute(result);
    _speakStep(force: true);
  }
  Future<void> _trackGps() async {
    try {
      final current = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
      _onPosition(current);
      _positions = Geolocator.getPositionStream(locationSettings: const LocationSettings(accuracy: LocationAccuracy.best, distanceFilter: 5)).listen(_onPosition);
    } catch (e) { if (mounted) setState(() => _error = 'Location unavailable: $e'); }
  }
  Future<void> _onPosition(Position position) async {
    if (!mounted) return;
    setState(() => _current = position);
    final route = _route;
    if (route == null) return;
    final here = LatLng(position.latitude, position.longitude);
    if (_stepIndex < route.steps.length && _distance(here, route.steps[_stepIndex].endLocation) < 25) { setState(() => _stepIndex++); _speakStep(force: true); }
    if (!_rerouting && _distanceToPolyline(here, route.polylinePoints) > 50) {
      _rerouting = true;
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('You are off route. Finding a new Google Maps route…')));
      await _loadRoute(here);
    } else { _speakStep(); }
  }
  double _distance(LatLng a, LatLng b) => Geolocator.distanceBetween(a.latitude, a.longitude, b.latitude, b.longitude);
  double _distanceToPolyline(LatLng point, List<LatLng> line) => line.fold(double.infinity, (nearest, item) => math.min(nearest, _distance(point, item)));
  Future<void> _speakStep({bool force = false}) async {
    final route = _route;
    if (route == null || _stepIndex >= route.steps.length) return;
    final step = route.steps[_stepIndex];
    final remaining = _current == null ? 0 : _distance(LatLng(_current!.latitude, _current!.longitude), step.endLocation).round();
    final message = force ? step.instruction : 'In ${math.max(20, remaining)} meters, ${step.instruction}';
    if (!_voiceEnabled || message == _lastSpoken) return;
    _lastSpoken = message;
    try { await _tts.stop(); await _tts.speak(message); } catch (_) {}
  }
  Future<void> _fitRoute(NavigationRoute route) async {
    var minLat = route.polylinePoints.first.latitude, maxLat = minLat, minLng = route.polylinePoints.first.longitude, maxLng = minLng;
    for (final p in route.polylinePoints) { minLat = math.min(minLat, p.latitude); maxLat = math.max(maxLat, p.latitude); minLng = math.min(minLng, p.longitude); maxLng = math.max(maxLng, p.longitude); }
    try { await _map?.animateCamera(CameraUpdate.newLatLngBounds(LatLngBounds(southwest: LatLng(minLat, minLng), northeast: LatLng(maxLat, maxLng)), 96)); } catch (_) {}
  }
  Set<Marker> get _markers => {
    Marker(markerId: const MarkerId('destination'), position: widget.destination, infoWindow: InfoWindow(title: widget.destinationName ?? 'Destination')),
    if (_current != null) Marker(markerId: const MarkerId('user'), position: LatLng(_current!.latitude, _current!.longitude), icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure), rotation: _current!.heading.isFinite && _current!.heading >= 0 ? _current!.heading : 0, flat: true),
  };
  Set<Polyline> get _polylines => _route == null ? {} : {Polyline(polylineId: const PolylineId('google_route'), points: _route!.polylinePoints, color: const Color(0xFF2563EB), width: 7, geodesic: true)};
  IconData _maneuverIcon(String? instruction) {
    final value = instruction?.toLowerCase() ?? '';
    if (value.contains('u-turn') || value.contains('uturn')) return Icons.u_turn_left;
    if (value.contains('left')) return Icons.turn_left;
    if (value.contains('right')) return Icons.turn_right;
    if (value.contains('roundabout')) return Icons.roundabout_left;
    return Icons.straight;
  }
  Future<void> _recenter() async {
    if (_current == null) return;
    await _map?.animateCamera(CameraUpdate.newCameraPosition(CameraPosition(target: LatLng(_current!.latitude, _current!.longitude), zoom: 18, bearing: _current!.heading.isFinite && _current!.heading >= 0 ? _current!.heading : 0)));
  }
  @override void dispose() { _positions?.cancel(); _map?.dispose(); _tts.stop(); super.dispose(); }
  @override Widget build(BuildContext context) {
    final step = _route != null && _stepIndex < _route!.steps.length ? _route!.steps[_stepIndex] : null;
    return Scaffold(appBar: AppBar(title: Text(widget.travelMode == 'walking' ? 'Walking navigation' : widget.travelMode == 'bicycling' ? 'Bike navigation' : 'Driving navigation'), actions: [IconButton(icon: Icon(_voiceEnabled ? Icons.volume_up : Icons.volume_off), tooltip: 'Voice guidance', onPressed: () => setState(() => _voiceEnabled = !_voiceEnabled))]), body: Stack(children: [
      GoogleMap(initialCameraPosition: CameraPosition(target: widget.origin, zoom: 15), onMapCreated: (map) { _map = map; if (_route != null) _fitRoute(_route!); }, markers: _markers, polylines: _polylines, myLocationButtonEnabled: true, zoomControlsEnabled: false),
      if (!_loading && _error == null && step != null) Positioned(left: 16, right: 16, top: 16, child: SafeArea(child: Card(elevation: 6, child: Padding(padding: const EdgeInsets.all(14), child: Row(children: [Icon(_maneuverIcon(step.instruction), color: const Color(0xFF2563EB), size: 42), const SizedBox(width: 14), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(step.instruction, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)), const SizedBox(height: 3), Text(step.distanceText, style: TextStyle(color: Colors.grey.shade700))]))]))))),
      Positioned(right: 16, bottom: 150, child: FloatingActionButton.small(heroTag: 'recenter_navigation', onPressed: _recenter, child: const Icon(Icons.my_location))),
      Positioned(left: 16, right: 16, bottom: 24, child: SafeArea(top: false, child: Card(child: Padding(padding: const EdgeInsets.all(16), child: _loading ? const Row(children: [CircularProgressIndicator(), SizedBox(width: 16), Text('Getting your route…')]) : _error != null ? Column(mainAxisSize: MainAxisSize.min, children: [Text(_error!), TextButton(onPressed: () => _loadRoute(_current == null ? widget.origin : LatLng(_current!.latitude, _current!.longitude)), child: const Text('Retry'))]) : Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [Text(step == null ? 'You have arrived' : 'Next turn', style: const TextStyle(fontWeight: FontWeight.w700)), const SizedBox(height: 5), Text('${_route!.distance} • ${_route!.duration}'), const SizedBox(height: 3), const Text('Google Maps route', style: TextStyle(color: Colors.grey))]))))),
    ]));
  }
}
