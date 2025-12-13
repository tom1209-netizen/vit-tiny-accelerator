#!/usr/bin/env python3
"""
Softmax Distribution Test Suite
Tests the softmax function with different input distributions
and generates expected outputs for hardware verification.
"""

import numpy as np
np.random.seed(42)

def softmax_uint8(logits):
    """Compute softmax and convert to UINT8 (0-255 scale)"""
    logits = np.array(logits, dtype=np.float64)
    max_val = logits.max()
    exp_logits = np.exp(logits - max_val)  # Max-subtracted for stability
    probs = exp_logits / exp_logits.sum()
    uint8_probs = np.clip(np.round(probs * 255), 0, 255).astype(np.uint8)
    return probs, uint8_probs, max_val

def print_test_case(name, logits, description):
    """Print detailed analysis of a test case"""
    logits = np.array(logits, dtype=np.int8)
    probs, uint8_probs, max_val = softmax_uint8(logits)
    
    print(f"\n{'='*70}")
    print(f"TEST: {name}")
    print(f"{'='*70}")
    print(f"\n{description}\n")
    
    print(f"Input Logits (INT8):     {list(logits)}")
    print(f"Global Max:              {int(max_val)}")
    print(f"Shifted (x - max):       {list(logits - int(max_val))}")
    print(f"\nFloat Probabilities:     {[f'{p:.4f}' for p in probs]}")
    print(f"UINT8 Output (0-255):    {list(uint8_probs)}")
    print(f"Sum of probs:            {probs.sum():.6f}")
    print(f"Sum of UINT8:            {uint8_probs.sum()} (ideal: 255)")
    
    # Identify dominant tokens
    top_indices = np.argsort(probs)[::-1][:3]
    print(f"\nTop 3 tokens:")
    for i, idx in enumerate(top_indices):
        if probs[idx] > 0.001:
            print(f"  #{i+1}: Token {idx} = {logits[idx]:+4d} → {probs[idx]*100:.1f}% ({uint8_probs[idx]}/255)")
    
    # Entropy analysis
    entropy = -np.sum(probs * np.log(probs + 1e-10))
    max_entropy = np.log(len(logits))
    print(f"\nEntropy: {entropy:.3f} / {max_entropy:.3f} (max)")
    print(f"Confidence: {'HIGH (peaked)' if entropy < 1.0 else 'MEDIUM' if entropy < 2.0 else 'LOW (spread)'}")
    
    return logits, uint8_probs


# =============================================================================
# TEST CASE 1: Standard Normal Distribution (mean=0, std=10)
# =============================================================================
logits_normal = np.random.normal(loc=0, scale=10, size=8).astype(np.int8)
print_test_case(
    "NORMAL DISTRIBUTION (μ=0, σ=10)",
    logits_normal,
    """A standard normal (Gaussian) distribution centered at 0 with std=10.
In neural networks, this simulates balanced attention where no single 
token dominates strongly. The softmax will spread probability across
multiple tokens based on their relative values."""
)


# =============================================================================
# TEST CASE 2: Normal with High Variance (more spread)
# =============================================================================
logits_high_var = np.random.normal(loc=0, scale=30, size=8).astype(np.int8)
print_test_case(
    "NORMAL DISTRIBUTION - HIGH VARIANCE (μ=0, σ=30)",
    logits_high_var,
    """Higher variance means more extreme values. The exponential in softmax
amplifies differences, so the highest value will dominate more strongly.
This simulates confident predictions where one token stands out."""
)


# =============================================================================
# TEST CASE 3: Normal with Low Variance (more concentrated)
# =============================================================================
logits_low_var = np.random.normal(loc=0, scale=3, size=8).astype(np.int8)
print_test_case(
    "NORMAL DISTRIBUTION - LOW VARIANCE (μ=0, σ=3)",
    logits_low_var,
    """Lower variance means values are clustered together. When all logits
are similar, softmax produces nearly uniform probabilities - the model
is "uncertain" and spreads attention across all tokens."""
)


# =============================================================================
# TEST CASE 4: Bimodal Distribution (Two Peaks)
# =============================================================================
# Mix of two normal distributions
peak1 = np.random.normal(loc=-20, scale=5, size=4).astype(np.int8)
peak2 = np.random.normal(loc=20, scale=5, size=4).astype(np.int8)
logits_bimodal = np.concatenate([peak1, peak2])
print_test_case(
    "BIMODAL DISTRIBUTION (Two Peaks at -20 and +20)",
    logits_bimodal,
    """Bimodal distribution with two clusters. In attention, this happens
when there are two distinct groups of relevant tokens. The HIGHER peak
group will dominate completely due to exponential amplification.
The lower peak (~-20) contributes essentially 0 probability."""
)


