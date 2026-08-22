import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/services/places_service.dart';
import '../../core/services/demo_service_request_service.dart';
import '../navigation_screen.dart';
import 'demo_service_request_screen.dart';

class HospitalFinderScreen extends StatefulWidget {
  const HospitalFinderScreen({super.key});

  @override
  State<HospitalFinderScreen> createState() => _HospitalFinderScreenState();
}

class _HospitalFinderScreenState extends State<HospitalFinderScreen> {
  final PlacesService _placesService = PlacesService();
  GoogleMapController? _mapController;
  Position? _position;
  List<HospitalPlace> _hospitals = [];
  bool _isLoading = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadHospitals();
  }

  @override
  void dispose() {
    _mapController?.dispose();
    super.dispose();
  }

  Future<void> _loadHospitals() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      final position = await _getCurrentPosition();
      final hospitals = await _placesService.getNearbyHospitals(
        latitude: position.latitude,
        longitude: position.longitude,
      );
      if (!mounted) return;
      setState(() {
        _position = position;
        _hospitals = hospitals;
        _isLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _errorMessage = error.toString().replaceFirst('Exception: ', '');
        _isLoading = false;
      });
    }
  }

  Future<Position> _getCurrentPosition() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw Exception('Turn on Location to find nearby hospitals.');
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      throw Exception('Location permission is required to find hospitals.');
    }
    final lastKnownPosition = await Geolocator.getLastKnownPosition();
    if (lastKnownPosition != null) return lastKnownPosition;

    try {
      return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: Duration(seconds: 8),
        ),
      );
    } on TimeoutException {
      throw Exception(
        'Unable to get your location quickly. Move to an open area and try again.',
      );
    }
  }

  void _focusHospital(HospitalPlace hospital) {
    _mapController?.animateCamera(
      CameraUpdate.newLatLngZoom(
        LatLng(hospital.latitude, hospital.longitude),
        15.5,
      ),
    );
  }

  Future<void> _showHospitalDetails(HospitalPlace hospital) async {
    _focusHospital(hospital);
    final detailedHospital = await _placesService.getHospitalDetails(hospital);
    if (!mounted) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _HospitalDetailsSheet(
        hospital: detailedHospital,
        onCall: () => _callHospital(detailedHospital.phoneNumber),
        onNavigate: () {
          Navigator.pop(context);
          _openNavigation(detailedHospital);
        },
        onRequestAmbulance: () => _requestAmbulance(detailedHospital),
      ),
    );
  }

  Future<void> _requestAmbulance(HospitalPlace hospital) async {
    final position = _position;
    if (position == null) return;
    try {
      final requestId = await DemoServiceRequestService()
          .createHospitalAmbulanceRequest(
        userLatitude: position.latitude,
        userLongitude: position.longitude,
        hospitalName: hospital.name,
        hospitalPlaceId: hospital.placeId,
        hospitalLatitude: hospital.latitude,
        hospitalLongitude: hospital.longitude,
      );
      if (!mounted) return;
      Navigator.pop(context);
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => DemoServiceRequestScreen(
            serviceType: DemoServiceType.ambulance,
            initialRequestId: requestId,
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(error.toString().replaceFirst('Exception: ', '')),
        ),
      );
    }
  }

  Future<void> _callHospital(String? number) async {
    if (number == null || number.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Phone number is unavailable for this hospital.')),
      );
      return;
    }
    final uri = Uri(scheme: 'tel', path: number.replaceAll(' ', ''));
    if (!await launchUrl(uri)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Unable to open the phone dialer.')),
        );
      }
    }
  }

  void _openNavigation(HospitalPlace hospital) {
    final position = _position;
    if (position == null) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => NavigationScreen(
          initialOrigin: LatLng(position.latitude, position.longitude),
          initialDestination: LatLng(hospital.latitude, hospital.longitude),
          initialOriginName: 'Current location',
          initialDestinationName: hospital.name,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Nearest Hospitals'),
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF102E4A),
        elevation: 0.5,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _errorMessage != null
          ? _FinderMessage(message: _errorMessage!, onRetry: _loadHospitals)
          : _hospitals.isEmpty
          ? _FinderMessage(
              message: 'No hospitals were found near your current location.',
              onRetry: _loadHospitals,
            )
          : Column(
              children: [
                SizedBox(
                  height: MediaQuery.of(context).size.height * 0.34,
                  child: GoogleMap(
                    initialCameraPosition: CameraPosition(
                      target: LatLng(_position!.latitude, _position!.longitude),
                      zoom: 13,
                    ),
                    myLocationEnabled: true,
                    myLocationButtonEnabled: true,
                    markers: _hospitals
                        .map(
                          (hospital) => Marker(
                            markerId: MarkerId(hospital.placeId),
                            position: LatLng(hospital.latitude, hospital.longitude),
                            icon: BitmapDescriptor.defaultMarkerWithHue(
                              BitmapDescriptor.hueGreen,
                            ),
                            infoWindow: InfoWindow(title: hospital.name),
                            onTap: () => _showHospitalDetails(hospital),
                          ),
                        )
                        .toSet(),
                    onMapCreated: (controller) => _mapController = controller,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Hospitals nearest to you',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                            color: Color(0xFF102E4A),
                          ),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: _loadHospitals,
                        icon: const Icon(Icons.refresh, size: 18),
                        label: const Text('Refresh'),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    itemCount: _hospitals.length,
                    separatorBuilder: (context, index) =>
                        const SizedBox(height: 10),
                    itemBuilder: (context, index) {
                      final hospital = _hospitals[index];
                      return _HospitalCard(
                        hospital: hospital,
                        onTap: () => _showHospitalDetails(hospital),
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }
}

class _HospitalCard extends StatelessWidget {
  const _HospitalCard({required this.hospital, required this.onTap});

  final HospitalPlace hospital;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            border: Border.all(color: const Color(0xFFD8DDE5)),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              _HospitalPhoto(url: hospital.photoUrl, size: 72),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      hospital.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF102E4A),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      hospital.address,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, color: Colors.black54),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        const Icon(Icons.near_me_outlined, size: 15, color: Color(0xFF178C46)),
                        const SizedBox(width: 3),
                        Text(_formatDistance(hospital.distanceMeters)),
                        if (hospital.rating != null) ...[
                          const SizedBox(width: 10),
                          const Icon(Icons.star, size: 15, color: Color(0xFFD88E1C)),
                          const SizedBox(width: 2),
                          Text(hospital.rating!.toStringAsFixed(1)),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: Colors.black38),
            ],
          ),
        ),
      ),
    );
  }
}

