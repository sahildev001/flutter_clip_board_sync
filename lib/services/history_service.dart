import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import '../models/clipboard_item.dart';

class HistoryService {
  static final HistoryService _instance = HistoryService._internal();
  factory HistoryService() => _instance;
  HistoryService._internal();

  Database? _database;

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    String path = join(await getDatabasesPath(), 'clipboard_history.db');
    return await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) {
        return db.execute(
          'CREATE TABLE clipboard_items(id TEXT PRIMARY KEY, type TEXT, content TEXT, filePath TEXT, fileName TEXT, timestamp INTEGER, deviceName TEXT)',
        );
      },
    );
  }

  Future<void> saveClipboardItem(ClipboardItem item) async {
    final db = await database;
    await db.insert(
      'clipboard_items',
      item.toJson(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<ClipboardItem>> getClipboardHistory() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'clipboard_items',
      orderBy: 'timestamp DESC',
      limit: 100,
    );

    return List.generate(maps.length, (i) {
      return ClipboardItem.fromJson(maps[i]);
    });
  }

  Future<void> clearHistory() async {
    final db = await database;
    await db.delete('clipboard_items');
  }
}