FROM python:3.13-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt && useradd --uid 10001 --create-home luma && mkdir /data && chown luma:luma /data
COPY service.py wsgi.py admin.py ./
USER luma
ENV LUMA_DB=/data/luma.sqlite3
EXPOSE 8080
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "1", "--threads", "4", "--timeout", "120", "wsgi:application"]
