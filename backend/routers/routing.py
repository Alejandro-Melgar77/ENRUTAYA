from fastapi import APIRouter, HTTPException
from pydantic import BaseModel
import pandas as pd
import networkx as nx
import math
import os

router = APIRouter()

# ── Globales ─────────────────────────────────────────────────────────────────
G = None
puntos_df = None
puntos_indexed = None
lineas_df = None
linea_ruta_df = None
lineas_puntos_df = None
trasbordos_df = None
ruta_to_linea = {}

# ── Constantes físicas ────────────────────────────────────────────────────────
BUS_SPEED_KMH    = 40.0                          # km/h
BUS_SPEED_MPM    = BUS_SPEED_KMH * 1000.0 / 60  # m/min ≈ 666.67
WALK_SPEED_MPM   = 80.0                          # m/min ≈ 4.8 km/h
TRANSFER_PENALTY = 8.0                           # minutos penalización trasbordo


class RouteRequest(BaseModel):
    origen_lat: float
    origen_lng: float
    destino_lat: float
    destino_lng: float


# ── Utilidades geográficas ───────────────────────────────────────────────────

def haversine_m(lat1, lng1, lat2, lng2) -> float:
    """Distancia Haversine en metros."""
    R = 6371000.0
    φ1, φ2 = math.radians(lat1), math.radians(lat2)
    Δφ = math.radians(lat2 - lat1)
    Δλ = math.radians(lng2 - lng1)
    a = math.sin(Δφ / 2) ** 2 + math.cos(φ1) * math.cos(φ2) * math.sin(Δλ / 2) ** 2
    return R * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))


def dist_to_time(dist_m: float) -> float:
    """Metros → minutos a la velocidad del microbús."""
    return dist_m / BUS_SPEED_MPM


def walk_time(dist_m: float) -> float:
    """Metros → minutos caminando."""
    return dist_m / WALK_SPEED_MPM


# ── Construcción del grafo ────────────────────────────────────────────────────

