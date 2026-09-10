from ultralytics import YOLO 
from paddleocr import PaddleOCR 
import numpy as np 
import cv2 
 
# ========================= 
# Load models 
# ========================= 
model = YOLO("best.pt") 
print("Model loaded successfully!") 
ocr = PaddleOCR(lang="en")
print("OCR model loaded") 
 
# ========================= 
# ROI function 
# ========================= 
def extract_roi(image: np.ndarray, bbox: list, padding_percent: float = 0.05) -> np.ndarray: 
   if image is None or image.size == 0: 
       return None 
   h, w, _ = image.shape 
   x1, y1, x2, y2 = map(int, bbox) 
   pad_w = int((x2 - x1) * padding_percent) 
   pad_h = int((y2 - y1) * padding_percent) 
   x1_crop = max(0, x1 - pad_w) 
   y1_crop = max(0, y1 - pad_h) 
   x2_crop = min(w, x2 + pad_w) 
   y2_crop = min(h, y2 + pad_h) 
   roi = image[y1_crop:y2_crop, x1_crop:x2_crop] 
   if roi.size == 0: 
       return None 
   return roi 
 
# ========================= 
# Open phone camera 
# ========================= 
cap = cv2.VideoCapture(0) 
 
if not cap.isOpened(): 
   print("Camera could not be opened.") 
   exit() 
print("Camera opened successfully")
ocr_text = None 
 
# ========================= 
# Keep taking frames 
# until OCR succeeds 
# ========================= 
while ocr_text is None: 
   ret, frame = cap.read() 
   if not ret: 
       print("Could not read frame.") 
       continue 
 
   # ------------------------- 
   # YOLO on current frame 
   # ------------------------- 
   yolo_result = model(frame, verbose=False)[0] 
   bus_front = [] 
   bus_numbers = [] 
 
   for box in yolo_result.boxes: 
       class_id = int(box.cls[0]) 
       x1, y1, x2, y2 = map( 
           int, 
           box.xyxy[0] 
       ) 
 
       if class_id == 0: 
           bus_front.append( 
               (x1, y1, x2, y2) 
           ) 
       elif class_id == 1: 
           bus_numbers.append( 
               (x1, y1, x2, y2) 
           ) 
 
   # ------------------------- 
   # Find bus number panel 
   # inside bus front 
   # ------------------------- 
   roi = None 
   for bx1, by1, bx2, by2 in bus_front: 
       for px1, py1, px2, py2 in bus_numbers: 
           if ( 
               px1 >= bx1 
               and py1 >= by1 
               and px2 <= bx2 
               and py2 <= by2 
           ): 
               bbox = ( 
                   px1, 
                   py1, 
                   px2, 
                   py2 
               ) 
               roi = extract_roi( 
                   frame, 
                   bbox 
               ) 
               break 
       if roi is not None: 
           break 
 
   # ------------------------- 
   # If no panel detected, 
   # get another camera frame 
   # ------------------------- 
   if roi is None: 
       continue 
 
   # ------------------------- 
   # OCR 
   # ------------------------- 
   ocr_result = ocr.predict(roi) 
 
   if not ocr_result: 
       continue 
 
   texts = ocr_result[0]["rec_texts"] 
 
   # إذا OCR ما قرأ شيء 
   # يرجع لأول الـwhile 
   # ويأخذ frame جديد 
   if not texts: 
       continue 
 
   # ------------------------- 
   # OCR succeeded 
   # ------------------------- 
   ocr_text = texts 
   print("OCR:", ocr_text) 

   cv2.imshow("Captured Frame", frame)
   cv2.waitKey(0)
 
# ========================= 
# Close camera 
# ========================= 
cap.release() 
cv2.destroyAllWindows() 
print("Finished.")