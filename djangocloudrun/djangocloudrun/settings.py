import io
import os
from urllib.parse import urlparse

import environ
import google.auth
import requests
from google.cloud.run_v2.services.services.client import ServicesClient


from .basesettings import *


env = environ.Env()
if env("APPLICATION_SETTINGS", default=None):
    env.read_env(io.StringIO(os.environ.get("APPLICATION_SETTINGS", None)))
else:
    env_file = BASE_DIR / ".env"
    env.read_env(env_file)


SECRET_KEY = env("SECRET_KEY")
DEBUG = env("DEBUG", default=False)
DATABASES = {"default": env.db()}
SERVICE_NAME = env("SERVICE_NAME", default=None)

try:
    _, PROJECT_ID = google.auth.default()
except google.auth.exceptions.DefaultCredentialsError:
    PROJECT_ID = env("PROJECT_ID", default=None)

try:
    response = requests.get(
        "http://metadata.google.internal/computeMetadata/v1/instance/region",
        headers={"Metadata-Flavor": "Google"},
    )
    REGION = response.text.split("/")[-1]
except requests.exceptions.ConnectionError:
    REGION = None

if all((PROJECT_ID, REGION, SERVICE_NAME)):
    service_path = f"projects/{PROJECT_ID}/locations/{REGION}/services/{SERVICE_NAME}"
    client = ServicesClient()
    service_uri = client.get_service(name=service_path).uri
    ALLOWED_HOSTS = [urlparse(service_uri).netloc]
    CSRF_TRUSTED_ORIGINS = [service_uri]
else:
    ALLOWED_HOSTS = ["*"]

if GS_BUCKET_NAME := env("STATICFILES_BUCKET_NAME", default=None):
    STATICFILES_DIRS = []
    GS_DEFAULT_ACL = "publicRead"
    STORAGES = {
        "default": {
            "BACKEND": "storages.backends.gcloud.GoogleCloudStorage",
        },
        "staticfiles": {
            "BACKEND": "storages.backends.gcloud.GoogleCloudStorage",
        },
    }
