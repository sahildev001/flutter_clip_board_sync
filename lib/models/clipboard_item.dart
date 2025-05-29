import 'dart:io';

enum ClipboardItemType { text, file, image }

class ClipboardItem {
  final String id;
  final ClipboardItemType type;
  final String content;
  late final String? filePath;
  final String? fileName;
  final DateTime timestamp;
  final String deviceName;

  ClipboardItem({
    required this.id,
    required this.type,
    required this.content,
    this.filePath,
    this.fileName,
    required this.timestamp,
    required this.deviceName,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type.toString(),
    'content': content,
    'filePath': filePath,
    'fileName': fileName,
    'timestamp': timestamp.millisecondsSinceEpoch,
    'deviceName': deviceName,
  };

  factory ClipboardItem.fromJson(Map<String, dynamic> json) => ClipboardItem(
    id: json['id'],
    type: ClipboardItemType.values.firstWhere(
          (e) => e.toString() == json['type'],
    ),
    content: json['content'],
    filePath: json['filePath'],
    fileName: json['fileName'],
    timestamp: DateTime.fromMillisecondsSinceEpoch(json['timestamp']),
    deviceName: json['deviceName'],
  );
}