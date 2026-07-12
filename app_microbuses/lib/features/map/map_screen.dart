import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'dart:convert';
import 'package:geolocator/geolocator.dart';
import '../../services/api_service.dart';

// Estados del flujo principal
enum MapState {
  initial,
  selectingOrigin,
  originPlaced,
  selectingDest,
  destPlaced,
  calculating,
  showingResult,
  showingLines,
}

class MapScreen extends StatefulWidget {
  final bool isOperator;
  const MapScreen({super.key, required this.isOperator});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> with SingleTickerProviderStateMixin {
  final MapController _mapController = MapController();
  MapState _state = MapState.initial;

  // Animación del microbús
  late AnimationController _busAnimationController;
  late Animation<double> _busAnimation;

  // Ubicación del usuario
  LatLng _userLocation = const LatLng(-17.7845, -63.1795);

  // Puntos seleccionados
  LatLng? _origen;
  LatLng? _destino;

  // Resultado del algoritmo
  Map<String, dynamic>? _rutaOptima;
  List<dynamic> _rutasAlternativas = [];
  int _rutaSeleccionadaIndex = -1; // -1 = óptima
  bool _isRouteNotFound = false; // Flag para mensaje de error específico
  bool _showDashboard = true; // Flag para ocultar/mostrar dashboard de ruta

  // Polylines para dibujar
  List<Polyline> _polylines = [];
  List<Marker> _markers = [];

  // Micros disponibles
  List<dynamic> _todasLasLineas = [];
  Map<int, String> _lineasSeleccionadas = {}; // id_linea -> 'ida' o 'vuelta'
  List<Polyline> _polylinesLineas = [];

  @override
  void initState() {
    super.initState();
    _checkLocationPermission();
    
    // Configurar animación del microbús
    _busAnimationController = AnimationController(
      duration: const Duration(seconds: 2),
      vsync: this,
    )..repeat(reverse: true);
    
    _busAnimation = Tween<double>(begin: -1.0, end: 1.0).animate(
      CurvedAnimation(parent: _busAnimationController, curve: Curves.easeInOutSine)
    );
  }

  @override
  void dispose() {
    _busAnimationController.dispose();
    super.dispose();
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
      // Ignorar si falla GPS
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
      _isRouteNotFound = false;
      _showDashboard = true;
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

    if (result == null || result['status'] != 'success') {
      setState(() {
        _state = MapState.showingResult;
        _isRouteNotFound = true;
      });
      return;
    }

    _rutaOptima = result['ruta_optima'] as Map<String, dynamic>?;
    _rutasAlternativas = (result['rutas_alternativas'] as List?) ?? [];
    _rutaSeleccionadaIndex = -1;
    _isRouteNotFound = false;
    _showDashboard = true;
    _state = MapState.showingResult;
    _drawCurrentRoute(); // llena _polylines y _markers sin setState interno
    setState(() {}); // un solo setState al final para re-pintar todo
  }

  void _drawCurrentRoute() {
    Map<String, dynamic> ruta;
    if (_rutaSeleccionadaIndex == -1) {
      ruta = _rutaOptima!;
    } else {
      ruta = _rutasAlternativas[_rutaSeleccionadaIndex] as Map<String, dynamic>;
    }

    List<Polyline> newPolylines = [];
    List<Marker> newMarkers = [];

    // Dibujar segmentos — siempre en morado (color de la app) sin importar el color de la linea
    final List segmentos = (ruta['segmentos'] as List?) ?? [];
    for (var seg in segmentos) {
      final List rawCoords = (seg['coordenadas'] as List?) ?? [];
      final List<LatLng> points = rawCoords
          .map((c) => LatLng((c['lat'] as num).toDouble(), (c['lng'] as num).toDouble()))
          .toList();
      if (points.length >= 2) {
        newPolylines.add(Polyline(
          points: points,
          strokeWidth: 7.0,
          color: const Color(0xFF6A1B9A), // morado oscuro fijo
        ));
      }
    }

    // Dibujar marcadores de instrucciones
    final List instrucciones = (ruta['instrucciones'] as List?) ?? [];
    for (var inst in instrucciones) {
      final double? lat = (inst['lat'] as num?)?.toDouble();
      final double? lng = (inst['lng'] as num?)?.toDouble();
      if (lat == null || lng == null) continue;

      IconData icon;
      Color color;
      double size = 36;

      switch (inst['tipo'] as String? ?? '') {
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
        point: LatLng(lat, lng),
        width: size + 8,
        height: size + 8,
        child: Icon(icon, color: color, size: size),
      ));
    }

    // Marcador de origen (punto azul grande)
    if (_origen != null) {
      newMarkers.add(Marker(
        point: _origen!,
        width: 44,
        height: 44,
        child: const Icon(Icons.person_pin_circle, color: Colors.blue, size: 44),
      ));
    }

    // Actualizar estado SIN setState anidado — aquí siempre estamos fuera de build
    _polylines = newPolylines;
    _markers = newMarkers;
  }

