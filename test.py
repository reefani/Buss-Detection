from paddleocr import PaddleOCR

print("TEST STARTED")

print("Before OCR")

ocr = PaddleOCR(lang="en")

print("OCR loaded successfully")

print("TEST FINISHED")







'''from paddleocr import PaddleOCR

print("Before OCR")

ocr = PaddleOCR(lang="en")

print("OCR loaded successfully")

'''









'''
import cv2

print("TEST STARTED")

for i in range(5):
    print("Testing camera:", i)

    cap = cv2.VideoCapture(i, cv2.CAP_DSHOW)

    if cap.isOpened():
        ret, frame = cap.read()

        if ret:
            print(f"Camera {i}: WORKING")
        else:
            print(f"Camera {i}: OPENED BUT NO FRAME")
    else:
        print(f"Camera {i}: NOT AVAILABLE")

    cap.release()

print("TEST FINISHED")
'''

