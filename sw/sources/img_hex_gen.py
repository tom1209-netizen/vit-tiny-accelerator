import os

import numpy as np
from PIL import Image

# --- CẤU HÌNH TÊN FILE ẢNH ---
IMAGE_PATH = "dog.jpg"  # Thay tên file ảnh của bạn vào đây
OUTPUT_HEADER = "images_raw.h"


def generate_header():
    if not os.path.exists(IMAGE_PATH):
        print(f"Lỗi: Không tìm thấy file {IMAGE_PATH}")
        return

    try:
        # Mở ảnh và convert sang RGB
        img = Image.open(IMAGE_PATH).convert("RGB")
    except Exception as e:
        print(f"Lỗi đọc ảnh: {e}")
        return

    width, height = img.size
    arr = np.array(img)

    print(f"Đang xử lý ảnh: {width}x{height}...")

    # Bắt đầu ghi nội dung file header
    c_code = '#ifndef IMAGES_RAW_H\n#define IMAGES_RAW_H\n\n#include "xil_types.h"\n\n'

    c_code += f"/* Image: {os.path.basename(IMAGE_PATH)} ({width}x{height}) */\n"
    # Mảng sẽ chứa: [WIDTH, HEIGHT, Pixel0, Pixel1, ...]
    c_code += f"const u32 img_raw_data[{width * height + 2}] = {{\n"

    # Ghi Header: Width, Height
    c_code += f"    {width}, {height}, // Header [Width, Height]\n"

    # Ghi Pixel Data
    count = 0
    for y in range(height):
        c_code += "    "
        for x in range(width):
            # Lấy RGB và ép kiểu sang int để tránh lỗi numpy uint8 overflow
            r = int(arr[y, x, 0])
            g = int(arr[y, x, 1])
            b = int(arr[y, x, 2])

            # Format ARGB Little Endian (0x00RRGGBB -> trong RAM là BB GG RR 00)
            # Thử nghiệm nếu màu sai thì đổi thứ tự ở đây (ví dụ BGR)
            val = (0x00 << 24) | (r << 16) | (g << 8) | b

            c_code += f"0x{val:08X}, "
            count += 1
        c_code += "\n"

    c_code += "};\n\n#endif\n"

    with open(OUTPUT_HEADER, "w") as f:
        f.write(c_code)

    print(f"XONG! Đã tạo file {OUTPUT_HEADER}.")
    print(f"Kích thước ảnh: {width}x{height}")


if __name__ == "__main__":
    generate_header()