def init_graph():
    global G, puntos_df, puntos_indexed, lineas_df, linea_ruta_df
    global lineas_puntos_df, trasbordos_df, ruta_to_linea

    base_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    datos_dir = os.path.join(base_dir, "..", "Documentos", "Datos_Lineas")
    
    # Archivos individuales (respetando el case-sensitive de git/Linux)
    puntos_path = os.path.join(datos_dir, "puntos.xlsx")
    lineas_path = os.path.join(datos_dir, "DatosLineas.xls")  # Contiene la hoja Lineas
    lineas_puntos_path = os.path.join(datos_dir, "LineasPuntos.xlsx")
    linea_ruta_path = os.path.join(datos_dir, "LineaRuta.xlsx")
    trasbordos_path = os.path.join(datos_dir, "PuntosTrasbordos.xlsx")

    try:
        puntos_df       = pd.read_excel(puntos_path)
        lineas_df       = pd.read_excel(lineas_path, sheet_name="Lineas")
        lineas_puntos_df = pd.read_excel(lineas_puntos_path)
        linea_ruta_df   = pd.read_excel(linea_ruta_path)
        trasbordos_df   = pd.read_excel(trasbordos_path)

        puntos_indexed = puntos_df.set_index("IdPunto")

        # Mapeo IdLineaRuta → metadatos de la línea
        ruta_to_linea = {}
        for _, row in linea_ruta_df.iterrows():
            id_linea = int(row["IdLinea"])
            match = lineas_df[lineas_df["IdLinea"] == id_linea]
            if match.empty:
                continue
            info = match.iloc[0]
            ruta_to_linea[int(row["IdLineaRuta"])] = {
                "id_linea":      id_linea,
                "id_linea_ruta": int(row["IdLineaRuta"]),
                "nombre":        str(info["NombreLinea"]).strip(),
                "color":         str(info["ColorLinea"]).strip(),
                "descripcion":   str(row.get("Descripcion", "")).strip(),
            }

        # Grafo expandido: nodo = (IdPunto, IdLineaRuta)
        G = nx.DiGraph()

        # ── 1. Aristas de viaje (dentro de cada ruta) ──────────────────────
        for _, row in lineas_puntos_df.iterrows():
            u_id = int(row["IdPunto"])
            v_id_raw = row["IdPuntoDest"]
            if pd.isna(v_id_raw):
                continue
            v_id = int(v_id_raw)
            if v_id == 0:
                continue

            id_lr = int(row["IdLineaRuta"])
            linea = ruta_to_linea.get(id_lr)
            if linea is None:
                continue
            if u_id not in puntos_indexed.index or v_id not in puntos_indexed.index:
                continue

            lat_u = float(puntos_indexed.loc[u_id, "Latitud"])
            lng_u = float(puntos_indexed.loc[u_id, "Longitud"])
            lat_v = float(puntos_indexed.loc[v_id, "Latitud"])
            lng_v = float(puntos_indexed.loc[v_id, "Longitud"])

            node_u = (u_id, id_lr)
            node_v = (v_id, id_lr)

            if node_u not in G:
                G.add_node(node_u, lat=lat_u, lng=lng_u, id_punto=u_id, linea=linea)
            if node_v not in G:
                G.add_node(node_v, lat=lat_v, lng=lng_v, id_punto=v_id, linea=linea)

            # Distancia es la variable independiente; tiempo depende de ella
            dist_m   = haversine_m(lat_u, lng_u, lat_v, lng_v)
            time_min = dist_to_time(dist_m)

            G.add_edge(node_u, node_v,
                       weight=time_min,
                       dist_m=dist_m,
                       tipo="viaje",
                       linea=linea)

        # ── 2. Aristas de trasbordo (solo las del Excel) ────────────────────
        # Índice: (IdPunto, IdLinea) → lista de IdLineaRuta presentes en ese punto
        punto_linea_map: dict[tuple, list] = {}
        for node in G.nodes():
            id_punto, id_lr = node
            id_linea = ruta_to_linea[id_lr]["id_linea"]
            key = (id_punto, id_linea)
            punto_linea_map.setdefault(key, []).append(id_lr)

        trasbordo_count = 0
        for _, row in trasbordos_df.iterrows():
            id_punto    = int(row["IdPunto"])
            linea_orig  = int(row["IdLineaOrigen"])
            linea_dest  = int(row["IdLineaDestino"])
            penalty     = float(row.get("PenalizacionMin", TRANSFER_PENALTY))

            lrs_orig = punto_linea_map.get((id_punto, linea_orig), [])
            lrs_dest = punto_linea_map.get((id_punto, linea_dest), [])

            for lr_o in lrs_orig:
                for lr_d in lrs_dest:
                    if not G.has_edge((id_punto, lr_o), (id_punto, lr_d)):
                        G.add_edge((id_punto, lr_o), (id_punto, lr_d),
                                   weight=penalty, dist_m=0.0, tipo="transbordo")
                        trasbordo_count += 1

        print(f"Grafo listo: {G.number_of_nodes()} nodos, "
              f"{G.number_of_edges()} aristas, "
              f"{trasbordo_count} transbordos.")
    except Exception as exc:
        import traceback
        traceback.print_exc()
        print(f"Error en init_graph: {exc}")


# ── Búsqueda de punto más cercano ─────────────────────────────────────────────

def nearest_point(lat: float, lng: float):
    """Devuelve (IdPunto, dist_metros) del punto geográfico más cercano."""
    best_id, best_d = None, float("inf")
    for idx, row in puntos_indexed.iterrows():
        d = haversine_m(lat, lng, float(row["Latitud"]), float(row["Longitud"]))
        if d < best_d:
            best_d, best_id = d, idx
    return best_id, best_d


# ── Construcción de la respuesta de ruta ─────────────────────────────────────

