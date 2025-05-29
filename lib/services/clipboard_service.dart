import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:open_file/open_file.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import '../models/clipboard_item.dart';
import 'connection_service.dart';
import 'history_service.dart';
import 'background_service.dart';

class ClipboardService {
  static final ClipboardService _instance = ClipboardService._internal();
  factory ClipboardService() => _instance;
  ClipboardService._internal();

  String _lastClipboardContent = '';
  bool _isMonitoring = false;

  Future<void> startClipboardMonitoring() async {
    if (_isMonitoring) return;
    _isMonitoring = true;

    // Monitor clipboard changes in background
    _monitorClipboard();
  }

  void _monitorClipboard() async {
    while (_isMonitoring) {
      await Future.delayed(Duration(milliseconds: 500));
      await _checkClipboardChange();
    }
  }

  Future<void> _checkClipboardChange() async {
    try {
      final clipboardData = await Clipboard.getData(Clipboard.kTextPlain);
      final currentContent = clipboardData?.text ?? '';

      if (currentContent.isNotEmpty &&
          currentContent != _lastClipboardContent &&
          currentContent.length > 1) { // Avoid single character changes
        _lastClipboardContent = currentContent;
        await _handleClipboardChange(currentContent);
      }
    } catch (e) {
      print('Error checking clipboard: $e');
    }
  }

  Future<void> _handleClipboardChange(String content) async {
    final clipboardItem = ClipboardItem(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      type: ClipboardItemType.text,
      content: content,
      timestamp: DateTime.now(),
      deviceName: Platform.localHostname,
    );

    // Save to history
    await HistoryService().saveClipboardItem(clipboardItem);

    // Send to connected device
    if (ConnectionService().isConnected) {
      ConnectionService().sendClipboardData(clipboardItem);
    }

    // Notify background service
    BackgroundService().sendMessageToBackground({
      'type': 'clipboard_changed',
      'content': content,
    });
  }

  Future<void> pickAndShareFile() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles();

      if (result != null) {
        final file = File(result.files.single.path!);
        final fileName = result.files.single.name;

        // Read file content for transfer
        final fileBytes = await file.readAsBytes();
        final base64Content = base64Encode(fileBytes);

        final clipboardItem = ClipboardItem(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          type: ClipboardItemType.file,
          content: base64Content,
          filePath: file.path,
          fileName: fileName,
          timestamp: DateTime.now(),
          deviceName: Platform.localHostname,
        );

        // Save to history
        await HistoryService().saveClipboardItem(clipboardItem);

        // Send to connected device
        if (ConnectionService().isConnected) {
          ConnectionService().sendClipboardData(clipboardItem);
        }
      }
    } catch (e) {
      print('Error picking file: $e');
    }
  }

  Future<void> openFile(ClipboardItem item) async {
    try {
      if (item.type == ClipboardItemType.file) {
        String filePath;

        if (item.filePath != null && File(item.filePath!).existsSync()) {
          // File exists locally
          filePath = item.filePath!;
        } else {
          // File was received from another device, save it locally
          filePath = await _saveReceivedFile(item);
        }

        // Open the file
        final result = await OpenFile.open(filePath);
        if (result.type != ResultType.done) {
          throw Exception('Could not open file: ${result.message}');
        }

        // Also copy file path to clipboard for easy pasting
        await Clipboard.setData(ClipboardData(text: filePath));
      }
    } catch (e) {
      print('Error opening file: $e');
      throw e;
    }
  }

  Future<String> _saveReceivedFile(ClipboardItem item) async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final syncFolder = Directory('${directory.path}/clipboard_sync');

      if (!await syncFolder.exists()) {
        await syncFolder.create(recursive: true);
      }

      final fileName = item.fileName ?? 'received_file_${item.id}';
      final filePath = '${syncFolder.path}/$fileName';

      // Decode base64 content and save
      final fileBytes = base64Decode(item.content);
      final file = File(filePath);
      await file.writeAsBytes(fileBytes);

      return filePath;
    } catch (e) {
      print('Error saving received file: $e');
      throw e;
    }
  }

  Future<void> copyFileToClipboard(ClipboardItem item) async {
    try {
      if (item.type == ClipboardItemType.file) {
        String filePath;

        if (item.filePath != null && File(item.filePath!).existsSync()) {
          filePath = item.filePath!;
        } else {
          filePath = await _saveReceivedFile(item);
        }

        // Copy file path to clipboard
        await Clipboard.setData(ClipboardData(text: filePath));
        _lastClipboardContent = filePath;
      }
    } catch (e) {
      print('Error copying file to clipboard: $e');
      throw e;
    }
  }

  void setClipboardData(String data) {
    try {
      Clipboard.setData(ClipboardData(text: data));
      _lastClipboardContent = data;
    } catch (e) {
      print('Error setting clipboard data: $e');
    }
  }

  Future<void> handleReceivedFile(ClipboardItem item) async {
    try {
      if (item.type == ClipboardItemType.file) {
        // Save the received file
        final filePath = await _saveReceivedFile(item);

        // Update the item with local file path
        item.filePath = filePath;

        // Save updated item to history
        await HistoryService().saveClipboardItem(item);

        // Show notification
        await BackgroundService().showNotification(
          'File Received',
          'Received ${item.fileName} from ${item.deviceName}',
        );
      }
    } catch (e) {
      print('Error handling received file: $e');
    }
  }

  void stopClipboardMonitoring() {
    _isMonitoring = false;
  }
}