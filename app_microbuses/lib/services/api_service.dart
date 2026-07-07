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
}