def build_route(path_nodes: list,
                orig_lat: float, orig_lng: float,
                dest_lat: float, dest_lng: float) -> dict:
    """
    Recibe la lista de nodos (IdPunto, IdLineaRuta) del camino real
    (ya sin super-nodos) y devuelve el dict completo de la ruta.
    """
    instrucciones   = []
    segmentos       = []
    total_dist_m    = 0.0   # variable independiente: distancia geográfica en bus
    total_time_bus  = 0.0   # tiempo en bus = f(distancia)
    lineas_usadas   = []
    cur_linea       = None
    cur_seg_coords  = []

    for i in range(len(path_nodes) - 1):
        u = path_nodes[i]
        v = path_nodes[i + 1]
        edge = G[u][v]
        tipo = edge["tipo"]

        if tipo == "viaje":
            dist_m   = edge["dist_m"]          # distancia real Haversine
            time_min = edge["weight"]           # = dist_m / BUS_SPEED_MPM
            total_dist_m   += dist_m
            total_time_bus += time_min

            linea = edge["linea"]

            # ¿Comenzamos un nuevo segmento de línea?
            if cur_linea is None:
                # Primer boarding
                instrucciones.append({
                    "tipo":    "subir",
                    "mensaje": f"Sube a la línea {linea['nombre']}",
                    "lat": G.nodes[u]["lat"],
                    "lng": G.nodes[u]["lng"],
                })
                cur_seg_coords = [
                    {"lat": G.nodes[u]["lat"], "lng": G.nodes[u]["lng"]},
                    {"lat": G.nodes[v]["lat"], "lng": G.nodes[v]["lng"]},
                ]
                lineas_usadas.append(linea["nombre"])
                cur_linea = linea

            elif cur_linea["id_linea_ruta"] == linea["id_linea_ruta"]:
                # Misma ruta, seguimos acumulando
                cur_seg_coords.append({"lat": G.nodes[v]["lat"], "lng": G.nodes[v]["lng"]})

            else:
                # Cambio implícito de ruta (no debería ocurrir sin edge de transbordo,
                # pero lo manejamos por seguridad)
                segmentos.append({
                    "linea": cur_linea["nombre"],
                    "color": cur_linea["color"],
                    "coordenadas": list(cur_seg_coords),
                })
                instrucciones.append({
                    "tipo":    "trasbordo",
                    "mensaje": f"Transbordo: Baja y toma {linea['nombre']}",
                    "lat": G.nodes[u]["lat"],
                    "lng": G.nodes[u]["lng"],
                })
                lineas_usadas.append(linea["nombre"])
                cur_linea = linea
                cur_seg_coords = [
                    {"lat": G.nodes[u]["lat"], "lng": G.nodes[u]["lng"]},
                    {"lat": G.nodes[v]["lat"], "lng": G.nodes[v]["lng"]},
                ]

        elif tipo == "transbordo":
            # Cerrar segmento anterior
            if cur_seg_coords and cur_linea:
                segmentos.append({
                    "linea": cur_linea["nombre"],
                    "color": cur_linea["color"],
                    "coordenadas": list(cur_seg_coords),
                })
                cur_seg_coords = []

            nueva = G.nodes[v]["linea"]
            instrucciones.append({
                "tipo":    "trasbordo",
                "mensaje": f"Transbordo: Baja y toma {nueva['nombre']}",
                "lat": G.nodes[u]["lat"],
                "lng": G.nodes[u]["lng"],
            })
            lineas_usadas.append(nueva["nombre"])
            cur_linea = nueva
            cur_seg_coords = [{"lat": G.nodes[v]["lat"], "lng": G.nodes[v]["lng"]}]
            # El tiempo de espera/penalización ya está en edge['weight']
            # No suma dist_m (es 0 en transbordo)

    # Cerrar último segmento
    if cur_seg_coords and cur_linea:
        segmentos.append({
            "linea": cur_linea["nombre"],
            "color": cur_linea["color"],
            "coordenadas": list(cur_seg_coords),
        })

    # Instrucción de bajada
    last = path_nodes[-1]
    instrucciones.append({
        "tipo":    "bajar",
        "mensaje": "Baja del micro aquí",
        "lat": G.nodes[last]["lat"],
        "lng": G.nodes[last]["lng"],
    })

    # Deduplicar líneas consecutivas iguales
    cleaned = []
    for l in lineas_usadas:
        if not cleaned or cleaned[-1] != l:
            cleaned.append(l)

    # ── Distancias de caminata (usuario → primer parada / última parada → destino) ──
    first = path_nodes[0]
    dist_walk_orig = haversine_m(orig_lat, orig_lng,
                                 G.nodes[first]["lat"], G.nodes[first]["lng"])
    dist_walk_dest = haversine_m(G.nodes[last]["lat"], G.nodes[last]["lng"],
                                 dest_lat, dest_lng)

    time_walk_orig = walk_time(dist_walk_orig)
    time_walk_dest = walk_time(dist_walk_dest)

    tiempo_total = round(total_time_bus + time_walk_orig + time_walk_dest, 1)
    dist_total_km = round(total_dist_m / 1000.0, 2)

    return {
        "lineas_usadas":               cleaned,
        "num_transbordos":             max(len(cleaned) - 1, 0),
        "distancia_total_km":          dist_total_km,
        "tiempo_estimado_min":         tiempo_total,
        "tiempo_en_bus_min":           round(total_time_bus, 1),
        "distancia_caminata_origen_m": round(dist_walk_orig),
        "distancia_caminata_destino_m": round(dist_walk_dest),
        "instrucciones":               instrucciones,
        "segmentos":                   segmentos,
    }


