from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import text
from models.schemas import ETARequest
from database import get_db

router = APIRouter()

@router.get("/lineas")
async def get_lineas(db: AsyncSession = Depends(get_db)):
    query = text("SELECT id, nombre, ST_AsGeoJSON(ruta) as ruta FROM lineas")
    result = await db.execute(query)
    lineas = []
    for row in result.fetchall():
        lineas.append({
            "id": row.id,
            "nombre": row.nombre,
            "ruta": row.ruta
        })
    return {"lineas": lineas}

@router.post("/eta")
async def calculate_eta(request: ETARequest, db: AsyncSession = Depends(get_db)):
    # Encuentra la unidad más cercana de la línea dada y calcula el ETA
    query = text("""
        SELECT u.id, u.placa, 
               ST_DistanceSphere(ST_SetSRID(ST_MakePoint(:lng, :lat), 4326), p.ubicacion) as dist_meters
        FROM posiciones_actuales p
        JOIN unidades u ON p.unidad_id = u.id
        WHERE u.linea_id = :linea_id
        ORDER BY dist_meters ASC
        LIMIT 1
    """)
    result = await db.execute(query, {"lng": request.user_lng, "lat": request.user_lat, "linea_id": request.linea_id})
    row = result.fetchone()
    
    if not row:
        raise HTTPException(status_code=404, detail="No hay unidades activas para esta línea.")
        
    dist = row.dist_meters
    # Asumiendo velocidad promedio de 250 metros por minuto (15 km/h) en tráfico
    eta_minutes = int(dist / 250.0)
    if eta_minutes == 0:
        eta_minutes = 1
        
    return {
        "linea_id": request.linea_id,
        "unidad_placa": row.placa,
        "eta_minutes": eta_minutes,
        "distancia_metros": round(dist, 2),
        "message": f"El microbús llegará en aproximadamente {eta_minutes} minutos."
    }
