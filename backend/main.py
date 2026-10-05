from fastapi import FastAPI
from pydantic import BaseModel
import base64
import cv2
import numpy as np

from pipeline import process_frame

app = FastAPI()

class FramePayload(BaseModel):
    image: str
    timestamp: int
# endpoint n
@app.post("/api/v1/detect")
async def detect_bus(payload: FramePayload):
    print(f"Received frame packet! Size: {len(payload.image)} chars")
    
    try:
        # Decode Base64 image received from Flutter
        image_bytes = base64.b64decode(payload.image)
        np_array = np.frombuffer(image_bytes, np.uint8)
        frame = cv2.imdecode(np_array, cv2.IMREAD_COLOR)

        if frame is None:
            return {
                "detected": False,
                "route_number": "",
                "confidence": 0.0
            }

        # Run the real YOLO + OCR pipeline
        route_number = process_frame(frame)

        if route_number is not None:
            return {
                "detected": True,
                "route_number": route_number,
                "confidence": 0.0
            }

        return {
            "detected": False,
            "route_number": "",
            "confidence": 0.0
        }

    except Exception as e:
        print(f"API processing error: {e}")
        return {
            "detected": False,
            "route_number": "",
            "confidence": 0.0
        }
    
      