# ── Endpoint: calcular ruta ───────────────────────────────────────────────────

@router.post("/calculate")
async def calculate_route(req: RouteRequest):
    if G is None:
        init_graph()
    if G is None:
        raise HTTPException(500, "El sistema de rutas no está inicializado.")

    orig_id, _ = nearest_point(req.origen_lat, req.origen_lng)
    dest_id, _ = nearest_point(req.destino_lat, req.destino_lng)

    if orig_id is None or dest_id is None:
        raise HTTPException(404, "No se encontraron puntos cercanos.")
    if orig_id == dest_id:
        raise HTTPException(400, "El origen y el destino son el mismo punto.")

    nodos_orig = [n for n in G.nodes() if n[0] == orig_id]
    nodos_dest = [n for n in G.nodes() if n[0] == dest_id]

    if not nodos_orig or not nodos_dest:
        raise HTTPException(404, "No hay líneas en el origen o destino indicados.")

    # Super-nodos temporales
    S = ("__ORIG__", -1)
    T = ("__DEST__", -1)
    dummy_linea = {"id_linea": -1, "id_linea_ruta": -1,
                   "nombre": "", "color": "", "descripcion": ""}

    G.add_node(S, lat=req.origen_lat, lng=req.origen_lng,
               id_punto=-1, linea=dummy_linea)
    G.add_node(T, lat=req.destino_lat, lng=req.destino_lng,
               id_punto=-2, linea=dummy_linea)

    for no in nodos_orig:
        G.add_edge(S, no, weight=0.001, dist_m=0.0, tipo="viaje",
                   linea=G.nodes[no]["linea"])
    for nd in nodos_dest:
        G.add_edge(nd, T, weight=0.001, dist_m=0.0, tipo="viaje",
                   linea=G.nodes[nd]["linea"])

    try:
        direct_routes    = []
        transfer_routes  = []
        seen_combos      = set()

        try:
            paths_gen = nx.shortest_simple_paths(G, S, T, weight="weight")
            evaluated = 0
            for path in paths_gen:
                evaluated += 1
                if evaluated > 60:
                    break

                real_path = path[1:-1]   # quitar super-nodos
                if len(real_path) < 2:
                    continue

                try:
                    rdata = build_route(real_path,
                                        req.origen_lat, req.origen_lng,
                                        req.destino_lat, req.destino_lng)
                except Exception:
                    continue

                # No más de 2 transbordos para ciudad pequeña
                if rdata["num_transbordos"] > 2:
                    continue

                combo = tuple(rdata["lineas_usadas"])
                if combo in seen_combos:
                    continue
                seen_combos.add(combo)

                if rdata["num_transbordos"] == 0:
                    direct_routes.append(rdata)
                else:
                    transfer_routes.append(rdata)

                if len(direct_routes) >= 3 and len(transfer_routes) >= 3:
                    break
                if len(direct_routes) + len(transfer_routes) >= 6:
                    break

        except nx.NetworkXNoPath:
            pass

        # Ordenar cada grupo por tiempo
        direct_routes.sort(key=lambda r: r["tiempo_estimado_min"])
        transfer_routes.sort(key=lambda r: r["tiempo_estimado_min"])

        # Ruta óptima: directa si existe, si no, la de menor tiempo con trasbordo
        all_routes = direct_routes + transfer_routes
        if not all_routes:
            raise HTTPException(404, "No se encontró una ruta posible entre estos puntos.")

        ruta_optima      = all_routes[0]
        rutas_alternativas = all_routes[1:6]

    finally:
        # Siempre limpiar super-nodos aunque haya excepción
        if S in G:
            G.remove_node(S)
        if T in G:
            G.remove_node(T)

    orig_row = puntos_indexed.loc[orig_id]
    dest_row = puntos_indexed.loc[dest_id]

    return {
        "status":             "success",
        "origen_encontrado":  {"lat": float(orig_row["Latitud"]), "lng": float(orig_row["Longitud"])},
        "destino_encontrado": {"lat": float(dest_row["Latitud"]), "lng": float(dest_row["Longitud"])},
        "ruta_optima":        ruta_optima,
        "rutas_alternativas": rutas_alternativas,
        "total_rutas":        len(all_routes),
    }

