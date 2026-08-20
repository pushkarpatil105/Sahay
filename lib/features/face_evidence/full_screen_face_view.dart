import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

class FullScreenFaceView extends StatelessWidget {
  final String imageUrl;
  final int faceNumber;

  const FullScreenFaceView({
    super.key,
    required this.imageUrl,
    required this.faceNumber,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text('Face #$faceNumber'),
        actions: [
          IconButton(
            onPressed: () => Share.shareUri(Uri.parse(imageUrl)),
            icon: const Icon(Icons.share_outlined),
          ),
        ],
      ),
      body: Center(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SizedBox(
              width: constraints.maxWidth * 0.96,
              child: AspectRatio(
                aspectRatio: 3 / 4,
                child: InteractiveViewer(
                  minScale: 1.0,
                  maxScale: 5.0,
                  child: CachedNetworkImage(
                    imageUrl: imageUrl,
                    width: double.infinity,
                    height: double.infinity,
                    fit: BoxFit.cover,
                    placeholder: (context, url) => const Center(
                      child: CircularProgressIndicator(color: Colors.white),
                    ),
                    errorWidget: (context, url, error) => const Icon(
                      Icons.broken_image_outlined,
                      color: Colors.white,
                      size: 48,
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
