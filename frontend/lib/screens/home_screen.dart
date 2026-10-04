import 'package:flutter/material.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        // Temporary button for testing navigation.
        // The UI design will be added by the Design Team.
        child: ElevatedButton(
          onPressed: () {
            // Navigate from Home Screen to Detection Screen.
            Navigator.pushNamed(context, '/detection');
          },
          child: const Text('Start Detection'),
        ),
      ),
    );
  }
}