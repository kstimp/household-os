FROM python:3.13-slim

WORKDIR /app

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY hub ./hub

ENV PYTHONUNBUFFERED=1
ENV HUB_DB_PATH=/app/data/hub.db

EXPOSE 8000

CMD ["uvicorn", "hub.main:create_app", "--factory", "--host", "0.0.0.0", "--port", "8000"]
