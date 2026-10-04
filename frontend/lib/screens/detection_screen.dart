import 'package:flutter/material.dart';

class DetectionScreen extends StatelessWidget {
  const DetectionScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        // Temporary button for testing navigation.
        // The camera interface will be added later.
        child: ElevatedButton(
          onPressed: () {
            // Stop detection and return to the Home Screen.
            Navigator.pop(context);
          },
          child: const Text('Stop Detection'),
        ),
      ),
    );
  }
}