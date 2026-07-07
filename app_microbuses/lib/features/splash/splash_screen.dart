import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import '../role_selection_screen.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _checkPermissions();
  }

  Future<void> _checkPermissions() async {
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        // Los servicios de ubicación están deshabilitados
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          // Permisos denegados
        }
      }
      
      if (permission == LocationPermission.deniedForever) {
        // Permisos denegados permanentemente
      }
    } catch (e) {
      debugPrint("Error al solicitar permisos: $e");
    } finally {
      // Navegar a la selección de rol pase lo que pase
      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const RoleSelectionScreen()),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.directions_bus, size: 80, color: Colors.deepPurple),
            SizedBox(height: 20),
            CircularProgressIndicator(color: Colors.deepPurple),
            SizedBox(height: 20),
            Text('Solicitando permisos GPS...', style: TextStyle(fontSize: 16)),
          ],
        ),
      ),
    );
  }
}
