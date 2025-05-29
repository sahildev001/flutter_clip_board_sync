import 'package:clipboard_local_sync/screens/main_screen.dart';
import 'package:flutter/material.dart';


void main() {
  runApp(ClipboardSharingApp());
}

class ClipboardSharingApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Clipboard Sync',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
      home: MainScreen(),
    );
  }
}
