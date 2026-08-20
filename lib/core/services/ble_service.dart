import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nari_shakti/core/services/sos_service.dart';
import 'package:nari_shakti/core/services/lock_screen_sos_service.dart';
import 'package:nari_shakti/main.dart';

enum BleStatus {
  idle,
  bluetoothOff,
  permissionsDenied,
  scanning,
  connecting,
  connected,
  disconnected,
  error,
}

class BleService {
  BleService._internal();
  static final BleService _instance = BleService._internal();
  factory BleService() => _instance;

  static final Guid _serviceUuid = Guid('6E400001-B5A3-F393-E0A9-E50E24DCCA9E');
  static final Guid _rxUuid = Guid('6E400003-B5A3-F393-E0A9-E50E24DCCA9E');
  static final Guid _txUuid = Guid('6E400002-B5A3-F393-E0A9-E50E24DCCA9E');
  static const String _lastDeviceKey = 'ble_last_device_id';

  final StreamController<BleStatus> _statusController =
      StreamController<BleStatus>.broadcast();
  final StreamController<List<ScanResult>> _devicesController =
      StreamController<List<ScanResult>>.broadcast();
  final StreamController<String> _eventController =
      StreamController<String>.broadcast();

  BleStatus _status = BleStatus.idle;
  final List<ScanResult> _scanDevices = [];

  BluetoothDevice? _connectedDevice;
  BluetoothCharacteristic? _rxCharacteristic;
  BluetoothCharacteristic? _txCharacteristic;

  StreamSubscription<BluetoothConnectionState>? _connectionSub;
  StreamSubscription<List<int>>? _notifySub;
  StreamSubscription<BluetoothAdapterState>? _adapterSub;
  StreamSubscription<List<ScanResult>>? _scanSub;

  bool _isInitialized = false;
  bool _isConnecting = false;
  bool _autoReconnect = true;
  String? _lastDeviceRemoteId;

  Stream<BleStatus> get statusStream => _statusController.stream;
  Stream<List<ScanResult>> get devicesStream => _devicesController.stream;
  Stream<String> get eventStream => _eventController.stream;

  BleStatus get status => _status;
  bool get isConnected => _status == BleStatus.connected;
  BluetoothDevice? get connectedDevice => _connectedDevice;

  Future<void> initialize() async {
    if (_isInitialized) return;
    _isInitialized = true;

    await _loadLastConnectedDevice();

    _adapterSub = FlutterBluePlus.adapterState.listen((state) {
      if (state == BluetoothAdapterState.off) {
        _setStatus(BleStatus.bluetoothOff);
      } else if (_status == BleStatus.bluetoothOff) {
        _setStatus(BleStatus.idle);
        if (_autoReconnect && _lastDeviceRemoteId != null) {
          startScan();
        }
      }
    });
  }

  Future<bool> requestPermissions() async {
    if (!Platform.isAndroid) return true;

    final List<Permission> requiredPermissions = [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
    ];
    final List<Permission> optionalPermissions = [Permission.locationWhenInUse];

    final result = await [
      ...requiredPermissions,
      ...optionalPermissions,
    ].request();
    final granted = requiredPermissions.every(
      (permission) => result[permission]?.isGranted == true,
    );
    if (!granted) {
      _setStatus(BleStatus.permissionsDenied);
    }
    return granted;
  }

  Future<bool> ensureBluetoothOn() async {
    final state = await FlutterBluePlus.adapterState.first;
    if (state == BluetoothAdapterState.on) return true;

    if (Platform.isAndroid) {
      try {
        await FlutterBluePlus.turnOn();
      } catch (e) {
        debugPrint('[BLE] turnOn failed: $e');
      }
    }

    final newState = await FlutterBluePlus.adapterState.first;
    if (newState != BluetoothAdapterState.on) {
      _setStatus(BleStatus.bluetoothOff);
      return false;
    }
    _setStatus(BleStatus.idle);
    return true;
  }

  Future<void> startScan() async {
    await initialize();

    final hasPermissions = await requestPermissions();
    if (!hasPermissions) return;

    final btOn = await ensureBluetoothOn();
    if (!btOn) return;

    _scanDevices.clear();
    _devicesController.add(List.unmodifiable(_scanDevices));
    _setStatus(BleStatus.scanning);

    await _scanSub?.cancel();
    _scanSub = FlutterBluePlus.scanResults.listen((results) async {
      final filtered = results.where(_isTargetDevice).toList();
      debugPrint(
        '[BLE] scanResults=${results.length} filtered=${filtered.length}',
      );
      for (final r in filtered) {
        debugPrint(
          '[BLE] found device name=${r.device.platformName} adv=${r.advertisementData.advName} '
          'id=${r.device.remoteId.str} rssi=${r.rssi} services=${r.advertisementData.serviceUuids.map((e) => e.str).join(',')}',
        );
      }
      _scanDevices
        ..clear()
        ..addAll(filtered);
      _devicesController.add(List.unmodifiable(_scanDevices));

      if (_autoReconnect && _lastDeviceRemoteId != null && !_isConnecting) {
        for (final r in filtered) {
          if (r.device.remoteId.str == _lastDeviceRemoteId && !isConnected) {
            await connect(r.device);
            break;
          }
        }
      }
    });

    try {
      await FlutterBluePlus.startScan(
        // Do not hard-filter by service UUID during scan.
        // Some firmware builds do not advertise service UUID in scan response.
        timeout: const Duration(seconds: 8),
      );
    } catch (e) {
      debugPrint('[BLE] scan error: $e');
      _setStatus(BleStatus.error);
    }
  }

