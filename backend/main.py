from fastapi import FastAPI
from pydantic import BaseModel
import random

app = FastAPI()

class FramePayload(BaseModel):
    image: str
    timestamp: int

@app.post("/api/v1/detect")
async def detect_bus(payload: FramePayload):
    print(f"Received frame packet! Size: {len(payload.image)} chars")
    
    # Simulated response (will be replaced with YOLOv8 + PaddleOCR later)
    routes = ["410", "12", "7", "302"]
    detected = random.choice([True, False])
    
    return {
        "detected": detected,
        "route_number": random.choice(routes) if detected else "",
        "confidence": 0.92 if detected else 0.0
    }