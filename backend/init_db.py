import asyncio
import asyncpg
import os

DATABASE_URL = "postgresql://postgres:ENRRUTAYA%2177@db.rtwtdqytjmeoibbtrbqi.supabase.co:5432/postgres"
# Convert to asyncpg format
ASYNC_DB_URL = DATABASE_URL

async def init_db():
    print("Conectando a la base de datos Supabase...")
    conn = await asyncpg.connect(ASYNC_DB_URL)
    
    print("Habilitando extensión PostGIS...")
    await conn.execute('CREATE EXTENSION IF NOT EXISTS postgis;')

    print("Creando tabla: lineas")
    await conn.execute('''
        CREATE TABLE IF NOT EXISTS lineas (
            id SERIAL PRIMARY KEY,
            nombre VARCHAR(100) NOT NULL,
            ruta GEOMETRY(LineString, 4326)
        );
    ''')

    print("Creando tabla: unidades")
    await conn.execute('''
        CREATE TABLE IF NOT EXISTS unidades (
            id SERIAL PRIMARY KEY,
            placa VARCHAR(20) UNIQUE NOT NULL,
            linea_id INTEGER REFERENCES lineas(id) ON DELETE CASCADE
        );
    ''')

    print("Creando tabla: posiciones_actuales")
    await conn.execute('''
        CREATE TABLE IF NOT EXISTS posiciones_actuales (
            id SERIAL PRIMARY KEY,
            unidad_id INTEGER UNIQUE REFERENCES unidades(id) ON DELETE CASCADE,
            ubicacion GEOMETRY(Point, 4326),
            velocidad FLOAT DEFAULT 0.0,
            timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );
    ''')

    # Insert some dummy data for testing
    print("Insertando datos de prueba...")
    await conn.execute('''
        INSERT INTO lineas (nombre, ruta) 
        VALUES (
            'Línea 17', 
            ST_GeomFromText('LINESTRING(-63.1812 -17.7833, -63.1780 -17.7850, -63.1750 -17.7880)', 4326)
        ) ON CONFLICT DO NOTHING;
    ''')
    
    # We can't easily DO NOTHING without a constraint on nombre, so let's just ignore errors for dummy data
    try:
        await conn.execute('''
            INSERT INTO unidades (placa, linea_id) VALUES ('ABC-123', 1) ON CONFLICT (placa) DO NOTHING;
            INSERT INTO unidades (placa, linea_id) VALUES ('XYZ-987', 1) ON CONFLICT (placa) DO NOTHING;
        ''')
    except Exception as e:
        print(f"Nota: datos de unidades podrían ya existir ({e})")

    print("Base de datos inicializada correctamente.")
    await conn.close()

if __name__ == "__main__":
    asyncio.run(init_db())
