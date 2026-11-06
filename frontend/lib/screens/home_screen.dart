import 'package:flutter/material.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          SizedBox(
            width: double.infinity,
            height: double.infinity,
            child: const ColoredBox(color: Color(0xFF999999)),
          ),

          Transform.translate(
            offset: const Offset(0, 0),
            child: Center(
              child: Container(
                width: MediaQuery.of(context).size.width * 0.80,
                height: MediaQuery.of(context).size.width * 0.704,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.all(
                    Radius.elliptical(
                      MediaQuery.of(context).size.width * 0.40,
                      MediaQuery.of(context).size.width * 0.352,
                    ),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0x99000000),
                      blurRadius: 30,
                      spreadRadius: 7,
                      offset: Offset.zero,
                    ),

                    BoxShadow(
                      color: const Color(0x80000000),
                      blurRadius: 10,
                      spreadRadius: 1,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: ElevatedButton(
                  onPressed: () {
                    Navigator.pushNamed(context, '/detection');
                  },
                  style: ElevatedButton.styleFrom(
                    shape: const CircleBorder(),
                    backgroundColor: const Color(0XFF00B001),
                    foregroundColor: Colors.black,
                  ),
                  child: Text(
                    'ابدأ',
                    style: TextStyle(
                      fontSize: MediaQuery.of(context).size.width * 0.272,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
