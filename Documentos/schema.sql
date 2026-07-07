-- Enable PostGIS if not already enabled
CREATE EXTENSION IF NOT EXISTS postgis;

-- Tabla para almacenar las líneas de microbuses y sus rutas
CREATE TABLE IF NOT EXISTS lineas (
    id SERIAL PRIMARY KEY,
    nombre VARCHAR(100) NOT NULL,
    ruta GEOMETRY(LineString, 4326) NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Tabla para las unidades (microbuses)
CREATE TABLE IF NOT EXISTS unidades (
    id SERIAL PRIMARY KEY,
    linea_id INTEGER REFERENCES lineas(id) ON DELETE CASCADE,
    placa VARCHAR(20) UNIQUE NOT NULL,
    conductor VARCHAR(100),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Tabla para las posiciones actuales de las unidades
CREATE TABLE IF NOT EXISTS posiciones_actuales (
    id SERIAL PRIMARY KEY,
    unidad_id INTEGER REFERENCES unidades(id) ON DELETE CASCADE,
    ubicacion GEOMETRY(Point, 4326) NOT NULL,
    velocidad FLOAT DEFAULT 0.0,
    timestamp TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Índices espaciales
CREATE INDEX IF NOT EXISTS idx_lineas_ruta ON lineas USING GIST (ruta);
CREATE INDEX IF NOT EXISTS idx_posiciones_ubicacion ON posiciones_actuales USING GIST (ubicacion);

-- RLS Policies (Row Level Security) - Basic examples
ALTER TABLE lineas ENABLE ROW LEVEL SECURITY;
ALTER TABLE unidades ENABLE ROW LEVEL SECURITY;
ALTER TABLE posiciones_actuales ENABLE ROW LEVEL SECURITY;

-- Permitir lectura pública de las líneas
CREATE POLICY "Lineas public read" ON lineas FOR SELECT USING (true);

-- Permitir lectura pública de las unidades
CREATE POLICY "Unidades public read" ON unidades FOR SELECT USING (true);

-- Permitir lectura pública de las posiciones
CREATE POLICY "Posiciones public read" ON posiciones_actuales FOR SELECT USING (true);

-- Podríamos requerir auth para inserciones, pero se deja simplificado por ahora.
CREATE POLICY "Posiciones public insert" ON posiciones_actuales FOR INSERT WITH CHECK (true);
CREATE POLICY "Posiciones public update" ON posiciones_actuales FOR UPDATE USING (true);

-- Actualización automática del timestamp en posiciones
CREATE OR REPLACE FUNCTION update_posiciones_timestamp()
RETURNS TRIGGER AS $$
BEGIN
    NEW.timestamp = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER update_posiciones_timestamp_trigger
BEFORE UPDATE ON posiciones_actuales
FOR EACH ROW
EXECUTE FUNCTION update_posiciones_timestamp();
