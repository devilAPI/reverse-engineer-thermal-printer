import 'package:flutter/material.dart';

import 'ui/home_page.dart';

void main() => runApp(const ThermalPhotoApp());

class ThermalPhotoApp extends StatelessWidget {
  const ThermalPhotoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Thermal Photo',
      theme: ThemeData(colorSchemeSeed: Colors.blueGrey, useMaterial3: true),
      darkTheme: ThemeData(colorSchemeSeed: Colors.blueGrey, brightness: Brightness.dark, useMaterial3: true),
      home: const HomePage(),
    );
  }
}
