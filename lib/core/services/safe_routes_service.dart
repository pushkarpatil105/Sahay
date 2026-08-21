import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../models/route_model.dart';

class SafeRoutesService {
  static const String scoreRoutesEndpoint = '/api/v1/scoreRoutes';
  static const String _cacheKey = 'backend_url_cache';

  // List of URLs to try (in order of preference)
  static const List<String> _possibleUrls = [
    'http://192.168.0.148:5050', // Physical device or native emulator
  ];

  static String? _cachedBackendUrl;

  static Future<void> clearCachedBackendUrl() async {
    _cachedBackendUrl = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_cacheKey);
  }

  /// Auto-detect backend URL by testing connectivity
  /// Caches the working URL for subsequent calls
  static Future<String> getBackendUrl({bool forceRefresh = false}) async {
    print('ðŸ“ Starting backend URL detection...');
    final prefs = await SharedPreferences.getInstance();

    if (forceRefresh) {
      print('â™»ï¸ Forcing backend rediscovery');
      await clearCachedBackendUrl();
    }

    // Return cached URL if available and still reachable.
    if (_cachedBackendUrl != null) {
      print('ðŸ“Œ Using cached backend URL: $_cachedBackendUrl');
      if (await _validateBackendUrl(_cachedBackendUrl!)) {
        return _cachedBackendUrl!;
      }
      print('â™»ï¸ Cached backend URL is stale, clearing it');
      _cachedBackendUrl = null;
      await prefs.remove(_cacheKey);
    }

    // Try to load from SharedPreferences
    final cachedUrl = prefs.getString(_cacheKey);

    if (cachedUrl != null) {
      print('ðŸ“Œ Loaded backend URL from cache: $cachedUrl');
      if (await _validateBackendUrl(cachedUrl)) {
        _cachedBackendUrl = cachedUrl;
        return cachedUrl;
      }
      print('â™»ï¸ Stored backend URL is stale, clearing it');
      await prefs.remove(_cacheKey);
    }

    // Auto-detect by trying each URL
    print('ðŸ” Auto-detecting backend URL...');
    for (final url in _possibleUrls) {
      print('  â†³ Trying: $url');
      try {
        final response = await http
            .get(Uri.parse('$url/health'))
            .timeout(const Duration(seconds: 3));

        if (response.statusCode == 200) {
          print('âœ… Backend found at: $url');
          _cachedBackendUrl = url;
          await prefs.setString(_cacheKey, url);
          return url;
        }
      } catch (e) {
        print('  âœ— Not reachable: $e');
        continue;
      }
    }

    print('â³ Loopback addresses failed. Starting LAN subnet scan...');
    // If the simple loopback checks failed, scan the local LAN subnet.
    final lanUrl = await _scanLocalSubnetForBackend();
    if (lanUrl != null) {
      print('âœ… Backend found on LAN at: $lanUrl');
      _cachedBackendUrl = lanUrl;
      await prefs.setString(_cacheKey, lanUrl);
      return lanUrl;
    }

    // If none work, throw error with helpful info
    print('â›” LAN scan also failed. No backend found.');
    print('âŒ Could not find backend at any of these addresses:');
    for (final url in _possibleUrls) {
      print('   - $url');
    }
    print('ðŸ’¡ Make sure:');
    print(
      '   1. FastAPI backend is running: python main.py or uvicorn main:app --host 0.0.0.0 --port 5050',
    );
    print('   2. Your device is on the SAME WiFi network as your PC');
    print('   3. Firewall allows port 5050');
    print(
      '   4. Find your PC IP with "ipconfig" and check if accessible from phone on same WiFi',
    );
    throw Exception(
      'Backend not found. Make sure FastAPI is running on port 5050 and your device is on the same network.',
    );
  }

  static Future<bool> _validateBackendUrl(String backendUrl) async {
    try {
      final response = await http
          .get(Uri.parse('$backendUrl/health'))
          .timeout(const Duration(seconds: 2));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  static Future<String?> _scanLocalSubnetForBackend() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );

      final addresses = interfaces
          .expand((interface) => interface.addresses)
          .where(
            (address) => !address.isLoopback && address.rawAddress.length == 4,
          )
          .toList();

      if (addresses.isEmpty) {
        print('âš ï¸ Could not determine local IPv4 address for LAN scan');
        return null;
      }

      final orderedAddresses = [...addresses]
        ..sort((a, b) {
          int score(InternetAddress address) {
            final octets = address.address.split('.');
            if (octets.length != 4) return 0;
            final first = int.tryParse(octets[0]) ?? 0;
            final second = int.tryParse(octets[1]) ?? 0;
            if (first == 10 ||
                (first == 192 && second == 168) ||
                (first == 172 && second >= 16 && second <= 31)) {
              return 2;
            }
            return 1;
          }

          return score(b).compareTo(score(a));
        });

      final subnetPrefixes = <String>{
        for (final address in orderedAddresses)
          if (address.address.split('.').length == 4)
            '${address.address.split('.')[0]}.${address.address.split('.')[1]}.${address.address.split('.')[2]}',
      }.toList();

      print(
        'ðŸŒ Device IPv4 candidates: ${orderedAddresses.map((address) => address.address).join(', ')}',
      );
      print('ðŸ”Ž Scanning for backend on detected subnets (port 5050)...');

      // Scan a small subset first, then expand if needed.
      final candidateHosts = <int>{1, 2, 10, 20, 50, 100, 150, 200, 254};
      final sequentialChecks = List<int>.generate(254, (index) => index + 1)
        ..shuffle();

      // Prioritize common host addresses, then fall back to full scan.
      final orderedCandidates = <int>{
        ...candidateHosts,
        ...sequentialChecks.take(60),
      };

      for (final subnetPrefix in subnetPrefixes) {
        print('   â†³ Checking subnet $subnetPrefix.0/24');
        var checked = 0;
        for (final host in orderedCandidates) {
          checked++;
          final url = 'http://$subnetPrefix.$host:5050';
          try {
            final response = await http
                .get(Uri.parse('$url/health'))
                .timeout(const Duration(milliseconds: 500));
            if (response.statusCode == 200) {
              print(
                'âœ… LAN scan: Found backend at $url after checking $checked hosts',
              );
              return url;
            }
          } catch (_) {
            // keep scanning
          }
        }
        print(
          'â›” Subnet $subnetPrefix checked $checked hosts, none responded with healthy backend',
        );
      }
    } catch (e) {
      print('âš ï¸ LAN scan failed: $e');
    }

    return null;
  }

  /// Score routes and get top-3 safest options
  static Future<ScoreRoutesResponse> scoreRoutes({
    required double originLat,
    required double originLng,
    required double destLat,
    required double destLng,
    String travelMode = 'driving',
  }) async {
    try {
      // Get backend URL (auto-detect if needed)
      final backendUrl = await getBackendUrl();

      // Get Firebase ID token
      final user = FirebaseAuth.instance.currentUser;
      String? idToken;
      if (user != null) {
        idToken = await user.getIdToken();
      }

      final payload = {
        'user_id': user?.uid ?? 'anonymous',
        'origin': {'lat': originLat, 'lng': originLng},
        'destination': {'lat': destLat, 'lng': destLng},
        'trip_time': DateTime.now().toIso8601String(),
        'travel_mode': travelMode,
      };

      final headers = {
        'Content-Type': 'application/json',
        if (idToken != null) 'Authorization': 'Bearer $idToken',
      };

      print(
        'ðŸš€ Attempting to connect to backend at: $backendUrl$scoreRoutesEndpoint',
      );
      print(
        'ðŸ“ Route request: Origin ($originLat, $originLng) â†’ Destination ($destLat, $destLng)',
      );
      print(
        'â³ Waiting for model to score routes (this may take 20-30 seconds)...',
      );

      final response = await http
          .post(
            Uri.parse('$backendUrl$scoreRoutesEndpoint'),
            headers: headers,
            body: jsonEncode(payload),
          )
          .timeout(
            const Duration(seconds: 120),
            onTimeout: () {
              print('â±ï¸ TIMEOUT: Backend not responding after 120 seconds');
              throw TimeoutException(
                'Backend did not respond. Check if:\n'
                '1. FastAPI backend is running on port 5050\n'
                '2. Device is on the same WiFi network\n'
                '3. No firewall blocking port 5050',
                null,
              );
            },
          );

      print('âœ… Backend response received with status: ${response.statusCode}');

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        print(
          'ðŸ“Š Successfully parsed ${data['meta']['routes_scored']} scored routes',
        );
        return ScoreRoutesResponse.fromJson(data);
      } else {
        print('âŒ Backend error: ${response.statusCode}');
        print('ðŸ“ Response: ${response.body}');
        throw Exception(
          'Failed to score routes: ${response.statusCode} - ${response.body}',
        );
      }
    } catch (e) {
      print('ðŸ”´ Error in scoreRoutes: $e');
      throw Exception('Error scoring routes: $e');
    }
  }

  /// Health check for backend
  static Future<bool> healthCheck() async {
    try {
      final backendUrl = await getBackendUrl();
      print('ðŸ¥ Pinging backend at: $backendUrl/health');
      final response = await http
          .get(Uri.parse('$backendUrl/health'))
          .timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        print('âœ… Backend is healthy and reachable');
        return true;
      } else {
        print('âš ï¸ Backend responded with status: ${response.statusCode}');
        return false;
      }
    } catch (e) {
      print('âŒ Health check failed: $e');
      print('ðŸ”§ Troubleshooting:');
      print('   - Is FastAPI running on port 5050?');
      print('   - Is your device on the same WiFi network?');
      print('   - Machine IP: Open Command Prompt and run "ipconfig"');
      print('   - Look for IPv4 Address (e.g., 192.168.1.100)');
      return false;
    }
  }
}


