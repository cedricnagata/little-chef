"""
LittleChef Backend API
A FastAPI-based backend for the LittleChef cooking assistant app.
"""

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.middleware.trustedhost import TrustedHostMiddleware

from app.config import settings

# Create FastAPI app instance
app = FastAPI(
    title=settings.app_name,
    description="Backend API for LittleChef cooking assistant",
    version=settings.version,
    docs_url="/docs" if settings.debug else None,  # Disable docs in production
    redoc_url="/redoc" if settings.debug else None,  # Disable redoc in production
)

# Security: Add trusted host middleware
app.add_middleware(
    TrustedHostMiddleware, 
    allowed_hosts=["localhost", "127.0.0.1", "*.littlechef.com"] if settings.environment == "production" else ["*"]
)

# Configure CORS for iOS app communication
app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.allowed_origins_list,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Include routers
from app.routers import auth, users, recipes

app.include_router(auth.router)
app.include_router(users.router)
app.include_router(recipes.router)

# Basic health check endpoint
@app.get("/")
async def root():
    """Root endpoint - basic health check"""
    return {
        "message": "LittleChef API is running!",
        "version": settings.version,
        "status": "healthy"
    }

@app.get("/health")
async def health_check():
    """Health check endpoint for monitoring"""
    return {
        "status": "healthy",
        "service": "littlechef-api"
    }

# Run the app
if __name__ == "__main__":
    import uvicorn
    # Only bind to localhost for development security
    uvicorn.run("main:app", host="127.0.0.1", port=8000, reload=settings.debug)