  void _resetToInitial() {
    setState(() {
      _state = MapState.initial;
      _origen = null;
      _destino = null;
      _rutaOptima = null;
      _rutasAlternativas = [];
      _rutaSeleccionadaIndex = -1;
      _isRouteNotFound = false;
      _showDashboard = true;
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

  void _toggleLinea(int idLinea, [String? sentido]) {
    setState(() {
      if (_lineasSeleccionadas.containsKey(idLinea)) {
        if (sentido == null || _lineasSeleccionadas[idLinea] == sentido) {
          _lineasSeleccionadas.remove(idLinea);
        } else {
          _lineasSeleccionadas[idLinea] = sentido;
        }
      } else {
        _lineasSeleccionadas[idLinea] = sentido ?? 'ida';
      }
      _rebuildLineasPolylines();
    });
  }

  // Paleta de colores para diferenciar líneas cuando la BD no tiene colores únicos
  static const List<Color> _lineaPalette = [
    Color(0xFFE53935), // rojo
    Color(0xFF1E88E5), // azul
    Color(0xFF43A047), // verde
    Color(0xFFFF8F00), // naranja
    Color(0xFF8E24AA), // morado
    Color(0xFF00ACC1), // cyan
    Color(0xFFD81B60), // rosa
    Color(0xFF3949AB), // índigo
    Color(0xFF00897B), // teal
    Color(0xFFEF6C00), // naranja oscuro
  ];

  Color _getLineaColor(int index, String? hexFromDb) {
    // Si el color de la BD es diferente del rojo por defecto, usarlo
    if (hexFromDb != null && hexFromDb.isNotEmpty) {
      final c = _hexToColor(hexFromDb);
      // Solo usar el color de la BD si no es exactamente #FF0000 (rojo default sin definir)
      if (c != const Color(0xFFFF0000)) return c;
    }
    // Caso contrario, usar paleta propia por índice
    return _lineaPalette[index % _lineaPalette.length];
  }

  void _rebuildLineasPolylines() {
    List<Polyline> newPolylines = [];

    int paletteIndex = 0;
    for (var linea in _todasLasLineas) {
      final idLinea = linea['id_linea'] as int;
      if (!_lineasSeleccionadas.containsKey(idLinea)) {
        paletteIndex++;
        continue;
      }

      final String selectedSentido = _lineasSeleccionadas[idLinea]!;
      Color color = _getLineaColor(paletteIndex, linea['color'] as String?);
      paletteIndex++;

      for (var ruta in linea['rutas']) {
        if (ruta['sentido'] != selectedSentido) continue;

        List<LatLng> points = [];
        for (var coord in ruta['coordenadas']) {
          points.add(LatLng((coord['lat'] as num).toDouble(), (coord['lng'] as num).toDouble()));
        }
        if (points.length >= 2) {
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
              PolylineLayer(polylines: _polylines),
              PolylineLayer(polylines: _polylinesLineas),
              MarkerLayer(markers: _markers),
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

          // CROSSHAIR de origen/destino
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

          // === CONTROLES ESTADO INICIAL ===
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

          // === ORIGEN / DESTINO INSTRUCCIONES ===
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

          // === CARGANDO ANIMADO ===
          if (_state == MapState.calculating)
            Container(
              color: Colors.black.withOpacity(0.6),
              child: Center(
                child: Card(
                  elevation: 8,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 32.0),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 200,
                          height: 60,
                          child: AnimatedBuilder(
                            animation: _busAnimation,
                            builder: (context, child) {
                              return Stack(
                                children: [
                                  Positioned(
                                    bottom: 10,
                                    left: 0,
                                    right: 0,
                                    child: Container(height: 2, color: Colors.grey.shade300),
                                  ),
                                  Align(
                                    alignment: Alignment(_busAnimation.value, 0),
                                    child: Icon(Icons.directions_bus, size: 48, color: Colors.purple.shade700),
                                  ),
                                ],
                              );
                            },
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text('Calculando ruta...', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.purple.shade700)),
                      ],
                    ),
                  ),
                ),
              ),
            ),

          // === ERROR ESPECÍFICO ===
          if (_state == MapState.showingResult && _isRouteNotFound)
            Container(
              color: Colors.black.withOpacity(0.5),
              child: Center(
                child: Card(
                  margin: const EdgeInsets.symmetric(horizontal: 30),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  child: Padding(
                    padding: const EdgeInsets.all(24.0),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.location_off, size: 64, color: Colors.red),
                        const SizedBox(height: 16),
                        const Text(
                          'No se puede calcular la ruta requerida',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'disponible proximamente.....',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 14, color: Colors.grey),
                        ),
                        const SizedBox(height: 24),
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
                            label: const Text('Calcular otra ruta'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

          // === RESULTADO ÉXITO: DASHBOARD OCULTABLE ===
          if (_state == MapState.showingResult && !_isRouteNotFound && _rutaOptima != null)
            AnimatedPositioned(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeInOut,
              bottom: _showDashboard ? 0 : -MediaQuery.of(context).size.height * 0.45,
              left: 0,
              right: 0,
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: const BorderRadius.only(topLeft: Radius.circular(24), topRight: Radius.circular(24)),
                  boxShadow: [BoxShadow(blurRadius: 15, color: Colors.black.withOpacity(0.3), offset: const Offset(0, -2))],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Handle para ocultar/mostrar (hace toggle)
                    GestureDetector(
                      onTap: () {
                        setState(() {
                          _showDashboard = !_showDashboard;
                        });
                      },
                      behavior: HitTestBehavior.opaque,
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Center(
                          child: Container(
                            width: 50,
                            height: 6,
                            decoration: BoxDecoration(
                              color: Colors.grey.shade400,
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                        ),
                      ),
                    ),
                    
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.route, color: Colors.purple.shade700),
                              const SizedBox(width: 8),
                              Text(
                                _rutaSeleccionadaIndex == -1 ? 'Ruta Óptima' : 'Ruta Alternativa ${_rutaSeleccionadaIndex + 1}',
                                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.purple.shade900),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          _buildRouteInfoCard(_rutaSeleccionadaIndex == -1 ? _rutaOptima! : _rutasAlternativas[_rutaSeleccionadaIndex]),
                          const SizedBox(height: 16),
                          Container(
                            constraints: const BoxConstraints(maxHeight: 180),
                            child: SingleChildScrollView(
                              child: _buildInstruccionesList(_rutaSeleccionadaIndex == -1 ? _rutaOptima! : _rutasAlternativas[_rutaSeleccionadaIndex]),
                            ),
                          ),
                          const SizedBox(height: 16),
                          if (_rutasAlternativas.isNotEmpty)
                            SizedBox(
                              width: double.infinity,
                              height: 48,
                              child: OutlinedButton.icon(
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: Colors.purple.shade700,
                                  side: BorderSide(color: Colors.purple.shade700, width: 2),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                ),
                                onPressed: _showAlternativeRoutes,
                                icon: const Icon(Icons.alt_route),
                                label: Text('Ver Rutas Alternativas (${_rutasAlternativas.length})', style: const TextStyle(fontWeight: FontWeight.bold)),
                              ),
                            ),
                          const SizedBox(height: 10),
                          SizedBox(
                            width: double.infinity,
                            height: 52,
                            child: ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.purple.shade700,
                                foregroundColor: Colors.white,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                elevation: 2,
                              ),
                              onPressed: _startSelectOrigin,
                              icon: const Icon(Icons.refresh),
                              label: const Text('Calcular otra ruta', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            
          // Botón flotante para re-mostrar el dashboard si está oculto
          if (_state == MapState.showingResult && !_isRouteNotFound && !_showDashboard)
            Positioned(
              bottom: 20,
              right: 20,
              child: FloatingActionButton(
                backgroundColor: Colors.purple.shade700,
                foregroundColor: Colors.white,
                onPressed: () {
                  setState(() {
                    _showDashboard = true;
                  });
                },
                child: const Icon(Icons.keyboard_arrow_up, size: 32),
              ),
            ),

          // PANEL MICROS DISPONIBLES
          if (_state == MapState.showingLines)
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                height: MediaQuery.of(context).size.height * 0.5,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: const BorderRadius.only(topLeft: Radius.circular(24), topRight: Radius.circular(24)),
                  boxShadow: [BoxShadow(blurRadius: 15, color: Colors.black.withOpacity(0.3))],
                ),
                child: Column(
                  children: [
                    Container(
                      margin: const EdgeInsets.symmetric(vertical: 12),
                      width: 50,
                      height: 6,
                      decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(3)),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Row(
                        children: [
                          Icon(Icons.directions_bus, color: Colors.purple.shade700),
                          const SizedBox(width: 8),
                          Text('Micros Disponibles', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.purple.shade900)),
                          const Spacer(),
                          IconButton(
                            icon: const Icon(Icons.close, color: Colors.red),
                            onPressed: _resetToInitial,
                          ),
                        ],
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
                                final isSelected = _lineasSeleccionadas.containsKey(id);
                                final selectedSentido = isSelected ? _lineasSeleccionadas[id] : null;
                                // Usar el mismo método de color que usa el mapa
                                final color = _getLineaColor(index, linea['color'] as String?);

                                return ListTile(
                                  leading: Container(
                                    width: 48,
                                    height: 48,
                                    decoration: BoxDecoration(
                                      color: isSelected ? color : color.withOpacity(0.12),
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Icon(Icons.directions_bus, color: isSelected ? Colors.white : color),
                                  ),
                                  title: Text(linea['nombre'], style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: isSelected ? color : Colors.black87)),
                                  subtitle: const Text('Ver recorrido completo'),
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (isSelected)
                                        Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            InkWell(
                                              onTap: () => _toggleLinea(id, 'ida'),
                                              child: Container(
                                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                                decoration: BoxDecoration(
                                                  color: selectedSentido == 'ida' ? color : Colors.grey.shade200,
                                                  borderRadius: const BorderRadius.only(topLeft: Radius.circular(8), topRight: Radius.circular(8)),
                                                ),
                                                child: Icon(Icons.arrow_upward, size: 18, color: selectedSentido == 'ida' ? Colors.white : Colors.grey.shade600),
                                              ),
                                            ),
                                            InkWell(
                                              onTap: () => _toggleLinea(id, 'vuelta'),
                                              child: Container(
                                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                                decoration: BoxDecoration(
                                                  color: selectedSentido == 'vuelta' ? color : Colors.grey.shade200,
                                                  borderRadius: const BorderRadius.only(bottomLeft: Radius.circular(8), bottomRight: Radius.circular(8)),
                                                ),
                                                child: Icon(Icons.arrow_downward, size: 18, color: selectedSentido == 'vuelta' ? Colors.white : Colors.grey.shade600),
                                              ),
                                            ),
                                          ],
                                        ),
                                      const SizedBox(width: 8),
                                      isSelected
                                          ? Icon(Icons.check_circle, color: color, size: 28)
                                          : Icon(Icons.circle_outlined, color: Colors.grey.shade400, size: 28),
                                    ],
                                  ),
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
    );
  }

  Widget _buildRouteInfoCard(Map<String, dynamic> ruta) {
    final distKm = ruta['distancia_total_km'] ?? 0;
    final walkOrig = ruta['distancia_caminata_origen_m'] ?? 0;
    final walkDest = ruta['distancia_caminata_destino_m'] ?? 0;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.purple.shade50,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.purple.shade100, width: 2),
      ),
      child: Column(
        children: [
          // Fila 1: Tiempo, Distancia, Transbordos
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _buildInfoItem(Icons.timer, '${ruta['tiempo_estimado_min']} min', 'Tiempo Total'),
              Container(width: 1, height: 36, color: Colors.purple.shade200),
              _buildInfoItem(Icons.straighten, '$distKm km', 'Distancia'),
              Container(width: 1, height: 36, color: Colors.purple.shade200),
              _buildInfoItem(Icons.transfer_within_a_station, '${ruta['num_transbordos']}', 'Transbordos'),
            ],
          ),
          const Divider(height: 16),
          // Fila 2: Caminata al bus, En bus, Caminata desde bus
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _buildInfoItem(Icons.directions_walk, '$walkOrig m', 'Al micro'),
              Container(width: 1, height: 36, color: Colors.purple.shade200),
              _buildInfoItem(Icons.directions_bus, '${ruta['tiempo_en_bus_min'] ?? ruta['tiempo_estimado_min']} min', 'En micro'),
              Container(width: 1, height: 36, color: Colors.purple.shade200),
              _buildInfoItem(Icons.directions_walk, '$walkDest m', 'Al destino'),
            ],
          ),
        ],
      ),
    );
  }
  
  Widget _buildInfoItem(IconData icon, String value, String label) {
    return Expanded(
      child: Column(
        children: [
          Icon(icon, color: Colors.purple.shade700, size: 22),
          const SizedBox(height: 2),
          Text(value, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.purple.shade900), textAlign: TextAlign.center),
          Text(label, style: const TextStyle(fontSize: 10, color: Colors.grey), textAlign: TextAlign.center),
        ],
      ),
    );
  }

  Widget _buildInstruccionesList(Map<String, dynamic> ruta) {
    final instrucciones = ruta['instrucciones'] as List;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Paso a paso:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.black87)),
        const SizedBox(height: 8),
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
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(color: color.withOpacity(0.1), shape: BoxShape.circle),
                  child: Icon(icon, size: 20, color: color),
                ),
                const SizedBox(width: 12),
                Expanded(child: Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(inst['mensaje'], style: const TextStyle(fontSize: 14, color: Colors.black87, fontWeight: FontWeight.w500)),
                )),
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
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.only(topLeft: Radius.circular(24), topRight: Radius.circular(24)),
          ),
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(child: Container(width: 50, height: 6, decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(3)))),
              const SizedBox(height: 16),
              Text('Rutas Disponibles', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.purple.shade900)),
              const SizedBox(height: 16),
              
              _buildAlternativeTile(
                title: 'Ruta Óptima',
                ruta: _rutaOptima!,
                isSelected: _rutaSeleccionadaIndex == -1,
                icon: Icons.star,
                onTap: () {
                  Navigator.pop(context);
                  _rutaSeleccionadaIndex = -1;
                  _drawCurrentRoute();
                  setState(() {});
                }
              ),
              
              // Alternativas
              ...List.generate(_rutasAlternativas.length, (index) {
                return _buildAlternativeTile(
                  title: 'Alternativa ${index + 1}',
                  ruta: _rutasAlternativas[index] as Map<String, dynamic>,
                  isSelected: _rutaSeleccionadaIndex == index,
                  icon: Icons.alt_route,
                  onTap: () {
                    Navigator.pop(context);
                    _rutaSeleccionadaIndex = index;
                    _drawCurrentRoute();
                    setState(() {});
                  }
                );
              }),
            ],
          ),
        );
      },
    );
  }
  
  Widget _buildAlternativeTile({required String title, required Map<String, dynamic> ruta, required bool isSelected, required IconData icon, required VoidCallback onTap}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: isSelected ? Colors.purple.shade50 : Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: isSelected ? Colors.purple.shade400 : Colors.grey.shade300, width: 2),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: Icon(icon, color: isSelected ? Colors.purple.shade700 : Colors.grey.shade500, size: 32),
        title: Text(title, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: isSelected ? Colors.purple.shade900 : Colors.black87)),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 8.0),
          child: Text(
            '${ruta['tiempo_estimado_min']} min • ${ruta['distancia_total_km'] ?? '?'} km • ${ruta['num_transbordos']} trasbordos\nLíneas: ${(ruta['lineas_usadas'] as List).join(' -> ')}',
            style: const TextStyle(height: 1.4),
          ),
        ),
        onTap: onTap,
      ),
    );
  }
}