  Future<void> stopScan() async {
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
    if (!isConnected) {
      _setStatus(BleStatus.idle);
    }
  }

  Future<void> connect(BluetoothDevice device) async {
    if (_isConnecting) return;
    _isConnecting = true;
    _setStatus(BleStatus.connecting);

    debugPrint(
      '[BLE] connect request name=${device.platformName} id=${device.remoteId.str}',
    );

    try {
      await stopScan();
      await _notifySub?.cancel();
      await _connectionSub?.cancel();

      await device.connect(timeout: const Duration(seconds: 15));
      _connectedDevice = device;
      _lastDeviceRemoteId = device.remoteId.str;
      await _saveLastConnectedDevice(_lastDeviceRemoteId!);

      _connectionSub = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.connected) {
          _setStatus(BleStatus.connected);
        } else if (state == BluetoothConnectionState.disconnected) {
          _setStatus(BleStatus.disconnected);
          _rxCharacteristic = null;
          _txCharacteristic = null;
          _connectedDevice = null;
          if (_autoReconnect && _lastDeviceRemoteId != null) {
            startScan();
          }
        }
      });

      await _discoverCharacteristics(device);
      _setStatus(BleStatus.connected);
    } catch (e) {
      debugPrint('[BLE] connect error: $e');
      _setStatus(BleStatus.error);
    } finally {
      _isConnecting = false;
    }
  }

  Future<void> _discoverCharacteristics(BluetoothDevice device) async {
    final services = await device.discoverServices();
    debugPrint('[BLE] discovered ${services.length} services');

    BluetoothCharacteristic? fallbackNotifyCharacteristic;
    BluetoothCharacteristic? fallbackWriteCharacteristic;

    for (final service in services) {
      debugPrint(
        '[BLE] service ${service.uuid.str} chars=${service.characteristics.length}',
      );
      if (service.uuid != _serviceUuid) continue;

      for (final c in service.characteristics) {
        debugPrint(
          '[BLE] char ${c.uuid.str} props notify=${c.properties.notify} indicate=${c.properties.indicate} '
          'read=${c.properties.read} write=${c.properties.write} writeNoResp=${c.properties.writeWithoutResponse}',
        );
        if (c.uuid == _txUuid) {
          _txCharacteristic = c;
          debugPrint(
            '[BLE] matched notify characteristic ${c.uuid.str} (incoming SOS)',
          );
        } else if (c.uuid == _rxUuid) {
          _rxCharacteristic = c;
          debugPrint(
            '[BLE] matched write characteristic ${c.uuid.str} (outgoing commands)',
          );
        } else if ((c.properties.notify || c.properties.indicate) &&
            fallbackNotifyCharacteristic == null) {
          fallbackNotifyCharacteristic = c;
        } else if ((c.properties.write || c.properties.writeWithoutResponse) &&
            fallbackWriteCharacteristic == null) {
          fallbackWriteCharacteristic = c;
        }
      }
    }

    if (_txCharacteristic == null && fallbackNotifyCharacteristic != null) {
      _txCharacteristic = fallbackNotifyCharacteristic;
      debugPrint(
        '[BLE] using fallback notify characteristic ${_txCharacteristic!.uuid.str}',
      );
    }

    if (_rxCharacteristic == null && fallbackWriteCharacteristic != null) {
      _rxCharacteristic = fallbackWriteCharacteristic;
      debugPrint(
        '[BLE] using fallback write characteristic ${_rxCharacteristic!.uuid.str}',
      );
    }

    if (_txCharacteristic == null) {
      debugPrint('[BLE] no notify characteristic found for incoming SOS data');
    }
    if (_rxCharacteristic == null) {
      debugPrint(
        '[BLE] no write characteristic found for outgoing vibration commands',
      );
    }

    if (_txCharacteristic != null) {
      await _txCharacteristic!.setNotifyValue(true);
      await _notifySub?.cancel();
      _notifySub = _txCharacteristic!.onValueReceived.listen((value) async {
        if (value.isEmpty) return;
        final msg = utf8.decode(value, allowMalformed: true).trim();
        final normalized = msg.toUpperCase();
        debugPrint(
          '[BLE] notification from ${_txCharacteristic!.uuid.str} raw="$msg" bytes=$value',
        );

        if (normalized == 'TIMER_START' ||
            normalized == 'SOS_FROM_BUTTON' ||
            normalized == 'BOTH_TRIGGERS_FIRING' ||
            normalized == 'SOS_FROM_SHAKE') {
          // Forward raw message so UI/listeners can decide how to react.
          _eventController.add(msg);

          // If Flutter UI isn't available (background/lock-screen), bring
          // app to foreground and route to the appropriate screen.
          try {
            if (navigatorKey.currentState == null) {
              await LockScreenSosService().bringAppToForeground();
              // Wait briefly for the Flutter engine to become available
              await Future.delayed(const Duration(milliseconds: 500));
            }

            if (normalized == 'SOS_FROM_BUTTON') {
              // Button press → open Safe Timer with auto-start
              if (navigatorKey.currentState != null) {
                navigatorKey.currentState!.pushNamed(
                  '/safe_timer',
                  arguments: <String, dynamic>{'autoStart': true},
                );
              } else {
                // Fallback: native countdown if Flutter nav still unavailable
                await LockScreenSosService().launchNativeCountdown(5);
              }
            } else if (normalized == 'SOS_FROM_SHAKE') {
              // Only launch native countdown if Flutter UI was NOT available
              // (foreground shake is handled by the home_screen event listener)
              if (navigatorKey.currentState == null) {
                await LockScreenSosService().launchNativeCountdown(5);
              }
            } else {
              await LockScreenSosService().launchNativeCountdown(5);
            }
          } catch (e) {
            debugPrint('[BLE] error launching from background: $e');
          }
        } else if (normalized == 'SOS_NOW') {
          // Immediate SOS: trigger background SOS flow without waiting for countdown
          debugPrint(
            '[BLE] immediate SOS_NOW received from device - triggering SOS',
          );
          try {
            SosService().triggerSOSBackground('iot_device');
          } catch (e) {
            debugPrint('[BLE] error triggering SOS_NOW: $e');
          }
        } else if (normalized == 'SOS') {
          // Some devices only send plain "SOS". Treat this as an immediate trigger.
          debugPrint(
            '[BLE] immediate SOS received from device - triggering SOS',
          );
          try {
            SosService().triggerSOSBackground('iot_device');
          } catch (e) {
            debugPrint('[BLE] error triggering SOS: $e');
          }
          // Also forward the raw message for UI handlers (backwards compatibility)
          _eventController.add(msg);
        } else {
          // Default: keep forwarding raw messages for backwards compatibility
          if (msg.isNotEmpty) {
            _eventController.add(msg);
          }
        }
      });
      debugPrint(
        '[BLE] notifications enabled on ${_txCharacteristic!.uuid.str}',
      );
    }
  }

  Future<void> sendCommand(String command) async {
    if (_rxCharacteristic == null || !isConnected) return;

    final payload = utf8.encode(command);
    try {
      await _rxCharacteristic!.write(
        payload,
        withoutResponse: _rxCharacteristic!.properties.writeWithoutResponse,
      );
    } catch (e) {
      debugPrint('[BLE] write error: $e');
    }
  }

  Future<void> disconnect() async {
    _autoReconnect = false;
    try {
      await _notifySub?.cancel();
      await _connectionSub?.cancel();
      if (_connectedDevice != null) {
        await _connectedDevice!.disconnect();
      }
    } catch (_) {}

    _rxCharacteristic = null;
    _txCharacteristic = null;
    _connectedDevice = null;
    _setStatus(BleStatus.idle);
  }

  void enableAutoReconnect() {
    _autoReconnect = true;
  }

  Future<void> _loadLastConnectedDevice() async {
    final prefs = await SharedPreferences.getInstance();
    _lastDeviceRemoteId = prefs.getString(_lastDeviceKey);
  }

  Future<void> _saveLastConnectedDevice(String remoteId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastDeviceKey, remoteId);
  }

  void _setStatus(BleStatus newStatus) {
    _status = newStatus;
    _statusController.add(newStatus);
  }

  bool _isTargetDevice(ScanResult result) {
    final name = result.device.platformName.toLowerCase();
    final advName = result.advertisementData.advName.toLowerCase();
    final remoteId = result.device.remoteId.str;
    final matchesName =
        name.contains('narishakti') ||
        advName.contains('narishakti') ||
        name.contains('nari') ||
        advName.contains('nari');
    final matchesService = result.advertisementData.serviceUuids
        .map((e) => e.str.toLowerCase())
        .contains(_serviceUuid.str.toLowerCase());
    final matchesRemembered =
        _lastDeviceRemoteId != null && remoteId == _lastDeviceRemoteId;

    if (matchesName || matchesService || matchesRemembered) {
      return true;
    }

    // Keep this broad for discovery debugging so we can see non-matching boards.
    return true;
  }
}
