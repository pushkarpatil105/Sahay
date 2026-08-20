import 'dart:async';

import 'package:flutter/material.dart';
import 'package:nari_shakti/core/services/live_share_service.dart';

class LiveShareBubble extends StatefulWidget {
  const LiveShareBubble({super.key});

  @override
  State<LiveShareBubble> createState() => _LiveShareBubbleState();
}

class _LiveShareBubbleState extends State<LiveShareBubble> {
  bool _isSharing = false;
  bool _expanded = false;
  Offset _position = const Offset(16, 160);
  StreamSubscription<bool>? _subscription;

  static const double _margin = 12;
  static const double _collapsedSize = 56;
  static const double _expandedWidth = 290;
  static const double _expandedHeight = 56;

  @override
  void initState() {
    super.initState();
    _isSharing = LiveShareService().isSharingNow;
    _subscription = LiveShareService().isSharing.listen((sharing) {
      if (!mounted) return;
      setState(() {
        _isSharing = sharing;
        if (!sharing) {
          _expanded = false;
        }
      });
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_isSharing) return const SizedBox.shrink();

    final screen = MediaQuery.sizeOf(context);
    final bubbleWidth = _expanded ? _expandedWidth : _collapsedSize;
    final bubbleHeight = _expanded ? _expandedHeight : _collapsedSize;

    final maxX = (screen.width - bubbleWidth - _margin).clamp(
      _margin,
      double.infinity,
    );
    final maxY = (screen.height - bubbleHeight - _margin).clamp(
      _margin,
      double.infinity,
    );

    final clampedPosition = Offset(
      _position.dx.clamp(_margin, maxX),
      _position.dy.clamp(_margin, maxY),
    );

    return Positioned(
      left: clampedPosition.dx,
      top: clampedPosition.dy,
      child: GestureDetector(
        onPanUpdate: (details) {
          setState(() {
            _position = Offset(
              (clampedPosition.dx + details.delta.dx).clamp(_margin, maxX),
              (clampedPosition.dy + details.delta.dy).clamp(_margin, maxY),
            );
          });
        },
        child: GestureDetector(
          onTap: () => setState(() => _expanded = !_expanded),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: const Color(0xFF1565C0),
              borderRadius: BorderRadius.circular(_expanded ? 18 : 999),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF1565C0).withValues(alpha: 0.35),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: _expanded
                ? _expandedContent()
                : const Icon(Icons.location_on, color: Colors.white, size: 28),
          ),
        ),
      ),
    );
  }

  Widget _expandedContent() {
    return Material(
      color: Colors.transparent,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.location_on, color: Colors.white, size: 24),
          const SizedBox(width: 10),
          const Text(
            'Sharing Live Location',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 12),
          TextButton(
            onPressed: () async {
              await LiveShareService().stopSharing();
            },
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFF1565C0),
              backgroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            ),
            child: const Text('Stop'),
          ),
        ],
      ),
    );
  }
}
