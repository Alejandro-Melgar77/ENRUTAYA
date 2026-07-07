import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

class MapScreen extends StatelessWidget {
  final bool isOperator;

  const MapScreen({super.key, required this.isOperator});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(isOperator ? 'Panel de Operador' : 'Mapa de Rutas'),
      ),
      body: FlutterMap(
        options: MapOptions(
          initialCenter: const LatLng(-17.7833, -63.1821), // Centro de Santa Cruz
          initialZoom: 13.0,
        ),
        children: [
          TileLayer(
            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
            userAgentPackageName: 'com.example.app_microbuses',
          ),
          // Las capas de marcadores / rutas reales irán aquí
        ],
      ),
      floatingActionButton: isOperator ? FloatingActionButton.extended(
        onPressed: () {
          // Lógica conceptual: Enviar ubicación actual al backend
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Ubicación compartida con el backend')),
          );
        },
        icon: const Icon(Icons.share_location),
        label: const Text('Compartir Ubicación'),
      ) : null,
    );
  }
}
