import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'dart:convert';
import 'package:geolocator/geolocator.dart';
import '../../services/api_service.dart';

class MapScreen extends StatefulWidget {
  final bool isOperator;
  const MapScreen({super.key, required this.isOperator});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final MapController _mapController = MapController();
  List<Polyline> _rutas = [];
  bool _isLoading = false;
  
  LatLng? _origen;
  LatLng? _destino;
  List<String> _instrucciones = [];
  LatLng _currentLocation = const LatLng(-17.7845, -63.1795); // Santa Cruz por defecto

  @override
  void initState() {
    super.initState();
    if (!widget.isOperator) {
      _checkLocationPermission();
    }
  }

  Future<void> _checkLocationPermission() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return;
    
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return;
    }
    
    if (permission == LocationPermission.deniedForever) return;
    
    Position position = await Geolocator.getCurrentPosition();
    setState(() {
      _currentLocation = LatLng(position.latitude, position.longitude);
      if (_origen == null) {
        _origen = _currentLocation; // Setear origen por defecto
      }
    });
    _mapController.move(_currentLocation, 14.5);
  }

  Color _hexToColor(String? hexString) {
    if (hexString == null || hexString.isEmpty) return Colors.purpleAccent;
    final buffer = StringBuffer();
    if (hexString.length == 6 || hexString.length == 7) buffer.write('ff');
    buffer.write(hexString.replaceFirst('#', ''));
    try {
      return Color(int.parse(buffer.toString(), radix: 16));
    } catch(e) {
      return Colors.purpleAccent;
    }
  }

  void _onMapTap(TapPosition tapPosition, LatLng point) {
    setState(() {
      if (_origen == null) {
        _origen = point;
      } else if (_destino == null) {
        _destino = point;
        _calcularRutaOptima();
      } else {
        _origen = point;
        _destino = null;
        _rutas = [];
        _instrucciones = [];
      }
    });
  }

  Future<void> _calcularRutaOptima() async {
    if (_origen == null || _destino == null) return;
    
    setState(() {
      _isLoading = true;
      _instrucciones = [];
    });
    
    final result = await ApiService().calculateRoute(
      _origen!.latitude, _origen!.longitude,
      _destino!.latitude, _destino!.longitude
    );
    
    if (result != null && result['status'] == 'success') {
      List<LatLng> points = [];
      List<Polyline> newPolylines = [];
      String currentLine = "";
      Color currentColor = Colors.purple;
      
      for (var coord in result['coordenadas']) {
        final point = LatLng(coord['lat'], coord['lng']);
        final linea = coord['linea'];
        
        if (currentLine != linea && points.isNotEmpty) {
          // Guardar tramo anterior
          points.add(point); // conectar el vertice
          newPolylines.add(Polyline(
            points: List.from(points),
            strokeWidth: 6.0,
            color: currentColor,
          ));
          points.clear();
        }
        
        points.add(point);
        currentLine = linea;
        currentColor = _hexToColor(coord['color']);
      }
      
      // Ultimo tramo
      if (points.isNotEmpty) {
        newPolylines.add(Polyline(
          points: points,
          strokeWidth: 6.0,
          color: currentColor,
        ));
      }
      
      setState(() {
        _rutas = newPolylines;
        _instrucciones = List<String>.from(result['instrucciones']);
        _isLoading = false;
      });
      
      // Ajustar la cámara para ver toda la ruta
      _mapController.move(_origen!, 13.5);
    } else {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No se encontró una ruta de transporte entre esos dos puntos.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isOperator ? 'Panel de Operador' : 'Calculador de Rutas'),
        backgroundColor: Colors.purple,
        foregroundColor: Colors.white,
      ),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _currentLocation,
              initialZoom: 14.0,
              onTap: widget.isOperator ? null : _onMapTap,
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.example.app_microbuses',
              ),
              PolylineLayer(
                polylines: _rutas,
              ),
              MarkerLayer(
                markers: [
                  if (_origen != null)
                    Marker(
                      point: _origen!,
                      width: 40,
                      height: 40,
                      child: const Icon(Icons.location_on, color: Colors.green, size: 40),
                    ),
                  if (_destino != null)
                    Marker(
                      point: _destino!,
                      width: 40,
                      height: 40,
                      child: const Icon(Icons.location_on, color: Colors.red, size: 40),
                    ),
                  // Current location marker (blue dot)
                  Marker(
                    point: _currentLocation,
                    width: 20,
                    height: 20,
                    child: Container(
                      decoration: const BoxDecoration(
                        color: Colors.blue,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
          
          // Instrucciones UI
          if (_instrucciones.isNotEmpty)
            Positioned(
              bottom: 20,
              left: 10,
              right: 10,
              child: Card(
                elevation: 4,
                child: Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text("Transbordos Sugeridos:", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                      const SizedBox(height: 8),
                      ..._instrucciones.map((inst) => Row(
                        children: [
                          const Icon(Icons.directions_bus, size: 16, color: Colors.purple),
                          const SizedBox(width: 8),
                          Expanded(child: Text(inst)),
                        ],
                      )),
                    ],
                  ),
                ),
              ),
            ),
            
          // Helper Text
          if (_origen == null || _destino == null)
            Positioned(
              top: 10,
              left: 10,
              right: 10,
              child: Card(
                color: Colors.white.withOpacity(0.9),
                child: Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Text(
                    _origen == null 
                      ? "Toca el mapa para indicar tu Origen (A)" 
                      : "Ahora toca el mapa en tu Destino (B)",
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.purple),
                  ),
                ),
              ),
            ),
            
          if (_isLoading)
            const Center(child: CircularProgressIndicator(color: Colors.purple)),
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
      ) : FloatingActionButton(
        backgroundColor: Colors.purple,
        foregroundColor: Colors.white,
        onPressed: _checkLocationPermission,
        child: const Icon(Icons.my_location),
      ),
    );
  }
}
