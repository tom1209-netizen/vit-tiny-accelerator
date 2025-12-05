import math

M_BITS = 12
NUM_ENTRIES = 1 << M_BITS  # 4096 lines
OUT_WIDTH = 32

# choose format Q2.30 for value in this lut (Range [1.0, 2.0))
# Bit 31: 2^1, Bit 30: 2^0
FRAC_BITS = 30
SCALE = 1 << FRAC_BITS

print(f"Generating {OUT_WIDTH}-bit LUT for 2^v (Unsigned Q2.{FRAC_BITS})...")

with open("lut_pow2.hex", "w") as f:
    for i in range(NUM_ENTRIES):
        # v runs from 0.0 to ~0.999...
        v_real = i / float(NUM_ENTRIES)

        # calculate 2^v (for value from 1.0 to ~1.999)
        res_real = math.pow(2, v_real)

        # Scale to Fixed-point
        res_int = int(round(res_real * SCALE))

        # bound handling
        if res_int >= (1 << OUT_WIDTH):
            res_int = (1 << OUT_WIDTH) - 1

        # write to file HEX )
        hex_str = f"{res_int:08X}"
        f.write(f"{hex_str}\n")

print("Done! File lut_pow2.hex created.")
