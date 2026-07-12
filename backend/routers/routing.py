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
puntos_indexed = None
lineas_df = None
linea_ruta_df = None
lineas_puntos_df = None
trasbordos_df = None
ruta_to_linea = {}

# Constantes
BUS_SPEED_KM_H = 40.0       # Velocidad promedio del microbús
BUS_SPEED_M_MIN = BUS_SPEED_KM_H * 1000.0 / 60.0  # ~666.67 m/min
WALK_SPEED_M_MIN = 80.0     # Velocidad caminando: ~4.8 km/h
TRANSFER_PENALTY_DEFAULT = 5.0  # minutos


class RouteRequest(BaseModel):
    origen_lat: float
    origen_lng: float
    destino_lat: float
    destino_lng: float


def haversine_meters(lat1, lng1, lat2, lng2):
    """Distancia Haversine en metros entre dos puntos geográficos."""
    R = 6371000  # radio de la Tierra en metros
    phi1 = math.radians(lat1)
    phi2 = math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dlam = math.radians(lng2 - lng1)
    a = math.sin(dphi/2)**2 + math.cos(phi1) * math.cos(phi2) * math.sin(dlam/2)**2
    return R * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))


def init_graph():
    global G, puntos_df, puntos_indexed, lineas_df, linea_ruta_df, lineas_puntos_df, trasbordos_df, ruta_to_linea

    base_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    data_dir = os.path.join(base_dir, "data")

    try:
        puntos_df = pd.read_excel(os.path.join(data_dir, "puntos.xlsx"))
        lineas_df = pd.read_excel(os.path.join(data_dir, "DatosLineas.xls"))
        lineas_puntos_df = pd.read_excel(os.path.join(data_dir, "LineasPuntos.xlsx"))
        linea_ruta_df = pd.read_excel(os.path.join(data_dir, "LineaRuta.xlsx"))
        trasbordos_df = pd.read_excel(os.path.join(data_dir, "PuntosTrasbordos.xlsx"))

        # Indexar puntos
        puntos_indexed = puntos_df.set_index('IdPunto')

        # Mapeo de IdLineaRuta -> info de la línea
        ruta_to_linea = {}
        for _, row in linea_ruta_df.iterrows():
            id_linea = int(row['IdLinea'])
            linea_match = lineas_df[lineas_df['IdLinea'] == id_linea]
            if linea_match.empty:
                continue
            linea_info = linea_match.iloc[0]
            ruta_to_linea[int(row['IdLineaRuta'])] = {
                'id_linea': id_linea,
                'id_linea_ruta': int(row['IdLineaRuta']),
                'nombre': str(linea_info['NombreLinea']).strip(),
                'color': str(linea_info['ColorLinea']).strip(),
                'descripcion': str(row.get('Descripcion', '')).strip(),
            }

        # Mapeo de IdLinea -> lista de IdLineaRuta
        linea_to_rutas = {}
        for id_lr, info in ruta_to_linea.items():
            lid = info['id_linea']
            if lid not in linea_to_rutas:
                linea_to_rutas[lid] = []
            linea_to_rutas[lid].append(id_lr)

        # GRAFO EXPANDIDO: Nodos = (IdPunto, IdLineaRuta)
        G = nx.DiGraph()

        # 1. Aristas de viaje
        for _, row in lineas_puntos_df.iterrows():
            u_id = int(row['IdPunto'])
            v_id = int(row['IdPuntoDest'])
            if pd.isna(v_id) or v_id == 0:
                continue

            id_lr = int(row['IdLineaRuta'])
            linea_data = ruta_to_linea.get(id_lr)
            if linea_data is None:
                continue

            if u_id not in puntos_indexed.index or v_id not in puntos_indexed.index:
                continue

            node_u = (u_id, id_lr)
            node_v = (v_id, id_lr)

            lat_u = float(puntos_indexed.loc[u_id]['Latitud'])
            lng_u = float(puntos_indexed.loc[u_id]['Longitud'])
            lat_v = float(puntos_indexed.loc[v_id]['Latitud'])
            lng_v = float(puntos_indexed.loc[v_id]['Longitud'])

            if node_u not in G:
                G.add_node(node_u, lat=lat_u, lng=lng_u, id_punto=u_id, linea=linea_data)
            if node_v not in G:
                G.add_node(node_v, lat=lat_v, lng=lng_v, id_punto=v_id, linea=linea_data)

            dist_m = haversine_meters(lat_u, lng_u, lat_v, lng_v)
            time_min = dist_m / BUS_SPEED_M_MIN  # tiempo en minutos a 40 km/h

            G.add_edge(node_u, node_v, weight=time_min, dist_m=dist_m, tipo='viaje', linea=linea_data)

        # 2. Aristas de transbordo SOLO donde el Excel lo define
        # Primero construir set de pares (IdPunto, IdLinea) -> lista de IdLineaRuta
        punto_linea_rutas = {}
        for node in G.nodes():
            id_punto, id_lr = node
            id_linea = ruta_to_linea[id_lr]['id_linea']
            key = (id_punto, id_linea)
            if key not in punto_linea_rutas:
                punto_linea_rutas[key] = []
            punto_linea_rutas[key].append(id_lr)

        # Añadir transbordos de ida/vuelta de la MISMA línea (penalización baja: 0.5 min)
        puntos_fisicos = {}
        for node in G.nodes():
            id_punto, id_lr = node
            if id_punto not in puntos_fisicos:
                puntos_fisicos[id_punto] = []
            puntos_fisicos[id_punto].append(id_lr)

        for id_punto, lr_list in puntos_fisicos.items():
            for lr1 in lr_list:
                for lr2 in lr_list:
                    if lr1 != lr2 and ruta_to_linea[lr1]['id_linea'] == ruta_to_linea[lr2]['id_linea']:
                        G.add_edge((id_punto, lr1), (id_punto, lr2),
                                   weight=0.5, dist_m=0, tipo='cambio_sentido')

        # Añadir transbordos reales del Excel PuntosTrasbordos
        trasbordo_count = 0
        for _, row in trasbordos_df.iterrows():
            id_punto = int(row['IdPunto'])
            id_linea_orig = int(row['IdLineaOrigen'])
            id_linea_dest = int(row['IdLineaDestino'])
            penalty = float(row.get('PenalizacionMin', TRANSFER_PENALTY_DEFAULT))

            # Encontrar los IdLineaRuta que corresponden a cada IdLinea en ese punto
            lrs_orig = punto_linea_rutas.get((id_punto, id_linea_orig), [])
            lrs_dest = punto_linea_rutas.get((id_punto, id_linea_dest), [])

            for lr_o in lrs_orig:
                for lr_d in lrs_dest:
                    if lr_o != lr_d:
                        if not G.has_edge((id_punto, lr_o), (id_punto, lr_d)):
                            G.add_edge((id_punto, lr_o), (id_punto, lr_d),
                                       weight=penalty, dist_m=0, tipo='transbordo')
                            trasbordo_count += 1

        print(f"Grafo: {G.number_of_nodes()} nodos, {G.number_of_edges()} aristas, {trasbordo_count} transbordos del Excel.")
    except Exception as e:
        import traceback
        traceback.print_exc()
        print(f"Error al inicializar: {e}")


