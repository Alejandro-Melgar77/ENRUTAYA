from fastapi import APIRouter, HTTPException
from pydantic import BaseModel
import pandas as pd
import networkx as nx
import math
import os
from typing import List, Optional

router = APIRouter()

# Variables globales
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
        trasbordos_df = pd.read_excel(os.path.join(data_dir, "PuntosTrasbordos.xlsx"))
        
        # Crear mapeo
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
            
        puntos_df_indexed = puntos_df.set_index('IdPunto')
        
        # GRAFO EXPANDIDO: Nodos son (IdPunto, IdLineaRuta)
        G = nx.DiGraph()
        
        # 1. Crear aristas de viaje (dentro de una misma línea)
        for _, row in lineas_puntos_df.iterrows():
            u = int(row['IdPunto'])
            v = int(row['IdPuntoDest'])
            if pd.isna(v) or v == 0:
                continue
            
            id_linea_ruta = int(row['IdLineaRuta'])
            linea_data = ruta_to_linea.get(id_linea_ruta, None)
            if linea_data is None:
                continue
            
            if u in puntos_df_indexed.index and v in puntos_df_indexed.index:
                # Añadir nodos al grafo
                node_u = (u, id_linea_ruta)
                node_v = (v, id_linea_ruta)
                
                if node_u not in G:
                    G.add_node(node_u, lat=float(puntos_df_indexed.loc[u]['Latitud']), lng=float(puntos_df_indexed.loc[u]['Longitud']), id_punto=u, linea=linea_data)
                if node_v not in G:
                    G.add_node(node_v, lat=float(puntos_df_indexed.loc[v]['Latitud']), lng=float(puntos_df_indexed.loc[v]['Longitud']), id_punto=v, linea=linea_data)
                
                # Calcular peso (tiempo)
                dlat = G.nodes[node_u]['lat'] - G.nodes[node_v]['lat']
                dlng = G.nodes[node_u]['lng'] - G.nodes[node_v]['lng']
                dist_approx = math.sqrt(dlat**2 + dlng**2) * 111000
                weight = max(dist_approx / 250.0, 0.1)
                
                G.add_edge(node_u, node_v, weight=weight, tipo='viaje', linea=linea_data)

        # 2. Crear aristas de transbordo (cambiar de línea en el mismo punto físico o puntos cercanos)
        # Agrupar nodos físicos (IdPunto)
        puntos_fisicos = {}
        for node in G.nodes():
            id_punto, id_lr = node
            if id_punto not in puntos_fisicos:
                puntos_fisicos[id_punto] = []
            puntos_fisicos[id_punto].append(id_lr)
            
        # Conectar diferentes líneas en el MISMO punto con una alta penalización (ej: 5 min)
        for id_punto, lineas_rutas in puntos_fisicos.items():
            for lr1 in lineas_rutas:
                for lr2 in lineas_rutas:
                    if lr1 != lr2:
                        # Si es de la misma "Línea" (ej. ida y vuelta), penalizamos un poco menos que cambiar a otra línea distinta
                        linea1 = ruta_to_linea[lr1]['id_linea']
                        linea2 = ruta_to_linea[lr2]['id_linea']
                        penalty = 1.0 if linea1 == linea2 else 10.0 # 10 minutos penalización por trasbordo
                        G.add_edge((id_punto, lr1), (id_punto, lr2), weight=penalty, tipo='transbordo')
        
        # Opcional: Procesar trasbordos peatonales definidos en PuntosTrasbordos.xlsx
        # ... (Por simplicidad en el MVP asumimos que cruzan en el mismo IdPunto)

        print(f"Grafo Expandido: {G.number_of_nodes()} nodos, {G.number_of_edges()} aristas.")
    except Exception as e:
        import traceback
        traceback.print_exc()
        print(f"Error al inicializar: {e}")

def get_nearest_physical_point(lat, lng):
    min_dist = float('inf')
    nearest_punto = None
    for idx, row in puntos_df.set_index('IdPunto').iterrows():
        dist = math.hypot(lat - row['Latitud'], lng - row['Longitud'])
        if dist < min_dist:
            min_dist = dist
            nearest_punto = idx
    return nearest_punto

