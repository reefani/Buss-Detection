from fastapi import FastAPI, UploadFile, File
import cv2
import numpy as np

from pipeline import process_frame

app = FastAPI()


@app.post("/api/v1/detect")
async def detect_bus(image: UploadFile = File(...)):
    try:
        # Read JPEG bytes received from Flutter
        image_bytes = await image.read()

        # Decode JPEG bytes into an OpenCV image
        np_array = np.frombuffer(image_bytes, np.uint8)
        frame = cv2.imdecode(np_array, cv2.IMREAD_COLOR)

        if frame is None:
            print("Invalid image received")
            return {
                "detected": False,
                "route_number": "",
                "confidence": 0.0,
                "bus_in_guidance_zone": False,
            }

        print(
            f"Received frame: {frame.shape[1]}x{frame.shape[0]}"
        )

        # Run the real YOLO + OCR pipeline
        result = process_frame(frame)

        if result.route_number is not None:
            return {
                "detected": True,
                "route_number": result.route_number,
                "confidence": 0.0,
                "bus_in_guidance_zone": result.bus_in_guidance_zone,
            }

        return {
            "detected": False,
            "route_number": "",
            "confidence": 0.0,
            "bus_in_guidance_zone": result.bus_in_guidance_zone,
        }

    except Exception as e:
        print(f"API processing error: {e}")

        return {
            "detected": False,
            "route_number": "",
            "confidence": 0.0,
            "bus_in_guidance_zone": False,
        }