def get_nearest_physical_point(lat, lng):
    """Encuentra el IdPunto más cercano a unas coordenadas."""
    min_dist = float('inf')
    nearest = None
    for idx, row in puntos_indexed.iterrows():
        dist = haversine_meters(lat, lng, row['Latitud'], row['Longitud'])
        if dist < min_dist:
            min_dist = dist
            nearest = idx
    return nearest, min_dist


def build_route_response(path_nodes, user_origin_lat, user_origin_lng, user_dest_lat, user_dest_lng):
    """Construye respuesta con datos de distancia, tiempo, instrucciones, segmentos."""
    instrucciones = []
    segmentos = []

    total_dist_m = 0.0
    total_time_min = 0.0
    lineas_usadas = []

    current_segment_coords = []
    current_linea = None

    for i in range(len(path_nodes) - 1):
        u = path_nodes[i]
        v = path_nodes[i + 1]
        edge = G[u][v]
        total_time_min += edge['weight']
        total_dist_m += edge.get('dist_m', 0)

        tipo = edge['tipo']
        if tipo == 'viaje':
            linea = edge['linea']
            if current_linea is None or current_linea['id_linea_ruta'] != linea['id_linea_ruta']:
                # Si cambiamos de línea (no de tipo transbordo sino por cambio de viaje)
                if current_linea is not None and current_linea['id_linea'] != linea['id_linea']:
                    # Fue un transbordo implícito
                    if current_segment_coords:
                        segmentos.append({
                            "linea": current_linea['nombre'],
                            "color": current_linea['color'],
                            "coordenadas": list(current_segment_coords)
                        })
                    instrucciones.append({
                        "tipo": "trasbordo",
                        "mensaje": f"Transbordo: Baja y toma {linea['nombre']}",
                        "lat": G.nodes[u]['lat'],
                        "lng": G.nodes[u]['lng']
                    })
                    current_segment_coords = [{"lat": G.nodes[u]['lat'], "lng": G.nodes[u]['lng']}]
                    lineas_usadas.append(linea['nombre'])
                elif current_linea is None:
                    instrucciones.append({
                        "tipo": "subir",
                        "mensaje": f"Sube a la línea {linea['nombre']}",
                        "lat": G.nodes[u]['lat'],
                        "lng": G.nodes[u]['lng']
                    })
                    current_segment_coords.append({"lat": G.nodes[u]['lat'], "lng": G.nodes[u]['lng']})
                    lineas_usadas.append(linea['nombre'])

                current_linea = linea

            current_segment_coords.append({"lat": G.nodes[v]['lat'], "lng": G.nodes[v]['lng']})

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
                "mensaje": f"Transbordo: Baja y toma {nueva_linea['nombre']}",
                "lat": G.nodes[u]['lat'],
                "lng": G.nodes[u]['lng']
            })

            current_linea = nueva_linea
            lineas_usadas.append(nueva_linea['nombre'])
            current_segment_coords = [{"lat": G.nodes[v]['lat'], "lng": G.nodes[v]['lng']}]

        elif tipo == 'cambio_sentido':
            # No es un transbordo visible al usuario, es ida->vuelta de la misma línea
            if current_segment_coords and current_linea:
                segmentos.append({
                    "linea": current_linea['nombre'],
                    "color": current_linea['color'],
                    "coordenadas": list(current_segment_coords)
                })
            current_linea = G.nodes[v]['linea']
            current_segment_coords = [{"lat": G.nodes[v]['lat'], "lng": G.nodes[v]['lng']}]

    # Último segmento
    if current_segment_coords and current_linea:
        segmentos.append({
            "linea": current_linea['nombre'],
            "color": current_linea['color'],
            "coordenadas": list(current_segment_coords)
        })

    # Instrucción de bajada
    last_node = path_nodes[-1]
    instrucciones.append({
        "tipo": "bajar",
        "mensaje": "Baja del micro aquí",
        "lat": G.nodes[last_node]['lat'],
        "lng": G.nodes[last_node]['lng']
    })

    # Limpiar líneas contiguas repetidas
    cleaned_lineas = []
    for l in lineas_usadas:
        if not cleaned_lineas or cleaned_lineas[-1] != l:
            cleaned_lineas.append(l)

    # Calcular distancias de caminata
    first_bus_node = path_nodes[0]
    last_bus_node = path_nodes[-1]
    dist_walk_to_bus = haversine_meters(
        user_origin_lat, user_origin_lng,
        G.nodes[first_bus_node]['lat'], G.nodes[first_bus_node]['lng']
    )
    dist_walk_from_bus = haversine_meters(
        G.nodes[last_bus_node]['lat'], G.nodes[last_bus_node]['lng'],
        user_dest_lat, user_dest_lng
    )
    time_walk_to = dist_walk_to_bus / WALK_SPEED_M_MIN
    time_walk_from = dist_walk_from_bus / WALK_SPEED_M_MIN

    total_dist_km = total_dist_m / 1000.0

    return {
        "lineas_usadas": cleaned_lineas,
        "tiempo_estimado_min": round(total_time_min + time_walk_to + time_walk_from, 1),
        "tiempo_en_bus_min": round(total_time_min, 1),
        "distancia_total_km": round(total_dist_km, 2),
        "distancia_caminata_origen_m": round(dist_walk_to_bus),
        "distancia_caminata_destino_m": round(dist_walk_from_bus),
        "num_transbordos": max(len(cleaned_lineas) - 1, 0),
        "instrucciones": instrucciones,
        "segmentos": segmentos,
    }


