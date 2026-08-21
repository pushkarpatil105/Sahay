import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/services/places_service.dart';
import '../navigation_screen.dart';

class PoliceFinderScreen extends StatefulWidget {
  const PoliceFinderScreen({super.key});
  @override State<PoliceFinderScreen> createState() => _PoliceFinderScreenState();
}

class _PoliceFinderScreenState extends State<PoliceFinderScreen> {
  final _places = PlacesService();
  Position? _position;
  List<PolicePlace> _stations = [];
  bool _loading = true;
  String? _error;

  @override void initState() { super.initState(); _loadStations(); }
  Future<void> _loadStations() async {
    setState(() { _loading = true; _error = null; });
    try {
      if (!await Geolocator.isLocationServiceEnabled()) throw Exception('Turn on Location to find nearby police stations.');
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) throw Exception('Location permission is required to find police stations.');
      final position = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
      final stations = await _places.getNearbyPoliceStations(latitude: position.latitude, longitude: position.longitude);
      if (mounted) setState(() { _position = position; _stations = stations; _loading = false; });
    } catch (e) { if (mounted) setState(() { _error = e.toString().replaceFirst('Exception: ', ''); _loading = false; }); }
  }
  Future<void> _openDetails(PolicePlace station) async {
    final details = await _places.getPoliceStationDetails(station);
    if (!mounted) return;
    showModalBottomSheet(context: context, isScrollControlled: true, builder: (context) => SafeArea(child: Padding(padding: const EdgeInsets.all(20), child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(details.name, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
      const SizedBox(height: 8), Text('${_distance(details.distanceMeters)} away', style: const TextStyle(color: Color(0xFF1565C0))),
      const SizedBox(height: 12), Row(crossAxisAlignment: CrossAxisAlignment.start, children: [const Icon(Icons.location_on_outlined), const SizedBox(width: 8), Expanded(child: Text(details.address))]),
      const SizedBox(height: 10), Row(children: [const Icon(Icons.phone_outlined), const SizedBox(width: 8), Text(details.phoneNumber ?? 'Phone number unavailable')]),
      const SizedBox(height: 20), Row(children: [Expanded(child: OutlinedButton.icon(onPressed: details.phoneNumber == null ? null : () => _call(details.phoneNumber!), icon: const Icon(Icons.call_outlined), label: const Text('Call'))), const SizedBox(width: 10), Expanded(child: ElevatedButton.icon(onPressed: () { Navigator.pop(context); _navigate(details); }, icon: const Icon(Icons.navigation_outlined), label: const Text('Navigate')))]),
    ]))));
  }
  Future<void> _call(String number) async { if (!await launchUrl(Uri(scheme: 'tel', path: number.replaceAll(' ', '')))) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Unable to open the phone dialer.'))); } }
  void _navigate(PolicePlace station) { final position = _position; if (position == null) return; Navigator.push(context, MaterialPageRoute(builder: (_) => NavigationScreen(initialOrigin: LatLng(position.latitude, position.longitude), initialDestination: LatLng(station.latitude, station.longitude), initialOriginName: 'Current location', initialDestinationName: station.name))); }
  @override Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: const Text('Nearest Police Stations')), body: _loading ? const Center(child: CircularProgressIndicator()) : _error != null ? _Message(text: _error!, onRetry: _loadStations) : _stations.isEmpty ? _Message(text: 'No police stations were found near your current location.', onRetry: _loadStations) : Column(children: [SizedBox(height: MediaQuery.of(context).size.height * .34, child: GoogleMap(initialCameraPosition: CameraPosition(target: LatLng(_position!.latitude, _position!.longitude), zoom: 13), myLocationEnabled: true, markers: _stations.map((station) => Marker(markerId: MarkerId(station.placeId), position: LatLng(station.latitude, station.longitude), icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueBlue), infoWindow: InfoWindow(title: station.name), onTap: () => _openDetails(station))).toSet())), Padding(padding: const EdgeInsets.fromLTRB(16, 14, 8, 8), child: Row(children: [const Expanded(child: Text('Police stations nearest to you', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold))), TextButton.icon(onPressed: _loadStations, icon: const Icon(Icons.refresh), label: const Text('Refresh'))])), Expanded(child: ListView.separated(padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), itemCount: _stations.length, separatorBuilder: (_, __) => const SizedBox(height: 10), itemBuilder: (_, index) { final station = _stations[index]; return Card(child: ListTile(leading: const CircleAvatar(child: Icon(Icons.local_police)), title: Text(station.name), subtitle: Text('${station.address}\n${_distance(station.distanceMeters)} away', maxLines: 3, overflow: TextOverflow.ellipsis), isThreeLine: true, trailing: const Icon(Icons.chevron_right), onTap: () => _openDetails(station))); }))]));
}

class _Message extends StatelessWidget { const _Message({required this.text, required this.onRetry}); final String text; final Future<void> Function() onRetry; @override Widget build(BuildContext context) => Center(child: Padding(padding: const EdgeInsets.all(28), child: Column(mainAxisSize: MainAxisSize.min, children: [const Icon(Icons.local_police_outlined, size: 48), const SizedBox(height: 12), Text(text, textAlign: TextAlign.center), const SizedBox(height: 16), ElevatedButton(onPressed: onRetry, child: const Text('Try again'))]))); }
String _distance(double meters) => meters < 1000 ? '${meters.round()} m' : '${(meters / 1000).toStringAsFixed(1)} km';
