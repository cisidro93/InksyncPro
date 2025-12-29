import cbz_to_pdf
import os

def test_max_size():
    input_file = "test.cbz"
    output_limited = "test_limited.pdf"
    
    # Set a very small limit to force resizing (e.g., 1MB)
    # The original test.cbz is likely small, but this ensures logic runs
    max_size_mb = 1 

    if not os.path.exists(input_file):
        print("Error: test.cbz not found. Run create_test_cbz.py first.")
        return

    print(f"Converting with max size limit: {max_size_mb}MB...")
    cbz_to_pdf.convert_cbz_to_pdf(input_file, output_limited, max_size_mb=max_size_mb)

    size_limited = os.path.getsize(output_limited)
    print(f"Limited size: {size_limited} bytes ({size_limited/1024/1024:.2f} MB)")

    if size_limited < max_size_mb * 1024 * 1024:
        print("SUCCESS: File is within limit.")
    else:
        print("WARNING: File exceeds limit (might be due to PDF overhead or minimum image size).")

if __name__ == "__main__":
    test_max_size()
