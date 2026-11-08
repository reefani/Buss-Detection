import re
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

def process_frame(frame):
    global capture_id
    if frame is None or frame.size == 0:
        return None
    

    yolo_result = model(frame, verbose=False)[0]
    print(f"[YOLO] Total detections: {len(yolo_result.boxes)}", flush=True)
    for debug_box in yolo_result.boxes:
        print(f"[YOLO] class={int(debug_box.cls[0])}, confidence={float(debug_box.conf[0]):.3f}, bbox={debug_box.xyxy[0].tolist()}", flush=True)
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
        print(f"[ROI FAILED] buses={len(bus_front)}, panels={len(bus_numbers)}; no accepted panel inside a bus", flush=True)
        return None

    # Execute OCR
    try:
        results = ocr.predict(roi)
        print(f"[OCR] Raw prediction results: {results}", flush=True)
        extracted_numbers = []
        print("OCR executed")



        if results:
            for res in results:
                if isinstance(res, dict):
                    rec_texts = res.get("rec_texts", [])
                    rec_scores = res.get("rec_scores", [])
                    print(f"[OCR] rec_texts={rec_texts}, rec_scores={rec_scores}", flush=True)
                    for text, score in zip(rec_texts, rec_scores):
                        # Extract STRICTLY numerical digits (0-9)
                        digits_only = re.sub(r"[^\d]", "", text).strip()
                        print(f"[OCR] raw={text!r}, score={score}, digits={digits_only!r}, accepted={bool(digits_only and score > 0.35 and 1 <= len(digits_only) <= 3)}", flush=True)

                        # Validate digit sequence length (1 to 3 digits long)
                        if (
                            digits_only
                            and score > 0.35
                            and 1 <= len(digits_only) <= 3
                        ):
                            extracted_numbers.append(digits_only)

        if extracted_numbers:
            print(f"[OCR] Accepted candidates: {extracted_numbers}", flush=True)
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
            return route_number

        print("[OCR FAILED] No accepted route number", flush=True)
        return None

    except Exception as e:
        print(f"Error during OCR execution: {e}")
        return None
