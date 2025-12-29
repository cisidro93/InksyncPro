import zipfile
import os
from PIL import Image, ImageDraw

def create_test_cbz(filename="test.cbz"):
    # Create a few dummy images
    images = []
    for i in range(3):
        img = Image.new('RGB', (100, 100), color = (73, 109, 137))
        d = ImageDraw.Draw(img)
        d.text((10,10), f"Page {i+1}", fill=(255, 255, 0))
        img_name = f"page_{i+1:03d}.jpg"
        img.save(img_name)
        images.append(img_name)

    # Create CBZ file
    with zipfile.ZipFile(filename, 'w') as zipf:
        for img in images:
            zipf.write(img)
            os.remove(img) # Clean up image file

    print(f"Created {filename}")

if __name__ == "__main__":
    create_test_cbz()
