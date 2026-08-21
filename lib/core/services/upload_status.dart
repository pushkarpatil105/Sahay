enum UploadState { queued, success, failed }
 
class UploadStatus {
  final String sosId;
  final UploadState state;
  final String message;
 
  const UploadStatus({
    required this.sosId,
    required this.state,
    required this.message,
  });
}

