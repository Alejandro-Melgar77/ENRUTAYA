import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'dart:convert';
import 'package:geolocator/geolocator.dart';
import '../../services/api_service.dart';

// Estados del flujo principal
enum MapState {
  initial,           // Mapa con botones "Calcular Ruta" y "Micros Disponibles"
  selectingOrigin,   // Flecha de origen visible, esperando que usuario arrastre
  originPlaced,      // Origen colocado, botón "Confirmar Origen" visible
  selectingDest,     // Flecha de destino visible
  destPlaced,        // Destino colocado, botón "Confirmar Destino" visible
  calculating,       // Calculando ruta...
  showingResult,     // Ruta dibujada en el mapa
  showingLines,      // Mostrando listado de líneas
}

class MapScreen extends StatefulWidget {
  final bool isOperator;
  const MapScreen({super.key, required this.isOperator});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final MapController _mapController = MapController();
  MapState _state = MapState.initial;

  // Ubicación del usuario
  LatLng _userLocation = const LatLng(-17.7845, -63.1795);

  // Puntos seleccionados
  LatLng? _origen;
  LatLng? _destino;

  // Resultado del algoritmo
  Map<String, dynamic>? _rutaOptima;
  List<dynamic> _rutasAlternativas = [];
  int _rutaSeleccionadaIndex = -1; // -1 = óptima
  String? _errorMsg;

  // Polylines para dibujar
  List<Polyline> _polylines = [];
  List<Marker> _markers = [];

  // Micros disponibles
  List<dynamic> _todasLasLineas = [];
  Set<int> _lineasSeleccionadas = {};
  List<Polyline> _polylinesLineas = [];

  @override
  void initState() {
    super.initState();
    _checkLocationPermission();
  }

