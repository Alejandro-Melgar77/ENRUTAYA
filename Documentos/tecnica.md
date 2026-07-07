# Documentación Técnica: EN RUTA YA!

Este documento describe la arquitectura, diseño de base de datos, casos de uso y flujos principales del sistema EN RUTA YA!.

## 1. Diagrama de Arquitectura

El sistema está compuesto por una aplicación cliente (móvil/web) que interactúa con servicios de backend en Supabase y mapas base.

```mermaid
graph TD
    subgraph Cliente ["Cliente (Pasajero / Operador)"]
        A[Aplicación Web/Móvil]
        B[Geolocalización GPS]
    end

    subgraph Backend ["Supabase (PostgreSQL / Auth / Realtime)"]
        C[API REST / GraphQL]
        D[(Base de Datos PostgreSQL)]
        E[Autenticación]
        F[Canales Realtime]
    end

    subgraph Servicios Externos
        G[Mapas (Mapbox / OSM)]
    end

    A -->|Autenticación y Consultas| C
    A -->|Login| E
    B -->|Envío de Coordenadas| C
    A <-->|Suscripción GPS y ETA| F
    C --> D
    E --> D
    F --> D
    A -->|Carga de Mapas| G
```

## 2. Diagrama de Entidad-Relación (ERD)

El modelo de datos gestionado en Supabase (PostgreSQL) centraliza la información de las rutas (líneas), los vehículos (unidades) y su seguimiento en tiempo real.

```mermaid
erDiagram
    LINEAS ||--o{ UNIDADES : "posee"
    UNIDADES ||--o{ POSICIONES_ACTUALES : "registra"

    LINEAS {
        uuid id PK
        string nombre
        string descripcion
        geometry ruta_coordenadas
        timestamp created_at
    }

    UNIDADES {
        uuid id PK
        uuid linea_id FK
        string matricula
        string numero_economico
        uuid operador_id
        string estado
        timestamp created_at
    }

    POSICIONES_ACTUALES {
        uuid id PK
        uuid unidad_id FK
        float latitud
        float longitud
        float velocidad
        timestamp timestamp_gps
        timestamp created_at
    }
```

## 3. Diagrama de Casos de Uso

Los principales actores del sistema son el Pasajero (usuario final) y el Operador (conductor del microbús).

```mermaid
flowchart LR
    Pasajero([Pasajero])
    Operador([Operador])

    subgraph Sistema EN RUTA YA!
        UC1(Visualizar rutas y paradas)
        UC2(Ver ubicación en tiempo real)
        UC3(Consultar Tiempo Estimado de Llegada - ETA)
        UC4(Iniciar sesión)
        UC5(Transmitir ubicación GPS)
        UC6(Finalizar viaje/ruta)
    end

    Pasajero --> UC1
    Pasajero --> UC2
    Pasajero --> UC3

    Operador --> UC4
    Operador --> UC5
    Operador --> UC6
```

## 4. Diagramas de Secuencia

### 4.a Login de Operador y envío de GPS

Este flujo describe cómo un operador inicia sesión y la aplicación comienza a transmitir sus coordenadas hacia Supabase.

```mermaid
sequenceDiagram
    participant O as Operador
    participant App as Aplicación (App)
    participant Auth as Supabase Auth
    participant DB as Supabase DB (Posiciones)

    O->>App: Ingresa credenciales
    App->>Auth: Solicita inicio de sesión
    Auth-->>App: Retorna Token JWT (Éxito)
    O->>App: Inicia ruta
    loop Envío Periódico (ej. cada 5 seg)
        App->>App: Obtiene coordenadas GPS
        App->>DB: Inserta/Actualiza en posiciones_actuales
        DB-->>App: Confirma actualización
    end
    O->>App: Finaliza ruta
    App->>DB: Actualiza estado de unidad
```

### 4.b Pasajero visualizando rutas y ETA

Este flujo muestra cómo el pasajero obtiene la información de las unidades y se suscribe a sus actualizaciones en tiempo real.

```mermaid
sequenceDiagram
    participant P as Pasajero
    participant App as Aplicación (App)
    participant DB as Supabase DB (Líneas/Unidades)
    participant RT as Supabase Realtime (Posiciones)

    P->>App: Abre la aplicación
    App->>DB: Consulta líneas y rutas
    DB-->>App: Retorna datos de líneas
    P->>App: Selecciona una línea
    App->>DB: Consulta unidades activas de la línea
    DB-->>App: Retorna unidades
    App->>RT: Suscribe a cambios en posiciones_actuales (unidad_id)
    loop Eventos Realtime
        RT-->>App: Push de nuevas coordenadas GPS
        App->>App: Actualiza marcador en el mapa
        App->>App: Recalcula ETA
    end
```
