import 'package:http/http.dart' as http;
import 'dart:convert';

class ApiService {
  // URL de Producción en Render
  static const String baseUrl = 'https://enrutaya.onrender.com/api';

  // Endpoint conceptual para login de operador
  Future<bool> loginOperator(String email, String password) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/auth/login'),
        body: jsonEncode({'email': email, 'password': password}),
        headers: {'Content-Type': 'application/json'},
      );
      return response.statusCode == 200;
    } catch (e) {
      // Simula éxito para pruebas de UI
      return true;
    }
  }

  // Endpoint conceptual para obtener microbuses (Vista pasajero)
  Future<List<dynamic>> getMicrobuses() async {
    try {
      final response = await http.get(Uri.parse('$baseUrl/microbuses'));
      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      }
      return [];
    } catch (e) {
      return [];
    }
  }
}
