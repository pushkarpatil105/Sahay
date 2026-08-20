import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../core/services/sos_service.dart';
import 'package:nari_shakti/core/services/lock_screen_sos_service.dart';

class SafeTimerScreen extends StatefulWidget {
  /// When true, the timer starts automatically after loading settings
  /// (used when triggered by IoT button press).
  final bool autoStart;

  const SafeTimerScreen({super.key, this.autoStart = false});

  @override
  State<SafeTimerScreen> createState() => _SafeTimerScreenState();
}

class _SafeTimerScreenState extends State<SafeTimerScreen> {
  // Settings
  int _timerMinutes = 30;
  String _safePin = '';
  int _graceSeconds = 60;

  // Timer state
  bool _isRunning = false;
  bool _isGracePeriod = false;
  int _remainingSeconds = 0;
  int _graceRemaining = 0;
  Timer? _timer;
  Timer? _graceTimer;

  // PIN entry
  final List<TextEditingController> _pinControllers = List.generate(
    4,
    (_) => TextEditingController(),
  );
  final List<FocusNode> _pinFocusNodes = List.generate(4, (_) => FocusNode());
  final String _enteredPin = '';
  bool _pinError = false;

  /// Whether auto-start has already been attempted (prevents re-triggering
  /// on hot-reload or rebuild).
  bool _autoStartHandled = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _graceTimer?.cancel();
    for (var c in _pinControllers) {
      c.dispose();
    }
    for (var f in _pinFocusNodes) {
      f.dispose();
    }
    super.dispose();
  }

  Future<void> _loadSettings() async {
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) return;
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .get();
      if (!mounted) return;
      setState(() {
        _timerMinutes = doc.data()?['safe_timer_minutes'] ?? 30;
        _safePin = doc.data()?['safe_pin'] ?? '';
        _graceSeconds = doc.data()?['grace_seconds'] ?? 60;
        _remainingSeconds = _timerMinutes * 60;
      });
    } catch (e) {}

    // Auto-start the timer when triggered by IoT button press
    if (widget.autoStart && !_autoStartHandled) {
      _autoStartHandled = true;
      // Small delay to let the widget fully build before starting
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_safePin.isEmpty) {
          // PIN not set yet – show settings dialog so user can configure
          _showSetPinFirst();
        } else {
          _startTimer();
        }
      });
    }
  }

  Future<void> _saveSettings() async {
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      await FirebaseFirestore.instance.collection('users').doc(uid).set({
        'safe_timer_minutes': _timerMinutes,
        'safe_pin': _safePin,
        'grace_seconds': _graceSeconds,
      }, SetOptions(merge: true));
    } catch (e) {}
  }

  void _startTimer() {
    if (_safePin.isEmpty) {
      _showSetPinFirst();
      return;
    }
    setState(() {
      _isRunning = true;
      _remainingSeconds = _timerMinutes * 60;
    });
    _vibrateCountdownTick();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (_remainingSeconds <= 0) {
        t.cancel();
        _startGracePeriod();
      } else {
        setState(() => _remainingSeconds--);
        _vibrateCountdownTick();
      }
    });
  }

  void _stopTimer() {
    _timer?.cancel();
    _graceTimer?.cancel();
    setState(() {
      _isRunning = false;
      _isGracePeriod = false;
      _remainingSeconds = _timerMinutes * 60;
      _graceRemaining = _graceSeconds;
    });
  }

  void _startGracePeriod() {
    setState(() {
      _isGracePeriod = true;
      _graceRemaining = _graceSeconds;
    });
    _graceTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (_graceRemaining <= 0) {
        t.cancel();
        _autoSOS();
      } else {
        setState(() => _graceRemaining--);
        _vibrateCountdownTick();
      }
    });
  }

  void _autoSOS() {
    setState(() {
      _isRunning = false;
      _isGracePeriod = false;
    });
    SosService().triggerSOS(context, 'dead_man_switch');
  }

  void _vibrateCountdownTick() {
    LockScreenSosService().vibrateSOSWarning();
  }

  void _checkPin() {
    final entered = _pinControllers.map((c) => c.text).join();
    if (entered == _safePin) {
      _graceTimer?.cancel();
      _timer?.cancel();
      setState(() {
        _isRunning = false;
        _isGracePeriod = false;
        _remainingSeconds = _timerMinutes * 60;
        _pinError = false;
      });
      for (var c in _pinControllers) {
        c.clear();
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('✅ You\'re safe! Timer stopped.'),
          backgroundColor: Colors.green,
        ),
      );
    } else {
      setState(() => _pinError = true);
      for (var c in _pinControllers) {
        c.clear();
      }
      _pinFocusNodes[0].requestFocus();
    }
  }

  void _showSetPinFirst() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Please set your safe PIN in settings first'),
        backgroundColor: const Color(0xFFFF5722),
        action: SnackBarAction(
          label: 'Set PIN',
          textColor: Colors.white,
          onPressed: _showSettingsDialog,
        ),
      ),
    );
  }

  void _showSettingsDialog() {
    int tempMinutes = _timerMinutes;
    int tempGrace = _graceSeconds;
    final pinController = TextEditingController(text: _safePin);

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: const Text(
            'Timer Settings',
            style: TextStyle(
              color: Color(0xFF1A1A1A),
              fontWeight: FontWeight.bold,
            ),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Timer duration
                const Text(
                  'Timer Duration',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF1A1A1A),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '$tempMinutes minutes',
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFFFF5722),
                  ),
                ),
                Slider(
                  value: tempMinutes.toDouble(),
                  min: 1,
                  max: 120,
                  divisions: 119,
                  activeColor: const Color(0xFFFF5722),
                  inactiveColor: Colors.grey.shade200,
                  onChanged: (v) =>
                      setDialogState(() => tempMinutes = v.toInt()),
                ),
                const SizedBox(height: 16),

                // Grace period
                const Text(
                  'Grace Period (to enter PIN)',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF1A1A1A),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '$tempGrace seconds',
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFFFF5722),
                  ),
                ),
                Slider(
                  value: tempGrace.toDouble(),
                  min: 10,
                  max: 300,
                  divisions: 29,
                  activeColor: const Color(0xFFFF5722),
                  inactiveColor: Colors.grey.shade200,
                  onChanged: (v) => setDialogState(() => tempGrace = v.toInt()),
                ),
                const SizedBox(height: 16),

                // Safe PIN
                const Text(
                  'Safe PIN (4 digits)',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF1A1A1A),
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: pinController,
                  keyboardType: TextInputType.number,
                  maxLength: 4,
                  obscureText: true,
                  style: const TextStyle(
                    color: Color(0xFF1A1A1A),
                    fontSize: 20,
                    letterSpacing: 8,
                  ),
                  decoration: InputDecoration(
                    hintText: '••••',
                    hintStyle: const TextStyle(color: Colors.black26),
                    filled: true,
                    fillColor: Colors.grey.shade50,
                    counterText: '',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: Colors.grey.shade200),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: Colors.grey.shade200),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(
                        color: Color(0xFFFF5722),
                        width: 2,
                      ),
                    ),
                  ),
                ),
              ],
            ),
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
                setState(() {
                  _timerMinutes = tempMinutes;
                  _graceSeconds = tempGrace;
                  _safePin = pinController.text;
                  _remainingSeconds = _timerMinutes * 60;
                });
                _saveSettings();
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

  String _formatTime(int seconds) {
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFAFAFA),
      appBar: AppBar(
        backgroundColor: Colors.white,
        title: const Text(
          'Safe Timer',
          style: TextStyle(
            color: Color(0xFF1A1A1A),
            fontWeight: FontWeight.bold,
          ),
        ),
        iconTheme: const IconThemeData(color: Color(0xFF1A1A1A)),
        elevation: 0,
        actions: [
          IconButton(
            onPressed: _isRunning ? null : _showSettingsDialog,
            icon: Icon(
              Icons.settings_outlined,
              color: _isRunning ? Colors.black26 : const Color(0xFFFF5722),
            ),
          ),
        ],
      ),
      body: _isGracePeriod ? _buildGraceUI() : _buildTimerUI(),
    );
  }

  Widget _buildTimerUI() {
    final progress = _isRunning
        ? _remainingSeconds / (_timerMinutes * 60)
        : 1.0;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            const SizedBox(height: 20),

            // How it works card
            if (!_isRunning)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFFFF5722).withOpacity(0.06),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: const Color(0xFFFF5722).withOpacity(0.15),
                  ),
                ),
                child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'How it works',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF1A1A1A),
                        fontSize: 14,
                      ),
                    ),
                    SizedBox(height: 8),
                    Text(
                      '1. Set your timer duration and safe PIN in settings\n'
                      '2. Start the timer before a journey\n'
                      '3. When timer ends, enter your PIN to confirm safety\n'
                      '4. If PIN not entered in time → SOS auto-triggers',
                      style: TextStyle(
                        color: Colors.black54,
                        fontSize: 13,
                        height: 1.6,
                      ),
                    ),
                  ],
                ),
              ),

            const Spacer(),

            // Circular timer
            SizedBox(
              width: 220,
              height: 220,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  SizedBox(
                    width: 220,
                    height: 220,
                    child: CircularProgressIndicator(
                      value: progress,
                      strokeWidth: 8,
                      backgroundColor: Colors.grey.shade200,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        _isRunning
                            ? const Color(0xFFFF5722)
                            : Colors.grey.shade300,
                      ),
                    ),
                  ),
                  Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        _isRunning
                            ? _formatTime(_remainingSeconds)
                            : _formatTime(_timerMinutes * 60),
                        style: TextStyle(
                          fontSize: 44,
                          fontWeight: FontWeight.bold,
                          color: _isRunning
                              ? const Color(0xFF1A1A1A)
                              : Colors.black38,
                        ),
                      ),
                      Text(
                        _isRunning ? 'remaining' : '$_timerMinutes min',
                        style: const TextStyle(
                          fontSize: 13,
                          color: Colors.black38,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),

            Text(
              _isRunning
                  ? 'Timer is active. Enter PIN when prompted.'
                  : 'Press Start to begin safe journey timer',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.black45, fontSize: 13),
            ),

            const Spacer(),

            // Buttons
            Row(
              children: [
                if (_isRunning)
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _stopTimer,
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Color(0xFFFF5722)),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                      child: const Text(
                        'Stop Timer',
                        style: TextStyle(
                          color: Color(0xFFFF5722),
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ),
                if (_isRunning) const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: ElevatedButton(
                    onPressed: _isRunning ? null : _startTimer,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFFF5722),
                      disabledBackgroundColor: Colors.grey.shade300,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      elevation: 0,
                    ),
                    child: Text(
                      _isRunning ? 'Running...' : 'Start Timer',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (!_isRunning)
              TextButton.icon(
                onPressed: _showSettingsDialog,
                icon: const Icon(
                  Icons.tune,
                  color: Color(0xFFFF5722),
                  size: 16,
                ),
                label: const Text(
                  'Tap settings to set PIN & duration',
                  style: TextStyle(color: Color(0xFFFF5722), fontSize: 13),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildGraceUI() {
    final graceProgress = _graceRemaining / _graceSeconds;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Warning header
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: const Color(0xFFFF1744).withOpacity(0.08),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: const Color(0xFFFF1744).withOpacity(0.3),
                ),
              ),
              child: Column(
                children: [
                  const Icon(
                    Icons.warning_amber_rounded,
                    color: Color(0xFFFF1744),
                    size: 48,
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Are you safe?',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF1A1A1A),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Enter your safe PIN to confirm.\nSOS will auto-trigger if time runs out.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.black54, fontSize: 14),
                  ),
                  const SizedBox(height: 16),
                  // Grace countdown
                  SizedBox(
                    width: 80,
                    height: 80,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        CircularProgressIndicator(
                          value: graceProgress,
                          strokeWidth: 6,
                          backgroundColor: Colors.grey.shade200,
                          valueColor: const AlwaysStoppedAnimation<Color>(
                            Color(0xFFFF1744),
                          ),
                        ),
                        Text(
                          '$_graceRemaining',
                          style: const TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFFFF1744),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'seconds remaining',
                    style: TextStyle(color: Colors.black38, fontSize: 12),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 32),

            // PIN entry
            if (_pinError)
              const Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: Text(
                  'Wrong PIN. Try again.',
                  style: TextStyle(
                    color: Color(0xFFFF1744),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),

            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: List.generate(4, (index) {
                return SizedBox(
                  width: 60,
                  height: 68,
                  child: TextField(
                    controller: _pinControllers[index],
                    focusNode: _pinFocusNodes[index],
                    keyboardType: TextInputType.number,
                    maxLength: 1,
                    obscureText: true,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Color(0xFF1A1A1A),
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    ),
                    decoration: InputDecoration(
                      counterText: '',
                      filled: true,
                      fillColor: Colors.grey.shade50,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: Colors.grey.shade200),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: Colors.grey.shade200),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(
                          color: Color(0xFFFF5722),
                          width: 2,
                        ),
                      ),
                    ),
                    onChanged: (value) {
                      setState(() => _pinError = false);
                      if (value.isNotEmpty && index < 3) {
                        _pinFocusNodes[index + 1].requestFocus();
                      }
                      if (value.isEmpty && index > 0) {
                        _pinFocusNodes[index - 1].requestFocus();
                      }
                      if (index == 3 && value.isNotEmpty) {
                        Future.delayed(
                          const Duration(milliseconds: 100),
                          _checkPin,
                        );
                      }
                    },
                  ),
                );
              }),
            ),
            const SizedBox(height: 24),

            SizedBox(
              width: double.infinity,
              height: 56,
              child: ElevatedButton(
                onPressed: _checkPin,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFFF5722),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  elevation: 0,
                ),
                child: const Text(
                  "I'm Safe",
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
