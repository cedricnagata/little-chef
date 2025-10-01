"""
Configuration settings for LittleChef backend
"""

import os
from typing import Optional
from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    """Application settings loaded from environment variables"""
    
    # App Configuration
    app_name: str = "LittleChef API"
    version: str = "0.1.0"
    debug: bool = True
    environment: str = "development"
    
    # Security Configuration
    max_content_length: int = 10 * 1024 * 1024  # 10MB max request size
    
    # Database Configuration
    database_type: str = "postgresql"  # Options: "postgresql" or "sqlite"
    database_url: str = ""  # PostgreSQL connection string
    sqlite_db_path: str = "sqlite:///./littlechef.db"  # SQLite database path
    
    # OpenAI Configuration
    openai_api_key: str = ""  # Will be required when using LLM features
    
    # ElevenLabs Configuration
    elevenlabs_api_key: str = ""  # For text-to-speech synthesis
    elevenlabs_api_url: str = "https://api.elevenlabs.io/v1"  # ElevenLabs API base URL
    
    # Firecrawl Configuration
    firecrawl_api_key: str = ""  # For web scraping
    firecrawl_api_url: str = "https://api.firecrawl.dev/v2/scrape"  # Firecrawl API endpoint
    
    # JWT Configuration  
    jwt_secret_key: str  # Must be set in environment
    jwt_algorithm: str = "HS256"
    jwt_access_token_expire_minutes: int = 30
    jwt_refresh_token_expire_days: int = 7
    
    # CORS Configuration
    allowed_origins: str = "http://localhost:3000"
    
    class Config:
        env_file = ".env"
        env_file_encoding = "utf-8"
    
    def get_database_url(self) -> str:
        """Get the appropriate database URL based on database_type"""
        if self.database_type == "sqlite":
            return self.sqlite_db_path
        elif self.database_type == "postgresql":
            if not self.database_url:
                raise ValueError("DATABASE_URL is required when using PostgreSQL")
            return self.database_url
        else:
            raise ValueError(f"Invalid database_type: {self.database_type}. Must be 'sqlite' or 'postgresql'")
    
    def __post_init__(self):
        """Validate critical settings after initialization"""
        # Validate database configuration
        if self.database_type not in ["sqlite", "postgresql"]:
            raise ValueError("DATABASE_TYPE must be 'sqlite' or 'postgresql'")
        
        if self.database_type == "postgresql" and not self.database_url:
            raise ValueError("DATABASE_URL environment variable is required when using PostgreSQL")
        
        if not self.jwt_secret_key:
            raise ValueError("JWT_SECRET_KEY environment variable is required")
        
        # Security: Validate JWT secret length
        if len(self.jwt_secret_key) < 32:
            raise ValueError("JWT_SECRET_KEY must be at least 32 characters long")
        
        # Security: Warn about debug mode in production
        if self.environment == "production" and self.debug:
            raise ValueError("DEBUG must be False in production environment")
        
    @property
    def allowed_origins_list(self) -> list[str]:
        """Convert comma-separated origins to list"""
        if self.allowed_origins == "*":
            return ["*"]
        return [origin.strip() for origin in self.allowed_origins.split(",")]


# Global settings instance
settings = Settings()
