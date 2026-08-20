import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

class PermissionService {
  static final PermissionService _instance = PermissionService._internal();
  factory PermissionService() => _instance;
  PermissionService._internal();

  Future<void> requestAllPermissions(BuildContext context) async {
    // Request all at once
    await [
      Permission.location,
      Permission.microphone,
      Permission.camera,
      Permission.sms,
      Permission.phone,
      Permission.notification,
      Permission.ignoreBatteryOptimizations,
      Permission.storage,
    ].request();
  }
}