from fastapi import FastAPI
from routers import routes, units, routing
from fastapi.middleware.cors import CORSMiddleware
import os
from dotenv import load_dotenv

load_dotenv()

app = FastAPI(title="SIG-Microbuses API", version="1.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(routes.router, prefix="/api/routes", tags=["Routes"])
app.include_router(units.router, prefix="/api/units", tags=["Units"])
app.include_router(routing.router, prefix="/api/routing", tags=["Routing"])

@app.get("/")
async def root():
    return {"message": "Welcome to SIG-Microbuses API"}

if __name__ == "__main__":
    import uvicorn
    uvicorn.run("main:app", host="0.0.0.0", port=8000, reload=True)
