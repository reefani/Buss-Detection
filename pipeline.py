<<<<<<< Updated upstream
from ultralytics import YOLO
model = YOLO("best.pt") 
print("Model loaded successfully!")


import numpy as np

def extract_roi(image: np.ndarray, bbox: list, padding_percent: float = 0.05) -> np.ndarray:
    """
    Crops and validates the bus-numbers panel from an image frame.

    :param image: Full frame numpy array (BGR)
    :param bbox: Bounding box [x1, y1, x2, y2]
    :param padding_percent: Margin expansion around the detected box
    :return: Cropped numpy array or None
    """
    if image is None or image.size == 0:
        return None

    h, w, _ = image.shape
    x1, y1, x2, y2 = map(int, bbox)

    # 1. Add expansion margin padding
    pad_w = int((x2 - x1) * padding_percent)
    pad_h = int((y2 - y1) * padding_percent)

    # 2. Boundary clamping
=======
import re
import cv2
import numpy as np

# Import Torch & Ultralytics first to prevent DLL crashing
import torch
from ultralytics import YOLO

# Import PaddleOCR
from paddleocr import PaddleOCR

# =========================
# Load models
# =========================
model = YOLO("best.pt")
print("Model loaded successfully!")

# Disable extra document preprocessing stages (Doc Ori, UVDoc) to prevent engine overhead
ocr = PaddleOCR(
    use_angle_cls=False,
    use_doc_orientation_classify=False,
    use_doc_unwarping=False,
    enable_mkldnn=False,
    lang="en",
)
print("OCR model loaded")


# =========================
# ROI function
# =========================
def extract_roi(
    image: np.ndarray, bbox: list, padding_percent: float = 0.05
) -> np.ndarray:
    if image is None or image.size == 0:
        return None
    h, w, _ = image.shape
    x1, y1, x2, y2 = map(int, bbox)
    pad_w = int((x2 - x1) * padding_percent)
    pad_h = int((y2 - y1) * padding_percent)
>>>>>>> Stashed changes
    x1_crop = max(0, x1 - pad_w)
    y1_crop = max(0, y1 - pad_h)
    x2_crop = min(w, x2 + pad_w)
    y2_crop = min(h, y2 + pad_h)
<<<<<<< Updated upstream

    # 3. Perform image array crop
    roi = image[y1_crop:y2_crop, x1_crop:x2_crop]

    # 4. Dimension validation
    if roi.size == 0 or roi.shape[0] == 0 or roi.shape[1] == 0:
        return None

    return roi


import cv2

import os # we use [os] to read the images in the folder (test_images)

image_folder = "test_images" # the folder that contains the images for testing

image_files = [
    file for file in os.listdir(image_folder)
    if file.lower().endswith((".jpg", ".jpeg", ".png", ".webp"))
]


for image_name in image_files: 

  image_path = os.path.join(image_folder, image_name) 
  image = cv2.imread(image_path) 

  roi = None 

  if image is None:
    print("Could not read image:", image_name)
    continue


  results = model(image)

  for result in results:
    bus_front = []
    bus_numbers = []

    for box in result.boxes:
      class_id = int (box.cls[0])
      confidence = float(box.conf[0])
      x1, y1, x2, y2 = map(int, box.xyxy[0])

      if class_id == 0:
        bus_front.append((x1, y1, x2, y2))
        print("Bus number detected!")

      elif class_id == 1:
        bus_numbers.append((x1, y1, x2, y2))

    for bx1, by1, bx2, by2 in bus_front:
      for px1, py1, px2, py2 in bus_numbers:

        if(px1 >= bx1 and
           py1 >= by1 and
           px2 <= bx2 and
           py2 <= by2):

          bbox = (px1, py1, px2, py2)
          roi = extract_roi(image, bbox)

          if roi is not None: # لو ينحذف التحقق هذا عادي لاني اوريدي كتبته تحت بس خليته لانه يطبع الكوردنيتس للترتيب بس وقت الرن 
            print("roi created successfully")

          print("panel coordinates:", (px1, py1, px2, py2))


  import matplotlib.pyplot as plt

  if roi is not None:

    plt.imshow(cv2.cvtColor(roi, cv2.COLOR_BGR2RGB))
    plt.axis("off")
    plt.show()

  else:
    print("No ROI found in this image.")
    continue




  from paddleocr import PaddleOCR
  ocr = PaddleOCR(lang="en")
  result = ocr.predict(roi)
  print(result[0]["rec_texts"])



