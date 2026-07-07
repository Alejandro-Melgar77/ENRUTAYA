import 'package:http/http.dart' as http;
import 'dart:convert';

class ApiService {
  // URL de Producción en Render
  static const String baseUrl = 'https://enrutaya.onrender.com/api';

  // Autenticación de Operador (Microbús)
  Future<bool> loginOperator(String placa, String password) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/units/login'),
        body: jsonEncode({'placa': placa}),
        headers: {'Content-Type': 'application/json'},
      );
      return response.statusCode == 200;
    } catch (e) {
      print("Login error: $e");
      return false;
    }
  }

  // Obtener las líneas y sus rutas desde la base de datos (PostGIS)
  Future<List<dynamic>> getLineas() async {
    try {
      final response = await http.get(Uri.parse('$baseUrl/routes/lineas'));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['lineas'] ?? [];
      }
      return [];
    } catch (e) {
      print("Error fetching lineas: $e");
      return [];
    }
  }

  // Algoritmo de rutas óptimas (Ir de A hacia B)
  Future<Map<String, dynamic>?> calculateRoute(double originLat, double originLng, double destLat, double destLng) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/routing/calculate'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'origen_lat': originLat,
          'origen_lng': originLng,
          'destino_lat': destLat,
          'destino_lng': destLng
        }),
      );
      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      }
      return null;
    } catch (e) {
      print("Error calculating route: $e");
      return null;
    }
  }
}
