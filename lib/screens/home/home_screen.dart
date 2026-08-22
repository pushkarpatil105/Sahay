import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:image_picker/image_picker.dart';
import '../map/safety_map_screen.dart';
import '../services/hospital_finder_screen.dart';
import '../services/police_finder_screen.dart';
import '../services/nearby_service_finder_screen.dart';
import '../services/tow_assistance_screen.dart';
import '../services/demo_service_request_screen.dart';
import '../../core/services/demo_service_request_service.dart';
import '../../core/services/sos_service.dart';
import '../../core/services/sos_countdown_service.dart';
import '../../core/services/ble_service.dart';
import '../../core/services/voice_detection_service.dart';
// Shake detection is handled by native ShakeDetectionForegroundService
import '../../core/services/protection_service.dart';
import '../../core/services/upload_queue_service.dart';
import '../../core/services/upload_status.dart';
import '../../core/services/cloudinary_service.dart';
import '../../widgets/ble_connect_sheet.dart';
import 'package:sahay/main.dart';
import 'dart:async';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _currentIndex = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFAFAFA),
      body: _currentIndex == 0
          ? const _HomePage()
          : _currentIndex == 1
          ? const SafetyMapScreen()
          : _currentIndex == 2
          ? const _AiAssistantPage()
          : _currentIndex == 3
          ? const _NewSectionPage()
          : const _ProfilePage(),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.06),
              blurRadius: 20,
              offset: const Offset(0, -5),
            ),
          ],
        ),
        child: BottomNavigationBar(
          currentIndex: _currentIndex,
          onTap: (index) => setState(() => _currentIndex = index),
          backgroundColor: Colors.white,
          selectedItemColor: const Color(0xFFFF5722),
          unselectedItemColor: Colors.black38,
          type: BottomNavigationBarType.fixed,
          elevation: 0,
          items: const [
            BottomNavigationBarItem(
              icon: Icon(Icons.home_outlined),
              activeIcon: Icon(Icons.home),
              label: 'Home',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.map_outlined),
              activeIcon: Icon(Icons.map),
              label: 'Map',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.auto_awesome_outlined),
              activeIcon: Icon(Icons.auto_awesome),
              label: 'AI Assistant',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.dashboard_outlined),
              activeIcon: Icon(Icons.dashboard),
              label: 'Section',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.person_outline),
              activeIcon: Icon(Icons.person),
              label: 'Profile',
            ),
          ],
        ),
      ),
    );
  }
}

// â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
// HOME PAGE
// â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

class _HomePage extends StatefulWidget {
  const _HomePage();

