import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/services/places_service.dart';
import '../navigation_screen.dart';

class NearbyServiceFinderScreen extends StatefulWidget {
  const NearbyServiceFinderScreen({super.key, required this.title, required this.placesType, required this.icon, this.keyword, this.emergencyNumber, this.emergencyLabel});
  final String title;
  final String placesType;
  final IconData icon;
  final String? keyword;
  final String? emergencyNumber;
  final String? emergencyLabel;
  @override State<NearbyServiceFinderScreen> createState() => _NearbyServiceFinderScreenState();
}

class _NearbyServiceFinderScreenState extends State<NearbyServiceFinderScreen> {
  final _places = PlacesService();
  Position? _position;
  List<NearbyServicePlace> _results = [];
  bool _loading = true;
  String? _error;
  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      if (!await Geolocator.isLocationServiceEnabled()) throw Exception('Turn on Location to find nearby ${widget.title.toLowerCase()}.');
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) throw Exception('Location permission is required.');
      final position = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
      final results = await _places.getNearbyServices(latitude: position.latitude, longitude: position.longitude, type: widget.placesType, keyword: widget.keyword);
      if (mounted) setState(() { _position = position; _results = results; _loading = false; });
    } catch (e) { if (mounted) setState(() { _error = e.toString().replaceFirst('Exception: ', ''); _loading = false; }); }
  }
  Future<void> _showDetails(NearbyServicePlace place) async {
    final details = await _places.getServiceDetails(place);
    if (!mounted) return;
    showModalBottomSheet(context: context, isScrollControlled: true, builder: (context) => SafeArea(child: Padding(padding: const EdgeInsets.all(20), child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [Text(details.name, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)), const SizedBox(height: 8), Text('${_distance(details.distanceMeters)} away', style: const TextStyle(color: Color(0xFF1565C0))), const SizedBox(height: 12), Text(details.address), const SizedBox(height: 10), Text(details.phoneNumber ?? 'Phone number unavailable'), const SizedBox(height: 20), Row(children: [Expanded(child: OutlinedButton.icon(onPressed: details.phoneNumber == null ? null : () => _call(details.phoneNumber!), icon: const Icon(Icons.call_outlined), label: const Text('Call'))), const SizedBox(width: 10), Expanded(child: ElevatedButton.icon(onPressed: () { Navigator.pop(context); _navigate(details); }, icon: const Icon(Icons.navigation_outlined), label: const Text('Navigate')))])]))));
  }
  Future<void> _call(String number) async { if (!await launchUrl(Uri(scheme: 'tel', path: number.replaceAll(' ', ''))) && mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Unable to open the phone dialer.'))); }
  void _navigate(NearbyServicePlace place) { final position = _position; if (position == null) return; Navigator.push(context, MaterialPageRoute(builder: (_) => NavigationScreen(initialOrigin: LatLng(position.latitude, position.longitude), initialDestination: LatLng(place.latitude, place.longitude), initialOriginName: 'Current location', initialDestinationName: place.name))); }
  @override Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: Text(widget.title)), body: _loading ? const Center(child: CircularProgressIndicator()) : _error != null ? _StateMessage(text: _error!, retry: _load) : _results.isEmpty ? _StateMessage(text: 'No ${widget.title.toLowerCase()} were found near your current location.', retry: _load) : Column(children: [if (widget.emergencyNumber != null) Container(width: double.infinity, margin: const EdgeInsets.all(12), child: ElevatedButton.icon(style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white), onPressed: () => _call(widget.emergencyNumber!), icon: const Icon(Icons.emergency), label: Text('${widget.emergencyLabel ?? 'Emergency'}: ${widget.emergencyNumber}'))), SizedBox(height: MediaQuery.of(context).size.height * .30, child: GoogleMap(initialCameraPosition: CameraPosition(target: LatLng(_position!.latitude, _position!.longitude), zoom: 13), myLocationEnabled: true, markers: _results.map((place) => Marker(markerId: MarkerId(place.placeId), position: LatLng(place.latitude, place.longitude), infoWindow: InfoWindow(title: place.name), onTap: () => _showDetails(place))).toSet())), Expanded(child: ListView.separated(padding: const EdgeInsets.all(16), itemCount: _results.length, separatorBuilder: (_, __) => const SizedBox(height: 10), itemBuilder: (_, index) { final place = _results[index]; return Card(child: ListTile(leading: CircleAvatar(child: Icon(widget.icon)), title: Text(place.name), subtitle: Text('${place.address}\n${_distance(place.distanceMeters)} away', maxLines: 3, overflow: TextOverflow.ellipsis), isThreeLine: true, trailing: const Icon(Icons.chevron_right), onTap: () => _showDetails(place))); }))]));
}
class _StateMessage extends StatelessWidget { const _StateMessage({required this.text, required this.retry}); final String text; final Future<void> Function() retry; @override Widget build(BuildContext context) => Center(child: Padding(padding: const EdgeInsets.all(28), child: Column(mainAxisSize: MainAxisSize.min, children: [Text(text, textAlign: TextAlign.center), const SizedBox(height: 16), ElevatedButton(onPressed: retry, child: const Text('Try again'))]))); }
String _distance(double meters) => meters < 1000 ? '${meters.round()} m' : '${(meters / 1000).toStringAsFixed(1)} km';
