import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:async';
import '../models/device_model.dart';
import '../models/clipboard_item.dart';
import 'clipboard_service.dart';
import 'device_discovery_service.dart';
import 'background_service.dart';

class ConnectionService {
  static final ConnectionService _instance = ConnectionService._internal();
  factory ConnectionService() => _instance;
  ConnectionService._internal();

  ServerSocket? _server;
  Socket? _connectedSocket;
  DeviceModel? _connectedDevice;
  Function(ClipboardItem)? onClipboardReceived;
  Function(String)? onConnectionStatusChanged;
  Timer? _heartbeatTimer;
  Timer? _reconnectTimer;
  bool _isReconnecting = false;

  Future<void> startServer() async {
    try {
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, 8080);
      print('Server started on port 8080');

      _server!.listen((Socket socket) {
        print('Client connected: ${socket.remoteAddress.address}');
        _handleConnection(socket);
      });

      // Start background service
      await BackgroundService().startBackgroundService();
    } catch (e) {
      print('Error starting server: $e');
    }
  }

  void _handleConnection(Socket socket) {
    socket.listen(
          (Uint8List data) {
        try {
          final message = json.decode(String.fromCharCodes(data));
          _handleMessage(socket, message);
        } catch (e) {
          print('Error handling message: $e');
        }
      },
      onDone: () {
        print('Client disconnected');
        if (_connectedSocket == socket) {
          _handleDisconnection();
        }
      },
      onError: (error) {
        print('Socket error: $error');
        if (_connectedSocket == socket) {
          _handleDisconnection();
        }
      },
    );
  }

  void _handleDisconnection() {
    _connectedSocket = null;
    _heartbeatTimer?.cancel();
    onConnectionStatusChanged?.call('Disconnected');

    // Start reconnection attempts
    if (_connectedDevice != null && !_isReconnecting) {
      _startReconnection();
    }
  }

  void _startReconnection() {
    _isReconnecting = true;
    _reconnectTimer = Timer.periodic(Duration(seconds: 5), (timer) async {
      if (_connectedDevice != null) {
        print('Attempting to reconnect to ${_connectedDevice!.name}...');
        final success = await _attemptReconnection(_connectedDevice!);
        if (success) {
          timer.cancel();
          _isReconnecting = false;
          onConnectionStatusChanged?.call('Reconnected');
        }
      } else {
        timer.cancel();
        _isReconnecting = false;
      }
    });
  }

  Future<bool> _attemptReconnection(DeviceModel device) async {
    try {
      final socket = await Socket.connect(device.ipAddress, 8080, timeout: Duration(seconds: 3));

      final pairRequest = {
        'type': 'pair_request',
        'deviceId': Platform.localHostname,
        'deviceName': Platform.localHostname,
        'wifiName': await DeviceDiscoveryService().getCurrentWifiName(),
        'isReconnection': true,
      };
      socket.write(json.encode(pairRequest));

      // Listen for response with timeout
      final completer = Completer<bool>();
      Timer(Duration(seconds: 5), () {
        if (!completer.isCompleted) {
          completer.complete(false);
        }
      });

      socket.listen((data) {
        final response = json.decode(String.fromCharCodes(data));
        if (response['type'] == 'pair_response' && !completer.isCompleted) {
          if (response['accepted']) {
            _connectedSocket = socket;
            device.isConnected = true;
            _startHeartbeat();
            completer.complete(true);
          } else {
            completer.complete(false);
          }
        }
      });

      return await completer.future;
    } catch (e) {
      print('Reconnection failed: $e');
      return false;
    }
  }

  void _handleMessage(Socket socket, Map<String, dynamic> message) {
    switch (message['type']) {
      case 'discovery':
        _handleDiscovery(socket, message);
        break;
      case 'pair_request':
        _handlePairRequest(socket, message);
        break;
      case 'clipboard_data':
        _handleClipboardData(message);
        break;
      case 'file_data':
        _handleFileData(message);
        break;
      case 'heartbeat':
        _handleHeartbeat(socket);
        break;
      case 'heartbeat_response':
      // Connection is alive, do nothing
        break;
    }
  }

  void _handleDiscovery(Socket socket, Map<String, dynamic> message) {
    final response = {
      'type': 'discovery_response',
      'deviceId': Platform.localHostname,
      'deviceName': Platform.localHostname,
      'wifiName': message['wifiName'],
    };
    socket.write(json.encode(response));
  }

  void _handlePairRequest(Socket socket, Map<String, dynamic> message) {
    final response = {
      'type': 'pair_response',
      'accepted': true,
      'deviceName': Platform.localHostname,
    };
    socket.write(json.encode(response));

    _connectedSocket = socket;
    _connectedDevice = DeviceModel(
      id: message['deviceId'],
      name: message['deviceName'],
      wifiName: message['wifiName'],
      ipAddress: socket.remoteAddress.address,
      isConnected: true,
      isPaired: true,
    );

    _startHeartbeat();
    onConnectionStatusChanged?.call('Connected to ${_connectedDevice!.name}');
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(Duration(seconds: 10), (timer) {
      if (_connectedSocket != null) {
        try {
          final heartbeat = {'type': 'heartbeat', 'timestamp': DateTime.now().millisecondsSinceEpoch};
          _connectedSocket!.write(json.encode(heartbeat));
        } catch (e) {
          print('Heartbeat failed: $e');
          _handleDisconnection();
        }
      } else {
        timer.cancel();
      }
    });
  }

  void _handleHeartbeat(Socket socket) {
    final response = {
      'type': 'heartbeat_response',
      'timestamp': DateTime.now().millisecondsSinceEpoch
    };
    socket.write(json.encode(response));
  }

  void _handleClipboardData(Map<String, dynamic> message) {
    final clipboardItem = ClipboardItem.fromJson(message['data']);
    ClipboardService().setClipboardData(clipboardItem.content);
    onClipboardReceived?.call(clipboardItem);

    // Send acknowledgment
    if (_connectedSocket != null) {
      final ack = {
        'type': 'clipboard_ack',
        'itemId': clipboardItem.id,
        'timestamp': DateTime.now().millisecondsSinceEpoch
      };
      _connectedSocket!.write(json.encode(ack));
    }
  }

  void _handleFileData(Map<String, dynamic> message) {
    final clipboardItem = ClipboardItem.fromJson(message['data']);
    onClipboardReceived?.call(clipboardItem);

    // Send acknowledgment
    if (_connectedSocket != null) {
      final ack = {
        'type': 'file_ack',
        'itemId': clipboardItem.id,
        'timestamp': DateTime.now().millisecondsSinceEpoch
      };
      _connectedSocket!.write(json.encode(ack));
    }
  }

  Future<bool> connectToDevice(DeviceModel device) async {
    try {
      final socket = await Socket.connect(device.ipAddress, 8080);

      final pairRequest = {
        'type': 'pair_request',
        'deviceId': Platform.localHostname,
        'deviceName': Platform.localHostname,
        'wifiName': await DeviceDiscoveryService().getCurrentWifiName(),
      };
      socket.write(json.encode(pairRequest));

      // Wait for response with timeout
      final completer = Completer<bool>();
      Timer(Duration(seconds: 10), () {
        if (!completer.isCompleted) {
          completer.complete(false);
        }
      });

      socket.listen((data) {
        final response = json.decode(String.fromCharCodes(data));
        if (response['type'] == 'pair_response' && !completer.isCompleted) {
          if (response['accepted']) {
            _connectedSocket = socket;
            _connectedDevice = device;
            device.isConnected = true;
            device.isPaired = true;
            _startHeartbeat();
            onConnectionStatusChanged?.call('Connected to ${device.name}');
            completer.complete(true);
          } else {
            completer.complete(false);
          }
        }
      });

      return await completer.future;
    } catch (e) {
      print('Error connecting to device: $e');
      return false;
    }
  }

  void sendClipboardData(ClipboardItem item) {
    if (_connectedSocket != null) {
      try {
        final message = {
          'type': 'clipboard_data',
          'data': item.toJson(),
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        };
        _connectedSocket!.write(json.encode(message));
      } catch (e) {
        print('Error sending clipboard data: $e');
        _handleDisconnection();
      }
    }
  }

  void disconnect() {
    _heartbeatTimer?.cancel();
    _reconnectTimer?.cancel();
    _connectedSocket?.close();
    _connectedSocket = null;
    _connectedDevice?.isConnected = false;
    _connectedDevice = null;
    _isReconnecting = false;
    onConnectionStatusChanged?.call('Disconnected');
  }

  DeviceModel? get connectedDevice => _connectedDevice;
  bool get isConnected => _connectedSocket != null;
  bool get isReconnecting => _isReconnecting;
}