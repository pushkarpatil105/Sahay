import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:nari_shakti/core/services/ble_service.dart';

Future<void> showBleConnectSheet(BuildContext context) async {
  await showGeneralDialog(
    context: context,
    barrierLabel: 'BLE Connect',
    barrierDismissible: true,
    barrierColor: Colors.black54,
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (_, __, ___) => const _BleConnectDialog(),
    transitionBuilder: (context, anim, _, child) {
      final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween(begin: 0.97, end: 1.0).animate(curved),
          child: child,
        ),
      );
    },
  );
}

class _BleConnectDialog extends StatefulWidget {
  const _BleConnectDialog();

  @override
  State<_BleConnectDialog> createState() => _BleConnectDialogState();
}

class _BleConnectDialogState extends State<_BleConnectDialog> {
  final BleService _bleService = BleService();
  static const MethodChannel _channel = MethodChannel(
    'nari_shakti/ble_settings',
  );

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    await _bleService.initialize();
    _bleService.enableAutoReconnect();
    final bluetoothOn = await _bleService.ensureBluetoothOn();
    if (bluetoothOn) await _bleService.startScan();
  }

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    final h = MediaQuery.of(context).size.height;

    return BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
      child: Center(
        child: Container(
          width: w * 0.86,
          constraints: BoxConstraints(maxHeight: h * 0.64),
          decoration: BoxDecoration(
            color: const Color(0xFFFAFAFA),
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: Colors.black26.withOpacity(0.18),
                blurRadius: 20,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _HeaderRow(onClose: () => Navigator.pop(context)),
                  const SizedBox(height: 8),

                  // content
                  Flexible(
                    child: StreamBuilder<BleStatus>(
                      stream: _bleService.statusStream,
                      initialData: _bleService.status,
                      builder: (context, statusSnap) {
                        final status = statusSnap.data ?? BleStatus.idle;

                        if (status == BleStatus.bluetoothOff) {
                          return _BluetoothOffCard(bleService: _bleService);
                        }

                        if (status == BleStatus.permissionsDenied) {
                          return const Center(
                            child: Padding(
                              padding: EdgeInsets.symmetric(horizontal: 10),
                              child: Text(
                                'Bluetooth permissions denied. Please allow permissions and retry.',
                                textAlign: TextAlign.center,
                                style: TextStyle(fontSize: 12),
                              ),
                            ),
                          );
                        }

                        if (status == BleStatus.connected) {
                          final deviceName =
                              _bleService.connectedDevice?.platformName;
                          return _ConnectedState(
                            deviceName: deviceName?.isNotEmpty == true
                                ? deviceName!
                                : 'NariShakti device',
                            onRescan: () => _bleService.startScan(),
                            onDisconnect: () => _bleService.disconnect(),
                          );
                        }

                        return _DeviceList(
                          bleService: _bleService,
                          status: status,
                        );
                      },
                    ),
                  ),

                  const SizedBox(height: 8),

                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: () => _openBluetoothSettings(),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFFD32F2F),
                        side: const BorderSide(color: Color(0xFFD32F2F)),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                      ),
                      child: const Text(
                        'More settings',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openBluetoothSettings() async {
    try {
      await _channel.invokeMethod('openBluetoothSettings');
    } catch (_) {
      await _bleService.startScan();
    }
  }
}

class _HeaderRow extends StatelessWidget {
  const _HeaderRow({required this.onClose});
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: const Color(0xFFFF5722).withOpacity(0.08),
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Icon(
            Icons.bluetooth,
            color: Color(0xFF0D6EFD),
            size: 16,
          ),
        ),
        const SizedBox(width: 8),
        const Expanded(
          child: Text(
            'Bluetooth',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: Color(0xFF1A1A1A),
            ),
          ),
        ),
        IconButton(
          onPressed: onClose,
          icon: const Icon(Icons.close, size: 20, color: Colors.black54),
        ),
      ],
    );
  }
}

