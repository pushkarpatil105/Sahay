import 'dart:convert';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:open_file/open_file.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../features/face_evidence/face_evidence_repository.dart';
import '../../features/face_evidence/full_screen_face_view.dart';

class EvidenceStorageScreen extends StatelessWidget {
  const EvidenceStorageScreen({super.key});

  String _formatDate(DateTime dt) {
    final months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final hour = dt.hour > 12
        ? dt.hour - 12
        : dt.hour == 0
        ? 12
        : dt.hour;
    final minute = dt.minute.toString().padLeft(2, '0');
    final ampm = dt.hour >= 12 ? 'PM' : 'AM';
    return '${dt.day} ${months[dt.month - 1]} ${dt.year}, $hour:$minute $ampm';
  }

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;

    return Scaffold(
      backgroundColor: const Color(0xFFFAFAFA),
      appBar: AppBar(
        backgroundColor: Colors.white,
        title: const Text(
          'Evidence Storage',
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
                  .collection('users')
                  .doc(uid)
                  .collection('evidence')
                  .orderBy('timestamp', descending: true)
                  .snapshots(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(
                    child: CircularProgressIndicator(color: Color(0xFFFF5722)),
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
                            Icons.folder_outlined,
                            color: Color(0xFFFF5722),
                            size: 40,
                          ),
                        ),
                        const SizedBox(height: 16),
                        const Text(
                          'No evidence recorded yet',
                          style: TextStyle(
                            color: Colors.black38,
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Evidence is automatically collected\nwhen SOS is triggered.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.black26, fontSize: 13),
                        ),
                      ],
                    ),
                  );
                }

                return ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: docs.length,
                  itemBuilder: (context, index) {
                    final data = docs[index].data() as Map<String, dynamic>;
                    final docId = docs[index].id;
                    final timestamp = data['timestamp'] != null
                        ? (data['timestamp'] as dynamic).toDate() as DateTime
                        : DateTime.now();
                    final location = data['location'] as Map<String, dynamic>?;
                    final zipPath = data['zip_path'] as String?;
                    final dirPath = data['dir_path'] as String?;
                    final locationCount = data['location_count'] as int? ?? 0;
                    final hasAudio = data['has_audio'] as bool? ?? false;
                    final chunkCount = data['chunk_count'] as int? ?? 0;

                    final zipExists =
                        zipPath != null && File(zipPath).existsSync();
                    // audio is embedded in video chunks; do not expect separate audio file
                    final audioPath = null;
                    final audioExists = false;

                    return GestureDetector(
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => EvidenceFolderScreen(
                              uid: uid,
                              docId: docId,
                              data: data,
                            ),
                          ),
                        );
                      },
                      child: Container(
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
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: const EdgeInsets.all(16),
                              child: Row(
                                children: [
                                  Container(
                                    width: 44,
                                    height: 44,
                                    decoration: BoxDecoration(
                                      color: const Color(
                                        0xFFFF5722,
                                      ).withOpacity(0.1),
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: const Icon(
                                      Icons.folder_outlined,
                                      color: Color(0xFFFF5722),
                                      size: 22,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        const Text(
                                          'SOS Evidence Folder',
                                          style: TextStyle(
                                            fontWeight: FontWeight.bold,
                                            fontSize: 15,
                                            color: Color(0xFF1A1A1A),
                                          ),
                                        ),
                                        Text(
                                          _formatDate(timestamp),
                                          style: const TextStyle(
                                            fontSize: 12,
                                            color: Colors.black45,
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        const Text(
                                          'Type: SOS',
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: Colors.black45,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  IconButton(
                                    onPressed: () => _confirmDelete(
                                      context,
                                      uid,
                                      docId,
                                      zipPath,
                                      dirPath,
                                    ),
                                    icon: const Icon(
                                      Icons.delete_outline,
                                      color: Colors.black26,
                                      size: 20,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (location != null)
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  16,
                                  0,
                                  16,
                                  8,
                                ),
                                child: Row(
                                  children: [
                                    const Icon(
                                      Icons.location_on_outlined,
                                      size: 14,
                                      color: Colors.black38,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      '${(location['lat'] as num).toDouble().toStringAsFixed(4)}, ${(location['lng'] as num).toDouble().toStringAsFixed(4)}',
                                      style: const TextStyle(
                                        fontSize: 12,
                                        color: Colors.black38,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                              child: Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  _Tag(
                                    icon: Icons.movie,
                                    label: '$chunkCount clips',
                                  ),
                                  _Tag(
                                    icon: Icons.location_on,
                                    label: '$locationCount locations',
                                  ),
                                  // audio is part of video chunks; no separate audio tag
                                  if (zipExists)
                                    const _Tag(
                                      icon: Icons.folder_zip,
                                      label: 'ZIP ready',
                                    ),
                                ],
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: _ActionButton(
                                      icon: Icons.folder_open,
                                      label: 'Open Folder',
                                      onTap: () {
                                        Navigator.push(
                                          context,
                                          MaterialPageRoute(
                                            builder: (_) =>
                                                EvidenceFolderScreen(
                                                  uid: uid,
                                                  docId: docId,
                                                  data: data,
                                                ),
                                          ),
                                        );
                                      },
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                );
              },
            ),
    );
  }

  void _confirmDelete(
    BuildContext context,
    String uid,
    String docId,
    String? zipPath,
    String? dirPath,
  ) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text(
          'Delete Evidence?',
          style: TextStyle(
            color: Color(0xFF1A1A1A),
            fontWeight: FontWeight.bold,
          ),
        ),
        content: const Text(
          'This will permanently delete this evidence record and files.',
          style: TextStyle(color: Colors.black54),
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
            onPressed: () async {
              Navigator.pop(context);
              await FirebaseFirestore.instance
                  .collection('users')
                  .doc(uid)
                  .collection('evidence')
                  .doc(docId)
                  .delete();
              if (zipPath != null) {
                try {
                  await File(zipPath).delete();
                } catch (_) {}
              }
              if (dirPath != null) {
                try {
                  await Directory(dirPath).delete(recursive: true);
                } catch (_) {}
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              elevation: 0,
            ),
            child: const Text('Delete', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }
}

class EvidenceFolderScreen extends StatelessWidget {
  final String uid;
  final String docId;
  final Map<String, dynamic> data;

  const EvidenceFolderScreen({
    super.key,
    required this.uid,
    required this.docId,
    required this.data,
  });

  Future<List<File>> _loadLocalVideoChunks(String? dirPath) async {
    if (dirPath == null) {
      return const [];
    }

    final dir = Directory(dirPath);
    if (!await dir.exists()) {
      return const [];
    }

    final items = await dir.list().toList();
    final files = items
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.mp4'))
        .toList();

    files.sort((a, b) => a.path.compareTo(b.path));
    return files;
  }

  Future<List<Map<String, dynamic>>> _loadLocationEntries(
    String? dirPath,
  ) async {
    if (dirPath == null) {
      return const [];
    }

    final file = File('$dirPath/location_log.json');
    if (!await file.exists()) {
      return const [];
    }

    try {
      final raw = await file.readAsString();
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final locations = decoded['locations'] as List<dynamic>? ?? const [];
      return locations
          .whereType<Map>()
          .map((e) => e.map((k, v) => MapEntry(k.toString(), v)))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  String _formatLocationTime(String iso) {
    try {
      final dt = DateTime.parse(iso).toLocal();
      final minute = dt.minute.toString().padLeft(2, '0');
      final second = dt.second.toString().padLeft(2, '0');
      return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} ${dt.hour.toString().padLeft(2, '0')}:$minute:$second';
    } catch (_) {
      return iso;
    }
  }

  @override
  Widget build(BuildContext context) {
    final timestamp = data['timestamp'] != null
        ? (data['timestamp'] as dynamic).toDate() as DateTime
        : DateTime.now();
    final sosId = data['sos_id'] as String? ?? docId;
    final dirPath = data['dir_path'] as String?;
    final zipPath = data['zip_path'] as String?;
    final chunkUrls = (data['chunk_urls'] as List<dynamic>? ?? const [])
        .map((e) => e.toString())
        .toList();

    final audioPath = dirPath != null ? '$dirPath/audio.aac' : null;
    final audioExists = audioPath != null && File(audioPath).existsSync();
    final zipExists = zipPath != null && File(zipPath).existsSync();

    return Scaffold(
      backgroundColor: const Color(0xFFFAFAFA),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        iconTheme: const IconThemeData(color: Color(0xFF1A1A1A)),
        title: const Text(
          'SOS Evidence Folder',
          style: TextStyle(
            color: Color(0xFF1A1A1A),
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _SectionCard(
            title: 'Folder Info',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'SOS ID: $sosId',
                  style: const TextStyle(color: Colors.black54, fontSize: 12),
                ),
                const SizedBox(height: 6),
                Text(
                  'Time: $timestamp',
                  style: const TextStyle(color: Colors.black54, fontSize: 12),
                ),
                if (dirPath != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    'Local Folder: $dirPath',
                    style: const TextStyle(color: Colors.black54, fontSize: 12),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
          _SectionCard(
            title: 'Videos',
            child: FutureBuilder<List<File>>(
              future: _loadLocalVideoChunks(dirPath),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }

                final files = snapshot.data ?? const [];
                if (files.isEmpty) {
                  return const Text(
                    'No local video chunks found.',
                    style: TextStyle(color: Colors.black45),
                  );
                }

                return Column(
                  children: files.map((file) {
                    final name = file.uri.pathSegments.isNotEmpty
                        ? file.uri.pathSegments.last
                        : file.path;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _ActionButton(
                        icon: Icons.play_circle_outline,
                        label: 'Open $name',
                        onTap: () => OpenFile.open(file.path),
                      ),
                    );
                  }).toList(),
                );
              },
            ),
          ),
          if (chunkUrls.isNotEmpty) ...[
            const SizedBox(height: 12),
            _SectionCard(
              title: 'Cloud Video Links',
              child: Column(
                children: chunkUrls.asMap().entries.map((entry) {
                  final index = entry.key;
                  final url = entry.value;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _ActionButton(
                      icon: Icons.cloud_outlined,
                      label: 'Open Cloud Clip ${index + 1}',
                      onTap: () async {
                        final uri = Uri.tryParse(url);
                        if (uri != null) {
                          await launchUrl(
                            uri,
                            mode: LaunchMode.externalApplication,
                          );
                        }
                      },
                    ),
                  );
                }).toList(),
              ),
            ),
          ],
          // audio is embedded in video chunks; no separate audio section
          if (zipExists) ...[
            const SizedBox(height: 12),
            _SectionCard(
              title: 'ZIP Export',
              child: Column(
                children: [
                  _ActionButton(
                    icon: Icons.share,
                    label: 'Share ZIP',
                    onTap: () => Share.shareXFiles([
                      XFile(zipPath),
                    ], subject: 'SOS Evidence'),
                  ),
                  const SizedBox(height: 8),
                  _ActionButton(
                    icon: Icons.folder_zip,
                    label: 'Open ZIP',
                    onTap: () => OpenFile.open(zipPath),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 12),
          _SectionCard(
            title: 'Location Log',
            child: FutureBuilder<List<Map<String, dynamic>>>(
              future: _loadLocationEntries(dirPath),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }

                final entries = snapshot.data ?? const [];
                if (entries.isEmpty) {
                  return const Text(
                    'No location_log.json entries found.',
                    style: TextStyle(color: Colors.black45),
                  );
                }

                return Column(
                  children: entries.asMap().entries.map((entry) {
                    final index = entry.key;
                    final item = entry.value;

                    final lat = (item['lat'] as num?)?.toDouble();
                    final lng = (item['lng'] as num?)?.toDouble();
                    final time = item['timestamp']?.toString() ?? '';
                    final maps = item['maps_link']?.toString();

                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFF5722).withOpacity(0.06),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(
                            Icons.location_on_outlined,
                            size: 16,
                            color: Color(0xFFFF5722),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Point ${index + 1}: ${lat?.toStringAsFixed(5) ?? '--'}, ${lng?.toStringAsFixed(5) ?? '--'}',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: Colors.black87,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  _formatLocationTime(time),
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: Colors.black54,
                                  ),
                                ),
                                if (maps != null) ...[
                                  const SizedBox(height: 6),
                                  GestureDetector(
                                    onTap: () async {
                                      final uri = Uri.tryParse(maps);
                                      if (uri != null) {
                                        await launchUrl(
                                          uri,
                                          mode: LaunchMode.externalApplication,
                                        );
                                      }
                                    },
                                    child: const Text(
                                      'Open in Maps',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: Color(0xFFFF5722),
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                );
              },
            ),
          ),
          const SizedBox(height: 12),
          _SectionCard(
            title: 'Detected Faces',
            child: FutureBuilder<List<Map<String, dynamic>>>(
              future: FaceEvidenceRepository.getFaces(sosId),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const SizedBox(
                    height: 80,
                    child: Center(child: CircularProgressIndicator()),
                  );
                }

                final faces = snapshot.data ?? const [];
                if (faces.isEmpty) {
                  return const Text(
                    'No faces detected.',
                    style: TextStyle(color: Colors.black45),
                  );
                }

                return SizedBox(
                  height: 78,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: faces.length,
                    separatorBuilder: (context, index) =>
                        const SizedBox(width: 8),
                    itemBuilder: (context, index) {
                      final imageUrl =
                          faces[index]['face_url'] as String? ?? '';
                      return GestureDetector(
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => FullScreenFaceView(
                                imageUrl: imageUrl,
                                faceNumber: index + 1,
                              ),
                            ),
                          );
                        },
                        child: Container(
                          width: 72,
                          height: 72,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.red, width: 1.5),
                          ),
                          child: ClipOval(
                            child: CachedNetworkImage(
                              imageUrl: imageUrl,
                              fit: BoxFit.cover,
                              placeholder: (context, url) =>
                                  Container(color: Colors.grey.shade200),
                              errorWidget: (context, url, error) => Container(
                                color: Colors.grey.shade200,
                                child: const Icon(
                                  Icons.broken_image_outlined,
                                  color: Colors.grey,
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  final String title;
  final Widget child;

  const _SectionCard({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: Color(0xFF1A1A1A),
            ),
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  final IconData icon;
  final String label;

  const _Tag({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFFFF5722).withOpacity(0.08),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: const Color(0xFFFF5722)),
          const SizedBox(width: 4),
          Text(
            label,
            style: const TextStyle(
              fontSize: 11,
              color: Color(0xFFFF5722),
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
        decoration: BoxDecoration(
          color: const Color(0xFFFF5722).withOpacity(0.08),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 16, color: const Color(0xFFFF5722)),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  color: Color(0xFFFF5722),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
