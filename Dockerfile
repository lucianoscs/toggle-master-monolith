FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DEFAULT_TIMEOUT=100 \
    PIP_RETRIES=5

WORKDIR /app

# Dependências (todas fixadas em requirements.txt, gerado a partir de requirements.in)
COPY requirements.txt .
RUN pip install -r requirements.txt

# Usuário sem privilégios
RUN useradd --system --uid 10001 --no-create-home appuser

COPY app.py entrypoint.sh ./
RUN chmod 755 entrypoint.sh

USER appuser

EXPOSE 5000

# Liveness do container (o /ready, que consulta o banco, é usado nos testes e no deploy)
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD python -c "import os,urllib.request; urllib.request.urlopen('http://127.0.0.1:%s/health' % os.getenv('PORT','5000'), timeout=3)"

ENTRYPOINT ["./entrypoint.sh"]
CMD ["serve"]
