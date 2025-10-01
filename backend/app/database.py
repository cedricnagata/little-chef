"""
Database connection and session management
"""

from sqlalchemy import create_engine, event
from sqlalchemy.ext.declarative import declarative_base
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool
import os

from app.config import settings


def create_database_engine():
    """
    Create and configure database engine based on database_type setting.
    
    For PostgreSQL:
        - Uses connection pooling with pre-ping and recycling
        - Optimized for production use
    
    For SQLite:
        - Enables foreign key constraints
        - Uses check_same_thread=False for FastAPI compatibility
        - Uses StaticPool for in-memory databases
    """
    database_url = settings.get_database_url()
    
    if settings.database_type == "sqlite":
        # SQLite-specific configuration
        engine = create_engine(
            database_url,
            echo=False,
            connect_args={"check_same_thread": False},  # Required for FastAPI
            poolclass=StaticPool,  # Use StaticPool for SQLite
        )
        
        # Enable foreign key constraints for SQLite
        @event.listens_for(engine, "connect")
        def set_sqlite_pragma(dbapi_conn, connection_record):
            cursor = dbapi_conn.cursor()
            cursor.execute("PRAGMA foreign_keys=ON")
            cursor.close()
        
        return engine
    
    elif settings.database_type == "postgresql":
        # PostgreSQL-specific configuration
        return create_engine(
            database_url,
            echo=False,  # Disable SQLAlchemy SQL logging
            pool_pre_ping=True,  # Enables pessimistic disconnect handling
            pool_recycle=300,    # Recycle connections every 5 minutes
            echo_pool=False,  # Disable connection pool logging
        )
    
    else:
        raise ValueError(f"Unsupported database type: {settings.database_type}")


# Create database engine
engine = create_database_engine()

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
