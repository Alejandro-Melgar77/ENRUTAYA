from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import text
from models.schemas import UnitLogin, UnitPositionUpdate
from database import get_db

router = APIRouter()

@router.post("/login")
async def unit_login(login_data: UnitLogin, db: AsyncSession = Depends(get_db)):
    query = text("""
        SELECT id, placa, linea_id FROM unidades WHERE placa = :placa
    """)
    result = await db.execute(query, {"placa": login_data.placa})
    row = result.fetchone()
    
    if not row:
        raise HTTPException(status_code=401, detail="Unidad no registrada")
        
    return {
        "status": "success",
        "unidad_id": row.id,
        "placa": row.placa,
        "linea_id": row.linea_id,
        "message": "Unidad autenticada correctamente"
    }

@router.post("/{unidad_id}/position")
async def update_position(unidad_id: int, position: UnitPositionUpdate, db: AsyncSession = Depends(get_db)):
    query_check = text("SELECT id FROM posiciones_actuales WHERE unidad_id = :unidad_id")
    result = await db.execute(query_check, {"unidad_id": unidad_id})
    row = result.fetchone()
    
    if row:
        query_update = text("""
            UPDATE posiciones_actuales 
            SET ubicacion = ST_SetSRID(ST_MakePoint(:lng, :lat), 4326),
                velocidad = :velocidad,
                timestamp = CURRENT_TIMESTAMP
            WHERE unidad_id = :unidad_id
        """)
        await db.execute(query_update, {"lng": position.lng, "lat": position.lat, "velocidad": position.velocidad, "unidad_id": unidad_id})
    else:
        query_insert = text("""
            INSERT INTO posiciones_actuales (unidad_id, ubicacion, velocidad)
            VALUES (:unidad_id, ST_SetSRID(ST_MakePoint(:lng, :lat), 4326), :velocidad)
        """)
        try:
            await db.execute(query_insert, {"lng": position.lng, "lat": position.lat, "velocidad": position.velocidad, "unidad_id": unidad_id})
        except Exception as e:
            await db.rollback()
            raise HTTPException(status_code=400, detail=str(e))
            
    await db.commit()
    
    return {
        "status": "success",
        "unidad_id": unidad_id,
        "message": "Posición actualizada"
    }
