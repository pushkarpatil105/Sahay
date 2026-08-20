import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../map/safety_map_screen.dart';
import '../navigation_screen.dart';
import '../../core/services/sos_service.dart';
import '../../core/services/sos_countdown_service.dart';
import '../../core/services/ble_service.dart';
import '../../core/services/voice_detection_service.dart';
import '../../core/services/places_service.dart';
// Shake detection is handled by native ShakeDetectionForegroundService
import '../../core/services/protection_service.dart';
import '../../core/services/upload_queue_service.dart';
import '../../core/services/upload_status.dart';
import '../../widgets/ble_connect_sheet.dart';
import 'package:nari_shakti/main.dart';
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

// ─────────────────────────────────────────────
// HOME PAGE
// ─────────────────────────────────────────────

class _HomePage extends StatefulWidget {
  const _HomePage();

  @override
  State<_HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<_HomePage> with TickerProviderStateMixin {
  String _userName = 'there';
  String _address = 'Getting location...';
  Position? _position;
  final TextEditingController _fromController = TextEditingController();
  final TextEditingController _toController = TextEditingController();
  LatLng? _fromLatLng;
  LatLng? _toLatLng;
  GoogleMapController? _mapController;
  String? _localImagePath;
  bool _hasUnreadNotifications = false;
  bool _voiceEnabled = false;
  final VoiceDetectionService _voiceService = VoiceDetectionService();
  final PlacesService _placesService = PlacesService();
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
  final FocusNode _toFocusNode = FocusNode();
  bool _navExpanded = false;
  List<Map<String, String>> _placeSuggestions = [];
  Timer? _placeDebounce;
  bool _loadingPlaces = false;

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
    _fromController.dispose();
    _toController.dispose();
    _toFocusNode.dispose();
    _placeDebounce?.cancel();
    super.dispose();
  }