  @override
  State<_HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<_HomePage> with TickerProviderStateMixin {
  String _userName = 'there';
  String _address = 'Getting location...';
  Position? _position;
  String? _localImagePath;
  bool _hasUnreadNotifications = false;
  bool _voiceEnabled = false;
  final VoiceDetectionService _voiceService = VoiceDetectionService();
  final BleService _bleService = BleService();
  BleStatus _bleStatus = BleStatus.idle;
  StreamSubscription<BleStatus>? _bleStatusSub;
  StreamSubscription<String>? _bleEventSub;
  DateTime? _lastBleSosTriggerAt;
  // Shake detection handled by native ShakeDetectionForegroundService
  final ProtectionService _protectionService = ProtectionService();
  StreamSubscription<UploadStatus>? _uploadStatusSub;

  bool _isSosHolding = false;
  double _sosProgress = 0.0;
  int _sosDuration = 3;
  AnimationController? _sosAnimController;

  @override
  void initState() {
    super.initState();
    _getLocation();
    _loadUserName();
    _loadVoiceState();
    _initBle();
    _uploadStatusSub = UploadQueueService().statusStream.listen(
      _onUploadStatus,
    ); // ADD THIS
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _protectionService.start(context);
    });
  }

  @override
  void dispose() {
    _uploadStatusSub?.cancel(); // ADD THIS
    _bleStatusSub?.cancel();
    _bleEventSub?.cancel();
    _sosAnimController?.dispose();
    super.dispose();
  }

  Future<void> _initBle() async {
    await _bleService.initialize();
    _bleService.enableAutoReconnect();

    _bleStatusSub = _bleService.statusStream.listen((status) {
      if (!mounted) return;
      setState(() => _bleStatus = status);
    });

    _bleEventSub = _bleService.eventStream.listen((event) {
      final normalized = event.trim().toUpperCase();
      final now = DateTime.now();

      debugPrint('[BLE][SOS] received raw="$event" normalized="$normalized"');

      // Prevent duplicate SOS triggers when firmware sends repeated packets.
      if (_lastBleSosTriggerAt != null &&
          now.difference(_lastBleSosTriggerAt!).inSeconds < 3) {
        debugPrint(
          '[BLE][SOS] ignored duplicate packet within debounce window',
        );
        return;
      }

      if (normalized.contains('SOS_BTN') ||
          normalized.contains('BTN_SOS') ||
          normalized == 'SOS' ||
          normalized == 'SOS_FROM_BUTTON') {
        _lastBleSosTriggerAt = now;
        debugPrint(
          '[BLE][SOS] matched button trigger -> open safe timer screen (auto-start)',
        );
        navigatorKey.currentState?.pushNamed(
          '/safe_timer',
          arguments: <String, dynamic>{'autoStart': true},
        );
      } else if (normalized.contains('SOS_SHK') ||
          normalized.contains('SHAKE') ||
          normalized == 'SOS_FROM_SHAKE') {
        _lastBleSosTriggerAt = now;
        debugPrint(
          '[BLE][SOS] matched shake trigger -> open SOS countdown screen',
        );
        navigatorKey.currentState?.pushNamed(
          '/sos_countdown',
          arguments: <String, dynamic>{'triggeredBy': 'iot_shake'},
        );
      } else {
        debugPrint(
          '[BLE][SOS] ignored because string did not match any SOS trigger',
        );
      }
    });
  }

  Future<void> _openBleDialog() async {
    await showBleConnectSheet(context);
  }

  IconData _bleIconForStatus() {
    switch (_bleStatus) {
      case BleStatus.connected:
        return Icons.bluetooth_connected;
      case BleStatus.scanning:
      case BleStatus.connecting:
        return Icons.bluetooth_searching;
      default:
        return Icons.bluetooth;
    }
  }

  Color _bleColorForStatus() {
    switch (_bleStatus) {
      case BleStatus.connected:
        return Colors.blue.shade700;
      case BleStatus.scanning:
      case BleStatus.connecting:
        return Colors.lightBlue;
      default:
        return Colors.black54;
    }
  }

  void _onUploadStatus(UploadStatus status) {
    if (!mounted) return;

    Color bgColor;
    IconData icon;

    switch (status.state) {
      case UploadState.success:
        bgColor = const Color(0xFF2E7D32);
        icon = Icons.cloud_done_outlined;
        break;
      case UploadState.failed:
        bgColor = const Color(0xFFB71C1C);
        icon = Icons.cloud_off_outlined;
        break;
      case UploadState.queued:
        bgColor = const Color(0xFFE65100);
        icon = Icons.cloud_queue_outlined;
        break;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: bgColor,
        duration: const Duration(seconds: 5),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        content: Row(
          children: [
            Icon(icon, color: Colors.white, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                status.message,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _loadVoiceState() async {
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) return;
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .get();
      final enabled = doc.data()?['voice_detection_enabled'] ?? false;
      if (enabled == true) {
        _toggleVoice(forceEnable: true);
      }
    } catch (e) {}
  }

  Future<void> _toggleVoice({bool forceEnable = false}) async {
    final newState = forceEnable ? true : !_voiceEnabled;
    if (newState) {
      final ok = await _voiceService.enable(context);
      setState(() => _voiceEnabled = true);
    } else {
      await _voiceService.disable();
      setState(() => _voiceEnabled = false);
    }
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      await FirebaseFirestore.instance.collection('users').doc(uid).set({
        'voice_detection_enabled': newState,
      }, SetOptions(merge: true));
    } catch (e) {}
  }

  Future<void> _loadLocalImage() async {
    final prefs = await SharedPreferences.getInstance();
    final path = prefs.getString('profile_image_path');
    if (path != null && File(path).existsSync()) {
      setState(() => _localImagePath = path);
    }
  }

  Future<void> _checkUnreadNotifications() async {
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) return;
      final snap = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('notifications')
          .where('read', isEqualTo: false)
          .limit(1)
          .get();
      setState(() => _hasUnreadNotifications = snap.docs.isNotEmpty);
    } catch (e) {}
  }

  Future<void> _loadSosDuration() async {
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) return;
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .get();
      final duration = doc.data()?['sos_hold_duration'];
      if (duration != null) setState(() => _sosDuration = duration as int);
    } catch (e) {}
  }

  Future<void> _loadUserName() async {
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) return;
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .get();
      if (doc.exists) {
        final name =
            doc.data()?['profile']?['name'] ??
            doc.data()?['medical_info']?['name'] as String?;
        if (name != null && (name as String).isNotEmpty) {
          setState(() => _userName = name.split(' ').first);
        }
      }
    } catch (e) {}
  }

  Future<void> _getLocation() async {
    try {
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
      setState(() {
        _position = position;
        _address =
            '${position.latitude.toStringAsFixed(4)}, ${position.longitude.toStringAsFixed(4)}';
      });
    } catch (e) {
      setState(() => _address = 'Location unavailable');
    }
  }

  void _onSosHoldStart() {
    HapticFeedback.mediumImpact();
    setState(() {
      _isSosHolding = true;
      _sosProgress = 0.0;
    });

    _sosAnimController?.dispose();
    _sosAnimController = AnimationController(
      vsync: this,
      duration: Duration(seconds: _sosDuration),
    );

    _sosAnimController!.addListener(() {
      setState(() => _sosProgress = _sosAnimController!.value);
      if ((_sosAnimController!.value * 10).toInt() % 3 == 0) {
        HapticFeedback.lightImpact();
      }
    });

    _sosAnimController!.addStatusListener((status) {
      if (status == AnimationStatus.completed) _triggerSOS();
    });

    _sosAnimController!.forward();
  }

  void _onSosHoldEnd() {
    if (_sosAnimController?.isCompleted == true) return;
    _sosAnimController?.stop();
    setState(() {
      _isSosHolding = false;
      _sosProgress = 0.0;
    });
    HapticFeedback.lightImpact();
  }

  void _triggerSOS() {
    HapticFeedback.heavyImpact();
    Future.delayed(
      const Duration(milliseconds: 200),
      () => HapticFeedback.heavyImpact(),
    );
    Future.delayed(
      const Duration(milliseconds: 400),
      () => HapticFeedback.heavyImpact(),
    );
    setState(() {
      _isSosHolding = false;
      _sosProgress = 0.0;
    });
    SosService().triggerSOS(context, 'manual');
  }

  void _showServiceMessage(String service) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$service service will be available soon.'),
        backgroundColor: const Color(0xFFFF5722),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _showSafetyTipsModal(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        height: MediaQuery.of(context).size.height * 0.85,
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          children: [
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                color: Colors.grey[300],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const Text(
              'Safety Guide & App Tips',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: Color(0xFF1A1A1A),
              ),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 8,
                ),
                children: [
                  _TipSection(
                    icon: Icons.offline_bolt_outlined,
                    title: 'Hands-Free SOS Triggers',
                    content:
                        'You can trigger an SOS without unlocking your phone in 3 ways:\n\n'
                        'ðŸ—£ï¸ Voice Action: Say "bachao" or "help me" anywhere (Make sure Microphone permission is active).\n'
                        'ðŸ“³ Shake Action: Shake your phone vigorously.\n'
                        'ðŸ”Š Volume Buttons: Press the "Volume Down" button 5 times rapidly.',
                    color: Colors.orange,
                  ),
                  _TipSection(
                    icon: Icons.timer_outlined,
                    title: 'Safe Journey Timer',
                    content:
                        'Taking a cab alone or walking in the dark? Use the "Safe Timer" at the top of the home screen.\n\n'
                        'Set a countdown duration. If you don\'t manually check-in as safe before the timer expires, the app will automatically trigger the SOS sequence to your contacts!',
                    color: Colors.blue,
                  ),
                  _TipSection(
                    icon: Icons.phone_in_talk,
                    title: '112 Emergency Escalation',
                    content:
                        'When an SOS triggers, your contacts get an SMS immediately. '
                        'If you don\'t cancel the SOS within 30 seconds, Sahay will use its severe Cloud APIs to automatically mass dial you emergency contacts with an urgent voice message!\n\n'
                        'Hackathon Bonus: Your emergency contacts can also tap a link in your SMS to securely command your phone to dial 112!',
                    color: Colors.red,
                  ),
                  _TipSection(
                    icon: Icons.verified_user_outlined,
                    title: 'Why We Need Permissions',
                    content:
                        'â€¢ Location (Always): Needed to send live tracking loops to your family when SOS triggers.\n'
                        'â€¢ Microphone: Needed exclusively for the offline Picovoice ML model to detect your wake word.\n'
                        'â€¢ Camera: Used instantly during an SOS to grab visual evidence of your surroundings.',
                    color: Colors.green,
                  ),
                  const SizedBox(height: 40),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Shake detection handled by native service
    final initials = _userName.isNotEmpty
        ? _userName.trim()[0].toUpperCase()
        : '?';

    return SafeArea(
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () => FocusScope.of(context).unfocus(),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Hey,',
                        style: TextStyle(
                          fontSize: 22,
                          color: Colors.black54,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                      Text(
                        _userName,
                        style: const TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF1A1A1A),
                        ),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      // Notification bell with orange dot
                      GestureDetector(
                        onTap: () async {
                          await Navigator.pushNamed(context, '/notifications');
                          _checkUnreadNotifications();
                        },
                        child: Stack(
                          children: [
                            Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(12),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withOpacity(0.06),
                                    blurRadius: 10,
                                  ),
                                ],
                              ),
                              child: const Icon(
                                Icons.notifications_outlined,
                                size: 20,
                                color: Colors.black54,
                              ),
                            ),
                            if (_hasUnreadNotifications)
                              Positioned(
                                top: 6,
                                right: 6,
                                child: Container(
                                  width: 9,
                                  height: 9,
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFFF5722),
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: Colors.white,
                                      width: 1.5,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      GestureDetector(
                        onTap: _openBleDialog,
                        child: Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(12),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.06),
                                blurRadius: 10,
                              ),
                            ],
                          ),
                          child: Icon(
                            _bleIconForStatus(),
                            size: 20,
                            color: _bleColorForStatus(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Profile avatar
                      GestureDetector(
                        onTap: () async {
                          await Navigator.pushNamed(context, '/user_profile');
                          _loadUserName();
                          _loadLocalImage();
                        },
                        child: Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: const Color(0xFFFF5722).withOpacity(0.1),
                            border: Border.all(
                              color: const Color(0xFFFF5722).withOpacity(0.3),
                              width: 1.5,
                            ),
                            image: _localImagePath != null
                                ? DecorationImage(
                                    image: FileImage(File(_localImagePath!)),
                                    fit: BoxFit.cover,
                                  )
                                : null,
                          ),
                          child: _localImagePath == null
                              ? Center(
                                  child: Text(
                                    initials,
                                    style: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                      color: Color(0xFFFF5722),
                                    ),
                                  ),
                                )
                              : null,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const SizedBox(height: 20),

              // SOS Button
              Center(
                child: Column(
                  children: [
                    const Text(
                      'Hold for Emergency SOS',
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.black45,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 12),
                    GestureDetector(
                      onTapDown: (_) => _onSosHoldStart(),
                      onTapUp: (_) => _onSosHoldEnd(),
                      onTapCancel: () => _onSosHoldEnd(),
                      child: SizedBox(
                        width: 172,
                        height: 172,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            AnimatedContainer(
                              duration: const Duration(milliseconds: 300),
                              width: _isSosHolding ? 172 : 156,
                              height: _isSosHolding ? 172 : 156,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: const Color(
                                  0xFFFF1744,
                                ).withOpacity(_isSosHolding ? 0.15 : 0.08),
                              ),
                            ),
                            SizedBox(
                              width: 150,
                              height: 150,
                              child: CircularProgressIndicator(
                                value: _sosProgress,
                                strokeWidth: 4,
                                backgroundColor: Colors.grey.shade200,
                                valueColor: const AlwaysStoppedAnimation<Color>(
                                  Color(0xFFFF1744),
                                ),
                              ),
                            ),
                            AnimatedContainer(
                              duration: const Duration(milliseconds: 150),
                              width: _isSosHolding ? 126 : 132,
                              height: _isSosHolding ? 126 : 132,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                gradient: const RadialGradient(
                                  colors: [
                                    Color(0xFFFF1744),
                                    Color(0xFFFF5722),
                                  ],
                                  center: Alignment.center,
                                  radius: 0.85,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: const Color(
                                      0xFFFF1744,
                                    ).withOpacity(0.4),
                                    blurRadius: _isSosHolding ? 30 : 15,
                                    spreadRadius: _isSosHolding ? 5 : 0,
                                  ),
                                ],
                              ),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Icon(
                                    Icons.sos,
                                    color: Colors.white,
                                    size: 38,
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    _isSosHolding
                                        ? '${(_sosDuration - (_sosProgress * _sosDuration)).ceil()}s'
                                        : 'HOLD ${_sosDuration}s',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                      letterSpacing: 1,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // Voice Detection Toggle
              GestureDetector(
                onTap: _toggleVoice,
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.05),
                        blurRadius: 10,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: _voiceEnabled
                              ? const Color(0xFFFF5722).withOpacity(0.1)
                              : Colors.grey.shade100,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          _voiceEnabled ? Icons.mic : Icons.mic_off,
                          color: _voiceEnabled
                              ? const Color(0xFFFF5722)
                              : Colors.black38,
                          size: 22,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _voiceEnabled
                                  ? 'Voice Detection ON'
                                  : 'Voice Detection OFF',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                                color: _voiceEnabled
                                    ? const Color(0xFF1A1A1A)
                                    : Colors.black38,
                              ),
                            ),
                            Text(
                              _voiceEnabled
                                  ? 'Listening for "Help" or "Bachao"'
                                  : 'Tap to enable voice SOS trigger',
                              style: const TextStyle(
                                fontSize: 11,
                                color: Colors.black38,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Switch(
                        value: _voiceEnabled,
                        onChanged: (_) => _toggleVoice(),
                        activeThumbColor: const Color(0xFFFF5722),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 10),

              const Text(
                'SELECT EMERGENCY SERVICE',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: Colors.black54,
                  letterSpacing: 0.6,
                ),
              ),
              const SizedBox(height: 12),
              GridView.count(
                crossAxisCount: 2,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 1.34,
                children: [
                  _ServiceCard(
                    icon: Icons.local_hospital_outlined,
                    title: 'Ambulance',
                    subtitle: 'Medical emergency',
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const HospitalFinderScreen(),
                      ),
                    ),
                  ),
                  _ServiceCard(
                    icon: Icons.shield_outlined,
                    title: 'Police',
                    subtitle: 'Security & accident',
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const PoliceFinderScreen()),
                    ),
                  ),
                  _ServiceCard(
                    icon: Icons.car_repair_outlined,
                    title: 'Tow Truck',
                    subtitle: 'Vehicle breakdown',
                    onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const TowAssistanceScreen())),
                  ),
                  _ServiceCard(
                    icon: Icons.build_outlined,
                    title: 'Mechanic',
                    subtitle: 'Engine & tyre fix',
                    onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const NearbyServiceFinderScreen(title: 'Mechanics & Puncture Repair', placesType: 'car_repair', keyword: 'mechanic puncture repair', icon: Icons.build))),
                  ),
                  _ServiceCard(
                    icon: Icons.local_gas_station_outlined,
                    title: 'Fuel Delivery',
                    subtitle: 'Empty tank support',
                    onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const NearbyServiceFinderScreen(title: 'Nearby Fuel Stations', placesType: 'gas_station', icon: Icons.local_gas_station, emergencyNumber: '112', emergencyLabel: 'Emergency assistance'))),
                  ),
                  _ServiceCard(
                    icon: Icons.emergency_outlined,
                    title: 'Hospital',
                    subtitle: 'Find trauma centres',
                    onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const NearbyServiceFinderScreen(title: 'Nearby Hospitals', placesType: 'hospital', icon: Icons.local_hospital))),
                  ),
                ],
              ),
              const SizedBox(height: 22),
              const Text(
                'DEMO SERVICE REQUESTS',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: Colors.black54,
                  letterSpacing: 0.6,
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const DemoServiceRequestScreen(
                            serviceType: DemoServiceType.ambulance,
                          ),
                        ),
                      ),
                      icon: const Icon(Icons.local_hospital_outlined),
                      label: const Text('Demo Ambulance'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const DemoServiceRequestScreen(
                            serviceType: DemoServiceType.towing,
                          ),
                        ),
                      ),
                      icon: const Icon(Icons.car_repair_outlined),
                      label: const Text('Demo Tow'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
// PROFILE PAGE
// â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

class _ProfilePage extends StatefulWidget {
  const _ProfilePage();

  @override
  State<_ProfilePage> createState() => _ProfilePageState();
}

class _AiAssistantPage extends StatelessWidget {
  const _AiAssistantPage();

  @override
  Widget build(BuildContext context) {
    return const SafeArea(
      child: Center(
        child: Text(
          'AI Assistant',
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.bold,
            color: Color(0xFF1A1A1A),
          ),
        ),
      ),
    );
  }
}