class _ConnectedState extends StatelessWidget {
  const _ConnectedState({
    required this.deviceName,
    required this.onRescan,
    required this.onDisconnect,
  });
  final String deviceName;
  final VoidCallback onRescan;
  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _DeviceCard(
          icon: Icons.check_circle,
          iconColor: Colors.green.shade700,
          title: deviceName,
          subtitle: 'Connected',
          accentColor: Colors.green.shade700,
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: onRescan,
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                child: const Text('Scan Again', style: TextStyle(fontSize: 12)),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: ElevatedButton(
                onPressed: onDisconnect,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFD32F2F),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                child: const Text('Disconnect', style: TextStyle(fontSize: 12)),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _BluetoothOffCard extends StatelessWidget {
  const _BluetoothOffCard({required this.bleService});
  final BleService bleService;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _DeviceCard(
          icon: Icons.bluetooth_disabled,
          iconColor: Colors.black54,
          title: 'Bluetooth is off',
          subtitle: 'Turn it on to connect your safety device',
          accentColor: const Color(0xFFD32F2F),
          trailing: const _PillState(
            text: 'OFF',
            color: Color(0xFFE0E0E0),
            textColor: Colors.black54,
          ),
        ),
        const SizedBox(height: 10),
        ElevatedButton(
          onPressed: () async {
            final on = await bleService.ensureBluetoothOn();
            if (on) await bleService.startScan();
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFFFF5722),
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 10),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
          child: const Text(
            'Turn On Bluetooth',
            style: TextStyle(fontSize: 13),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Bluetooth must be on to find your Nari Shakti device nearby.',
          style: TextStyle(color: Colors.grey.shade600, fontSize: 11),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

class _DeviceList extends StatelessWidget {
  const _DeviceList({required this.bleService, required this.status});
  final BleService bleService;
  final BleStatus status;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          children: [
            if (status == BleStatus.scanning)
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            if (status == BleStatus.scanning) const SizedBox(width: 6),
            Expanded(
              child: Text(
                status == BleStatus.scanning
                    ? 'Scanning nearby devices...'
                    : 'Nearby devices',
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                  color: Color(0xFF1A1A1A),
                ),
              ),
            ),
            TextButton(
              onPressed: () => bleService.startScan(),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 6),
              ),
              child: const Text('Scan', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Expanded(
          child: StreamBuilder<List<ScanResult>>(
            stream: bleService.devicesStream,
            initialData: const [],
            builder: (context, snapshot) {
              final devices = snapshot.data ?? const [];

              if (devices.isEmpty) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: const Color(0xFFFF5722).withOpacity(0.08),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.bluetooth_searching,
                            color: Color(0xFFFF5722),
                            size: 24,
                          ),
                        ),
                        const SizedBox(height: 10),
                        const Text(
                          'No device found yet',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF2B2B2B),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Keep the device close and make sure it is powered on and in pairing/discoverable mode.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.grey.shade600,
                            height: 1.3,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFFF3E0),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: const Text(
                            'Scanning... please wait',
                            style: TextStyle(
                              fontSize: 11,
                              color: Color(0xFFD32F2F),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }

              return ListView.separated(
                padding: const EdgeInsets.only(bottom: 4),
                itemCount: devices.length,
                separatorBuilder: (_, __) => const SizedBox(height: 6),
                itemBuilder: (context, i) {
                  final d = devices[i].device;
                  final name = d.platformName.isEmpty
                      ? 'NariShakti device'
                      : d.platformName;
                  final rssi = devices[i].rssi;
                  return _DeviceCard(
                    icon: Icons.developer_board,
                    iconColor: const Color(0xFF0D6EFD),
                    title: name,
                    subtitle: 'RSSI $rssi • ${d.remoteId.str}',
                    accentColor: const Color(0xFFFF5722),
                    trailing: const _PillState(
                      text: 'Tap to connect',
                      color: Color(0xFFE8F0FE),
                      textColor: Color(0xFF0D6EFD),
                    ),
                    onTap: () => bleService.connect(d),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

class _DeviceCard extends StatelessWidget {
  const _DeviceCard({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.accentColor,
    this.trailing,
    this.onTap,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final Color accentColor;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.black12),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: iconColor.withOpacity(0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: iconColor, size: 20),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF1A1A1A),
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.grey.shade600,
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              trailing ?? Icon(Icons.chevron_right, color: accentColor),
            ],
          ),
        ),
      ),
    );
  }
}

class _PillState extends StatelessWidget {
  const _PillState({
    required this.text,
    required this.color,
    required this.textColor,
  });
  final String text;
  final Color color;
  final Color textColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: textColor,
          fontSize: 9,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
