import re
from dataclasses import dataclass
import cv2
import numpy as np
import torch
from paddleocr import PaddleOCR
from ultralytics import YOLO

from pathlib import Path


    
# Initialize YOLO model
BASE_DIR = Path(__file__).resolve().parent
DEBUG_SAVE = False
DEBUG_DIR = BASE_DIR / "debug_captures"
if DEBUG_SAVE:
    DEBUG_DIR.mkdir(exist_ok=True)

capture_id = 0
model = YOLO(BASE_DIR / "best.pt")

# Fractions of the frame covered by the centered camera guidance zone.
# Tune the two dimensions independently without changing detection settings.
GUIDANCE_ZONE_WIDTH_FRACTION = 0.60
GUIDANCE_ZONE_HEIGHT_FRACTION = 0.60


@dataclass(frozen=True)
class FrameDetectionResult:
    route_number: str | None = None
    bus_in_guidance_zone: bool = False

# Initialize PaddleOCR
ocr = PaddleOCR(
    use_angle_cls=False,
    use_doc_orientation_classify=False,
    use_doc_unwarping=False,
    enable_mkldnn=False,
    lang="en",
)




def extract_roi(
    image: np.ndarray, bbox: list, padding_percent: float = 0.02
) -> np.ndarray:
    if image is None or image.size == 0:
        return None
    h, w, _ = image.shape
    x1, y1, x2, y2 = map(int, bbox)
    pad_w = int((x2 - x1) * padding_percent)
    pad_h = int((y2 - y1) * padding_percent)
    x1_crop, y1_crop = max(0, x1 - pad_w), max(0, y1 - pad_h)
    x2_crop, y2_crop = min(w, x2 + pad_w), min(h, y2 + pad_h)
    return image[y1_crop:y2_crop, x1_crop:x2_crop]
print("roi detected")


# Check if panel box is STRICTLY inside the bus box
def is_inside(inner_box, outer_box, threshold=0.8):
    ix1, iy1, ix2, iy2 = inner_box
    ox1, oy1, ox2, oy2 = outer_box

    # Calculate intersection area
    inter_x1 = max(ix1, ox1)
    inter_y1 = max(iy1, oy1)
    inter_x2 = min(ix2, ox2)
    inter_y2 = min(iy2, oy2)

    if inter_x2 <= inter_x1 or inter_y2 <= inter_y1:
        return False

    inter_area = (inter_x2 - inter_x1) * (inter_y2 - inter_y1)
    inner_area = (ix2 - ix1) * (iy2 - iy1)

    return (inter_area / float(inner_area)) >= threshold
print("Panel is inside bus")

def bus_center_in_guidance_zone(
    bus_box,
    frame_shape,
    width_fraction=GUIDANCE_ZONE_WIDTH_FRACTION,
    height_fraction=GUIDANCE_ZONE_HEIGHT_FRACTION,
):
    """Check the bus center against the centered zone, including its edges."""
    if not 0 < width_fraction <= 1 or not 0 < height_fraction <= 1:
        raise ValueError("Guidance zone fractions must be greater than 0 and at most 1")

    height, width = frame_shape[:2]
    x1, y1, x2, y2 = bus_box
    center_x = (x1 + x2) / 2
    center_y = (y1 + y2) / 2
    margin_x = width * (1 - width_fraction) / 2
    margin_y = height * (1 - height_fraction) / 2
    return (
        margin_x <= center_x <= width - margin_x
        and margin_y <= center_y <= height - margin_y
    )


def process_frame(
    frame,
    guidance_zone_width=GUIDANCE_ZONE_WIDTH_FRACTION,
    guidance_zone_height=GUIDANCE_ZONE_HEIGHT_FRACTION,
):
    global capture_id
    if frame is None or frame.size == 0:
        return FrameDetectionResult()
    

    yolo_result = model(frame, verbose=False)[0]
    bus_front = []
    bus_numbers = []

    for box in yolo_result.boxes:
        class_id = int(box.cls[0])
        coords = tuple(map(int, box.xyxy[0]))
        if class_id == 0:  # Bus
            bus_front.append(coords)
            print("bus front detected")
        elif class_id == 1:  # Panel
            bus_numbers.append(coords)
            print("bus panel detected")

    bus_in_guidance_zone = any(
        bus_center_in_guidance_zone(
            bus_box, frame.shape, guidance_zone_width, guidance_zone_height
        )
        for bus_box in bus_front
    )
    guidance_result = FrameDetectionResult(
        bus_in_guidance_zone=bus_in_guidance_zone
    )

    roi = None

    # ONLY accept panels that are physically inside a detected bus
    for bus_box in bus_front:
        for panel_box in bus_numbers:
            if is_inside(panel_box, bus_box):
                print("Panel is inside bus")
                roi = extract_roi(frame, panel_box)
                capture_id += 1
                if DEBUG_SAVE:
                    cv2.imwrite(str(DEBUG_DIR / f"frame_{capture_id:04d}.jpg"), frame)
                    cv2.imwrite(str(DEBUG_DIR / f"roi_{capture_id:04d}.jpg"), roi)
                print("ROI extracted")
                break
        if roi is not None:
            break

    if roi is None:
        return guidance_result

    # Execute OCR
    try:
        results = ocr.predict(roi)
        extracted_numbers = []
        print("OCR executed")



        if results:
            for res in results:
                if isinstance(res, dict):
                    rec_texts = res.get("rec_texts", [])
                    rec_scores = res.get("rec_scores", [])
                    for text, score in zip(rec_texts, rec_scores):
                        # Extract STRICTLY numerical digits (0-9)
                        digits_only = re.sub(r"[^\d]", "", text).strip()

                        # Validate digit sequence length (1 to 4 digits long)
                        if (
                            digits_only
                            and score > 0.35
                            and 1 <= len(digits_only) <= 4
                        ):
                            extracted_numbers.append(digits_only)

        if extracted_numbers:
            route_number = extracted_numbers[0]  # Grab primary number match
            print(f"SUCCESS -> Recognized Route Number: {route_number}")
                    
            if DEBUG_SAVE:
                result_file = DEBUG_DIR / f"result_{capture_id:04d}.txt"
                result_file.write_text(
                    f"Capture ID: {capture_id:04d}\n"
                    f"OCR Text: {rec_texts}\n"
                    f"Recognized Route: {route_number}\n",
                    encoding="utf-8",
                )
            return FrameDetectionResult(
                route_number=route_number,
                bus_in_guidance_zone=bus_in_guidance_zone,
            )

        return guidance_result

    except Exception as e:
        print(f"Error during OCR execution: {e}")
        return guidance_result
