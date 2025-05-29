import 'dart:io';

import 'package:flutter/material.dart';
import '../services/device_discovery_service.dart';
import '../services/connection_service.dart';
import '../services/clipboard_service.dart';
import '../services/history_service.dart';
import '../services/background_service.dart';
import '../models/device_model.dart';
import '../models/clipboard_item.dart';
import 'package:permission_handler/permission_handler.dart';

class MainScreen extends StatefulWidget {
  @override
  _MainScreenState createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with TickerProviderStateMixin, WidgetsBindingObserver {
  List<DeviceModel> _devices = [];
  List<ClipboardItem> _history = [];
  bool _isScanning = false;
  TabController? _tabController;
  String _connectionStatus = 'Not connected';
  bool _isBackgroundServiceActive = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tabController = TabController(length: 3, vsync: this);
    _initializeServices();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tabController?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    switch (state) {
      case AppLifecycleState.resumed:
      // App came to foreground
        _loadHistory();
        break;
      case AppLifecycleState.paused:
      // App went to background - services should continue
        break;
      case AppLifecycleState.detached:
      // App is being terminated
        break;
      default:
        break;
    }
  }

  Future<void> _initializeServices() async {
    await _requestPermissions();

    // Initialize background service
    await BackgroundService().initializeBackgroundService();
    await BackgroundService().startBackgroundService();
    setState(() => _isBackgroundServiceActive = true);

    // Start connection service
    await ConnectionService().startServer();

    // Set up connection status listener
    ConnectionService().onConnectionStatusChanged = (status) {
      setState(() => _connectionStatus = status);

      // Notify background service about connection status
      if (status.contains('Connected')) {
        final deviceName = status.replaceAll('Connected to ', '');
        BackgroundService().sendMessageToBackground({
          'type': 'device_connected',
          'deviceName': deviceName,
        });
      } else if (status == 'Disconnected') {
        BackgroundService().sendMessageToBackground({
          'type': 'device_disconnected',
        });
      }
    };

    // Start clipboard monitoring
    ClipboardService().startClipboardMonitoring();

    // Set up clipboard received listener
    ConnectionService().onClipboardReceived = (ClipboardItem item) async {
      setState(() {
        _history.insert(0, item);
      });

      // Handle received files
      if (item.type == ClipboardItemType.file) {
        await ClipboardService().handleReceivedFile(item);
        _showSnackBar('File received: ${item.fileName}');
      } else {
        _showSnackBar('Clipboard synced from ${item.deviceName}');
      }
    };

    await _loadHistory();
    await _scanForDevices();
  }

  Future<void> _requestPermissions() async {
    final permissions = [
      Permission.location,
      Permission.storage,
      Permission.notification,
    ];

    // Add platform-specific permissions
    if (Platform.isAndroid) {
      permissions.add(Permission.nearbyWifiDevices);
    }

    await permissions.request();
  }

  Future<void> _scanForDevices() async {
    setState(() => _isScanning = true);

    try {
      final devices = await DeviceDiscoveryService().discoverDevices();
      setState(() {
        _devices = devices;
        _isScanning = false;
      });
    } catch (e) {
      setState(() => _isScanning = false);
      _showSnackBar('Error scanning for devices: $e');
    }
  }

  Future<void> _loadHistory() async {
    final history = await HistoryService().getClipboardHistory();
    setState(() => _history = history);
  }

  Future<void> _connectToDevice(DeviceModel device) async {
    _showSnackBar('Connecting to ${device.name}...');
    final success = await ConnectionService().connectToDevice(device);

    if (success) {
      setState(() {
        device.isConnected = true;
        device.isPaired = true;
      });
      _showSnackBar('Connected to ${device.name}');
    } else {
      _showSnackBar('Failed to connect to ${device.name}');
    }
  }

  Future<void> _handleHistoryItemTap(ClipboardItem item) async {
    try {
      switch (item.type) {
        case ClipboardItemType.text:
          ClipboardService().setClipboardData(item.content);
          _showSnackBar('Copied to clipboard');
          break;
        case ClipboardItemType.file:
          await _showFileOptionsDialog(item);
          break;
        case ClipboardItemType.image:
        // Handle image items if needed
          _showSnackBar('Image handling not implemented yet');
          break;
      }
    } catch (e) {
      _showSnackBar('Error: ${e.toString()}');
    }
  }