  Future<void> _checkLocationPermission() async {
    try {
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
        _userLocation = LatLng(position.latitude, position.longitude);
      });
      _mapController.move(_userLocation, 14.0);
    } catch (e) {
      // GPS no disponible, usar ubicación por defecto
    }
  }

  Color _hexToColor(String? hexString) {
    if (hexString == null || hexString.isEmpty) return Colors.purple;
    final buffer = StringBuffer();
    if (hexString.length == 6 || hexString.length == 7) buffer.write('ff');
    buffer.write(hexString.replaceFirst('#', ''));
    try {
      return Color(int.parse(buffer.toString(), radix: 16));
    } catch (e) {
      return Colors.purple;
    }
  }

  // --- ACCIONES DEL FLUJO ---

  void _startSelectOrigin() {
    setState(() {
      _state = MapState.selectingOrigin;
      _origen = _mapController.camera.center;
      _destino = null;
      _rutaOptima = null;
      _rutasAlternativas = [];
      _rutaSeleccionadaIndex = -1;
      _errorMsg = null;
      _polylines = [];
      _markers = [];
    });
  }

  void _confirmOrigin() {
    setState(() {
      _state = MapState.selectingDest;
      _destino = _mapController.camera.center;
    });
  }

  void _confirmDest() {
    setState(() {
      _state = MapState.calculating;
    });
    _calcularRuta();
  }

  Future<void> _calcularRuta() async {
    if (_origen == null || _destino == null) return;

    final result = await ApiService().calculateRoute(
      _origen!.latitude, _origen!.longitude,
      _destino!.latitude, _destino!.longitude,
    );

    if (result == null) {
      setState(() {
        _state = MapState.showingResult;
        _errorMsg = 'Error de conexión con el servidor. Verifica tu internet.';
      });
      return;
    }

    if (result['status'] != 'success') {
      setState(() {
        _state = MapState.showingResult;
        _errorMsg = result['detail'] ?? 'No se encontró una ruta posible.';
      });
      return;
    }

    setState(() {
      _rutaOptima = result['ruta_optima'];
      _rutasAlternativas = result['rutas_alternativas'] ?? [];
      _rutaSeleccionadaIndex = -1;
      _errorMsg = null;
      _state = MapState.showingResult;
      _drawCurrentRoute();
    });
  }

  void _drawCurrentRoute() {
    Map<String, dynamic> ruta;
    if (_rutaSeleccionadaIndex == -1) {
      ruta = _rutaOptima!;
    } else {
      ruta = Map<String, dynamic>.from(_rutasAlternativas[_rutaSeleccionadaIndex]);
    }

    List<Polyline> newPolylines = [];
    List<Marker> newMarkers = [];

    // Dibujar segmentos
    for (var seg in ruta['segmentos']) {
      List<LatLng> points = [];
      for (var coord in seg['coordenadas']) {
        points.add(LatLng(coord['lat'], coord['lng']));
      }
      newPolylines.add(Polyline(
        points: points,
        strokeWidth: 6.0,
        color: Colors.purple.shade700,
      ));
    }

    // Dibujar marcadores de instrucciones
    for (var inst in ruta['instrucciones']) {
      IconData icon;
      Color color;
      double size = 36;

      switch (inst['tipo']) {
        case 'subir':
          icon = Icons.directions_bus;
          color = Colors.green.shade700;
          break;
        case 'trasbordo':
          icon = Icons.transfer_within_a_station;
          color = Colors.orange.shade700;
          size = 40;
          break;
        case 'bajar':
          icon = Icons.place;
          color = Colors.red.shade700;
          break;
        default:
          icon = Icons.circle;
          color = Colors.grey;
      }

      newMarkers.add(Marker(
        point: LatLng(inst['lat'], inst['lng']),
        width: size,
        height: size + 16,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: size),
          ],
        ),
      ));
    }

    // Marcador de origen
    if (_origen != null) {
      newMarkers.add(Marker(
        point: _origen!,
        width: 40,
        height: 40,
        child: const Icon(Icons.person_pin_circle, color: Colors.blue, size: 40),
      ));
    }

    setState(() {
      _polylines = newPolylines;
      _markers = newMarkers;
    });
  }

  void _resetToInitial() {
    setState(() {
      _state = MapState.initial;
      _origen = null;
      _destino = null;
      _rutaOptima = null;
      _rutasAlternativas = [];
      _rutaSeleccionadaIndex = -1;
      _errorMsg = null;
      _polylines = [];
      _markers = [];
      _lineasSeleccionadas = {};
      _polylinesLineas = [];
      _todasLasLineas = [];
    });
  }

  void _showMicrosDisponibles() async {
    setState(() {
      _state = MapState.showingLines;
      _polylines = [];
      _markers = [];
    });

    if (_todasLasLineas.isEmpty) {
      final result = await ApiService().getAllLineas();
      if (result != null) {
        setState(() {
          _todasLasLineas = result;
        });
      }
    }
  }

  void _toggleLinea(int idLinea) {
    setState(() {
      if (_lineasSeleccionadas.contains(idLinea)) {
        _lineasSeleccionadas.remove(idLinea);
      } else {
        _lineasSeleccionadas.add(idLinea);
      }
      _rebuildLineasPolylines();
    });
  }

  void _rebuildLineasPolylines() {
    List<Polyline> newPolylines = [];

    for (var linea in _todasLasLineas) {
      if (!_lineasSeleccionadas.contains(linea['id_linea'])) continue;

      Color color = _hexToColor(linea['color']);
      for (var ruta in linea['rutas']) {
        List<LatLng> points = [];
        for (var coord in ruta['coordenadas']) {
          points.add(LatLng(coord['lat'], coord['lng']));
        }
        if (points.isNotEmpty) {
          newPolylines.add(Polyline(
            points: points,
            strokeWidth: 5.0,
            color: color,
          ));
        }
      }
    }

    _polylinesLineas = newPolylines;
  }

  // --- WIDGETS DE UI ---

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('EN RUTA YA!'),
        backgroundColor: Colors.purple.shade700,
        foregroundColor: Colors.white,
        leading: _state != MapState.initial
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: _resetToInitial,
              )
            : IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => Navigator.of(context).pop(),
              ),
      ),
      body: Stack(
        children: [
          // MAPA BASE
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _userLocation,
              initialZoom: 14.0,
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.example.app_microbuses',
              ),
              // Polylines de rutas calculadas
              PolylineLayer(polylines: _polylines),
              // Polylines de líneas seleccionadas (micros disponibles)
              PolylineLayer(polylines: _polylinesLineas),
              // Marcadores
              MarkerLayer(markers: _markers),
              // Punto azul de ubicación del usuario
              MarkerLayer(markers: [
                Marker(
                  point: _userLocation,
                  width: 18,
                  height: 18,
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.blue,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                  ),
                ),
              ]),
            ],
          ),

          // CROSSHAIR (flecha central) para seleccionar origen/destino
          if (_state == MapState.selectingOrigin || _state == MapState.originPlaced)
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.location_on, size: 48, color: Colors.green.shade700),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(4),
                      boxShadow: const [BoxShadow(blurRadius: 4, color: Colors.black26)],
                    ),
                    child: const Text('ORIGEN', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.green)),
                  ),
                ],
              ),
            ),

          if (_state == MapState.selectingDest || _state == MapState.destPlaced)
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.location_on, size: 48, color: Colors.red.shade700),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(4),
                      boxShadow: const [BoxShadow(blurRadius: 4, color: Colors.black26)],
                    ),
                    child: const Text('DESTINO', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.red)),
                  ),
                ],
              ),
            ),

          // === CONTROLES SEGÚN EL ESTADO ===

          // ESTADO INICIAL: Botones principales
          if (_state == MapState.initial)
            Positioned(
              bottom: 30,
              left: 20,
              right: 20,
              child: Column(
                children: [
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.purple.shade700,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        elevation: 4,
                      ),
                      onPressed: _startSelectOrigin,
                      icon: const Icon(Icons.route),
                      label: const Text('Calcular Ruta', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: Colors.purple.shade700,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: BorderSide(color: Colors.purple.shade700, width: 2),
                        ),
                        elevation: 4,
                      ),
                      onPressed: _showMicrosDisponibles,
                      icon: const Icon(Icons.directions_bus),
                      label: const Text('Micros Disponibles', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                    ),
                  ),
                ],
              ),
            ),

          // SELECCIONANDO ORIGEN: instrucción arriba + botón confirmar abajo
          if (_state == MapState.selectingOrigin || _state == MapState.originPlaced)
            Positioned(
              top: 10,
              left: 10,
              right: 10,
              child: Card(
                color: Colors.white.withOpacity(0.95),
                elevation: 4,
                child: const Padding(
                  padding: EdgeInsets.all(12.0),
                  child: Text(
                    'Mueve el mapa para posicionar la flecha verde en tu punto de partida',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontWeight: FontWeight.bold, color: Colors.green, fontSize: 14),
                  ),
                ),
              ),
            ),

          if (_state == MapState.selectingOrigin || _state == MapState.originPlaced)
            Positioned(
              bottom: 30,
              left: 20,
              right: 20,
              child: SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green.shade700,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    elevation: 4,
                  ),
                  onPressed: () {
                    _origen = _mapController.camera.center;
                    _confirmOrigin();
                  },
                  icon: const Icon(Icons.check_circle),
                  label: const Text('Confirmar Origen', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                ),
              ),
            ),

          // SELECCIONANDO DESTINO
          if (_state == MapState.selectingDest || _state == MapState.destPlaced)
            Positioned(
              top: 10,
              left: 10,
              right: 10,
              child: Card(
                color: Colors.white.withOpacity(0.95),
                elevation: 4,
                child: const Padding(
                  padding: EdgeInsets.all(12.0),
                  child: Text(
                    'Mueve el mapa para posicionar la flecha roja en tu destino',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontWeight: FontWeight.bold, color: Colors.red, fontSize: 14),
                  ),
                ),
              ),
            ),

          if (_state == MapState.selectingDest || _state == MapState.destPlaced)
            Positioned(
              bottom: 30,
              left: 20,
              right: 20,
              child: SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red.shade700,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    elevation: 4,
                  ),
                  onPressed: () {
                    _destino = _mapController.camera.center;
                    _confirmDest();
                  },
                  icon: const Icon(Icons.check_circle),
                  label: const Text('Confirmar Destino', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                ),
              ),
            ),

          // Marcador del origen ya confirmado (mientras se elige destino)
          if ((_state == MapState.selectingDest || _state == MapState.destPlaced) && _origen != null)
            Positioned(
              top: 80,
              left: 10,
              right: 10,
              child: Card(
                color: Colors.green.shade50,
                child: Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Row(
                    children: [
                      Icon(Icons.check_circle, color: Colors.green.shade700, size: 20),
                      const SizedBox(width: 8),
                      const Text('Origen confirmado', style: TextStyle(color: Colors.green, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
              ),
            ),

          // CALCULANDO
          if (_state == MapState.calculating)
            Container(
              color: Colors.black38,
              child: const Center(
                child: Card(
                  child: Padding(
                    padding: EdgeInsets.all(24.0),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(color: Colors.purple),
                        SizedBox(height: 16),
                        Text('Calculando ruta óptima...', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                      ],
                    ),
                  ),
                ),
              ),
            ),

          // RESULTADO: ERROR
          if (_state == MapState.showingResult && _errorMsg != null)
            Positioned(
              bottom: 30,
              left: 20,
              right: 20,
              child: Column(
                children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.red.shade50,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.red, width: 2),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.error, color: Colors.red, size: 32),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            _errorMsg!,
                            style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold, fontSize: 15),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.purple.shade700,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      onPressed: _startSelectOrigin,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Calcular otra ruta', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    ),
                  ),
                ],
              ),
            ),

          // RESULTADO: ÉXITO
          if (_state == MapState.showingResult && _errorMsg == null && _rutaOptima != null)
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: const BorderRadius.only(topLeft: Radius.circular(20), topRight: Radius.circular(20)),
                  boxShadow: [BoxShadow(blurRadius: 10, color: Colors.black.withOpacity(0.2))],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Handle bar
                    Container(
                      margin: const EdgeInsets.only(top: 8),
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(2)),
                    ),
                    // Información de la ruta
                    Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.route, color: Colors.purple.shade700),
                              const SizedBox(width: 8),
                              Text(
                                _rutaSeleccionadaIndex == -1 ? 'Ruta Óptima' : 'Ruta Alternativa ${_rutaSeleccionadaIndex + 1}',
                                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.purple.shade700),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          // Info de la ruta actual
                          _buildRouteInfoCard(_rutaSeleccionadaIndex == -1
                              ? _rutaOptima!
                              : _rutasAlternativas[_rutaSeleccionadaIndex]),
                          const SizedBox(height: 12),
                          // Instrucciones
                          _buildInstruccionesList(_rutaSeleccionadaIndex == -1
                              ? _rutaOptima!
                              : _rutasAlternativas[_rutaSeleccionadaIndex]),
                          const SizedBox(height: 12),
                          // Botón de rutas alternativas
                          if (_rutasAlternativas.isNotEmpty)
                            SizedBox(
                              width: double.infinity,
                              height: 44,
                              child: OutlinedButton.icon(
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: Colors.purple.shade700,
                                  side: BorderSide(color: Colors.purple.shade700),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                ),
                                onPressed: _showAlternativeRoutes,
                                icon: const Icon(Icons.alt_route),
                                label: Text('Rutas Alternativas (${_rutasAlternativas.length})'),
                              ),
                            ),
                          const SizedBox(height: 8),
                          SizedBox(
                            width: double.infinity,
                            height: 48,
                            child: ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.purple.shade700,
                                foregroundColor: Colors.white,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              ),
                              onPressed: _startSelectOrigin,
                              icon: const Icon(Icons.refresh),
                              label: const Text('Calcular otra ruta', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // MICROS DISPONIBLES: Panel lateral
          if (_state == MapState.showingLines)
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                height: MediaQuery.of(context).size.height * 0.45,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: const BorderRadius.only(topLeft: Radius.circular(20), topRight: Radius.circular(20)),
                  boxShadow: [BoxShadow(blurRadius: 10, color: Colors.black.withOpacity(0.2))],
                ),
                child: Column(
                  children: [
                    Container(
                      margin: const EdgeInsets.only(top: 8),
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(2)),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(12.0),
                      child: Row(
                        children: [
                          Icon(Icons.directions_bus, color: Colors.purple.shade700),
                          const SizedBox(width: 8),
                          Text('Micros Disponibles', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.purple.shade700)),
                          const Spacer(),
                          TextButton(
                            onPressed: _resetToInitial,
                            child: const Text('Cerrar', style: TextStyle(color: Colors.red)),
                          ),
                        ],
                      ),
                    ),
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 12),
                      child: Text('Toca una línea para ver su recorrido. Puedes ver varias a la vez.',
                        style: TextStyle(color: Colors.grey, fontSize: 13),
                      ),
                    ),
                    const Divider(),
                    Expanded(
                      child: _todasLasLineas.isEmpty
                          ? const Center(child: CircularProgressIndicator(color: Colors.purple))
                          : ListView.builder(
                              itemCount: _todasLasLineas.length,
                              itemBuilder: (context, index) {
                                final linea = _todasLasLineas[index];
                                final id = linea['id_linea'] as int;
                                final isSelected = _lineasSeleccionadas.contains(id);
                                final color = _hexToColor(linea['color']);

                                return ListTile(
                                  leading: Container(
                                    width: 40,
                                    height: 40,
                                    decoration: BoxDecoration(
                                      color: isSelected ? color : Colors.grey.shade200,
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Icon(Icons.directions_bus, color: isSelected ? Colors.white : color),
                                  ),
                                  title: Text(linea['nombre'], style: TextStyle(fontWeight: FontWeight.bold, color: isSelected ? color : Colors.black87)),
                                  subtitle: Text('${(linea['rutas'] as List).length} rutas disponibles'),
                                  trailing: isSelected
                                      ? Icon(Icons.visibility, color: color)
                                      : const Icon(Icons.visibility_off, color: Colors.grey),
                                  onTap: () => _toggleLinea(id),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
      // FAB para centrar en mi ubicación
      floatingActionButton: (_state == MapState.initial ||
              _state == MapState.selectingOrigin ||
              _state == MapState.selectingDest)
          ? FloatingActionButton(
              mini: true,
              backgroundColor: Colors.white,
              foregroundColor: Colors.purple.shade700,
              onPressed: () {
                _mapController.move(_userLocation, 14.5);
              },
              child: const Icon(Icons.my_location),
            )
          : null,
      floatingActionButtonLocation: FloatingActionButtonLocation.endTop,
    );
  }

  Widget _buildRouteInfoCard(Map<String, dynamic> ruta) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.purple.shade50,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          Column(
            children: [
              Icon(Icons.timer, color: Colors.purple.shade700),
              const SizedBox(height: 4),
              Text('${ruta['tiempo_estimado_min']} min', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.purple.shade700)),
              const Text('Tiempo', style: TextStyle(fontSize: 11, color: Colors.grey)),
            ],
          ),
          Column(
            children: [
              Icon(Icons.transfer_within_a_station, color: Colors.purple.shade700),
              const SizedBox(height: 4),
              Text('${ruta['num_transbordos']}', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.purple.shade700)),
              const Text('Transbordos', style: TextStyle(fontSize: 11, color: Colors.grey)),
            ],
          ),
          Column(
            children: [
              Icon(Icons.directions_bus, color: Colors.purple.shade700),
              const SizedBox(height: 4),
              Text('${(ruta['lineas_usadas'] as List).length}', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.purple.shade700)),
              const Text('Líneas', style: TextStyle(fontSize: 11, color: Colors.grey)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildInstruccionesList(Map<String, dynamic> ruta) {
    final instrucciones = ruta['instrucciones'] as List;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Instrucciones:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
        const SizedBox(height: 4),
        ...instrucciones.map((inst) {
          IconData icon;
          Color color;
          switch (inst['tipo']) {
            case 'subir':
              icon = Icons.directions_bus;
              color = Colors.green.shade700;
              break;
            case 'trasbordo':
              icon = Icons.transfer_within_a_station;
              color = Colors.orange.shade700;
              break;
            case 'bajar':
              icon = Icons.place;
              color = Colors.red.shade700;
              break;
            default:
              icon = Icons.info;
              color = Colors.grey;
          }
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
                Icon(icon, size: 18, color: color),
                const SizedBox(width: 8),
                Expanded(child: Text(inst['mensaje'], style: const TextStyle(fontSize: 13))),
              ],
            ),
          );
        }),
      ],
    );
  }

  void _showAlternativeRoutes() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.only(topLeft: Radius.circular(20), topRight: Radius.circular(20)),
      ),
      builder: (context) {
        return Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(2)),
                ),
              ),
              const SizedBox(height: 12),
              Text('Rutas Alternativas', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.purple.shade700)),
              const SizedBox(height: 4),
              // Opción: ruta óptima
              ListTile(
                leading: Icon(Icons.star, color: Colors.purple.shade700),
                title: const Text('Ruta Óptima', style: TextStyle(fontWeight: FontWeight.bold)),
                subtitle: Text('${_rutaOptima!['tiempo_estimado_min']} min • ${_rutaOptima!['num_transbordos']} transbordos • Líneas: ${(_rutaOptima!['lineas_usadas'] as List).join(', ')}'),
                selected: _rutaSeleccionadaIndex == -1,
                selectedTileColor: Colors.purple.shade50,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                onTap: () {
                  Navigator.pop(context);
                  setState(() {
                    _rutaSeleccionadaIndex = -1;
                    _drawCurrentRoute();
                  });
                },
              ),
              ...List.generate(_rutasAlternativas.length, (index) {
                final alt = _rutasAlternativas[index];
                return ListTile(
                  leading: Icon(Icons.alt_route, color: Colors.purple.shade400),
                  title: Text('Alternativa ${index + 1}', style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Text('${alt['tiempo_estimado_min']} min • ${alt['num_transbordos']} transbordos • Líneas: ${(alt['lineas_usadas'] as List).join(', ')}'),
                  selected: _rutaSeleccionadaIndex == index,
                  selectedTileColor: Colors.purple.shade50,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  onTap: () {
                    Navigator.pop(context);
                    setState(() {
                      _rutaSeleccionadaIndex = index;
                      _drawCurrentRoute();
                    });
                  },
                );
              }),
            ],
          ),
        );
      },
    );
  }
}
