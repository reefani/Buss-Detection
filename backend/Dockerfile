FROM python:3.12-slim

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    libglib2.0-0 \
    libgl1 \
    libgomp1 \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .

RUN pip install --no-cache-dir torch==2.14.1+cpu torchvision==0.29.1+cpu --index-url https://download.pytorch.org/whl/cpu

RUN pip install --no-cache-dir -r requirements.txt

# Cache the same models as pipeline.py in the image for runtime reuse.
RUN python -c "from paddleocr import PaddleOCR; PaddleOCR(use_angle_cls=False, use_doc_orientation_classify=False, use_doc_unwarping=False, enable_mkldnn=False, lang='en')"

# Skip model-host connectivity checks during container startup.
ENV PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK=True

COPY main.py pipeline.py best.pt ./

EXPOSE 8000

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
