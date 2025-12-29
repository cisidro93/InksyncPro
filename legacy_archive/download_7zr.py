import urllib.request
import sys

url = "https://www.7-zip.org/a/7zr.exe"
filename = "7zr.exe"

try:
    print(f"Downloading {url}...")
    urllib.request.urlretrieve(url, filename)
    print(f"Downloaded to {filename}")
except Exception as e:
    print(f"Error: {e}")
    sys.exit(1)