@router.post("/calculate")
async def calculate_route(req: RouteRequest):
    if G is None:
        init_graph()

    if G is None:
        raise HTTPException(status_code=500, detail="El sistema de rutas no está inicializado.")

    origen_punto_id, dist_to_orig = get_nearest_physical_point(req.origen_lat, req.origen_lng)
    destino_punto_id, dist_to_dest = get_nearest_physical_point(req.destino_lat, req.destino_lng)

    if origen_punto_id is None or destino_punto_id is None:
        raise HTTPException(status_code=404, detail="No se encontraron puntos cercanos.")

    if origen_punto_id == destino_punto_id:
        raise HTTPException(status_code=400, detail="El origen y destino son el mismo punto.")

    try:
        nodos_origen = [n for n in G.nodes() if n[0] == origen_punto_id]
        nodos_destino = [n for n in G.nodes() if n[0] == destino_punto_id]

        if not nodos_origen or not nodos_destino:
            raise HTTPException(status_code=404, detail="No hay líneas que pasen cerca del origen o destino.")

        # Supernodos temporales
        super_origen = ('SUPER_ORIGEN', 0)
        super_destino = ('SUPER_DESTINO', 0)
        G.add_node(super_origen, lat=req.origen_lat, lng=req.origen_lng, id_punto=-1, linea={'id_linea': 0, 'nombre': '', 'color': '', 'id_linea_ruta': 0, 'descripcion': ''})
        G.add_node(super_destino, lat=req.destino_lat, lng=req.destino_lng, id_punto=-2, linea={'id_linea': 0, 'nombre': '', 'color': '', 'id_linea_ruta': 0, 'descripcion': ''})

        for no in nodos_origen:
            G.add_edge(super_origen, no, weight=0.01, dist_m=0, tipo='viaje', linea=G.nodes[no]['linea'])
        for nd in nodos_destino:
            G.add_edge(nd, super_destino, weight=0.01, dist_m=0, tipo='viaje', linea=G.nodes[nd]['linea'])

        all_routes = []
        seen_combos = set()
        direct_routes = []
        transfer_routes = []

        try:
            paths_gen = nx.shortest_simple_paths(G, source=super_origen, target=super_destino, weight='weight')
            count = 0
            for path in paths_gen:
                if count >= 50:
                    break

                real_path = path[1:-1]
                if len(real_path) < 2:
                    count += 1
                    continue

                route_data = build_route_response(real_path, req.origen_lat, req.origen_lng, req.destino_lat, req.destino_lng)

                if route_data['num_transbordos'] > 3:
                    count += 1
                    continue

                combo_key = tuple(route_data['lineas_usadas'])
                if combo_key not in seen_combos:
                    seen_combos.add(combo_key)
                    if route_data['num_transbordos'] == 0:
                        direct_routes.append(route_data)
                    else:
                        transfer_routes.append(route_data)

                if len(direct_routes) + len(transfer_routes) >= 8:
                    break
                count += 1
        except nx.NetworkXNoPath:
            pass

        # Limpiar supernodos
        G.remove_node(super_origen)
        G.remove_node(super_destino)

        if not direct_routes and not transfer_routes:
            raise HTTPException(status_code=404, detail="No se encontró una ruta posible entre estos puntos.")

        # PRIORIZACIÓN: Rutas directas primero, luego con trasbordo, ordenadas por tiempo
        direct_routes.sort(key=lambda x: x['tiempo_estimado_min'])
        transfer_routes.sort(key=lambda x: x['tiempo_estimado_min'])

        # La ruta óptima es la directa más rápida si existe, sino la con trasbordo más rápida
        if direct_routes:
            ruta_optima = direct_routes[0]
            rutas_alternativas = direct_routes[1:] + transfer_routes
        else:
            ruta_optima = transfer_routes[0]
            rutas_alternativas = transfer_routes[1:]

        # Limitar alternativas
        rutas_alternativas = rutas_alternativas[:5]

        return {
            "status": "success",
            "origen_encontrado": {
                "lat": float(puntos_indexed.loc[origen_punto_id]['Latitud']),
                "lng": float(puntos_indexed.loc[origen_punto_id]['Longitud'])
            },
            "destino_encontrado": {
                "lat": float(puntos_indexed.loc[destino_punto_id]['Latitud']),
                "lng": float(puntos_indexed.loc[destino_punto_id]['Longitud'])
            },
            "ruta_optima": ruta_optima,
            "rutas_alternativas": rutas_alternativas,
            "total_rutas": 1 + len(rutas_alternativas)
        }
    except HTTPException:
        raise
    except Exception as e:
        import traceback
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=f"Error interno: {str(e)}")


