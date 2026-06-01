import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'screens/splash_screen.dart';

/// Global camera list — initialized once at startup
List<CameraDescription> appCameras = [];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Portrait-only orientation lock
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Fetch available cameras before app starts
  try {
    appCameras = await availableCameras();
  } on CameraException catch (e) {
    debugPrint('Camera fetch error: ${e.code} — ${e.description}');
  }

  runApp(const MonteageApp());
}

class MonteageApp extends StatelessWidget {
  const MonteageApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Monteage Attendance',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1565C0),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        fontFamily: 'Roboto',
      ),
      home: const SplashScreen(),
    );
  }
}