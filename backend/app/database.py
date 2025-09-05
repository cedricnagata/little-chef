"""
Database connection and session management
"""

from sqlalchemy import create_engine
from sqlalchemy.ext.declarative import declarative_base
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool
import os

from app.config import settings

# Create database engine
# Use PostgreSQL for development and production
engine = create_engine(
    settings.database_url,
    echo=settings.debug,
    pool_pre_ping=True,  # Enables pessimistic disconnect handling
    pool_recycle=300,    # Recycle connections every 5 minutes
    # Security: Disable SQL statement logging in production
    echo_pool=False if settings.environment == "production" else settings.debug,
)

# Create SessionLocal class
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)

# Create Base class for models
Base = declarative_base()


def get_db():
    """
    Dependency to get database session
    """
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


def create_tables():
    """
    Create all tables (for development/testing)
    In production, use Alembic migrations
    """
    Base.metadata.create_all(bind=engine)
