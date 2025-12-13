import math

def generate_exp_hex(filename="exp_table_q4_16.hex"):
    """
    Generates the Exponential Lookup Table.
    Input: Signed INT8 (-128 to 127)
    Output: Q4.16 Fixed Point (20 bits) representing e^x
    
    Logic:
    - Input 'x' is treated as an integer.
    - We want to store e^x in fixed point.
    - Since x is large (e.g. -128), e^-128 is tiny. e^0 is 1.0.
    - To make this useful for Softmax (which is shift-invariant), we assume 
      the input has ALREADY been shifted by max(x). 
      So inputs will be <= 0 (e.g., -10, -5, 0).
    - Positive inputs > 0 would explode in Q4.16 (e^2 = 7.38, e^127 is huge).
    - We clamp positive inputs to the max representable value or handle them carefully.
    - However, standard Softmax hardware subtracts max(x) first, so x <= 0.
    """
    print(f"Generating {filename}...")
    
    with open(filename, "w") as f:
        # Loop through all possible 8-bit inputs (0 to 255)
        # In Verilog, 'addr' is 8 bits.
        # If addr is signed, 0..127 are positive, 128..255 are negative (-128..-1).
        for i in range(256):
            # Interpret 'i' as a signed 8-bit integer
            if i < 128:
                val_in = i
            else:
                val_in = i - 256
            
            # Calculate e^x
            # Note: For Softmax, inputs are usually shifted by max, so val_in <= 0.
            # If val_in > 0, e^x can easily exceed our fixed point range.
            # PEANO paper adds a bias (+2) and clamps. 
            # Here we implement standard e^x for the range.
            
            real_exp = math.exp(val_in)
            
            # Convert to Q4.16 Fixed Point
            # 4 integer bits, 16 fractional bits.
            # Scale factor = 2^16 = 65536
            fixed_val = int(real_exp * 65536)
            
            # Clamp to max 20-bit value (0xFFFFF) just in case
            if fixed_val > 0xFFFFF:
                fixed_val = 0xFFFFF
            
            # Format as 5-digit hex (20 bits)
            f.write(f"{fixed_val:05X}\n")
            
    print(f"Done. (Range: e^-128 to e^127)")


def generate_recip_hex(filename="recip_lut.hex"):
    """
    Generates the Multi-Scale Reciprocal (MSR) Lookup Table.
    Table Size: 64 entries (LUT_ADDR_W = 6)
    
    Logic based on PEANO-ViT MSR-Approx:
    - We want to approximate 1/X.
    - The hardware shifts X such that its MSB lines up with the table size.
    - The table stores: round((1.0 / index) * 2^15)
    - Output is Q1.15 fixed point (16 bits)
    """
    print(f"Generating {filename}...")
    
    with open(filename, "w") as f:
        for i in range(64):
            if i == 0:
                # 1/0 is undefined. Set to max value (saturation)
                # In MSR logic, index 0 shouldn't happen for valid sums if logic is correct
                # or represents a very small sum that shifted to 0.
                fixed_val = 0xFFFF 
            else:
                # MSR Logic: The index 'i' represents a value in the range 
                # [32, 63] effectively due to the MSB alignment, but we fill 0-63.
                # The hardware effectively computes (Sum >> Shift).
                # We want Recip = 1 / (Index).
                # We scale by 2^15 to fit in 16 bits.
                
                # Note: MSR uses specific pre-computed points. 
                # Ideally, for an index 'i' obtained by shifting, it represents 'i'.
                # We calculate 1/i.
                recip = 1.0 / i
                
                # Scale to Q1.15 (Max value ~1.0 = 0x7FFF)
                # We use 15 fractional bits because 1/1 = 1.0 which needs the integer bit.
                fixed_val = int(recip * 32768)
                
                if fixed_val > 0xFFFF:
                    fixed_val = 0xFFFF
            
            f.write(f"{fixed_val:04X}\n")

    print("Done.")

if __name__ == "__main__":
    generate_exp_hex()
    generate_recip_hex()