class _AiAssistantPrototype extends StatefulWidget {
  const _AiAssistantPrototype();

  @override
  State<_AiAssistantPrototype> createState() => _AiAssistantPrototypeState();
}

class _AiAssistantPrototypeState extends State<_AiAssistantPrototype> {
  final TextEditingController _messageController = TextEditingController();
  final List<_AssistantMessage> _messages = [
    const _AssistantMessage(
      text:
          'Hi! I am Sahay AI. I can help you prepare for a safer journey or find the right safety feature.',
      isUser: false,
    ),
  ];

  @override
  void dispose() {
    _messageController.dispose();
    super.dispose();
  }

  void _sendMessage([String? suggestedMessage]) {
    final message = (suggestedMessage ?? _messageController.text).trim();
    if (message.isEmpty) return;

    setState(() {
      _messages.add(_AssistantMessage(text: message, isUser: true));
      _messages.add(_AssistantMessage(text: _responseFor(message), isUser: false));
      _messageController.clear();
    });
  }

  String _responseFor(String message) {
    final query = message.toLowerCase();
    if (query.contains('route') || query.contains('map')) {
      return 'Open the Map tab to view nearby safety reports and choose a safer route before you start travelling.';
    }
    if (query.contains('sos') || query.contains('emergency') || query.contains('help')) {
      return 'For immediate danger, press and hold the SOS button on Home. It will alert your trusted contacts with your location.';
    }
    if (query.contains('timer') || query.contains('journey')) {
      return 'Use Safe Timer before a journey. If you do not check in before it expires, Sahay can begin your emergency flow.';
    }
    if (query.contains('contact')) {
      return 'You can add or update trusted people from Profile → Emergency Contacts.';
    }
    return 'I can help with safer routes, Safe Timer, SOS, and emergency contacts. What would you like to know?';
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
            child: Row(
              children: [
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    color: const Color(0xFFFF5722).withOpacity(0.12),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(
                    Icons.auto_awesome,
                    color: Color(0xFFFF5722),
                  ),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Sahay AI Assistant',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF1A1A1A),
                        ),
                      ),
                      SizedBox(height: 2),
                      Text(
                        'Your personal safety companion',
                        style: TextStyle(fontSize: 13, color: Colors.black54),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            height: 42,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              children: [
                _SuggestionChip(
                  label: 'Plan a safe route',
                  onTap: () => _sendMessage('How do I plan a safe route?'),
                ),
                _SuggestionChip(
                  label: 'Use Safe Timer',
                  onTap: () => _sendMessage('How does Safe Timer work?'),
                ),
                _SuggestionChip(
                  label: 'Emergency help',
                  onTap: () => _sendMessage('I need emergency help'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
              itemCount: _messages.length,
              itemBuilder: (context, index) {
                final message = _messages[index];
                return Align(
                  alignment: message.isUser
                      ? Alignment.centerRight
                      : Alignment.centerLeft,
                  child: Container(
                    constraints: const BoxConstraints(maxWidth: 300),
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: message.isUser
                          ? const Color(0xFFFF5722)
                          : Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.05),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Text(
                      message.text,
                      style: TextStyle(
                        fontSize: 14,
                        height: 1.4,
                        color: message.isUser ? Colors.white : Colors.black87,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border(top: BorderSide(color: Colors.grey.shade200)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _messageController,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _sendMessage(),
                    decoration: InputDecoration(
                      hintText: 'Ask about your safety...',
                      filled: true,
                      fillColor: const Color(0xFFF6F6F6),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  onPressed: _sendMessage,
                  icon: const Icon(Icons.arrow_upward),
                  color: Colors.white,
                  style: IconButton.styleFrom(
                    backgroundColor: const Color(0xFFFF5722),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AssistantMessage {
  const _AssistantMessage({required this.text, required this.isUser});

  final String text;
  final bool isUser;
}

class _SuggestionChip extends StatelessWidget {
  const _SuggestionChip({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ActionChip(
        label: Text(label),
        onPressed: onTap,
        backgroundColor: const Color(0xFFFF5722).withOpacity(0.08),
        side: BorderSide(color: const Color(0xFFFF5722).withOpacity(0.22)),
        labelStyle: const TextStyle(
          color: Color(0xFFCC3D1F),
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _NewSectionPage extends StatefulWidget {
  const _NewSectionPage();

  @override
  State<_NewSectionPage> createState() => _NewSectionPageState();
}

class _NewSectionPageState extends State<_NewSectionPage> {
  final TextEditingController _detailsController = TextEditingController();
  String _incidentType = 'Multiple Vehicle Collision';
  String _severity = 'Moderate';
  XFile? _evidencePhoto;
  Position? _reportPosition;
  String _locationText = 'Fetching current location...';
  bool _isSubmitting = false;

  static const _incidentTypes = [
    'Multiple Vehicle Collision',
    'Single Vehicle Accident',
    'Road Obstruction',
    'Unsafe Activity',
    'Other Incident',
  ];

  @override
  void initState() {
    super.initState();
    _loadReportLocation();
  }

  @override
  void dispose() {
    _detailsController.dispose();
    super.dispose();
  }

  Future<void> _loadReportLocation() async {
    try {
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
      if (!mounted) return;
      setState(() {
        _reportPosition = position;
        _locationText =
            '${position.latitude.toStringAsFixed(5)}, ${position.longitude.toStringAsFixed(5)}';
      });
    } catch (_) {
      if (mounted) {
        setState(() => _locationText = 'Location unavailable — try again');
      }
    }
  }

  Future<void> _pickEvidencePhoto() async {
    final photo = await ImagePicker().pickImage(
      source: ImageSource.camera,
      imageQuality: 80,
      maxWidth: 1600,
      maxHeight: 1600,
    );
    if (photo != null && mounted) setState(() => _evidencePhoto = photo);
  }

  int get _detailsWordCount => _detailsController.text
      .trim()
      .split(RegExp(r'\s+'))
      .where((word) => word.isNotEmpty)
      .length;

  Future<void> _submitReport() async {
    if (_reportPosition == null) {
      await _loadReportLocation();
      if (_reportPosition == null) {
        _showReportError('Current location is required to submit a report.');
        return;
      }
    }
    if (_detailsWordCount == 0 || _detailsWordCount > 200) {
      _showReportError('Incident details must be between 1 and 200 words.');
      return;
    }
    if (_evidencePhoto == null) {
      _showReportError('Please capture an incident photo before submitting.');
      return;
    }

    setState(() => _isSubmitting = true);
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) throw Exception('Please sign in before submitting a report.');

      final now = DateTime.now();
      final photoUrl = await CloudinaryService().uploadFile(
        _evidencePhoto!.path,
        resourceType: 'image',
        publicId: 'nari_shakti/incident_reports/${user.uid}/${now.millisecondsSinceEpoch}',
      );
      if (photoUrl == null) throw Exception('Photo upload failed. Please try again.');

      final position = _reportPosition!;
      await FirebaseFirestore.instance.collection('unsafe_reports').add({
        'lat': position.latitude,
        'lng': position.longitude,
        'latitude': position.latitude,
        'longitude': position.longitude,
        'reason': _incidentType,
        'incident_type': _incidentType,
        'severity_assessment': _severity,
        'incident_details': _detailsController.text.trim(),
        'reported_by': user.uid,
        'timestamp': Timestamp.fromDate(now),
        'reported_at': Timestamp.fromDate(now),
        'photo_url': photoUrl,
        'cloudinary_url': photoUrl,
        'active': true,
        'expiresAt': Timestamp.fromDate(now.add(const Duration(hours: 24))),
        'upvotes': 0,
        'upvoted_by': <String>[],
      });

      if (!mounted) return;
      setState(() {
        _detailsController.clear();
        _evidencePhoto = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Incident report submitted successfully.'),
          backgroundColor: Color(0xFF178C46),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (error) {
      if (mounted) _showReportError(error.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  void _showReportError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: const Color(0xFFB71C1C),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border(bottom: BorderSide(color: Colors.grey.shade200)),
            ),
            child: const Row(
              children: [
                Icon(Icons.report_outlined, color: Color(0xFF102E4A)),
                SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Report Road Incident',
                        style: TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF102E4A),
                        ),
                      ),
                      SizedBox(height: 2),
                      Text(
                        'Share an incident with safety dispatch',
                        style: TextStyle(fontSize: 11, color: Colors.black54),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _ReportFieldLabel('INCIDENT TYPE'),
                  DropdownButtonFormField<String>(
                    value: _incidentType,
                    isExpanded: true,
                    decoration: _reportInputDecoration(),
                    items: _incidentTypes
                        .map(
                          (type) => DropdownMenuItem(
                            value: type,
                            child: Text(type, overflow: TextOverflow.ellipsis),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value != null) setState(() => _incidentType = value);
                    },
                  ),
                  const SizedBox(height: 18),
                  const _ReportFieldLabel('INCIDENT LOCATION (GPS AUTO-FILLED)'),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFFD8DDE5)),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.location_on_outlined, color: Color(0xFF102E4A)),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _locationText,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF102E4A),
                            ),
                          ),
                        ),
                        Text(
                          _reportPosition == null ? 'RETRY' : 'GPS',
                          style: TextStyle(
                            color: Color(0xFF178C46),
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                  const _ReportFieldLabel('SEVERITY ASSESSMENT'),
                  Row(
                    children: ['Minor Injury', 'Moderate', 'Critical']
                        .map(
                          (level) => Expanded(
                            child: Padding(
                              padding: EdgeInsets.only(
                                right: level == 'Critical' ? 0 : 8,
                              ),
                              child: _SeverityButton(
                                label: level,
                                selected: _severity == level,
                                onTap: () => setState(() => _severity = level),
                              ),
                            ),
                          ),
                        )
                        .toList(),
                  ),
                  const SizedBox(height: 18),
                  const _ReportFieldLabel('INCIDENT DETAILS'),
                  TextField(
                    controller: _detailsController,
                    maxLines: 4,
                    onChanged: (_) => setState(() {}),
                    decoration: _reportInputDecoration().copyWith(
                      hintText: 'Describe what happened and any immediate risks.',
                      alignLabelWithHint: true,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 5),
                    child: Text(
                      '$_detailsWordCount / 200 words',
                      style: TextStyle(
                        fontSize: 11,
                        color: _detailsWordCount > 200
                            ? const Color(0xFFB71C1C)
                            : Colors.black54,
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  const _ReportFieldLabel('UPLOAD INCIDENT EVIDENCE PHOTOS'),
                  InkWell(
                    onTap: _pickEvidencePhoto,
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(vertical: 18),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: const Color(0xFFD8DDE5),
                          style: BorderStyle.solid,
                        ),
                      ),
                      child: Column(
                        children: [
                          Icon(
                            _evidencePhoto != null
                                ? Icons.check_circle_outline
                                : Icons.add_a_photo_outlined,
                            color: const Color(0xFF102E4A),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            _evidencePhoto != null
                                ? 'Photo selected'
                                : 'Tap to capture photo',
                            style: const TextStyle(
                              color: Color(0xFF102E4A),
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 2),
                          const Text(
                            'Evidence helps verify safety reports',
                            style: TextStyle(fontSize: 11, color: Colors.black54),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
            child: SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton(
                onPressed: _isSubmitting ? null : _submitReport,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF102E4A),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(7),
                  ),
                ),
                child: _isSubmitting
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          color: Colors.white,
                          strokeWidth: 2,
                        ),
                      )
                    : const Text(
                        'SUBMIT REPORT TO DISPATCH',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  InputDecoration _reportInputDecoration() => InputDecoration(
    filled: true,
    fillColor: Colors.white,
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: const BorderSide(color: Color(0xFFD8DDE5)),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: const BorderSide(color: Color(0xFFD8DDE5)),
    ),
  );
}

class _ReportFieldLabel extends StatelessWidget {
  const _ReportFieldLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.bold,
          color: Color(0xFF102E4A),
        ),
      ),
    );
  }
}

class _SeverityButton extends StatelessWidget {
  const _SeverityButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isCritical = label == 'Critical';
    final color = isCritical ? const Color(0xFFDF252B) : const Color(0xFFD88E1C);
    return SizedBox(
      height: 42,
      child: OutlinedButton(
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
          backgroundColor: selected ? color : Colors.white,
          foregroundColor: selected ? Colors.white : color,
          side: BorderSide(color: selected ? color : const Color(0xFFD8DDE5)),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
          padding: const EdgeInsets.symmetric(horizontal: 4),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }
}

class _ProfilePageState extends State<_ProfilePage> {
  int _sosDuration = 3;
  String _userName = '';
  String _userPhone = '';
  String? _localImagePath;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) return;
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .get();
      final data = doc.data();
      final duration = data?['sos_hold_duration'];
      final name =
          data?['profile']?['name'] ?? data?['medical_info']?['name'] ?? '';
      final phone =
          data?['profile']?['phone'] ??
          FirebaseAuth.instance.currentUser?.phoneNumber ??
          '';

      final prefs = await SharedPreferences.getInstance();
      final path = prefs.getString('profile_image_path');

      setState(() {
        if (duration != null) _sosDuration = duration as int;
        _userName = name as String;
        _userPhone = phone as String;
        if (path != null && File(path).existsSync()) {
          _localImagePath = path;
        }
      });
    } catch (e) {}
  }

  Future<void> _saveSosDuration(int value) async {
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      await FirebaseFirestore.instance.collection('users').doc(uid).set({
        'sos_hold_duration': value,
      }, SetOptions(merge: true));
      setState(() => _sosDuration = value);
    } catch (e) {}
  }

  void _showSosDurationDialog() {
    int tempDuration = _sosDuration;
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: const Text(
            'SOS Hold Duration',
            style: TextStyle(
              color: Color(0xFF1A1A1A),
              fontWeight: FontWeight.bold,
            ),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'How long should you hold the SOS button?',
                style: TextStyle(color: Colors.black54, fontSize: 14),
              ),
              const SizedBox(height: 24),
              Text(
                '$tempDuration seconds',
                style: const TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFFFF5722),
                ),
              ),
              Slider(
                value: tempDuration.toDouble(),
                min: 1,
                max: 10,
                divisions: 9,
                activeColor: const Color(0xFFFF5722),
                inactiveColor: Colors.grey.shade200,
                label: '$tempDuration sec',
                onChanged: (value) {
                  setDialogState(() => tempDuration = value.toInt());
                },
              ),
              const Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('1s', style: TextStyle(color: Colors.black38)),
                  Text('10s', style: TextStyle(color: Colors.black38)),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text(
                'Cancel',
                style: TextStyle(color: Colors.black45),
              ),
            ),
            ElevatedButton(
              onPressed: () {
                _saveSosDuration(tempDuration);
                Navigator.pop(context);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFFF5722),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                elevation: 0,
              ),
              child: const Text('Save', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ),
    );
  }

  void _showComingSoon(BuildContext context, String feature) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$feature coming soon'),
        backgroundColor: const Color(0xFFFF5722),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final initials = _userName.isNotEmpty
        ? _userName.trim()[0].toUpperCase()
        : '?';

    return SafeArea(child: Container(color: const Color(0xFFFFFBFA), child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(28, 22, 28, 32),
      child: Column(crossAxisAlignment: CrossAxisAlignment.center, children: [
        GestureDetector(onTap: () async { await Navigator.pushNamed(context, '/user_profile'); _loadData(); }, child: Column(children: [
          Stack(clipBehavior: Clip.none, children: [
            Container(width: 104, height: 104, decoration: BoxDecoration(color: const Color(0xFFEAE7E8), borderRadius: BorderRadius.circular(16), image: _localImagePath == null ? null : DecorationImage(image: FileImage(File(_localImagePath!)), fit: BoxFit.cover)), child: _localImagePath == null ? Center(child: Text(initials, style: const TextStyle(fontSize: 38, fontWeight: FontWeight.bold, color: Color(0xFF0E124D)))) : null),
            Positioned(right: -8, bottom: -8, child: Container(width: 46, height: 46, decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(15), border: Border.all(color: const Color(0xFFD7D2D6))), child: const Icon(Icons.edit_outlined, color: Color(0xFF0E124D))))
          ]),
          const SizedBox(height: 25), Text(_userName.isEmpty ? 'Set your name' : _userName, style: const TextStyle(fontSize: 27, fontWeight: FontWeight.bold)), const SizedBox(height: 5), Text(_userPhone.isEmpty ? 'Add phone number' : _userPhone, style: const TextStyle(fontSize: 17, color: Color(0xFF4A4A50))), const SizedBox(height: 20),
          OutlinedButton(onPressed: () async { await Navigator.pushNamed(context, '/user_profile'); _loadData(); }, style: OutlinedButton.styleFrom(foregroundColor: const Color(0xFF0E124D), side: const BorderSide(color: Color(0xFF0E124D), width: 2), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)), padding: const EdgeInsets.symmetric(horizontal: 31, vertical: 12)), child: const Text('Edit Profile', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
        ])),
        const SizedBox(height: 40), const Align(alignment: Alignment.centerLeft, child: _SectionLabel('Safety')),
        _ProfileGroup(children: [
        _ProfileItem(
              icon: Icons.timer_outlined,
              title: 'Safe Timer',
              onTap: () => Navigator.pushNamed(context, '/safe_timer'),
            ),
            _ProfileItem(
              icon: Icons.contacts_outlined,
              title: 'Emergency Contacts',
              onTap: () => Navigator.pushNamed(context, '/contacts'),
            ),
            _ProfileItem(
              icon: Icons.timer_outlined,
              title: 'SOS Hold Duration',
              trailing: Text(
                '${_sosDuration}s',
                style: const TextStyle(
                  color: Color(0xFFFF5722),
                  fontWeight: FontWeight.bold,
                ),
              ),
              onTap: _showSosDurationDialog,
            ),
        ]), const SizedBox(height: 25), const Align(alignment: Alignment.centerLeft, child: _SectionLabel('Health')),
        _ProfileGroup(children: [
            _ProfileItem(
              icon: Icons.medical_information_outlined,
              title: 'Medical Profile',
              onTap: () => Navigator.pushNamed(context, '/medical'),
            ),
        ]), const SizedBox(height: 25), const Align(alignment: Alignment.centerLeft, child: _SectionLabel('History')),
        _ProfileGroup(children: [
            _ProfileItem(
              icon: Icons.history,
              title: 'SOS History',
              onTap: () => Navigator.pushNamed(context, '/sos_history'),
            ),
            _ProfileItem(
              icon: Icons.folder_outlined,
              title: 'Evidence Storage',
              subtitle: 'Audio, location recordings',
              onTap: () => Navigator.pushNamed(context, '/evidence'),
            ),
        ]), const SizedBox(height: 25), const Align(alignment: Alignment.centerLeft, child: _SectionLabel('Account')),
        _ProfileGroup(children: [
            _ProfileItem(
              icon: Icons.logout,
              title: 'Logout',
              titleColor: Colors.red,
              onTap: () async {
                await FirebaseAuth.instance.signOut();
                if (context.mounted) {
                  Navigator.pushReplacementNamed(context, '/');
                }
              },
            ),
        ]), const SizedBox(height: 28), Text('Sahay', style: TextStyle(fontSize: 13, color: Colors.grey.shade400)),
      ]),
    )));
  }
}

// â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
// SHARED WIDGETS
// â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

class _SectionLabel extends StatelessWidget {
  final String label;
  const _SectionLabel(this.label);

  @override
  Widget build(BuildContext context) {
    return Padding(
        padding: const EdgeInsets.only(bottom: 10, left: 20),
      child: Text(
        label.toUpperCase(),
        style: const TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.bold,
          color: Color(0xFF0E124D),
          letterSpacing: 1.0,
        ),
      ),
    );
  }
}

class _ServiceCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _ServiceCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFFD8DDE5)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Icon(icon, color: const Color(0xFF102E4A), size: 24),
                const Icon(
                  Icons.north_east,
                  color: Colors.black38,
                  size: 16,
                ),
              ],
            ),
            const Spacer(),
            Text(
              title,
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 15,
                color: Color(0xFF102E4A),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              subtitle,
              style: const TextStyle(fontSize: 10, color: Colors.black45),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProfileItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;
  final Widget? trailing;
  final Color? titleColor;

  const _ProfileItem({
    required this.icon,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.trailing,
    this.titleColor,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
        child: Row(
          children: [
            Icon(icon, color: const Color(0xFF25252B), size: 25),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w500,
                      color: titleColor ?? const Color(0xFF25252B),
                    ),
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle!,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.black38,
                      ),
                    ),
                ],
              ),
            ),
            trailing ??
                const Icon(
                  Icons.arrow_forward_ios,
                  size: 18,
                  color: const Color(0xFFC5C2C5),
                ),
          ],
        ),
      ),
    );
  }
}

class _ProfileGroup extends StatelessWidget {
  const _ProfileGroup({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: const Color(0xFFE3DFE1))),
    child: Column(children: children.asMap().entries.map((entry) => Column(children: [entry.value, if (entry.key < children.length - 1) const Divider(height: 1, indent: 64, color: Color(0xFFE7E3E4))])).toList()),
  );
}

class _TipSection extends StatelessWidget {
  final IconData icon;
  final String title;
  final String content;
  final Color color;

  const _TipSection({
    required this.icon,
    required this.title,
    required this.content,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 24),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: color, size: 24),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: color.withOpacity(0.8),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            content,
            style: const TextStyle(
              fontSize: 14,
              color: Colors.black87,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}
