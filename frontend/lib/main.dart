import 'package:flutter/material.dart';

import 'screens/home_screen.dart';
import 'screens/detection_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized(); // <--- Required before camera initialization
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      // Remove the debug banner.
      debugShowCheckedModeBanner: false,

      // The first screen displayed when the application starts.
      initialRoute: '/home',

      // Define the application screens and their routes.
      routes: {
        '/home': (context) => const HomeScreen(),
        '/detection': (context) => const DetectionScreen(),
      },
    );
  }
}