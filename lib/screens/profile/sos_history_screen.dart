import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class SosHistoryScreen extends StatelessWidget {
  const SosHistoryScreen({super.key});

  String _formatDate(DateTime dt) {
    final months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    final hour = dt.hour > 12 ? dt.hour - 12 : dt.hour == 0 ? 12 : dt.hour;
    final minute = dt.minute.toString().padLeft(2, '0');
    final ampm = dt.hour >= 12 ? 'PM' : 'AM';
    return '${dt.day} ${months[dt.month - 1]} ${dt.year}, $hour:$minute $ampm';
  }

  String _triggerLabel(String trigger) {
    switch (trigger) {
      case 'manual':
        return 'Manual Button';
      case 'voice':
        return 'Voice Keyword';
      case 'shake':
        return 'Shake Detection';
      case 'dead_man_switch':
        return 'Safe Timer Expired';
      case 'power_button':
        return 'Power Button';
      default:
        return trigger;
    }
  }

  IconData _triggerIcon(String trigger) {
    switch (trigger) {
      case 'manual':
        return Icons.touch_app_outlined;
      case 'voice':
        return Icons.mic_outlined;
      case 'shake':
        return Icons.vibration;
      case 'dead_man_switch':
        return Icons.timer_off_outlined;
      case 'power_button':
        return Icons.power_settings_new;
      default:
        return Icons.sos;
    }
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'active':
        return const Color(0xFFFF1744);
      case 'cancelled':
        return Colors.orange;
      case 'resolved':
        return Colors.green;
      default:
        return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;

    return Scaffold(
      backgroundColor: const Color(0xFFFAFAFA),
      appBar: AppBar(
        backgroundColor: Colors.white,
        title: const Text(
          'SOS History',
          style: TextStyle(
            color: Color(0xFF1A1A1A),
            fontWeight: FontWeight.bold,
          ),
        ),
        iconTheme: const IconThemeData(color: Color(0xFF1A1A1A)),
        elevation: 0,
      ),
      body: uid == null
          ? const Center(child: Text('Not logged in'))
          : StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('sos_events')
                  .where('user_id', isEqualTo: uid)
                  .orderBy('timestamp', descending: true)
                  .limit(50)
                  .snapshots(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(
                    child: CircularProgressIndicator(
                      color: Color(0xFFFF5722),
                    ),
                  );
                }

                if (snapshot.hasError) {
                  return Center(
                    child: Text(
                      'Error: ${snapshot.error}',
                      style: const TextStyle(color: Colors.black45),
                    ),
                  );
                }

                final docs = snapshot.data?.docs ?? [];

                if (docs.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 80,
                          height: 80,
                          decoration: BoxDecoration(
                            color: const Color(0xFFFF5722).withOpacity(0.08),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.history,
                            color: Color(0xFFFF5722),
                            size: 40,
                          ),
                        ),
                        const SizedBox(height: 16),
                        const Text(
                          'No SOS events yet',
                          style: TextStyle(
                            color: Colors.black38,
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Stay safe. Your SOS history\nwill appear here.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.black26,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  );
                }

                return ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: docs.length,
                  itemBuilder: (context, index) {
                    final data =
                        docs[index].data() as Map<String, dynamic>;
                    final trigger =
                        data['triggered_by'] as String? ?? 'manual';
                    final status =
                        data['status'] as String? ?? 'unknown';
                    final timestamp = data['timestamp'] != null
                        ? (data['timestamp'] as dynamic).toDate()
                            as DateTime
                        : DateTime.now();
                    final location =
                        data['location'] as Map<String, dynamic>?;
                    final lat = location?['lat'] as double?;
                    final lng = location?['lng'] as double?;

                    return Container(
                      margin: const EdgeInsets.only(bottom: 12),
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
                        children: [
                          // Header
                          Padding(
                            padding: const EdgeInsets.all(16),
                            child: Row(
                              children: [
                                Container(
                                  width: 44,
                                  height: 44,
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFFF1744)
                                        .withOpacity(0.1),
                                    borderRadius:
                                        BorderRadius.circular(12),
                                  ),
                                  child: Icon(
                                    _triggerIcon(trigger),
                                    color: const Color(0xFFFF1744),
                                    size: 22,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        _triggerLabel(trigger),
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 15,
                                          color: Color(0xFF1A1A1A),
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        _formatDate(timestamp),
                                        style: const TextStyle(
                                          fontSize: 12,
                                          color: Colors.black45,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                // Status badge
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: _statusColor(status)
                                        .withOpacity(0.1),
                                    borderRadius:
                                        BorderRadius.circular(20),
                                  ),
                                  child: Text(
                                    status.toUpperCase(),
                                    style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                      color: _statusColor(status),
                                      letterSpacing: 0.5,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),

                          // Location row
                          if (lat != null && lng != null)
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.fromLTRB(
                                  16, 0, 16, 16),
                              child: Row(
                                children: [
                                  const Icon(
                                    Icons.location_on_outlined,
                                    size: 14,
                                    color: Colors.black38,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    '${lat.toStringAsFixed(4)}, ${lng.toStringAsFixed(4)}',
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: Colors.black38,
                                    ),
                                  ),
                                ],
                              ),
                            ),

                          // Divider + contacts alerted
                          if (data['contacts_notified'] != null)
                            Container(
                              padding: const EdgeInsets.fromLTRB(
                                  16, 0, 16, 12),
                              child: Row(
                                children: [
                                  const Icon(
                                    Icons.people_outline,
                                    size: 14,
                                    color: Colors.black38,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    '${data['contacts_notified']} contact(s) alerted',
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: Colors.black38,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
    );
  }
}