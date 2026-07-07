from sqlalchemy.ext.asyncio import create_async_engine, AsyncSession
from sqlalchemy.orm import sessionmaker
import os
from dotenv import load_dotenv

load_dotenv()

# We expect DATABASE_URL to be set in .env or environment
DATABASE_URL = os.getenv("DATABASE_URL", "postgresql+asyncpg://postgres:ENRRUTAYA%2177@db.rtwtdqytjmeoibbtrbqi.supabase.co:5432/postgres")

engine = create_async_engine(DATABASE_URL, echo=False)
SessionLocal = sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)

async def get_db():
    async with SessionLocal() as session:
        yield session