# ── Endpoint: calcular ruta directa ──────────────────────────────────────────

@router.post("/calculate_direct")
async def calculate_direct_route(req: RouteRequest):
    if G is None:
        init_graph()
    if G is None:
        raise HTTPException(500, "El sistema de rutas no está inicializado.")

    orig_id, _ = nearest_point(req.origen_lat, req.origen_lng)
    dest_id, _ = nearest_point(req.destino_lat, req.destino_lng)

    if orig_id is None or dest_id is None:
        raise HTTPException(404, "No se encontraron puntos cercanos.")
    
    candidates = []

    for id_lr in ruta_to_linea.keys():
        pr = lineas_puntos_df[lineas_puntos_df["IdLineaRuta"] == id_lr].sort_values("Orden")
        
        pts = []
        for _, row in pr.iterrows():
            pid = int(row["IdPunto"])
            if pid in puntos_indexed.index:
                pts.append((pid,
                            float(puntos_indexed.loc[pid, "Latitud"]),
                            float(puntos_indexed.loc[pid, "Longitud"])))
        
        if len(pts) < 2:
            continue

        best_cost = float('inf')
        best_o = -1
        best_d = -1
        
        for i in range(len(pts)):
            d_o = haversine_m(req.origen_lat, req.origen_lng, pts[i][1], pts[i][2])
            for j in range(i + 1, len(pts)):
                d_d = haversine_m(req.destino_lat, req.destino_lng, pts[j][1], pts[j][2])
                cost = d_o + d_d
                if cost < best_cost:
                    best_cost = cost
                    best_o = i
                    best_d = j
                    
        if best_o != -1 and best_d != -1:
            real_path = [(pts[k][0], id_lr) for k in range(best_o, best_d + 1)]
            try:
                rdata = build_route(real_path,
                                    req.origen_lat, req.origen_lng,
                                    req.destino_lat, req.destino_lng)
                
                # Use walk distances to evaluate "best" since we want to minimize walking
                total_walk = rdata["distancia_caminata_origen_m"] + rdata["distancia_caminata_destino_m"]
                candidates.append((total_walk, rdata))
            except Exception:
                continue

    if not candidates:
        raise HTTPException(404, "No se encontró una ruta directa entre estos puntos.")

    # Sort candidates by total walk distance (ascending)
    candidates.sort(key=lambda x: x[0])
    
    all_routes = [c[1] for c in candidates]
    
    # Remove duplicates based on lineas_usadas
    seen_combos = set()
    unique_routes = []
    for r in all_routes:
        combo = tuple(r["lineas_usadas"])
        if combo not in seen_combos:
            seen_combos.add(combo)
            unique_routes.append(r)
            
    if not unique_routes:
        raise HTTPException(404, "No se encontró una ruta directa válida.")

    ruta_optima = unique_routes[0]
    rutas_alternativas = unique_routes[1:6]

    orig_row = puntos_indexed.loc[orig_id]
    dest_row = puntos_indexed.loc[dest_id]

    return {
        "status":             "success",
        "origen_encontrado":  {"lat": float(orig_row["Latitud"]), "lng": float(orig_row["Longitud"])},
        "destino_encontrado": {"lat": float(dest_row["Latitud"]), "lng": float(dest_row["Longitud"])},
        "ruta_optima":        ruta_optima,
        "rutas_alternativas": rutas_alternativas,
        "total_rutas":        len(unique_routes),
    }


