import numpy as np
from typing import Tuple, List
np.random.seed(42)


def depthwise_conv2d_int8(
    input_data: np.ndarray, 
    kernel: np.ndarray,
    padding: int = 1
) -> np.ndarray:
    """
    Apply depthwise 3x3 convolution with INT8 inputs.
    
    Args:
        input_data: Shape (H, W, C), INT8
        kernel: Shape (C, 3, 3), INT8
        padding: Zero padding (default 1 for same output size)
    
    Returns:
        output: Shape (H, W, C), INT32 (raw accumulator values)
    """
    H, W, C = input_data.shape
    
    # Pad input
    padded = np.pad(input_data, ((padding, padding), (padding, padding), (0, 0)), 
                    mode='constant', constant_values=0)
    
    output = np.zeros((H, W, C), dtype=np.int32)
    
    for row in range(H):
        for col in range(W):
            for c in range(C):
                # Extract 3x3 window
                window = padded[row:row+3, col:col+3, c]
                # Convolve with channel's kernel
                output[row, col, c] = np.sum(
                    window.astype(np.int32) * kernel[c].astype(np.int32)
                )
    
    return output


def generate_test_case(
    name: str,
    height: int,
    width: int,
    channels: int,
    kernel_type: str = 'random',
    input_type: str = 'random'
) -> Tuple[np.ndarray, np.ndarray, np.ndarray]:
    """
    Generate a test case with input, kernel, and expected output.
    
    Args:
        name: Test case name
        height, width, channels: Image dimensions
        kernel_type: 'random', 'identity', 'sobel', 'blur', 'edge'
        input_type: 'random', 'gradient', 'checkerboard', 'uniform'
    
    Returns:
        (input_data, kernel, expected_output)
    """
    print(f"\n{'='*70}")
    print(f"TEST: {name}")
    print(f"{'='*70}")
    print(f"Dimensions: {height}×{width}×{channels}")
    
    # Generate input
    if input_type == 'random':
        input_data = np.random.randint(-128, 127, size=(height, width, channels), dtype=np.int8)
    elif input_type == 'gradient':
        # Horizontal gradient
        input_data = np.tile(
            np.linspace(-64, 63, width, dtype=np.int8).reshape(1, width, 1),
            (height, 1, channels)
        ).astype(np.int8)
    elif input_type == 'checkerboard':
        checker = np.indices((height, width)).sum(axis=0) % 2
        input_data = np.where(checker[:,:,None], 50, -50).astype(np.int8)
        input_data = np.broadcast_to(input_data, (height, width, channels)).copy()
    elif input_type == 'uniform':
        input_data = np.full((height, width, channels), 10, dtype=np.int8)
    else:
        input_data = np.random.randint(-128, 127, size=(height, width, channels), dtype=np.int8)
    
    # Generate kernel
    if kernel_type == 'identity':
        # Identity kernel: only center element is 1
        kernel = np.zeros((channels, 3, 3), dtype=np.int8)
        kernel[:, 1, 1] = 1
    elif kernel_type == 'sobel':
        # Sobel-X edge detection (same for all channels)
        sobel_x = np.array([[-1, 0, 1], [-2, 0, 2], [-1, 0, 1]], dtype=np.int8)
        kernel = np.tile(sobel_x, (channels, 1, 1))
    elif kernel_type == 'blur':
        # Simple averaging (scaled to INT8)
        blur = np.ones((3, 3), dtype=np.int8) * 14  # ~1/9 * 127
        kernel = np.tile(blur, (channels, 1, 1))
    elif kernel_type == 'edge':
        # Laplacian edge detection
        laplacian = np.array([[0, -1, 0], [-1, 4, -1], [0, -1, 0]], dtype=np.int8)
        kernel = np.tile(laplacian, (channels, 1, 1))
    else:  # random
        kernel = np.random.randint(-16, 16, size=(channels, 3, 3), dtype=np.int8)
    
    # Compute expected output
    expected = depthwise_conv2d_int8(input_data, kernel)
    
    print(f"Kernel type: {kernel_type}")
    print(f"Input type: {input_type}")
    print(f"Input range: [{input_data.min()}, {input_data.max()}]")
    print(f"Kernel range: [{kernel.min()}, {kernel.max()}]")
    print(f"Output range: [{expected.min()}, {expected.max()}]")
    
    return input_data, kernel, expected


