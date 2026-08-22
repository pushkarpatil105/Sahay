import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../../core/services/demo_service_request_service.dart';

class DemoServiceRequestScreen extends StatefulWidget {
  const DemoServiceRequestScreen({
    super.key,
    required this.serviceType,
    this.initialRequestId,
  });

  final DemoServiceType serviceType;
  final String? initialRequestId;

  @override
  State<DemoServiceRequestScreen> createState() => _DemoServiceRequestScreenState();
}

class _DemoServiceRequestScreenState extends State<DemoServiceRequestScreen> {
  final _requests = DemoServiceRequestService();
  String? _requestId;
  bool _creating = false;
  bool _cancelling = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _requestId = widget.initialRequestId;
  }

  Future<void> _requestHelp() async {
    setState(() {
      _creating = true;
      _error = null;
    });
    try {
      final position = await _getCurrentPosition();
      final requestId = await _requests.createDemoRequest(
        serviceType: widget.serviceType,
        latitude: position.latitude,
        longitude: position.longitude,
      );
      if (mounted) setState(() => _requestId = requestId);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  Future<Position> _getCurrentPosition() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw Exception('Turn on location to send the demo request.');
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) permission = await Geolocator.requestPermission();
    if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
      throw Exception('Location permission is required to send the demo request.');
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

  Future<void> _cancelRequest() async {
    if (_requestId == null) return;
    setState(() => _cancelling = true);
    try {
      await _requests.cancelRequest(_requestId!);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not cancel the demo request.')));
      }
    } finally {
      if (mounted) setState(() => _cancelling = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isAmbulance = widget.serviceType == DemoServiceType.ambulance;
    return Scaffold(
      appBar: AppBar(title: Text('Demo ${isAmbulance ? 'Ambulance' : 'Tow'} Request')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: _requestId == null
            ? _RequestIntro(
                serviceType: widget.serviceType,
                isCreating: _creating,
                error: _error,
                onRequest: _requestHelp,
              )
            : StreamBuilder<DemoServiceRequest?>(
                stream: _requests.watchRequest(_requestId!),
                builder: (context, snapshot) {
                  if (snapshot.hasError) return const _StateMessage('Unable to receive live request updates.');
                  if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
                  final request = snapshot.data;
                  if (request == null) return const _StateMessage('This demo request no longer exists.');
                  return _RequestTracker(request: request, isCancelling: _cancelling, onCancel: _cancelRequest);
                },
              ),
      ),
    );
  }
}

class _RequestIntro extends StatelessWidget {
  const _RequestIntro({required this.serviceType, required this.isCreating, required this.error, required this.onRequest});
  final DemoServiceType serviceType;
  final bool isCreating;
  final String? error;
  final VoidCallback onRequest;

  @override
  Widget build(BuildContext context) {
    final ambulance = serviceType == DemoServiceType.ambulance;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisAlignment: MainAxisAlignment.center, children: [
      Icon(ambulance ? Icons.local_hospital : Icons.car_repair, size: 70, color: Colors.red.shade700),
      const SizedBox(height: 20),
      Text('Demo ${ambulance ? 'Ambulance' : 'Tow Truck'} Request', textAlign: TextAlign.center, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
      const SizedBox(height: 10),
      const Text('This sends a simulated request to the demo provider dashboard. It does not call or dispatch a real service.', textAlign: TextAlign.center),
      if (error != null) Padding(padding: const EdgeInsets.only(top: 16), child: Text(error!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.red))),
      const SizedBox(height: 24),
      ElevatedButton.icon(
        style: ElevatedButton.styleFrom(backgroundColor: Colors.red.shade700, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 15)),
        onPressed: isCreating ? null : onRequest,
        icon: isCreating ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.send),
        label: Text(isCreating ? 'Sending request...' : 'Send demo request'),
      ),
    ]);
  }
}

class _RequestTracker extends StatelessWidget {
  const _RequestTracker({required this.request, required this.isCancelling, required this.onCancel});
  final DemoServiceRequest request;
  final bool isCancelling;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final cancelled = request.status == 'cancelled';
    final completed = request.status == 'completed';
    return Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Icon(_statusIcon(request.status), color: _statusColor(request.status), size: 72),
      const SizedBox(height: 18),
      Text(_statusTitle(request.status), textAlign: TextAlign.center, style: const TextStyle(fontSize: 23, fontWeight: FontWeight.bold)),
      const SizedBox(height: 10),
      Text(_statusDescription(request), textAlign: TextAlign.center),
      const SizedBox(height: 24),
      Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Request ID: ${request.id}', style: const TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 6), Text('Service: ${request.serviceType}'),
        const SizedBox(height: 6), Text('Status: ${request.status}'),
        if (request.escalationCount > 0) Padding(padding: const EdgeInsets.only(top: 6), child: Text('Reassignment attempts: ${request.escalationCount}')),
      ]))),
      const SizedBox(height: 18),
      if (!cancelled && !completed) OutlinedButton.icon(onPressed: isCancelling ? null : onCancel, icon: const Icon(Icons.cancel_outlined), label: Text(isCancelling ? 'Cancelling...' : 'Cancel request')),
    ]);
  }
}

IconData _statusIcon(String status) => switch (status) {
  'accepted' || 'en_route' => Icons.check_circle,
  'rejected' || 'reassigned' => Icons.autorenew,
  'cancelled' => Icons.cancel,
  'completed' => Icons.task_alt,
  _ => Icons.hourglass_top,
};

Color _statusColor(String status) => switch (status) {
  'accepted' || 'en_route' || 'completed' => Colors.green,
  'rejected' || 'reassigned' => Colors.orange,
  'cancelled' => Colors.grey,
  _ => Colors.red,
};

String _statusTitle(String status) => switch (status) {
  'pending' => 'Waiting for a provider',
  'assigned' => 'Provider assigned',
  'accepted' => 'Request accepted',
  'rejected' => 'Finding another provider',
  'reassigned' => 'Request reassigned',
  'en_route' => 'Provider is on the way',
  'completed' => 'Request completed',
  'cancelled' => 'Request cancelled',
  _ => 'Request updated',
};

String _statusDescription(DemoServiceRequest request) {
  final provider = request.providerName;
  if (request.status == 'pending') return 'Your request is visible to the demo provider dashboard.';
  if (request.status == 'cancelled') return 'The demo provider dashboard has been notified.';
  return provider == null || provider.isEmpty ? 'The provider dashboard updated your request.' : 'Provider: $provider';
}

class _StateMessage extends StatelessWidget {
  const _StateMessage(this.message);
  final String message;
  @override
  Widget build(BuildContext context) => Center(child: Text(message, textAlign: TextAlign.center));
}
