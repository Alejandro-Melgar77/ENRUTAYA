from fastapi import APIRouter, HTTPException
from pydantic import BaseModel
import pandas as pd
import networkx as nx
import math
import os
from typing import List, Optional

router = APIRouter()

# Variables globales para cachear el grafo y los datos
G = None
puntos_df = None
lineas_df = None
linea_ruta_df = None
lineas_puntos_df = None
ruta_to_linea = {}

class RouteRequest(BaseModel):
    origen_lat: float
    origen_lng: float
    destino_lat: float
    destino_lng: float

def init_graph():
    global G, puntos_df, lineas_df, linea_ruta_df, lineas_puntos_df, ruta_to_linea
    
    base_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    data_dir = os.path.join(base_dir, "data")
    
    try:
        puntos_df = pd.read_excel(os.path.join(data_dir, "puntos.xlsx"))
        lineas_df = pd.read_excel(os.path.join(data_dir, "DatosLineas.xls"))
        lineas_puntos_df = pd.read_excel(os.path.join(data_dir, "LineasPuntos.xlsx"))
        linea_ruta_df = pd.read_excel(os.path.join(data_dir, "LineaRuta.xlsx"))
        
        # Crear mapeo de IdLineaRuta a IdLinea y su nombre/color/descripcion
        ruta_to_linea = {}
        for _, row in linea_ruta_df.iterrows():
            id_linea = row['IdLinea']
            linea_match = lineas_df[lineas_df['IdLinea'] == id_linea]
            if linea_match.empty:
                continue
            linea_info = linea_match.iloc[0]
            ruta_to_linea[int(row['IdLineaRuta'])] = {
                'id_linea': int(id_linea),
                'id_linea_ruta': int(row['IdLineaRuta']),
                'nombre': str(linea_info['NombreLinea']),
                'color': str(linea_info['ColorLinea']),
                'descripcion': str(row.get('Descripcion', '')),
            }
            
        # Indexar puntos por ID para rápido acceso
        puntos_df_indexed = puntos_df.set_index('IdPunto')
        
        G = nx.DiGraph()
        
        # Añadir nodos
        for idx, row in puntos_df_indexed.iterrows():
            G.add_node(int(idx), lat=float(row['Latitud']), lng=float(row['Longitud']),
                       stop=(str(row.get('Stop', 'N')) == 'S'))
            
        # Añadir aristas (trayectos de microbus)
        # Cada arista guarda la lista de lineas que la cubren
        for _, row in lineas_puntos_df.iterrows():
            u = int(row['IdPunto'])
            v = int(row['IdPuntoDest'])
            if pd.isna(v) or v == 0:
                continue
            
            id_linea_ruta = int(row['IdLineaRuta'])
            linea_data = ruta_to_linea.get(id_linea_ruta, None)
            if linea_data is None:
                continue
            
            # Calcular peso basado en distancia euclidiana entre puntos si Tiempo == 0
            if u in G.nodes and v in G.nodes:
                dlat = G.nodes[u]['lat'] - G.nodes[v]['lat']
                dlng = G.nodes[u]['lng'] - G.nodes[v]['lng']
                dist_approx = math.sqrt(dlat**2 + dlng**2) * 111000  # metros aprox
                weight = max(dist_approx / 250.0, 0.1)  # minutos a 250 m/min (15 km/h)
            else:
                weight = 1.0
            
            # Para DiGraph, solo guardamos una arista por par (u,v) con las lineas que la cubren
            if G.has_edge(u, v):
                existing = G[u][v]
                if linea_data['nombre'] not in [l['nombre'] for l in existing['lineas']]:
                    existing['lineas'].append(linea_data)
            else:
                G.add_edge(u, v, weight=weight, lineas=[linea_data])
                       
        print(f"Grafo inicializado: {G.number_of_nodes()} nodos, {G.number_of_edges()} aristas.")
    except Exception as e:
        import traceback
        traceback.print_exc()
        print(f"Error al inicializar el grafo de rutas: {e}")