def print_test_vectors(input_data: np.ndarray, kernel: np.ndarray, expected: np.ndarray):
    """Print first few values for verification."""
    H, W, C = input_data.shape
    
    print("\nSample values (pixel [0,0]):")
    print(f"  Input[0,0,:8]:    {list(input_data[0,0,:8])}")
    print(f"  Kernel[:8,1,1]:   {list(kernel[:8,1,1])}")  # Center element
    print(f"  Expected[0,0,:8]: {list(expected[0,0,:8])}")
    
    # Corner and edge cases
    print("\nBorder pixel samples:")
    print(f"  Output[0,0,0] (top-left):     {expected[0,0,0]}")
    print(f"  Output[0,{W-1},0] (top-right):    {expected[0,W-1,0]}")
    print(f"  Output[{H-1},0,0] (bot-left):    {expected[H-1,0,0]}")
    print(f"  Output[{H-1},{W-1},0] (bot-right):   {expected[H-1,W-1,0]}")


def export_to_hex(data: np.ndarray, filename: str, beat_size: int = 8):
    """Export test data to hex file for Verilog $readmemh."""
    flat = data.flatten()
    
    with open(filename, 'w') as f:
        for i in range(0, len(flat), beat_size):
            beat = flat[i:i+beat_size]
            # Pack as little-endian bytes
            hex_str = ''.join([f'{np.uint8(x):02X}' for x in beat[::-1]])
            f.write(f"{hex_str}\n")
    
    print(f"Exported to {filename}: {len(flat)//beat_size} beats")


# TEST CASES
print("\n" + "="*70)
print("DEPTHWISE CONVOLUTION TEST SUITE")
print("="*70)

# Test 1: Small image with identity kernel
print("\n### TEST 1: Identity Kernel (pass-through)")
inp1, kern1, exp1 = generate_test_case(
    "Identity Kernel 4x4x8",
    height=4, width=4, channels=8,
    kernel_type='identity', input_type='gradient'
)
print_test_vectors(inp1, kern1, exp1)

# Test 2: Edge detection
print("\n### TEST 2: Sobel Edge Detection")
inp2, kern2, exp2 = generate_test_case(
    "Sobel Edge 8x8x8",
    height=8, width=8, channels=8,
    kernel_type='sobel', input_type='gradient'
)
print_test_vectors(inp2, kern2, exp2)

# Test 3: Blur
print("\n### TEST 3: Blur Kernel")
inp3, kern3, exp3 = generate_test_case(
    "Blur 8x8x16",
    height=8, width=8, channels=16,
    kernel_type='blur', input_type='random'
)
print_test_vectors(inp3, kern3, exp3)

# Test 4: Random realistic
print("\n### TEST 4: Random (TinyViT-like)")
inp4, kern4, exp4 = generate_test_case(
    "Random 28x28x64",
    height=28, width=28, channels=64,
    kernel_type='random', input_type='random'
)
print_test_vectors(inp4, kern4, exp4)

# Test 5: Checkerboard with edge detection
print("\n### TEST 5: Checkerboard with Laplacian")
inp5, kern5, exp5 = generate_test_case(
    "Laplacian Edge 8x8x8",
    height=8, width=8, channels=8,
    kernel_type='edge', input_type='checkerboard'
)
print_test_vectors(inp5, kern5, exp5)

# Test 6: Uniform input (constant)
print("\n### TEST 6: Uniform Input")
inp6, kern6, exp6 = generate_test_case(
    "Uniform 4x4x8",
    height=4, width=4, channels=8,
    kernel_type='blur', input_type='uniform'
)
print_test_vectors(inp6, kern6, exp6)

# Summary
print("\n" + "="*70)
print("SUMMARY: TEST VECTORS FOR VERILOG")
print("="*70)

test_cases = [
    ("test1_identity", inp1, kern1, exp1),
    ("test2_sobel", inp2, kern2, exp2),
    ("test3_blur", inp3, kern3, exp3),
    ("test4_random", inp4, kern4, exp4),
    ("test5_laplacian", inp5, kern5, exp5),
    ("test6_uniform", inp6, kern6, exp6),
]

print("\nTest case dimensions:")
for name, inp, kern, exp in test_cases:
    H, W, C = inp.shape
    input_beats = H * W * (C // 8)
    kernel_beats = (C // 8) * 9
    print(f"  {name}: {H}x{W}x{C}, {kernel_beats} kernel beats, {input_beats} input beats")
