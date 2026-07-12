import re

# Mock the filesJSONString and queueButtonHTML variables
filesJSONString = "[]"
queueButtonHTML = ""

# Load WiFiServer.swift content
with open("ComicToPDF/ComicToPDF/Services/Network/WiFiServer.swift", "r", encoding="utf-8") as f:
    content = f.read()

# Find the generateHTML return block
# We can search for the start return """ and end """
match = re.search(r'return """(.*?)"""', content, re.DOTALL)
if match:
    html = match.group(1)
    # Replace the Swift string interpolations
    html = html.replace("\\(filesJSONString)", filesJSONString)
    html = html.replace("\\(queueButtonHTML)", queueButtonHTML)
    
    # Write to a test HTML file
    with open("scratch/test_server.html", "w", encoding="utf-8") as out:
        out.write(html)
    print("Test HTML generated successfully at scratch/test_server.html")
else:
    print("Could not locate generateHTML return block")
