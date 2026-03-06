import urllib.request
import re

url = "https://raw.githubusercontent.com/limitcat/LivePhotoDemo/master/LivePhotoDemo/LivePhoto.swift"
response = urllib.request.urlopen(url)
content = response.read().decode('utf-8')
lines = content.split('\n')
for i, line in enumerate(lines):
    if "still-image-time" in line or "metaAdaptor" in line:
        print("---")
        for j in range(max(0, i-5), min(len(lines), i+15)):
            print(lines[j])