def build_route_response(path_nodes):
    coordenadas = []
    instrucciones = []
    segmentos = []
    
    total_time = 0.0
    lineas_usadas = []
    
    current_segment_coords = []
    current_linea = None
    
    for i in range(len(path_nodes) - 1):
        u = path_nodes[i]
        v = path_nodes[i+1]
        edge = G[u][v]
        total_time += edge['weight']
        
        tipo = edge['tipo']
        if tipo == 'viaje':
            linea = edge['linea']
            if current_linea is None:
                current_linea = linea
                lineas_usadas.append(linea['nombre'])
                instrucciones.append({
                    "tipo": "subir",
                    "mensaje": f"Toma la línea {linea['nombre']}",
                    "lat": G.nodes[u]['lat'],
                    "lng": G.nodes[u]['lng']
                })
                current_segment_coords.append({"lat": G.nodes[u]['lat'], "lng": G.nodes[u]['lng']})
            
            current_segment_coords.append({"lat": G.nodes[v]['lat'], "lng": G.nodes[v]['lng']})
            coordenadas.append({
                "lat": G.nodes[v]['lat'], "lng": G.nodes[v]['lng'],
                "linea": linea['nombre'], "color": linea['color']
            })
            
        elif tipo == 'transbordo':
            # Terminar segmento actual
            if current_segment_coords and current_linea:
                segmentos.append({
                    "linea": current_linea['nombre'],
                    "color": current_linea['color'],
                    "coordenadas": list(current_segment_coords)
                })
            
            nueva_linea = G.nodes[v]['linea']
            instrucciones.append({
                "tipo": "trasbordo",
                "mensaje": f"Transbordo: Baja y toma la línea {nueva_linea['nombre']}",
                "lat": G.nodes[u]['lat'],
                "lng": G.nodes[u]['lng']
            })
            
            current_linea = nueva_linea
            lineas_usadas.append(nueva_linea['nombre'])
            current_segment_coords = [{"lat": G.nodes[v]['lat'], "lng": G.nodes[v]['lng']}]
            
    # Añadir último segmento
    if current_segment_coords and current_linea:
        segmentos.append({
            "linea": current_linea['nombre'],
            "color": current_linea['color'],
            "coordenadas": list(current_segment_coords)
        })
        
    last_node = path_nodes[-1]
    instrucciones.append({
        "tipo": "bajar",
        "mensaje": f"Baja del micro aquí (punto más cercano al destino)",
        "lat": G.nodes[last_node]['lat'],
        "lng": G.nodes[last_node]['lng']
    })
    
    # Limpiar líneas repetidas contiguas en lineas_usadas si las hubiera
    cleaned_lineas = []
    for l in lineas_usadas:
        if not cleaned_lineas or cleaned_lineas[-1] != l:
            cleaned_lineas.append(l)

    # Si coordenadas está vacío (ej. 1 solo nodo de viaje, forzamos inicio)
    if not coordenadas and len(path_nodes) > 0:
        first = G.nodes[path_nodes[0]]
        coordenadas.append({
            "lat": first['lat'], "lng": first['lng'],
            "linea": current_linea['nombre'] if current_linea else "Desconocido", 
            "color": current_linea['color'] if current_linea else "#000"
        })
        
    return {
        "lineas_usadas": cleaned_lineas,
        "tiempo_estimado_min": round(total_time, 1),
        "num_transbordos": max(len(cleaned_lineas) - 1, 0),
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
        
    origen_punto_id = get_nearest_physical_point(req.origen_lat, req.origen_lng)
    destino_punto_id = get_nearest_physical_point(req.destino_lat, req.destino_lng)
    
    if origen_punto_id is None or destino_punto_id is None:
        raise HTTPException(status_code=404, detail="No se encontraron puntos cercanos al origen o destino.")
    
    if origen_punto_id == destino_punto_id:
        raise HTTPException(status_code=400, detail="El origen y destino son el mismo punto.")
    
    try:
        # Encontrar todos los nodos del grafo expandido que corresponden al punto físico de origen y destino
        nodos_origen = [n for n in G.nodes() if n[0] == origen_punto_id]
        nodos_destino = [n for n in G.nodes() if n[0] == destino_punto_id]
        
        if not nodos_origen or not nodos_destino:
            raise HTTPException(status_code=404, detail="No hay líneas que pasen cerca del origen o destino.")

        # Añadir supernodo de inicio y fin temporalmente para buscar la mejor combinación
        super_origen = 'SUPER_ORIGEN'
        super_destino = 'SUPER_DESTINO'
        G.add_node(super_origen, lat=req.origen_lat, lng=req.origen_lng)
        G.add_node(super_destino, lat=req.destino_lat, lng=req.destino_lng)
        
        for no in nodos_origen:
            G.add_edge(super_origen, no, weight=0.1, tipo='viaje', linea=G.nodes[no]['linea'])
        for nd in nodos_destino:
            G.add_edge(nd, super_destino, weight=0.1, tipo='viaje', linea=G.nodes[nd]['linea'])

        # Encontrar rutas usando Dijkstra
        all_routes = []
        seen_line_combos = set()
        
        try:
            paths_gen = nx.shortest_simple_paths(G, source=super_origen, target=super_destino, weight='weight')
            count = 0
            for path in paths_gen:
                if count >= 30:  # Buscar más profundo
                    break
                    
                # Quitar supernodos del camino
                real_path = path[1:-1]
                if not real_path:
                    continue
                    
                route_data = build_route_response(real_path)
                
                # Filtrar si tiene demasiados transbordos (max 2 para ciudad pequeña)
                if route_data['num_transbordos'] > 2:
                    count += 1
                    continue
                
                combo_key = tuple(route_data['lineas_usadas'])
                if combo_key not in seen_line_combos:
                    seen_line_combos.add(combo_key)
                    all_routes.append(route_data)
                
                if len(all_routes) >= 5:
                    break
                count += 1
        except nx.NetworkXNoPath:
            pass
            
        # Eliminar supernodos para no ensuciar el grafo global
        G.remove_node(super_origen)
        G.remove_node(super_destino)
        
        if not all_routes:
            raise HTTPException(status_code=404, detail="No se encontró una ruta posible entre estos puntos.")
        
        # Ordenar por menor tiempo
        all_routes.sort(key=lambda x: x['tiempo_estimado_min'])
        
        ruta_optima = all_routes[0]
        rutas_alternativas = all_routes[1:] if len(all_routes) > 1 else []
        
        # Añadir datos visuales de los puntos exactos
        orig_lat = puntos_df[puntos_df['IdPunto'] == origen_punto_id].iloc[0]['Latitud']
        orig_lng = puntos_df[puntos_df['IdPunto'] == origen_punto_id].iloc[0]['Longitud']
        dest_lat = puntos_df[puntos_df['IdPunto'] == destino_punto_id].iloc[0]['Latitud']
        dest_lng = puntos_df[puntos_df['IdPunto'] == destino_punto_id].iloc[0]['Longitud']
        
        return {
            "status": "success",
            "origen_encontrado": {"lat": float(orig_lat), "lng": float(orig_lng)},
            "destino_encontrado": {"lat": float(dest_lat), "lng": float(dest_lng)},
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
    if G is None:
        init_graph()
        
    if lineas_df is None or linea_ruta_df is None:
        raise HTTPException(status_code=500, detail="Datos no cargados.")
    
    result = []
    puntos_indexed = puntos_df.set_index('IdPunto')
    
    for _, linea in lineas_df.iterrows():
        id_linea = int(linea['IdLinea'])
        nombre = str(linea['NombreLinea'])
        color = str(linea['ColorLinea'])
        
        rutas_de_linea = linea_ruta_df[linea_ruta_df['IdLinea'] == id_linea]
        
        sub_rutas = []
        for _, ruta in rutas_de_linea.iterrows():
            id_lr = int(ruta['IdLineaRuta'])
            desc = str(ruta.get('Descripcion', ''))
            
            puntos_ruta = lineas_puntos_df[lineas_puntos_df['IdLineaRuta'] == id_lr].sort_values('Orden')
            
            coords = []
            for _, pr in puntos_ruta.iterrows():
                pid = int(pr['IdPunto'])
                if pid in puntos_indexed.index:
                    coords.append({"lat": float(puntos_indexed.loc[pid]['Latitud']), "lng": float(puntos_indexed.loc[pid]['Longitud'])})
            
            # Añadir destino final si existe
            if not puntos_ruta.empty:
                last_dest = int(puntos_ruta.iloc[-1]['IdPuntoDest'])
                if last_dest != 0 and last_dest in puntos_indexed.index:
                    coords.append({"lat": float(puntos_indexed.loc[last_dest]['Latitud']), "lng": float(puntos_indexed.loc[last_dest]['Longitud'])})
            
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
