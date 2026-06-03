import os
import glob
import re

directory = "C:/Users/chris/.gemini/antigravity/scratch/InksyncPro/ComicToPDF"
swift_files = glob.glob(f"{directory}/**/*.swift", recursive=True)

for file in swift_files:
    with open(file, "r", encoding="utf-8") as f:
        content = f.read()
    
    # Replace documentDirectory first!
    content = re.sub(
        r'FileManager\.default\.urls\(for: \.documentDirectory, in: \.userDomainMask\)\.first!',
        r'(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)',
        content
    )
    
    # Replace fileManager.urls documentDirectory
    content = re.sub(
        r'fileManager\.urls\(for: \.documentDirectory, in: \.userDomainMask\)\.first!',
        r'(fileManager.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)',
        content
    )

    # Replace applicationSupportDirectory first!
    content = re.sub(
        r'FileManager\.default\.urls\(for: \.applicationSupportDirectory, in: \.userDomainMask\)\.first!',
        r'(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)',
        content
    )
    
    # Replace fileManager.urls applicationSupportDirectory
    content = re.sub(
        r'fileManager\.urls\(for: \.applicationSupportDirectory, in: \.userDomainMask\)\.first!',
        r'(fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)',
        content
    )

    with open(file, "w", encoding="utf-8") as f:
        f.write(content)

print("Replacement complete.")
