import 'package:http/http.dart' as http;
import 'dart:convert';

class ApiService {
  // ATENCIÓN: 'localhost' no funciona en un celular físico. 
  // Debes reemplazar '192.168.x.x' por la dirección IPv4 local de tu computadora.
  static const String baseUrl = 'http://192.168.1.100:3000/api';

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
