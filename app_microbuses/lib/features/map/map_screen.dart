import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'dart:convert';
import '../services/api_service.dart';

class MapScreen extends StatefulWidget {
  final bool isOperator;

  const MapScreen({super.key, required this.isOperator});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  List<Polyline> _rutas = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _cargarRutas();
  }

  Future<void> _cargarRutas() async {
    final lineas = await ApiService().getLineas();
    List<Polyline> polylines = [];
    
    for (var linea in lineas) {
      if (linea['ruta'] != null) {
        final geoJson = jsonDecode(linea['ruta']);
        if (geoJson['type'] == 'LineString') {
          List<LatLng> points = [];
          for (var coord in geoJson['coordinates']) {
            // PostGIS retorna GeoJSON en formato [longitud, latitud]
            points.add(LatLng(coord[1], coord[0]));
          }
          polylines.add(
            Polyline(
              points: points,
              strokeWidth: 5.0,
              color: Colors.purpleAccent,
            ),
          );
        }
      }
    }

    setState(() {
      _rutas = polylines;
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isOperator ? 'Panel de Operador' : 'Mapa de Rutas'),
        backgroundColor: Colors.purple,
        foregroundColor: Colors.white,
      ),
      body: _isLoading 
          ? const Center(child: CircularProgressIndicator(color: Colors.purple))
          : FlutterMap(
              options: MapOptions(
                initialCenter: const LatLng(-17.7845, -63.1795), // Ajustado al centro de la Línea 17
                initialZoom: 15.0,
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.example.app_microbuses',
                ),
                PolylineLayer(
                  polylines: _rutas,
                ),
              ],
            ),
      floatingActionButton: widget.isOperator ? FloatingActionButton.extended(
        backgroundColor: Colors.purple,
        foregroundColor: Colors.white,
        onPressed: () {
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
