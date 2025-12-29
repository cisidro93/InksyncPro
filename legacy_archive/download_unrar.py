import urllib.request
import sys

url = "https://www.rarlab.com/rar/UnRARDLL.exe"
filename = "UnRARDLL.exe"

try:
    print(f"Downloading {url}...")
    urllib.request.urlretrieve(url, filename)
    print(f"Downloaded to {filename}")
except Exception as e:
    print(f"Error: {e}")
    sys.exit(1)