def get_nearest_node(lat, lng):
    min_dist = float('inf')
    nearest = None
    for node_id, data in G.nodes(data=True):
        dist = math.hypot(lat - data['lat'], lng - data['lng'])
        if dist < min_dist:
            min_dist = dist
            nearest = node_id
    return nearest

def build_route_response(path_nodes):
    """Construye la respuesta de una ruta a partir de una lista de nodos."""
    coordenadas = []
    instrucciones = []
    segmentos = []  # Cada segmento es un tramo de una sola línea
    current_line_name = None
    current_segment_coords = []
    current_color = "#7B1FA2"  # Purple default
    total_time = 0.0
    
    for i in range(len(path_nodes) - 1):
        u = path_nodes[i]
        v = path_nodes[i+1]
        
        edge_data = G[u][v]
        total_time += edge_data['weight']
        
        # Seleccionar la línea preferida (mantener la actual si es posible para minimizar transbordos)
        available_lines = edge_data['lineas']
        chosen_line = None
        if current_line_name:
            for l in available_lines:
                if l['nombre'] == current_line_name:
                    chosen_line = l
                    break
        if chosen_line is None:
            chosen_line = available_lines[0]
        
        if current_line_name != chosen_line['nombre']:
            # Guardar segmento anterior
            if current_segment_coords:
                segmentos.append({
                    "linea": current_line_name,
                    "color": current_color,
                    "coordenadas": list(current_segment_coords)
                })
            
            # Detectar punto de trasbordo
            if current_line_name is not None:
                instrucciones.append({
                    "tipo": "trasbordo",
                    "mensaje": f"Transbordo: Baja y toma la línea {chosen_line['nombre']}",
                    "lat": G.nodes[u]['lat'],
                    "lng": G.nodes[u]['lng']
                })
            
            instrucciones.append({
                "tipo": "subir",
                "mensaje": f"Toma la línea {chosen_line['nombre']}",
                "lat": G.nodes[u]['lat'],
                "lng": G.nodes[u]['lng']
            })
            
            current_line_name = chosen_line['nombre']
            current_color = chosen_line['color']
            current_segment_coords = [{"lat": G.nodes[u]['lat'], "lng": G.nodes[u]['lng']}]
        else:
            current_segment_coords.append({"lat": G.nodes[u]['lat'], "lng": G.nodes[u]['lng']})
        
        coordenadas.append({
            "lat": G.nodes[u]['lat'],
            "lng": G.nodes[u]['lng'],
            "linea": chosen_line['nombre'],
            "color": chosen_line['color']
        })
    
    # Último nodo
    last_node = path_nodes[-1]
    current_segment_coords.append({"lat": G.nodes[last_node]['lat'], "lng": G.nodes[last_node]['lng']})
    coordenadas.append({
        "lat": G.nodes[last_node]['lat'],
        "lng": G.nodes[last_node]['lng'],
        "linea": current_line_name,
        "color": current_color
    })
    
    # Guardar último segmento
    if current_segment_coords:
        segmentos.append({
            "linea": current_line_name,
            "color": current_color,
            "coordenadas": list(current_segment_coords)
        })
    
    # Añadir instrucción de bajada
    instrucciones.append({
        "tipo": "bajar",
        "mensaje": f"Baja del micro aquí (punto más cercano al destino)",
        "lat": G.nodes[last_node]['lat'],
        "lng": G.nodes[last_node]['lng']
    })
    
    # Extraer solo los nombres únicos de líneas en orden
    lineas_usadas = []
    for s in segmentos:
        if s['linea'] not in lineas_usadas:
            lineas_usadas.append(s['linea'])
    
    return {
        "lineas_usadas": lineas_usadas,
        "tiempo_estimado_min": round(total_time, 1),
        "num_transbordos": max(len(lineas_usadas) - 1, 0),
        "instrucciones": instrucciones,
        "segmentos": segmentos,
        "coordenadas": coordenadas,
    }


