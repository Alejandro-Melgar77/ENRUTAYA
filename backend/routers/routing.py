from fastapi import APIRouter, HTTPException
from pydantic import BaseModel
import pandas as pd
import networkx as nx
import math
import os

router = APIRouter()

# Variables globales para cachear el grafo y los puntos
G = None
puntos_df = None
lineas_df = None

class RouteRequest(BaseModel):
    origen_lat: float
    origen_lng: float
    destino_lat: float
    destino_lng: float

def init_graph():
    global G, puntos_df, lineas_df
    
    base_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    data_dir = os.path.join(base_dir, "data")
    
    try:
        puntos_df = pd.read_excel(os.path.join(data_dir, "puntos.xlsx"))
        lineas_df = pd.read_excel(os.path.join(data_dir, "DatosLineas.xls"))
        lineas_puntos_df = pd.read_excel(os.path.join(data_dir, "LineasPuntos.xlsx"))
        linea_ruta_df = pd.read_excel(os.path.join(data_dir, "LineaRuta.xlsx"))
        trasbordos_df = pd.read_excel(os.path.join(data_dir, "PuntosTrasbordos.xlsx"))
        
        # Crear mapeo de IdLineaRuta a IdLinea y su nombre/color
        ruta_to_linea = {}
        for _, row in linea_ruta_df.iterrows():
            id_linea = row['IdLinea']
            linea_info = lineas_df[lineas_df['IdLinea'] == id_linea].iloc[0]
            ruta_to_linea[row['IdLineaRuta']] = {
                'id_linea': id_linea,
                'nombre': linea_info['NombreLinea'],
                'color': linea_info['ColorLinea']
            }
            
        # Indexar puntos por ID para rápido acceso
        puntos_df.set_index('IdPunto', inplace=True)
        
        G = nx.MultiDiGraph()
        
        # Añadir nodos
        for idx, row in puntos_df.iterrows():
            G.add_node(idx, lat=row['Latitud'], lng=row['Longitud'])
            
        # Añadir aristas (trayectos de microbus)
        for _, row in lineas_puntos_df.iterrows():
            u = row['IdPunto']
            v = row['IdPuntoDest']
            if pd.isna(v) or v == 0:
                continue
            
            linea_data = ruta_to_linea.get(row['IdLineaRuta'], {'id_linea': -1, 'nombre': 'Desconocido', 'color': '#000000'})
            
            # El tiempo puede venir como 0 en los datos brutos, asignamos 1 minuto como default de penalización por tramo
            tiempo = float(row['Tiempo']) if row['Tiempo'] > 0 else 1.0
            
            G.add_edge(u, v, 
                       weight=tiempo, 
                       tipo='microbus', 
                       linea_nombre=linea_data['nombre'], 
                       linea_color=linea_data['color'])
                       
        # Añadir aristas de transbordo (trasbordos peatonales)
        for _, row in trasbordos_df.iterrows():
            # Si los transbordos están en el mismo punto, es un loop que no ayuda a avanzar en un grafo de Nodos=Puntos, 
            # a menos que modelemos los nodos como (Punto, Linea). 
            # Como MVP, si la red de Puntos comparte los mismos IdPunto, NetworkX saltará mágicamente 
            # de una línea a otra sin penalización (porque están en el mismo nodo). 
            # Si queremos forzar una penalización visual, lo podemos omitir para el MVP,
            # ya que Dijkstra usará el mismo nodo para cambiar de arista.
            pass
            
        print(f"Grafo inicializado: {G.number_of_nodes()} nodos, {G.number_of_edges()} aristas.")
    except Exception as e:
        print(f"Error al inicializar el grafo de rutas: {e}")

def get_nearest_node(lat, lng):
    min_dist = float('inf')
    nearest = None
    for idx, row in puntos_df.iterrows():
        # Distancia euclidiana simple para MVP (suficiente para escalas pequeñas)
        dist = math.hypot(lat - row['Latitud'], lng - row['Longitud'])
        if dist < min_dist:
            min_dist = dist
            nearest = idx
    return nearest

@router.post("/calculate")
async def calculate_route(req: RouteRequest):
    if G is None:
        init_graph()
        
    if G is None:
        raise HTTPException(status_code=500, detail="El sistema de rutas no está inicializado.")
        
    origen_node = get_nearest_node(req.origen_lat, req.origen_lng)
    destino_node = get_nearest_node(req.destino_lat, req.destino_lng)
    
    try:
        # En MultiDiGraph, shortest_path usa el edge con menor peso entre dos nodos automáticamente
        path_nodes = nx.shortest_path(G, source=origen_node, target=destino_node, weight='weight')
        
        # Reconstruir las coordenadas y lineas
        coordenadas = []
        instrucciones = []
        current_line = None
        
        for i in range(len(path_nodes) - 1):
            u = path_nodes[i]
            v = path_nodes[i+1]
            
            # Obtener el mejor edge
            edge_data = min(G[u][v].values(), key=lambda e: e.get('weight', float('inf')))
            
            if current_line != edge_data['linea_nombre']:
                instrucciones.append(f"Toma la línea {edge_data['linea_nombre']}")
                current_line = edge_data['linea_nombre']
                
            coordenadas.append({
                "lat": G.nodes[u]['lat'],
                "lng": G.nodes[u]['lng'],
                "linea": edge_data['linea_nombre'],
                "color": edge_data['linea_color']
            })
            
        # Añadir el último nodo
        coordenadas.append({
            "lat": G.nodes[destino_node]['lat'],
            "lng": G.nodes[destino_node]['lng'],
            "linea": current_line,
            "color": G[path_nodes[-2]][destino_node][0]['linea_color'] if path_nodes else "#000"
        })
        
        return {
            "status": "success",
            "origen_encontrado": {"lat": G.nodes[origen_node]['lat'], "lng": G.nodes[origen_node]['lng']},
            "destino_encontrado": {"lat": G.nodes[destino_node]['lat'], "lng": G.nodes[destino_node]['lng']},
            "instrucciones": instrucciones,
            "coordenadas": coordenadas
        }
    except nx.NetworkXNoPath:
        raise HTTPException(status_code=404, detail="No se encontró una ruta posible entre estos puntos.")
