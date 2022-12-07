FROM python:3.9 
WORKDIR /app
COPY requirements.txt requirements.txt
RUN pip install -r requirements.txt
COPY . .
RUN  export PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION=python
CMD ["python", "./main.py"] 
# Or enter the name of your unique directory and parameter set.