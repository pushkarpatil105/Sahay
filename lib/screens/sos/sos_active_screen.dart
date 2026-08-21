import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:async';
import '../../core/services/sos_service.dart';
import '../../core/services/evidence_service.dart';
import '../../core/services/cloudinary_service.dart';
import '../../core/services/lock_screen_sos_service.dart';
import '../../core/services/escalation_service.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class SosActiveScreen extends StatefulWidget {
  const SosActiveScreen({super.key});

  @override
  State<SosActiveScreen> createState() => _SosActiveScreenState();
}

class _SosActiveScreenState extends State<SosActiveScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _pulseAnimation;
  int _secondsElapsed = 0;
  int _escalationSeconds = 30; // Escalation Tracker
  StreamSubscription<int>? _escalationSub;
  late String _sosId;
  late List _contacts;
  late String _triggeredBy;
  Position? _location;

  @override
  void initState() {
    super.initState();

    _escalationSub = EscalationService().countdownStream.listen((seconds) {
      if (mounted) setState(() => _escalationSeconds = seconds);
    });

    // Pulse animation
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.2).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeInOut),
    );

    // Timer
    _startTimer();
  }

  void _startTimer() {
    Future.delayed(const Duration(seconds: 1), () {
      if (mounted) {
        setState(() => _secondsElapsed++);
        _startTimer();
      }
    });
  }

  String get _formattedTime {
    final minutes = _secondsElapsed ~/ 60;
    final seconds = _secondsElapsed % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final args =
        ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>?;
    _sosId = args?['sosId'] ?? '';
    _contacts = args?['contacts'] ?? [];
    _triggeredBy = args?['triggeredBy'] ?? 'manual';
    _location = args?['location'];

    // ðŸ•µï¸ EXTRA SAFETY: If contacts are missing from navigation, fetch them now
    if (_contacts.isEmpty) {
      _fetchContactsSafely();
    } else {
      EscalationService().startSequence(
        _contacts,
        EvidenceService().getUserName(),
      );
    }
  }

  Future<void> _fetchContactsSafely() async {
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) return;
      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .get();
      if (mounted) {
        setState(() {
          _contacts = userDoc.data()?['emergency_contacts'] as List? ?? [];
        });
        if (_contacts.isNotEmpty) {
          EscalationService().startSequence(
            _contacts,
            EvidenceService().getUserName(),
          );
        }
        print('âœ… Late-fetched ${_contacts.length} contacts for active screen.');
      }
    } catch (e) {
      print('Error late-fetching contacts: $e');
    }
  }

  @override
  void dispose() {
    _escalationSub?.cancel();
    _animationController.dispose();
    super.dispose();
  }

  void _cancelSOS() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text('Cancel SOS?', style: TextStyle(color: Colors.white)),
        content: const Text(
          'Are you safe? This will cancel the emergency alert.',
          style: TextStyle(color: Colors.white60),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text(
              'No, Keep Active',
              style: TextStyle(color: Color(0xFFD32F2F)),
            ),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(context); // close dialog
              Navigator.pushReplacementNamed(
                context,
                '/home',
              ); // navigate immediately

              final zipPath = await EvidenceService().stopEvidence();
              if (zipPath != null) {
                final url = await CloudinaryService().uploadZip(
                  zipPath,
                  _sosId,
                );
                if (url != null) {
                  await EvidenceService().sendSmsToContacts(
                    _contacts.cast<Map<String, dynamic>>(),
                    EvidenceService().getUserName(),
                    EvidenceService().getLastPosition(),
                    zipUrl: url, // send cloud url as part of SMS
                  );
                }
              }
              await SosService().cancelSOS(_sosId);
              await LockScreenSosService().dismiss();
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
            child: const Text(
              'Yes, I am Safe',
              style: TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async => false,
      child: Scaffold(
        backgroundColor: const Color(0xFF1A0000),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              children: [
                // Header
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'ðŸš¨ SOS ACTIVE',
                      style: TextStyle(
                        color: Colors.red,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 2,
                      ),
                    ),
                    Text(
                      _formattedTime,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Triggered by: $_triggeredBy',
                  style: const TextStyle(color: Colors.white60, fontSize: 13),
                ),
                const SizedBox(height: 40),

                // Pulsing SOS button
                ScaleTransition(
                  scale: _pulseAnimation,
                  child: Container(
                    width: 180,
                    height: 180,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.red,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.red.withOpacity(0.6),
                          blurRadius: 40,
                          spreadRadius: 20,
                        ),
                      ],
                    ),
                    child: const Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.sos, color: Colors.white, size: 70),
                        Text(
                          'HELP\nSENT',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 40),

                // Status info
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.red.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.red.withOpacity(0.3)),
                  ),
                  child: Column(
                    children: [
                      _StatusRow(
                        icon: Icons.location_on,
                        label: 'Location',
                        value: _location != null
                            ? '${_location!.latitude.toStringAsFixed(4)}, ${_location!.longitude.toStringAsFixed(4)}'
                            : 'Getting location...',
                      ),
                      const Divider(color: Colors.white12),
                      _StatusRow(
                        icon: Icons.contacts,
                        label: 'Contacts Alerted',
                        value: '${_contacts.length} contacts',
                      ),
                      const Divider(color: Colors.white12),
                      const _StatusRow(
                        icon: Icons.fiber_manual_record,
                        label: 'Recording',
                        value: 'Active',
                        valueColor: Colors.red,
                      ),
                      const Divider(color: Colors.white12),
                      _StatusRow(
                        icon: Icons.phone_in_talk,
                        label: 'Escalation Alert',
                        value: _escalationSeconds > 0
                            ? 'Calling in ${_escalationSeconds}s'
                            : 'Call Dispatched',
                        valueColor: _escalationSeconds > 0
                            ? Colors.orange
                            : Colors.red,
                      ),
                    ],
                  ),
                ),

                const Spacer(),

                // 112 Override button
                SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: ElevatedButton(
                    onPressed: () async {
                      final uri = Uri.parse('tel:112');
                      if (await canLaunchUrl(uri)) await launchUrl(uri);
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.redAccent,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text(
                      'ðŸš¨ DIAL 112 NOW',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.5,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // Cancel button
                SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: ElevatedButton(
                    onPressed: _cancelSOS,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text(
                      'I AM SAFE â€” Cancel SOS',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color? valueColor;

  const _StatusRow({
    required this.icon,
    required this.label,
    required this.value,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(icon, color: Colors.white60, size: 18),
          const SizedBox(width: 12),
          Text(
            label,
            style: const TextStyle(color: Colors.white60, fontSize: 14),
          ),
          const Spacer(),
          Text(
            value,
            style: TextStyle(
              color: valueColor ?? Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}