@router.post("/calculate")
async def calculate_route(req: RouteRequest):
    if G is None:
        init_graph()
        
    if G is None:
        raise HTTPException(status_code=500, detail="El sistema de rutas no está inicializado.")
        
    origen_node = get_nearest_node(req.origen_lat, req.origen_lng)
    destino_node = get_nearest_node(req.destino_lat, req.destino_lng)
    
    if origen_node is None or destino_node is None:
        raise HTTPException(status_code=404, detail="No se encontraron puntos cercanos al origen o destino.")
    
    if origen_node == destino_node:
        raise HTTPException(status_code=400, detail="El origen y destino son el mismo punto.")
    
    try:
        # Buscar múltiples rutas usando k-shortest paths
        all_routes = []
        seen_line_combos = set()
        
        try:
            paths_gen = nx.shortest_simple_paths(G, source=origen_node, target=destino_node, weight='weight')
            count = 0
            for path in paths_gen:
                if count >= 20:  # Máximo 20 candidatos
                    break
                route_data = build_route_response(path)
                
                # Filtrar rutas con la misma combinación de líneas
                combo_key = tuple(route_data['lineas_usadas'])
                if combo_key not in seen_line_combos:
                    seen_line_combos.add(combo_key)
                    all_routes.append(route_data)
                
                if len(all_routes) >= 5:  # Máximo 5 rutas únicas
                    break
                count += 1
        except nx.NetworkXNoPath:
            raise HTTPException(status_code=404, detail="No se encontró una ruta posible entre estos puntos.")
        
        if not all_routes:
            raise HTTPException(status_code=404, detail="No se encontró una ruta posible entre estos puntos.")
        
        # La primera ruta es la óptima (menor tiempo)
        ruta_optima = all_routes[0]
        rutas_alternativas = all_routes[1:] if len(all_routes) > 1 else []
        
        return {
            "status": "success",
            "origen_encontrado": {"lat": G.nodes[origen_node]['lat'], "lng": G.nodes[origen_node]['lng']},
            "destino_encontrado": {"lat": G.nodes[destino_node]['lat'], "lng": G.nodes[destino_node]['lng']},
            "ruta_optima": ruta_optima,
            "rutas_alternativas": rutas_alternativas,
            "total_rutas": len(all_routes)
        }
    except HTTPException:
        raise
    except Exception as e:
        import traceback
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=f"Error interno al calcular la ruta: {str(e)}")


@router.get("/lineas")
async def get_all_lineas():
    """Devuelve todas las líneas con sus puntos para mostrar recorridos completos."""
    if G is None:
        init_graph()
        
    if lineas_df is None or linea_ruta_df is None:
        raise HTTPException(status_code=500, detail="Datos no cargados.")
    
    result = []
    for _, linea in lineas_df.iterrows():
        id_linea = int(linea['IdLinea'])
        nombre = str(linea['NombreLinea'])
        color = str(linea['ColorLinea'])
        
        # Obtener las rutas de esta línea (ida y vuelta)
        rutas_de_linea = linea_ruta_df[linea_ruta_df['IdLinea'] == id_linea]
        
        sub_rutas = []
        for _, ruta in rutas_de_linea.iterrows():
            id_lr = int(ruta['IdLineaRuta'])
            desc = str(ruta.get('Descripcion', ''))
            
            # Obtener puntos ordenados
            puntos_ruta = lineas_puntos_df[lineas_puntos_df['IdLineaRuta'] == id_lr].sort_values('Orden')
            
            coords = []
            for _, pr in puntos_ruta.iterrows():
                pid = int(pr['IdPunto'])
                if pid in G.nodes:
                    coords.append({"lat": G.nodes[pid]['lat'], "lng": G.nodes[pid]['lng']})
            
            # Añadir el último punto destino si existe
            if not puntos_ruta.empty:
                last_dest = int(puntos_ruta.iloc[-1]['IdPuntoDest'])
                if last_dest != 0 and last_dest in G.nodes:
                    coords.append({"lat": G.nodes[last_dest]['lat'], "lng": G.nodes[last_dest]['lng']})
            
            sub_rutas.append({
                "id_linea_ruta": id_lr,
                "descripcion": desc,
                "coordenadas": coords
            })
        
        result.append({
            "id_linea": id_linea,
            "nombre": nombre,
            "color": color,
            "rutas": sub_rutas
        })
    
    return {"lineas": result}
