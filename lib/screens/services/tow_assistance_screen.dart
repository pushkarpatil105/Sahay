import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/services/places_service.dart';
import '../../core/services/tow_service.dart';
import '../../core/services/demo_service_request_service.dart';
import 'demo_service_request_screen.dart';

class TowAssistanceScreen extends StatefulWidget {
  const TowAssistanceScreen({super.key});

  @override
  State<TowAssistanceScreen> createState() => _TowAssistanceScreenState();
}

class _TowAssistanceScreenState extends State<TowAssistanceScreen> {
  static const _indore = LatLng(22.7196, 75.8577);
  final _towService = TowService();
  final _places = PlacesService();
  List<TowOperator> _operators = [];
  List<NearbyServicePlace> _tollPlazas = [];
  LatLng _mapCenter = _indore;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final operatorsFuture = _towService.getIndoreOperators();
      final location = await _currentLocationOrIndore();
      final tollsFuture = _places.getNearbyTollPlazas(
        latitude: location.latitude,
        longitude: location.longitude,
      );
      final results = await Future.wait([operatorsFuture, tollsFuture]);
      if (!mounted) return;
      setState(() {
        _operators = results[0] as List<TowOperator>;
        _tollPlazas = results[1] as List<NearbyServicePlace>;
        _mapCenter = location;
        _loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = 'Unable to load towing assistance. Please try again.';
          _loading = false;
        });
      }
    }
  }

  Future<LatLng> _currentLocationOrIndore() async {
    if (!await Geolocator.isLocationServiceEnabled()) return _indore;
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return _indore;
    }
    final position = await Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.high,
    );
    return LatLng(position.latitude, position.longitude);
  }

  Future<void> _call(String number) async {
    final opened = await launchUrl(Uri(scheme: 'tel', path: number));
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Unable to open the phone dialer.')),
      );
    }
  }

  Future<void> _whatsApp(String number) async {
    final digits = number.replaceAll(RegExp(r'[^0-9]'), '');
    final opened = await launchUrl(
      Uri.parse('https://wa.me/$digits'),
      mode: LaunchMode.externalApplication,
    );
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('WhatsApp is unavailable on this device.')),
      );
    }
  }

  Future<void> _navigate(double latitude, double longitude) async {
    final destination = Uri.encodeComponent('$latitude,$longitude');
    final opened = await launchUrl(
      Uri.parse('https://www.google.com/maps/dir/?api=1&destination=$destination'),
      mode: LaunchMode.externalApplication,
    );
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Unable to open navigation.')),
      );
    }
  }

  Set<Marker> get _markers {
    final markers = <Marker>{
      for (final operator in _operators.where((item) => item.canShowOnMap))
        Marker(
          markerId: MarkerId(operator.id),
          position: LatLng(operator.latitude!, operator.longitude!),
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange),
          infoWindow: InfoWindow(title: operator.name, snippet: 'Towing service'),
          onTap: () => _showTowDetails(operator),
        ),
      for (final toll in _tollPlazas)
        Marker(
          markerId: MarkerId('toll-${toll.placeId}'),
          position: LatLng(toll.latitude, toll.longitude),
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueViolet),
          infoWindow: InfoWindow(title: toll.name, snippet: 'Toll plaza • NHAI 1033'),
          onTap: () => _showTollDetails(toll),
        ),
    };
    return markers;
  }

  void _showTowDetails(TowOperator operator) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: _TowDetails(
            operator: operator,
            onCall: _call,
            onWhatsApp: _whatsApp,
            onNavigate: _navigate,
            onRequestDemo: () {
              Navigator.pop(context);
              _openDemoTowRequest();
            },
          ),
        ),
      ),
    );
  }

  void _openDemoTowRequest() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => const DemoServiceRequestScreen(
          serviceType: DemoServiceType.towing,
        ),
      ),
    );
  }

  void _showTollDetails(NearbyServicePlace toll) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(toll.name, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(toll.address),
            const SizedBox(height: 16),
            Row(children: [
              Expanded(child: OutlinedButton.icon(onPressed: () => _navigate(toll.latitude, toll.longitude), icon: const Icon(Icons.navigation_outlined), label: const Text('Navigate'))),
              const SizedBox(width: 10),
              Expanded(child: ElevatedButton.icon(style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white), onPressed: () => _call('1033'), icon: const Icon(Icons.call), label: const Text('Call 1033'))),
            ]),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Tow Assistance')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _Failure(text: _error!, retry: _load)
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                  children: [
                    SizedBox(
                      height: 285,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: GoogleMap(
                          initialCameraPosition: CameraPosition(target: _mapCenter, zoom: 12),
                          myLocationEnabled: _mapCenter != _indore,
                          myLocationButtonEnabled: _mapCenter != _indore,
                          markers: _markers,
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Card(
                      color: Colors.red.shade700,
                      child: ListTile(
                        leading: const Icon(Icons.emergency, color: Colors.white),
                        title: const Text('On a National Highway?', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                        subtitle: const Text('Call NHAI toll-free emergency helpline 1033', style: TextStyle(color: Colors.white)),
                        trailing: FilledButton.icon(
                          style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.red.shade800),
                          onPressed: () => _call('1033'),
                          icon: const Icon(Icons.call),
                          label: const Text('Call'),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    const Text('Local towing services in Indore', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    const Text('Orange markers are data-file locations. They may be approximate.'),
                    const SizedBox(height: 10),
                    ..._operators.map((operator) => Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Card(
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: _TowDetails(
                            operator: operator,
                            onCall: _call,
                            onWhatsApp: _whatsApp,
                            onNavigate: _navigate,
                            onRequestDemo: _openDemoTowRequest,
                          ),
                        ),
                      ),
                    )),
                    if (_tollPlazas.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      const Text('Toll plazas from Google Maps', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 6),
                      Text('${_tollPlazas.length} toll plaza marker(s) are visible on the map.'),
                    ],
                  ],
                ),
    );
  }
}

