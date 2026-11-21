import '../services/bidi_helper.dart';

class NearbyDevice {
  final String id;
  final String name;
  final String ip;
  final int port;
  final String deviceType;
  final String serviceId;
  final DateTime lastSeen;
  final String connectionType;
  final String? p2pDeviceAddress;
  final String? p2pSsid;
  final String? p2pPassphrase;
  final String? p2pGoIp;

  NearbyDevice({
    required this.id,
    required this.name,
    required this.ip,
    this.port = 53318,
    this.deviceType = 'unknown',
    this.serviceId = 'com.the356company.sendsnap',
    DateTime? lastSeen,
    this.connectionType = 'lan',
    this.p2pDeviceAddress,
    this.p2pSsid,
    this.p2pPassphrase,
    this.p2pGoIp,
  }) : lastSeen = lastSeen ?? DateTime.now();

  // Backward compatibility getters
  String get endpointId => id;
  String get endpointName => name;

  bool get isWifiDirect =>
      connectionType == 'wifi_direct' || connectionType == 'hotspot';

  bool get hasDirectCredentials =>
      p2pSsid != null &&
      p2pSsid!.isNotEmpty &&
      p2pPassphrase != null &&
      p2pPassphrase!.isNotEmpty;

  bool get hasLanIp => ip.isNotEmpty && ip != '0.0.0.0';

  NearbyDevice copyWith({
    String? id,
    String? name,
    String? ip,
    int? port,
    String? deviceType,
    String? serviceId,
    DateTime? lastSeen,
    String? connectionType,
    String? p2pDeviceAddress,
    String? p2pSsid,
    String? p2pPassphrase,
    String? p2pGoIp,
  }) {
    return NearbyDevice(
      id: id ?? this.id,
      name: name ?? this.name,
      ip: ip ?? this.ip,
      port: port ?? this.port,
      deviceType: deviceType ?? this.deviceType,
      serviceId: serviceId ?? this.serviceId,
      lastSeen: lastSeen ?? this.lastSeen,
      connectionType: connectionType ?? this.connectionType,
      p2pDeviceAddress: p2pDeviceAddress ?? this.p2pDeviceAddress,
      p2pSsid: p2pSsid ?? this.p2pSsid,
      p2pPassphrase: p2pPassphrase ?? this.p2pPassphrase,
      p2pGoIp: p2pGoIp ?? this.p2pGoIp,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'ip': ip,
        'port': port,
        'deviceType': deviceType,
        'serviceId': serviceId,
        'connectionType': connectionType,
        if (p2pDeviceAddress != null) 'p2pDeviceAddress': p2pDeviceAddress,
        if (p2pSsid != null) 'p2pSsid': p2pSsid,
        if (p2pPassphrase != null) 'p2pPassphrase': p2pPassphrase,
        if (p2pGoIp != null) 'p2pGoIp': p2pGoIp,
      };

  factory NearbyDevice.fromJson(Map<String, dynamic> json) => NearbyDevice(
        id: json['id'] as String? ?? '',
        name: BidiHelper.sanitizeFileName(json['name'] as String? ?? 'Unknown'),
        ip: json['ip'] as String? ?? '',
        port: (json['port'] as num?)?.toInt() ?? 53318,
        deviceType: json['deviceType'] as String? ?? 'unknown',
        serviceId: json['serviceId'] as String? ?? 'com.the356company.sendsnap',
        connectionType: json['connectionType'] as String? ?? 'lan',
        p2pDeviceAddress: json['p2pDeviceAddress'] as String?,
        p2pSsid: json['p2pSsid'] as String?,
        p2pPassphrase: json['p2pPassphrase'] as String?,
        p2pGoIp: json['p2pGoIp'] as String?,
      );

  @override
  String toString() => 'NearbyDevice($name, $ip:$port)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NearbyDevice &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;
}