class _HospitalDetailsSheet extends StatelessWidget {
  const _HospitalDetailsSheet({
    required this.hospital,
    required this.onCall,
    required this.onNavigate,
    required this.onRequestAmbulance,
  });

  final HospitalPlace hospital;
  final VoidCallback onCall;
  final VoidCallback onNavigate;
  final VoidCallback onRequestAmbulance;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 42,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _HospitalPhoto(url: hospital.photoUrl, size: 88),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        hospital.name,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF102E4A),
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        '${_formatDistance(hospital.distanceMeters)} away',
                        style: const TextStyle(color: Color(0xFF178C46)),
                      ),
                      if (hospital.rating != null) ...[
                        const SizedBox(height: 4),
                        Text('Rating: ${hospital.rating!.toStringAsFixed(1)}'),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _DetailRow(icon: Icons.location_on_outlined, text: hospital.address),
            const SizedBox(height: 10),
            _DetailRow(
              icon: Icons.phone_outlined,
              text: hospital.phoneNumber ?? 'Phone number unavailable',
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: hospital.phoneNumber == null ? null : onCall,
                    icon: const Icon(Icons.call_outlined),
                    label: const Text('Call'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: onNavigate,
                    icon: const Icon(Icons.navigation_outlined),
                    label: const Text('Navigate'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF102E4A),
                      foregroundColor: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: onRequestAmbulance,
                icon: const Icon(Icons.send_outlined),
                label: const Text('Request Ambulance'),
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Sends a simulated request to the demo admin dashboard; no real ambulance is called.',
              style: TextStyle(fontSize: 12, color: Colors.black54),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _HospitalPhoto extends StatelessWidget {
  const _HospitalPhoto({required this.url, required this.size});

  final String? url;
  final double size;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(
        width: size,
        height: size,
        child: url == null
            ? const ColoredBox(
                color: Color(0xFFEAF4EE),
                child: Icon(Icons.local_hospital, color: Color(0xFF178C46)),
              )
            : Image.network(
                url!,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) => const ColoredBox(
                  color: Color(0xFFEAF4EE),
                  child: Icon(Icons.local_hospital, color: Color(0xFF178C46)),
                ),
              ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: const Color(0xFF102E4A)),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: const TextStyle(color: Colors.black87))),
      ],
    );
  }
}

class _FinderMessage extends StatelessWidget {
  const _FinderMessage({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.local_hospital_outlined, size: 48, color: Color(0xFF102E4A)),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            ElevatedButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
      ),
    );
  }
}

String _formatDistance(double meters) => meters < 1000
    ? '${meters.round()} m'
    : '${(meters / 1000).toStringAsFixed(1)} km';