# =============================================================================
# TEST CASE 5: Uniform Distribution
# =============================================================================
logits_uniform = np.random.randint(-50, 50, size=8).astype(np.int8)
print_test_case(
    "UNIFORM DISTRIBUTION (-50 to +50)",
    logits_uniform,
    """Uniformly random values across the INT8 range. The result depends
on which random value happens to be largest. Unlike normal distribution,
there's no central tendency - any token could be dominant."""
)


# =============================================================================
# TEST CASE 6: One-Hot (Single Dominant Token)
# =============================================================================
logits_onehot = np.array([-10, -10, -10, 50, -10, -10, -10, -10], dtype=np.int8)
print_test_case(
    "ONE-HOT (Single Dominant Token)",
    logits_onehot,
    """One token has a much higher value than others. This is the "confident"
case - the model is very sure about one token. The dominant token gets
~100% probability (255), others get ~0%. This is common in classification
tasks or when attention focuses on a single key token."""
)


# =============================================================================
# TEST CASE 7: Two Competing Tokens
# =============================================================================
logits_compete = np.array([-10, 30, -10, 30, -10, -10, -10, -10], dtype=np.int8)
print_test_case(
    "TWO COMPETING TOKENS (Equal High Values)",
    logits_compete,
    """Two tokens have the same high value. Softmax will split probability
equally between them (~50% each, ~127/255 each). This tests the case
where attention is divided between two equally important tokens."""
)


# =============================================================================
# TEST CASE 8: Exponential Distribution (Many Low, Few High)
# =============================================================================
logits_exp = np.random.exponential(scale=10, size=8).astype(np.int8)
print_test_case(
    "EXPONENTIAL DISTRIBUTION (scale=10)",
    logits_exp,
    """Exponential distribution has many small values and few large ones.
This mimics scenarios where most tokens are irrelevant (low logit) but
a few stand out. The rare high value(s) will dominate the softmax."""
)


# =============================================================================
# TEST CASE 9: All Same Value (Edge Case)
# =============================================================================
logits_same = np.array([10, 10, 10, 10, 10, 10, 10, 10], dtype=np.int8)
print_test_case(
    "ALL SAME VALUE (Uniform Attention)",
    logits_same,
    """All tokens have identical values. Softmax produces perfectly uniform
probabilities (1/8 = 12.5% each = 31-32/255 each). Tests the case where
all tokens are equally important - maximum entropy distribution."""
)


# =============================================================================
# TEST CASE 10: Negative Logits Only
# =============================================================================
logits_negative = np.array([-5, -10, -15, -3, -20, -8, -12, -7], dtype=np.int8)
print_test_case(
    "ALL NEGATIVE LOGITS",
    logits_negative,
    """All logits are negative. After max-subtraction, the highest value 
becomes 0 (exp(0)=1), others become more negative. This tests numerical
stability - the hardware must handle negative inputs correctly. Note
that the LEAST negative (-3) becomes the dominant token."""
)


# =============================================================================
# Summary Table for Hardware Verification
# =============================================================================
print("\n" + "="*70)
print("SUMMARY: EXPECTED OUTPUTS FOR VERILOG TESTBENCH")
print("="*70)
print("\nTest vectors in hex format for Verilog stimulus:")

test_cases = [
    ("Normal (σ=10)", logits_normal),
    ("High Variance", logits_high_var),
    ("Low Variance", logits_low_var),
    ("Bimodal", logits_bimodal),
    ("Uniform", logits_uniform),
    ("One-Hot", logits_onehot),
    ("Two Competing", logits_compete),
    ("Exponential", logits_exp),
    ("All Same", logits_same),
    ("All Negative", logits_negative),
]

for name, logits in test_cases:
    logits = np.array(logits, dtype=np.int8)
    _, uint8_out, _ = softmax_uint8(logits)
    
    # Convert to hex
    in_hex = ''.join([f'{np.uint8(x):02X}' for x in logits[::-1]])
    out_hex = ''.join([f'{x:02X}' for x in uint8_out[::-1]])
    
    print(f"\n{name}:")
    print(f"  Input:    64'h{in_hex}")
    print(f"  Expected: 64'h{out_hex}")