  Future<void> _showFileOptionsDialog(ClipboardItem item) async {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text('File Options'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('File: ${item.fileName ?? 'Unknown'}'),
              Text('From: ${item.deviceName}'),
              Text('Size: ${item.content.length} bytes'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text('Cancel'),
            ),
            TextButton(
              onPressed: () async {
                Navigator.of(context).pop();
                try {
                  await ClipboardService().copyFileToClipboard(item);
                  _showSnackBar('File path copied to clipboard');
                } catch (e) {
                  _showSnackBar('Error copying file: $e');
                }
              },
              child: Text('Copy Path'),
            ),
            ElevatedButton(
              onPressed: () async {
                Navigator.of(context).pop();
                try {
                  await ClipboardService().openFile(item);
                  _showSnackBar('Opening file...');
                } catch (e) {
                  _showSnackBar('Error opening file: $e');
                }
              },
              child: Text('Open File'),
            ),
          ],
        );
      },
    );
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Clipboard Sync'),
        actions: [
          IconButton(
            icon: Icon(_isBackgroundServiceActive ? Icons.cloud_done : Icons
                .cloud_off),
            onPressed: () => _showBackgroundServiceDialog(),
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          tabs: [
            Tab(icon: Icon(Icons.devices), text: 'Devices'),
            Tab(icon: Icon(Icons.content_copy), text: 'Clipboard'),
            Tab(icon: Icon(Icons.history), text: 'History'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildDevicesTab(),
          _buildClipboardTab(),
          _buildHistoryTab(),
        ],
      ),
    );
  }

  Future<void> _showBackgroundServiceDialog() async {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text('Background Service'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(
                    _isBackgroundServiceActive ? Icons.check_circle : Icons
                        .error,
                    color: _isBackgroundServiceActive ? Colors.green : Colors
                        .red,
                  ),
                  SizedBox(width: 8),
                  Text(_isBackgroundServiceActive ? 'Active' : 'Inactive'),
                ],
              ),
              SizedBox(height: 8),
              Text(
                'Background service keeps clipboard sync active when the app is not in foreground.',
                style: TextStyle(fontSize: 12),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text('OK'),
            ),
            if (!_isBackgroundServiceActive)
              ElevatedButton(
                onPressed: () async {
                  await BackgroundService().startBackgroundService();
                  setState(() => _isBackgroundServiceActive = true);
                  Navigator.of(context).pop();
                },
                child: Text('Start Service'),
              ),
          ],
        );
      },
    );
  }

  Widget _buildDevicesTab() {
    return Column(
      children: [
        Padding(
          padding: EdgeInsets.all(16.0),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _isScanning ? null : _scanForDevices,
                      icon: _isScanning
                          ? SizedBox(width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                          : Icon(Icons.refresh),
                      label: Text(
                          _isScanning ? 'Scanning...' : 'Scan for Devices'),
                    ),
                  ),
                ],
              ),
              SizedBox(height: 8),
              Container(
                padding: EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: ConnectionService().isConnected
                      ? Colors.green.shade50
                      : Colors.red.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: ConnectionService().isConnected
                        ? Colors.green
                        : Colors.red,
                    width: 1,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      ConnectionService().isConnected ? Icons.link : Icons
                          .link_off,
                      color: ConnectionService().isConnected
                          ? Colors.green
                          : Colors.red,
                    ),
                    SizedBox(width: 8),
                    Expanded(child: Text(_connectionStatus)),
                    if (ConnectionService().isReconnecting)
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: _devices.length,
            itemBuilder: (context, index) {
              final device = _devices[index];
              return Card(
                margin: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: ListTile(
                  leading: Icon(
                    device.isConnected ? Icons.link : Icons.devices,
                    color: device.isConnected ? Colors.green : Colors.grey,
                  ),
                  title: Text(device.name),
                  subtitle: Text(
                      'WiFi: ${device.wifiName}\nIP: ${device.ipAddress}'),
                  trailing: device.isConnected
                      ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.check_circle, color: Colors.green),
                      IconButton(
                        icon: Icon(Icons.close),
                        onPressed: () {
                          ConnectionService().disconnect();
                          setState(() => device.isConnected = false);
                        },
                      ),
                    ],
                  )
                      : ElevatedButton(
                    onPressed: () => _connectToDevice(device),
                    child: Text('Connect'),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildClipboardTab() {
    return Padding(
      padding: EdgeInsets.all(16.0),
      child: Column(
        children: [
          Card(
            child: Padding(
              padding: EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Quick Actions', style: Theme
                      .of(context)
                      .textTheme
                      .titleLarge),
                  SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: () =>
                              ClipboardService().pickAndShareFile(),
                          icon: Icon(Icons.file_upload),
                          label: Text('Share File'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          SizedBox(height: 16),
          Card(
            child: Padding(
              padding: EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Connection Status', style: Theme
                      .of(context)
                      .textTheme
                      .titleLarge),
                  SizedBox(height: 8),
                  Row(
                    children: [
                      Icon(
                        ConnectionService().isConnected ? Icons.link : Icons
                            .link_off,
                        color: ConnectionService().isConnected
                            ? Colors.green
                            : Colors.red,
                      ),
                      SizedBox(width: 8),
                      Expanded(child: Text(_connectionStatus)),
                    ],
                  ),
                  if (ConnectionService().isReconnecting) ...[
                    SizedBox(height: 8),
                    Row(
                      children: [
                        SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        SizedBox(width: 8),
                        Text('Reconnecting...'),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
          SizedBox(height: 16),
          Card(
            child: Padding(
              padding: EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Background Service', style: Theme
                      .of(context)
                      .textTheme
                      .titleLarge),
                  SizedBox(height: 8),
                  Row(
                    children: [
                      Icon(
                        _isBackgroundServiceActive ? Icons.check_circle : Icons
                            .error,
                        color: _isBackgroundServiceActive
                            ? Colors.green
                            : Colors.red,
                      ),
                      SizedBox(width: 8),
                      Text(_isBackgroundServiceActive ? 'Running' : 'Stopped'),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHistoryTab() {
    return Column(
      children: [
        Padding(
          padding: EdgeInsets.all(16.0),
          child: Row(
            children: [
              Expanded(child: Text('Clipboard History', style: Theme
                  .of(context)
                  .textTheme
                  .titleLarge)),
              IconButton(
                onPressed: () async {
                  await HistoryService().clearHistory();
                  await _loadHistory();
                },
                icon: Icon(Icons.clear_all),
              ),
            ],
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _loadHistory,
            child: ListView.builder(
              itemCount: _history.length,
              itemBuilder: (context, index) {
                final item = _history[index];
                return Card(
                  margin: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: ListTile(
                    leading: Icon(_getIconForType(item.type)),
                    title: Text(
                      item.type == ClipboardItemType.file
                          ? item.fileName ?? 'File'
                          : item.content,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                        '${item.deviceName} • ${_formatTime(item.timestamp)}'),
                    trailing: item.type == ClipboardItemType.file
                        ? Icon(Icons.more_vert)
                        : null,
                    onTap: () => _handleHistoryItemTap(item),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  IconData _getIconForType(ClipboardItemType type) {
    switch (type) {
      case ClipboardItemType.text:
        return Icons.text_fields;
      case ClipboardItemType.file:
        return Icons.attach_file;
      case ClipboardItemType.image:
        return Icons.image;
    }
  }

  String _formatTime(DateTime time) {
    final now = DateTime.now();
    final difference = now.difference(time);

    if (difference.inMinutes < 1) {
      return 'Just now';
    } else if (difference.inHours < 1) {
      return '${difference.inMinutes}m ago';
    } else if (difference.inDays < 1) {
      return '${difference.inHours}h ago';
    } else {
      return '${difference.inDays}d ago';
    }
  }
}