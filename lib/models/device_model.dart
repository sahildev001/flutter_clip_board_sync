
class DeviceModel {
  final String id;
  final String name;
  final String wifiName;
  final String ipAddress;
  bool isConnected;
  bool isPaired;

  DeviceModel({
    required this.id,
    required this.name,
    required this.wifiName,
    required this.ipAddress,
    this.isConnected = false,
    this.isPaired = false,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'wifiName': wifiName,
    'ipAddress': ipAddress,
    'isConnected': isConnected,
    'isPaired': isPaired,
  };

  factory DeviceModel.fromJson(Map<String, dynamic> json) => DeviceModel(
    id: json['id'],
    name: json['name'],
    wifiName: json['wifiName'],
    ipAddress: json['ipAddress'],
    isConnected: json['isConnected'] ?? false,
    isPaired: json['isPaired'] ?? false,
  );
}