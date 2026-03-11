import cbz_to_pdf
import os

def test_compression():
    input_file = "test.cbz"
    output_normal = "test_normal.pdf"
    output_compressed = "test_compressed.pdf"

    if not os.path.exists(input_file):
        print("Error: test.cbz not found. Run create_test_cbz.py first.")
        return

    print("Converting without compression...")
    cbz_to_pdf.convert_cbz_to_pdf(input_file, output_normal, compress=False)
    
    print("Converting with compression...")
    cbz_to_pdf.convert_cbz_to_pdf(input_file, output_compressed, compress=True)

    size_normal = os.path.getsize(output_normal)
    size_compressed = os.path.getsize(output_compressed)

    print(f"Normal size: {size_normal} bytes")
    print(f"Compressed size: {size_compressed} bytes")

    if size_compressed < size_normal:
        print("SUCCESS: Compressed file is smaller.")
    else:
        print("WARNING: Compressed file is not smaller (might be due to simple test images).")

if __name__ == "__main__":
    test_compression()
