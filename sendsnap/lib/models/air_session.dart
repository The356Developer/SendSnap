import 'device.dart';

class AirGrabSession {
  final String token;
  final NearbyDevice sender;
  final int fileCount;
  final String previewName;
  final int totalBytes;
  final DateTime expiresAt;

  const AirGrabSession({
    required this.token,
    required this.sender,
    required this.fileCount,
    required this.previewName,
    required this.totalBytes,
    required this.expiresAt,
  });

  bool get isExpired => DateTime.now().isAfter(expiresAt);

  Duration get remainingDuration {
    final diff = expiresAt.difference(DateTime.now());
    return diff.isNegative ? Duration.zero : diff;
  }

  AirGrabSession copyWith({
    String? token,
    NearbyDevice? sender,
    int? fileCount,
    String? previewName,
    int? totalBytes,
    DateTime? expiresAt,
  }) {
    return AirGrabSession(
      token: token ?? this.token,
      sender: sender ?? this.sender,
      fileCount: fileCount ?? this.fileCount,
      previewName: previewName ?? this.previewName,
      totalBytes: totalBytes ?? this.totalBytes,
      expiresAt: expiresAt ?? this.expiresAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'token': token,
        'sender': sender.toJson(),
        'fileCount': fileCount,
        'previewName': previewName,
        'totalBytes': totalBytes,
        'expiresAtMs': expiresAt.millisecondsSinceEpoch,
      };

  factory AirGrabSession.fromJson(Map<String, dynamic> json) {
    final senderMap = json['sender'] as Map<String, dynamic>? ?? const {};
    final expiresAtMs = (json['expiresAtMs'] as num?)?.toInt();
    return AirGrabSession(
      token: json['token'] as String? ?? '',
      sender: NearbyDevice.fromJson(senderMap),
      fileCount: (json['fileCount'] as num?)?.toInt() ?? 1,
      previewName: json['previewName'] as String? ?? 'Files',
      totalBytes: (json['totalBytes'] as num?)?.toInt() ?? 0,
      expiresAt: expiresAtMs != null
          ? DateTime.fromMillisecondsSinceEpoch(expiresAtMs)
          : DateTime.now().add(const Duration(seconds: 20)),
    );
  }
}
