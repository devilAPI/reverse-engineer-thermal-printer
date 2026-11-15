import 'package:flutter/material.dart';

import 'ui/app_shell.dart';

/// Desktop: `thermal_photo [image]` opens the image directly ("Open with").
void main(List<String> args) => runApp(ThermalPhotoApp(initialImage: args.where((a) => !a.startsWith('-')).firstOrNull));

class ThermalPhotoApp extends StatelessWidget {
  const ThermalPhotoApp({super.key, this.initialImage});

  final String? initialImage;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Thermal Photo',
      theme: ThemeData(colorSchemeSeed: Colors.blueGrey, useMaterial3: true),
      darkTheme: ThemeData(colorSchemeSeed: Colors.blueGrey, brightness: Brightness.dark, useMaterial3: true),
      home: AppShell(initialImage: initialImage),
    );
  }
}