# ── Endpoint: líneas disponibles (Micros Disponibles) ─────────────────────────

@router.get("/lineas")
async def get_all_lineas():
    if G is None:
        init_graph()
    if lineas_df is None:
        raise HTTPException(500, "Datos no cargados.")

    result = []
    for _, linea in lineas_df.iterrows():
        id_linea = int(linea["IdLinea"])
        nombre   = str(linea["NombreLinea"]).strip()
        color    = str(linea["ColorLinea"]).strip()

        rutas_de_linea = linea_ruta_df[linea_ruta_df["IdLinea"] == id_linea]
        sub_rutas = []
        total_dist = 0.0

        for _, ruta in rutas_de_linea.iterrows():
            id_lr      = int(ruta["IdLineaRuta"])
            desc       = str(ruta.get("Descripcion", "")).strip()
            dist_ruta  = float(ruta.get("Distancia", 0) or 0)
            total_dist += dist_ruta
            sentido    = "ida" if "Salida" in desc else "vuelta"

            # Puntos de la ruta en orden
            puntos_ruta = (
                lineas_puntos_df[lineas_puntos_df["IdLineaRuta"] == id_lr]
                .sort_values("Orden")
            )

            coords = []
            for _, pr in puntos_ruta.iterrows():
                pid = int(pr["IdPunto"])
                if pid in puntos_indexed.index:
                    coords.append({
                        "lat": float(puntos_indexed.loc[pid, "Latitud"]),
                        "lng": float(puntos_indexed.loc[pid, "Longitud"]),
                    })

            # Añadir el último destino si no es 0
            if not puntos_ruta.empty:
                last_dest_raw = puntos_ruta.iloc[-1]["IdPuntoDest"]
                if not pd.isna(last_dest_raw):
                    last_dest = int(last_dest_raw)
                    if last_dest != 0 and last_dest in puntos_indexed.index:
                        coords.append({
                            "lat": float(puntos_indexed.loc[last_dest, "Latitud"]),
                            "lng": float(puntos_indexed.loc[last_dest, "Longitud"]),
                        })

            sub_rutas.append({
                "id_linea_ruta": id_lr,
                "descripcion":   desc,
                "sentido":       sentido,
                "distancia_km":  dist_ruta,
                "coordenadas":   coords,
            })

        result.append({
            "id_linea":          id_linea,
            "nombre":            nombre,
            "color":             color,
            "distancia_total_km": round(total_dist, 2),
            "rutas":             sub_rutas,
        })

    return {"lineas": result}
