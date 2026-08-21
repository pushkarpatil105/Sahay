import 'dart:async';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:sahay/core/services/places_service.dart';
import 'package:sahay/screens/safe_navigation_screen.dart';

/// Destination picker. The origin is always the device's live GPS location.
class NavigationScreen extends StatefulWidget {
  final LatLng? initialOrigin;
  final LatLng? initialDestination;
  final String? initialOriginName;
  final String? initialDestinationName;
  const NavigationScreen({super.key, this.initialOrigin, this.initialDestination, this.initialOriginName, this.initialDestinationName});
  @override State<NavigationScreen> createState() => _NavigationScreenState();
}

class _NavigationScreenState extends State<NavigationScreen> {
  final _places = PlacesService();
  GoogleMapController? _map;
  StreamSubscription<Position>? _positions;
  LatLng? _origin;
  LatLng? _destination;
  String? _destinationName;
  String _travelMode = 'driving';
  bool _loading = true;
  String? _error;

  @override void initState() { super.initState(); _origin = widget.initialOrigin; _destination = widget.initialDestination; _destinationName = widget.initialDestinationName; _startGps(); }
  Future<void> _startGps() async {
    try {
      final current = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
      _setOrigin(current);
      _positions = Geolocator.getPositionStream(locationSettings: const LocationSettings(accuracy: LocationAccuracy.best, distanceFilter: 5)).listen(_setOrigin);
    } catch (e) { if (mounted) setState(() { _loading = false; _error = 'Location unavailable: $e'; }); }
  }
  void _setOrigin(Position position) { if (mounted) setState(() { _origin = LatLng(position.latitude, position.longitude); _loading = false; }); }
  Set<Marker> get _markers => {
    if (_origin != null) Marker(markerId: const MarkerId('origin'), position: _origin!, icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure), infoWindow: const InfoWindow(title: 'Current location')),
    if (_destination != null) Marker(markerId: const MarkerId('destination'), position: _destination!, infoWindow: InfoWindow(title: _destinationName ?? 'Destination')),
  };
  Future<void> _pickDestination() async {
    final controller = TextEditingController();
    var suggestions = <Map<String, String>>[];
    final selected = await showModalBottomSheet<PlaceLocation>(context: context, isScrollControlled: true, builder: (sheet) => StatefulBuilder(builder: (_, setSheet) => SafeArea(child: Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, MediaQuery.of(sheet).viewInsets.bottom + 16),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: controller, autofocus: true, decoration: const InputDecoration(labelText: 'Search destination', prefixIcon: Icon(Icons.search)), onChanged: (query) async { if (query.trim().isEmpty) return; final results = await _places.getAutocomplete(query); setSheet(() => suggestions = results); }),
        ConstrainedBox(constraints: const BoxConstraints(maxHeight: 320), child: ListView.builder(shrinkWrap: true, itemCount: suggestions.length, itemBuilder: (_, i) => ListTile(title: Text(suggestions[i]['description'] ?? ''), onTap: () async { final detail = await _places.getPlaceDetails(placeId: suggestions[i]['place_id'] ?? '', description: suggestions[i]['description'] ?? ''); if (detail != null && sheet.mounted) Navigator.pop(sheet, detail); }))),
      ]),
    ))));
    if (selected == null || !mounted) return;
    setState(() { _destination = LatLng(selected.latitude, selected.longitude); _destinationName = selected.description; _error = null; });
    _fitCamera();
  }
  Future<void> _fitCamera() async {
    if (_origin == null || _destination == null) return;
    final a = _origin!, b = _destination!;
    try { await _map?.animateCamera(CameraUpdate.newLatLngBounds(LatLngBounds(southwest: LatLng(a.latitude < b.latitude ? a.latitude : b.latitude, a.longitude < b.longitude ? a.longitude : b.longitude), northeast: LatLng(a.latitude > b.latitude ? a.latitude : b.latitude, a.longitude > b.longitude ? a.longitude : b.longitude)), 96)); } catch (_) {}
  }
  void _start() {
    if (_origin == null || _destination == null) { setState(() => _error = 'Wait for GPS, then choose a destination.'); return; }
    Navigator.push(context, MaterialPageRoute(builder: (_) => SafeNavigationScreen(origin: _origin!, destination: _destination!, originName: 'Current location', destinationName: _destinationName, travelMode: _travelMode)));
  }
  @override void dispose() { _positions?.cancel(); _map?.dispose(); super.dispose(); }
  @override Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: const Text('Navigation')), body: Stack(children: [
    GoogleMap(initialCameraPosition: CameraPosition(target: _origin ?? const LatLng(20.5937, 78.9629), zoom: _origin == null ? 5 : 15), onMapCreated: (map) => _map = map, markers: _markers, myLocationButtonEnabled: true, zoomControlsEnabled: false),
    Positioned(left: 16, right: 16, bottom: 24, child: SafeArea(top: false, child: Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(mainAxisSize: MainAxisSize.min, children: [
      ListTile(leading: const Icon(Icons.my_location), title: const Text('Starting point'), subtitle: Text(_loading ? 'Getting GPS location…' : 'Current location')),
      ListTile(leading: const Icon(Icons.location_on, color: Colors.red), title: const Text('Destination'), subtitle: Text(_destinationName ?? 'Choose destination'), onTap: _pickDestination),
      Wrap(spacing: 8, children: [
        ChoiceChip(label: const Text('Car'), selected: _travelMode == 'driving', onSelected: (_) => setState(() => _travelMode = 'driving')),
        ChoiceChip(label: const Text('Walk'), selected: _travelMode == 'walking', onSelected: (_) => setState(() => _travelMode = 'walking')),
        ChoiceChip(label: const Text('Bike'), selected: _travelMode == 'bicycling', onSelected: (_) => setState(() => _travelMode = 'bicycling')),
      ]),
      const SizedBox(height: 8),
      if (_error != null) Text(_error!, style: const TextStyle(color: Colors.red)),
      SizedBox(width: double.infinity, child: ElevatedButton.icon(onPressed: _start, icon: const Icon(Icons.navigation), label: const Text('Start navigation'))),
    ]))))),
  ]));
}
