import 'dart:io';
import 'dart:convert';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:wifi_scan/wifi_scan.dart';
import '../models/device_model.dart';

class DeviceDiscoveryService {
  static final DeviceDiscoveryService _instance = DeviceDiscoveryService._internal();
  factory DeviceDiscoveryService() => _instance;
  DeviceDiscoveryService._internal();

  final NetworkInfo _networkInfo = NetworkInfo();
  List<DeviceModel> _discoveredDevices = [];

  Future<List<DeviceModel>> discoverDevices() async {
    try {
      // Get current WiFi info
      final wifiName = await _networkInfo.getWifiName();
      final wifiIP = await _networkInfo.getWifiIP();

      if (wifiName == null || wifiIP == null) {
        throw Exception('Not connected to WiFi');
      }

      _discoveredDevices.clear();

      // Scan local network for devices running our app
      await _scanLocalNetwork(wifiName, wifiIP);

      return _discoveredDevices;
    } catch (e) {
      print('Error discovering devices: $e');
      return [];
    }
  }

  Future<void> _scanLocalNetwork(String wifiName, String currentIP) async {
    final baseIP = currentIP.substring(0, currentIP.lastIndexOf('.'));

    // Scan IP range 1-254
    for (int i = 1; i <= 254; i++) {
      final ip = '$baseIP.$i';
      if (ip == currentIP) continue;

      try {
        final socket = await Socket.connect(ip, 8080, timeout: Duration(milliseconds: 100));

        // Send discovery request
        socket.write(json.encode({
          'type': 'discovery',
          'deviceName': Platform.localHostname,
          'wifiName': wifiName,
        }));

        // Listen for response
        socket.listen((data) {
          try {
            final response = json.decode(String.fromCharCodes(data));
            if (response['type'] == 'discovery_response') {
              _discoveredDevices.add(DeviceModel(
                id: response['deviceId'],
                name: response['deviceName'],
                wifiName: response['wifiName'],
                ipAddress: ip,
              ));
            }
          } catch (e) {
            print('Error parsing discovery response: $e');
          }
        });

        await socket.close();
      } catch (e) {
        // Device not running our app or not reachable
        continue;
      }
    }
  }

  Future<String> getCurrentWifiName() async {
    return await _networkInfo.getWifiName() ?? 'Unknown';
  }
}