  void _onToChanged(String q) {
    _placeDebounce?.cancel();
    if (q.trim().isEmpty) {
      setState(() => _placeSuggestions = []);
      return;
    }
    _placeDebounce = Timer(const Duration(milliseconds: 300), () async {
      if (!mounted) return;
      setState(() => _loadingPlaces = true);
      try {
        final results = await _placesService.getAutocomplete(q);
        if (!mounted) return;
        setState(() {
          _placeSuggestions = results;
        });
      } catch (e) {
        setState(() => _placeSuggestions = []);
      } finally {
        if (mounted) setState(() => _loadingPlaces = false);
      }
    });
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
                        '🗣️ Voice Action: Say "bachao" or "help me" anywhere (Make sure Microphone permission is active).\n'
                        '📳 Shake Action: Shake your phone vigorously.\n'
                        '🔊 Volume Buttons: Press the "Volume Down" button 5 times rapidly.',
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
                        'If you don\'t cancel the SOS within 30 seconds, Nari Shakti will use its severe Cloud APIs to automatically mass dial you emergency contacts with an urgent voice message!\n\n'
                        'Hackathon Bonus: Your emergency contacts can also tap a link in your SMS to securely command your phone to dial 112!',
                    color: Colors.red,
                  ),
                  _TipSection(
                    icon: Icons.verified_user_outlined,
                    title: 'Why We Need Permissions',
                    content:
                        '• Location (Always): Needed to send live tracking loops to your family when SOS triggers.\n'
                        '• Microphone: Needed exclusively for the offline Picovoice ML model to detect your wake word.\n'
                        '• Camera: Used instantly during an SOS to grab visual evidence of your surroundings.',
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

              // Quick From/To Search Card
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.04),
                      blurRadius: 12,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFFCFA),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: const Color(0xFFFFECE2),
                      width: 1,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFFFFB27A).withOpacity(0.05),
                        blurRadius: 8,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  child: Column(
                    children: [
                      // From row
                      Row(
                        children: [
                          Container(
                            width: 10,
                            height: 10,
                            decoration: const BoxDecoration(
                              color: Colors.green,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: TextField(
                              controller: _fromController,
                              decoration: InputDecoration(
                                labelText: 'From',
                                hintText: 'Current Location',
                                border: InputBorder.none,
                              ),
                            ),
                          ),
                          IconButton(
                            onPressed: () async {
                              await _getLocation();
                              if (_position != null) {
                                _fromLatLng = LatLng(
                                  _position!.latitude,
                                  _position!.longitude,
                                );
                                _fromController.text = 'Current Location';
                              }
                            },
                            icon: Container(
                              width: 32,
                              height: 32,
                              decoration: BoxDecoration(
                                color: Colors.grey.shade100,
                                borderRadius: BorderRadius.circular(9),
                              ),
                              child: const Icon(
                                Icons.my_location,
                                color: Colors.black54,
                                size: 17,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const Divider(height: 10),
                      // To row
                      Row(
                        children: [
                          Container(
                            width: 10,
                            height: 10,
                            decoration: const BoxDecoration(
                              color: Colors.red,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: TextField(
                              controller: _toController,
                              focusNode: _toFocusNode,
                              onChanged: _onToChanged,
                              onTap: () => setState(() => _navExpanded = true),
                              onTapOutside: (_) =>
                                  FocusScope.of(context).unfocus(),
                              decoration: InputDecoration(
                                labelText: 'To',
                                hintText: 'Where to?',
                                border: InputBorder.none,
                              ),
                            ),
                          ),
                          IconButton(
                            onPressed: () {
                              // Quick open Google Maps search externally
                              // user can still type destination
                            },
                            icon: Container(
                              width: 32,
                              height: 32,
                              decoration: BoxDecoration(
                                color: Colors.grey.shade100,
                                borderRadius: BorderRadius.circular(9),
                              ),
                              child: const Icon(
                                Icons.map,
                                color: Colors.green,
                                size: 17,
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (_loadingPlaces) const SizedBox(height: 4),
                      if (_loadingPlaces)
                        const LinearProgressIndicator(minHeight: 3),
                      if (_placeSuggestions.isNotEmpty && _navExpanded)
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 180),
                          child: ListView.separated(
                            shrinkWrap: true,
                            itemBuilder: (ctx, i) {
                              final item = _placeSuggestions[i];
                              return ListTile(
                                title: Text(item['description'] ?? ''),
                                onTap: () async {
                                  final details = await _placesService
                                      .getPlaceDetails(
                                        placeId: item['place_id'] ?? '',
                                        description: item['description'] ?? '',
                                      );
                                  if (!mounted || details == null) return;
                                  final originLatLng =
                                      _fromLatLng ??
                                      (_position != null
                                          ? LatLng(
                                              _position!.latitude,
                                              _position!.longitude,
                                            )
                                          : null);
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) => NavigationScreen(
                                        initialOrigin: originLatLng,
                                        initialDestination: LatLng(
                                          details.latitude,
                                          details.longitude,
                                        ),
                                        initialOriginName:
                                            _fromController.text.isEmpty
                                            ? null
                                            : _fromController.text,
                                        initialDestinationName:
                                            details.description,
                                      ),
                                    ),
                                  );
                                  setState(() {
                                    _placeSuggestions = [];
                                    _navExpanded = false;
                                  });
                                  _toFocusNode.unfocus();
                                },
                              );
                            },
                            separatorBuilder: (_, __) =>
                                const Divider(height: 1),
                            itemCount: _placeSuggestions.length,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
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

              // Safe Timer card
              GestureDetector(
                onTap: () => Navigator.pushNamed(context, '/safe_timer'),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFFFFECEB), Color(0xFFFFF7F6)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Colors.orange.shade100),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFF1F0),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.timer,
                          color: Color(0xFFFF5722),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: const [
                            Text(
                              'Safe Timer',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 15,
                              ),
                            ),
                            SizedBox(height: 4),
                            Text(
                              'Set up auto check-in',
                              style: TextStyle(color: Colors.black54),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Text(
                          'Setup Required',
                          style: TextStyle(color: Color(0xFFFF5722)),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),

              // Medical + Safety Tips side by side
              Row(
                children: [
                  Expanded(
                    child: _InfoCard(
                      icon: Icons.medical_information_outlined,
                      title: 'Medical',
                      subtitle: 'Emergency info',
                      onTap: () => Navigator.pushNamed(context, '/medical'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _InfoCard(
                      icon: Icons.shield_outlined,
                      title: 'Safety Tips',
                      subtitle: 'Stay aware',
                      onTap: () => _showSafetyTipsModal(context),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 10),

              // Quick Actions row 2: Evidence + Emergency Contacts
              Row(
                children: [
                  Expanded(
                    child: _InfoCard(
                      icon: Icons.video_call_outlined,
                      title: 'Evidence',
                      subtitle: 'Record & save proof',
                      onTap: () => Navigator.pushNamed(context, '/evidence'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _InfoCard(
                      icon: Icons.contacts_outlined,
                      title: 'Emergency Contacts',
                      subtitle: 'Connect with trusted',
                      onTap: () => Navigator.pushNamed(context, '/contacts'),
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

// ─────────────────────────────────────────────
// PROFILE PAGE
// ─────────────────────────────────────────────

class _ProfilePage extends StatefulWidget {
  const _ProfilePage();

  @override
  State<_ProfilePage> createState() => _ProfilePageState();
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

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Profile',
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
                color: Color(0xFF1A1A1A),
              ),
            ),
            const SizedBox(height: 20),

            // Profile Card at top
            GestureDetector(
              onTap: () async {
                await Navigator.pushNamed(context, '/user_profile');
                _loadData();
              },
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFFFF5722), Color(0xFFFF1744)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 60,
                      height: 60,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white.withOpacity(0.2),
                        border: Border.all(
                          color: Colors.white.withOpacity(0.5),
                          width: 2,
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
                                  fontSize: 24,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
                                ),
                              ),
                            )
                          : null,
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _userName.isEmpty ? 'Set your name' : _userName,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _userPhone.isEmpty
                                ? 'Add phone number'
                                : _userPhone,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Icon(Icons.edit, color: Colors.white70, size: 18),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),

            _SectionLabel('Safety'),
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
            const SizedBox(height: 16),

            _SectionLabel('Health'),
            _ProfileItem(
              icon: Icons.medical_information_outlined,
              title: 'Medical Profile',
              onTap: () => Navigator.pushNamed(context, '/medical'),
            ),
            const SizedBox(height: 16),

            _SectionLabel('History'),
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
            const SizedBox(height: 16),

            _SectionLabel('Account'),
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
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// SHARED WIDGETS
// ─────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  final String label;
  const _SectionLabel(this.label);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, left: 4),
      child: Text(
        label.toUpperCase(),
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.bold,
          color: Colors.black38,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _InfoCard({
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
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 10,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: const Color(0xFFFF5722).withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: const Color(0xFFFF5722), size: 24),
            ),
            const SizedBox(height: 12),
            Text(
              title,
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 14,
                color: Color(0xFF1A1A1A),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              subtitle,
              style: const TextStyle(fontSize: 12, color: Colors.black45),
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
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: const Color(0xFFFF5722).withOpacity(0.08),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: const Color(0xFFFF5722), size: 20),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: titleColor ?? const Color(0xFF1A1A1A),
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
                  size: 14,
                  color: Colors.black26,
                ),
          ],
        ),
      ),
    );
  }
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