# نهاية الـ Loop 
print("All images finished.")
=======
    roi = image[y1_crop:y2_crop, x1_crop:x2_crop]
    return roi if roi.size > 0 else None


# =========================
# Open phone camera
# =========================
cap = cv2.VideoCapture(2, cv2.CAP_DSHOW)

if not cap.isOpened():
    print("Camera could not be opened.")
    exit()

print("Camera opened successfully")
ocr_text = None

# =========================
# Processing Loop
# =========================
while ocr_text is None:
    ret, frame = cap.read()
    if not ret or frame is None:
        continue

    # Run YOLO detection
    yolo_result = model(frame, verbose=False)[0]
    bus_front = []
    bus_numbers = []

    for box in yolo_result.boxes:
        class_id = int(box.cls[0])
        coords = tuple(map(int, box.xyxy[0]))

        if class_id == 0:
            bus_front.append(coords)
        elif class_id == 1:
            bus_numbers.append(coords)

    # Find ROI (Prefer panel inside front box, fallback to panel directly)
    roi = None
    for bx1, by1, bx2, by2 in bus_front:
        for px1, py1, px2, py2 in bus_numbers:
            if px1 >= bx1 and py1 >= by1 and px2 <= bx2 and py2 <= by2:
                roi = extract_roi(frame, (px1, py1, px2, py2))
                break
        if roi is not None:
            break

    # Fallback: If no front box matched, crop direct panel
    if roi is None and bus_numbers:
        roi = extract_roi(frame, bus_numbers[0])

    if roi is None:
        cv2.imshow("Pipeline Feed", frame)
        if cv2.waitKey(1) & 0xFF == ord("q"):
            break
        continue

    # Execute OCR Inference safely
    try:
        results = ocr.predict(roi)

        if results:
            extracted_texts = []
            for res in results:
                # PaddleOCR v3 output parsing
                if isinstance(res, dict):
                    rec_texts = res.get("rec_texts", [])
                    rec_scores = res.get("rec_scores", [])
                    for text, score in zip(rec_texts, rec_scores):
                        clean_text = re.sub(r"[^a-zA-Z0-9\s]", "", text).strip()
                        if clean_text and score > 0.35:
                            extracted_texts.append(clean_text)

                # Legacy output parsing fallback
                elif isinstance(res, list):
                    for line in res:
                        if (
                            isinstance(line, list)
                            and len(line) >= 2
                            and isinstance(line[1], (list, tuple))
                        ):
                            text, score = line[1][0], line[1][1]
                            clean_text = re.sub(
                                r"[^a-zA-Z0-9\s]", "", text
                            ).strip()
                            if clean_text and score > 0.35:
                                extracted_texts.append(clean_text)

            if extracted_texts:
                ocr_text = extracted_texts
                print("SUCCESS -> Recognized Route Number:", ocr_text)

                cv2.imshow("Detected ROI", roi)
                cv2.imshow("Captured Frame", frame)
                cv2.waitKey(0)
                break
    except Exception as e:
        print(f"Error during OCR execution: {e}")

    cv2.imshow("Pipeline Feed", frame)
    if cv2.waitKey(1) & 0xFF == ord("q"):
        break

cap.release()
cv2.destroyAllWindows()
print("Finished.")
>>>>>>> Stashed changes