@router.get("/lineas")
async def get_all_lineas():
    if G is None:
        init_graph()

    if lineas_df is None or linea_ruta_df is None:
        raise HTTPException(status_code=500, detail="Datos no cargados.")

    result = []
    for _, linea in lineas_df.iterrows():
        id_linea = int(linea['IdLinea'])
        nombre = str(linea['NombreLinea']).strip()
        color = str(linea['ColorLinea']).strip()

        rutas_de_linea = linea_ruta_df[linea_ruta_df['IdLinea'] == id_linea]

        sub_rutas = []
        total_dist_km = 0

        for _, ruta in rutas_de_linea.iterrows():
            id_lr = int(ruta['IdLineaRuta'])
            desc = str(ruta.get('Descripcion', '')).strip()
            dist_ruta = float(ruta.get('Distancia', 0))
            total_dist_km += dist_ruta

            puntos_ruta = lineas_puntos_df[lineas_puntos_df['IdLineaRuta'] == id_lr].sort_values('Orden')

            coords = []
            for _, pr in puntos_ruta.iterrows():
                pid = int(pr['IdPunto'])
                if pid in puntos_indexed.index:
                    coords.append({
                        "lat": float(puntos_indexed.loc[pid]['Latitud']),
                        "lng": float(puntos_indexed.loc[pid]['Longitud'])
                    })

            # Añadir destino final
            if not puntos_ruta.empty:
                last_dest = int(puntos_ruta.iloc[-1]['IdPuntoDest'])
                if last_dest != 0 and last_dest in puntos_indexed.index:
                    coords.append({
                        "lat": float(puntos_indexed.loc[last_dest]['Latitud']),
                        "lng": float(puntos_indexed.loc[last_dest]['Longitud'])
                    })

            sub_rutas.append({
                "id_linea_ruta": id_lr,
                "descripcion": desc,
                "distancia_km": dist_ruta,
                "coordenadas": coords
            })

        result.append({
            "id_linea": id_linea,
            "nombre": nombre,
            "color": color,
            "distancia_total_km": round(total_dist_km, 2),
            "rutas": sub_rutas
        })

    return {"lineas": result}
