from pydantic import BaseModel
from typing import Optional

class Location(BaseModel):
    lat: float
    lng: float

class UnitLogin(BaseModel):
    placa: str
    conductor: Optional[str] = None

class UnitPositionUpdate(BaseModel):
    lat: float
    lng: float
    velocidad: Optional[float] = 0.0

class ETARequest(BaseModel):
    user_lat: float
    user_lng: float
    linea_id: int
