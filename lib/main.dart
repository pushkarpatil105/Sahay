// lib/main.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';
import 'screens/splash_screen.dart'; // exports both SplashScreen and OnboardingScreen
import 'screens/auth/phone_auth_screen.dart';
import 'screens/auth/otp_screen.dart';
import 'screens/home/home_screen.dart';
import 'screens/profile/emergency_contacts_screen.dart';
import 'screens/profile/medical_profile_screen.dart';
import 'screens/map/safety_map_screen.dart';
import 'screens/sos/sos_active_screen.dart';
import 'screens/sos/sos_countdown_screen.dart';
import 'screens/profile/user_profile_screen.dart';
import 'screens/notifications_screen.dart';
import 'screens/timer/safe_timer_screen.dart';
import 'screens/profile/sos_history_screen.dart';
import 'screens/profile/evidence_storage_screen.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:sahay/core/services/upload_queue_service.dart';
// IMPORT the service
import 'package:sahay/core/services/lock_screen_sos_service.dart';
import 'package:sahay/widgets/live_share_bubble.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    await dotenv.load(fileName: ".env");
  } catch (e) {
    debugPrint('âš ï¸ Error loading .env file: $e');
  }

  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  // INITIALIZE Lock Screen Service
  // This allows the MethodChannel to start listening for native "SOS Button" taps immediately
  await LockScreenSosService().init();

  await UploadQueueService().init();

  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
    ),
  );
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return WithForegroundTask(
      child: MaterialApp(
        title: 'Sahay',
        navigatorKey:
            navigatorKey, // CRITICAL: Required to trigger SOS from background
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFFFF5722),
            brightness: Brightness.light,
          ),
          scaffoldBackgroundColor: const Color(0xFFFAFAFA),
          fontFamily: 'Roboto',
          useMaterial3: true,
        ),
        builder: (context, child) {
          return Stack(
            children: [
              child ?? const SizedBox.shrink(),
              const LiveShareBubble(),
            ],
          );
        },
        initialRoute: '/',
        routes: {
          '/': (context) => const SplashScreen(),
          '/onboarding': (context) => const OnboardingScreen(),
          '/phone': (context) => const PhoneAuthScreen(),
          '/otp': (context) => const OtpScreen(),
          '/home': (context) => const HomeScreen(),
          '/contacts': (context) => const EmergencyContactsScreen(),
          '/medical': (context) => const MedicalProfileScreen(),
          '/map': (context) => const SafetyMapScreen(),
          '/sos_countdown': (context) => const SosCountdownScreen(),
          '/sos_active': (context) => const SosActiveScreen(),
          '/user_profile': (context) => const UserProfileScreen(),
          '/notifications': (context) => const NotificationsScreen(),
          '/safe_timer': (context) {
            final args =
                ModalRoute.of(context)?.settings.arguments
                    as Map<String, dynamic>?;
            final autoStart = args?['autoStart'] == true;
            return SafeTimerScreen(autoStart: autoStart);
          },
          '/sos_history': (context) => const SosHistoryScreen(),
          '/evidence': (context) => const EvidenceStorageScreen(),
        },
      ),
    );
  }
}