class _TowDetails extends StatelessWidget {
  const _TowDetails({required this.operator, required this.onCall, required this.onWhatsApp, required this.onNavigate, required this.onRequestDemo});
  final TowOperator operator;
  final Future<void> Function(String) onCall;
  final Future<void> Function(String) onWhatsApp;
  final Future<void> Function(double, double) onNavigate;
  final VoidCallback onRequestDemo;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Row(children: [Expanded(child: Text(operator.name, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold))), if (operator.rating != null) Text('★ ${operator.rating!.toStringAsFixed(1)}', style: const TextStyle(color: Colors.amber, fontWeight: FontWeight.bold))]),
    const SizedBox(height: 6), Text(operator.address),
    if (operator.hours != null) Padding(padding: const EdgeInsets.only(top: 5), child: Text(operator.hours!)),
    if (operator.vehicleTypes.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 5), child: Text('Supports: ${operator.vehicleTypes.join(', ')}')),
    if (!operator.hasPhone) const Padding(padding: EdgeInsets.only(top: 8), child: Text('Contact number is awaiting verification.', style: TextStyle(color: Colors.red, fontWeight: FontWeight.w600))),
    const SizedBox(height: 12),
    Row(children: [
      Expanded(child: OutlinedButton.icon(onPressed: operator.canShowOnMap ? () => onNavigate(operator.latitude!, operator.longitude!) : null, icon: const Icon(Icons.navigation_outlined), label: const Text('Navigate'))),
      const SizedBox(width: 8),
      Expanded(child: OutlinedButton.icon(onPressed: operator.hasPhone ? () => onWhatsApp(operator.whatsapp) : null, icon: const Icon(Icons.chat_outlined), label: const Text('WhatsApp'))),
      const SizedBox(width: 8),
      Expanded(child: ElevatedButton.icon(onPressed: operator.hasPhone ? () => onCall(operator.phone) : null, icon: const Icon(Icons.call), label: const Text('Call'))),
    ]),
    const SizedBox(height: 8),
    SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        onPressed: onRequestDemo,
        icon: const Icon(Icons.send_outlined),
        label: const Text('Request demo tow service'),
      ),
    ),
    const SizedBox(height: 5),
    const Text('Sends a simulated request to the demo admin dashboard; no real operator is called.', style: TextStyle(fontSize: 12, color: Colors.black54), textAlign: TextAlign.center),
  ]);
}

class _Failure extends StatelessWidget {
  const _Failure({required this.text, required this.retry});
  final String text;
  final Future<void> Function() retry;
  @override
  Widget build(BuildContext context) => Center(child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [Text(text, textAlign: TextAlign.center), const SizedBox(height: 12), ElevatedButton(onPressed: retry, child: const Text('Try again'))])));
}
