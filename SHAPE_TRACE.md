# TinyViT-5M Shape Trace (Inference)

This document traces the tensor shapes through the `tiny_vit_5m_224` model during inference.
**Batch Size (B)** is assumed to be 1.
**Notation:** `(C, H, W)` for image-like tensors, `(N, C)` for token sequences (where N = H\*W).

## 1. Convolutional Stem (PatchEmbed)

| Step            | Module      | Input Shape      | Output Shape     | Description                                   |
| :-------------- | :---------- | :--------------- | :--------------- | :-------------------------------------------- |
| **Input**       | -           | `(3, 224, 224)`  | -                | RGB Image                                     |
| **Stem Conv 1** | `Conv2d_BN` | `(3, 224, 224)`  | `(32, 112, 112)` | Kernel 3x3, Stride 2, Pad 1. Channels 3->32.  |
| **Activation**  | `GELU`      | `(32, 112, 112)` | `(32, 112, 112)` | -                                             |
| **Stem Conv 2** | `Conv2d_BN` | `(32, 112, 112)` | `(64, 56, 56)`   | Kernel 3x3, Stride 2, Pad 1. Channels 32->64. |

## 2. Stage 0 (Convolutional Layers)

This stage uses `MBConv` blocks and operates in `NCHW` format until the final downsample.

| Step           | Module         | Input Shape    | Output Shape   | Description                                                                                                                                    |
| :------------- | :------------- | :------------- | :------------- | :--------------------------------------------------------------------------------------------------------------------------------------------- |
| **Block 1**    | `MBConv`       | `(64, 56, 56)` | `(64, 56, 56)` | Expand ratio 4.0. Depthwise 3x3.                                                                                                               |
| **Block 2**    | `MBConv`       | `(64, 56, 56)` | `(64, 56, 56)` | Expand ratio 4.0. Depthwise 3x3.                                                                                                               |
| **Downsample** | `PatchMerging` | `(64, 56, 56)` | `(784, 128)`   | **Transition to Stage 1**. <br>1. Pointwise 64->128 `(128, 56, 56)`<br>2. Depthwise Stride 2 `(128, 28, 28)`<br>3. Flatten to `(N=784, C=128)` |

## 3. Stage 1 (Transformer Layers)

This stage uses `TinyViTBlock` and operates on flattened token sequences `(N, C)`.
**Window Size:** 7x7 (16 windows total).

| Step           | Module         | Input Shape  | Output Shape | Description                                                                                                                                                                      |
| :------------- | :------------- | :----------- | :----------- | :------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Block 1**    | `TinyViTBlock` | `(784, 128)` | `(784, 128)` | Window Attention (4 heads) + Local Conv 3x3 + MLP.                                                                                                                               |
| **Block 2**    | `TinyViTBlock` | `(784, 128)` | `(784, 128)` | Window Attention (4 heads) + Local Conv 3x3 + MLP.                                                                                                                               |
| **Downsample** | `PatchMerging` | `(784, 128)` | `(196, 160)` | **Transition to Stage 2**. <br>1. Reshape to `(128, 28, 28)`<br>2. Pointwise 128->160 `(160, 28, 28)`<br>3. Depthwise Stride 2 `(160, 14, 14)`<br>4. Flatten to `(N=196, C=160)` |

## 4. Stage 2 (Transformer Layers)

**Window Size:** 14x14 (1 window total).

| Step           | Module         | Input Shape  | Output Shape | Description                                                                                                                                                                   |
| :------------- | :------------- | :----------- | :----------- | :---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Block 1**    | `TinyViTBlock` | `(196, 160)` | `(196, 160)` | Window Attention (5 heads) + Local Conv 3x3 + MLP.                                                                                                                            |
| **Block 2**    | `TinyViTBlock` | `(196, 160)` | `(196, 160)` | -                                                                                                                                                                             |
| **Block 3**    | `TinyViTBlock` | `(196, 160)` | `(196, 160)` | -                                                                                                                                                                             |
| **Block 4**    | `TinyViTBlock` | `(196, 160)` | `(196, 160)` | -                                                                                                                                                                             |
| **Block 5**    | `TinyViTBlock` | `(196, 160)` | `(196, 160)` | -                                                                                                                                                                             |
| **Block 6**    | `TinyViTBlock` | `(196, 160)` | `(196, 160)` | -                                                                                                                                                                             |
| **Downsample** | `PatchMerging` | `(196, 160)` | `(49, 320)`  | **Transition to Stage 3**. <br>1. Reshape to `(160, 14, 14)`<br>2. Pointwise 160->320 `(320, 14, 14)`<br>3. Depthwise Stride 2 `(320, 7, 7)`<br>4. Flatten to `(N=49, C=320)` |

## 5. Stage 3 (Transformer Layers)

**Window Size:** 7x7 (1 window total).

| Step        | Module         | Input Shape | Output Shape | Description                                         |
| :---------- | :------------- | :---------- | :----------- | :-------------------------------------------------- |
| **Block 1** | `TinyViTBlock` | `(49, 320)` | `(49, 320)`  | Window Attention (10 heads) + Local Conv 3x3 + MLP. |
| **Block 2** | `TinyViTBlock` | `(49, 320)` | `(49, 320)`  | Window Attention (10 heads) + Local Conv 3x3 + MLP. |

## 6. Classifier Head

| Step           | Module        | Input Shape | Output Shape | Description                            |
| :------------- | :------------ | :---------- | :----------- | :------------------------------------- |
| **Pooling**    | `Mean(dim=1)` | `(49, 320)` | `(320)`      | Global Average Pooling over tokens.    |
| **Norm**       | `LayerNorm`   | `(320)`     | `(320)`      | Final feature normalization.           |
| **Classifier** | `Linear`      | `(320)`     | `(1000)`     | Project to class logits (ImageNet-1k). |

## 7. Component Internal Dataflows

This section details the internal shape transformations within the primary building blocks.

### 7.1 Conv2d_BN (Generic)

Used in Stem, MBConv, and Local Convolutions.
**Operation:** `Conv2d` followed by `BatchNorm2d`.

| Step | Operation     | Input Shape       | Output Shape      | Notes                         |
| :--- | :------------ | :---------------- | :---------------- | :---------------------------- |
| 1    | `Conv2d`      | `(C_in, H, W)`    | `(C_out, H', W')` | Stride/Padding affect H', W'. |
| 2    | `BatchNorm2d` | `(C_out, H', W')` | `(C_out, H', W')` | Elementwise normalization.    |

### 7.2 MBConv Block Detail

**Example Context:** Stage 0, Block 1.
**Input:** `(64, 56, 56)` (C=64, H=56, W=56). **Expand Ratio:** 4.

| Step | Operation         | Input Shape     | Output Shape    | Notes                     |
| :--- | :---------------- | :-------------- | :-------------- | :------------------------ |
| 1    | `Conv2d_BN` (1x1) | `(64, 56, 56)`  | `(256, 56, 56)` | Expansion (64 \* 4).      |
| 2    | `GELU`            | `(256, 56, 56)` | `(256, 56, 56)` | Activation.               |
| 3    | `Conv2d_BN` (3x3) | `(256, 56, 56)` | `(256, 56, 56)` | Depthwise (Groups=256).   |
| 4    | `GELU`            | `(256, 56, 56)` | `(256, 56, 56)` | Activation.               |
| 5    | `Conv2d_BN` (1x1) | `(256, 56, 56)` | `(64, 56, 56)`  | Projection back to C.     |
| 6    | `Add`             | `(64, 56, 56)`  | `(64, 56, 56)`  | Residual: Input + Step 5. |
| 7    | `GELU`            | `(64, 56, 56)`  | `(64, 56, 56)`  | Final Activation.         |

### 7.3 TinyViTBlock Detail

**Example Context:** Stage 1, Block 1.
**Input:** `(N=784, C=128)` (Resolution 28x28). **Heads:** 4. **Window:** 7. **MLP Ratio:** 4.

#### Phase 1: Window Attention

| Step | Operation           | Input Shape        | Output Shape      | Notes                             |
| :--- | :------------------ | :----------------- | :---------------- | :-------------------------------- |
| 1    | `Window Partition`  | `(1, 28, 28, 128)` | `(16, 49, 128)`   | 16 windows of 7x7 (49) pixels.    |
| 2    | `LayerNorm`         | `(16, 49, 128)`    | `(16, 49, 128)`   | -                                 |
| 3    | `Linear` (QKV)      | `(16, 49, 128)`    | `(16, 49, 384)`   | Generates Q, K, V (128\*3).       |
| 4    | `Reshape/Permute`   | `(16, 49, 384)`    | `(16, 4, 49, 32)` | Split heads (4 heads, dim 32).    |
| 5    | `Attention` (QK^T)  | `(16, 4, 49, 32)`  | `(16, 4, 49, 49)` | Attention scores (N_win x N_win). |
| 6    | `Softmax`           | `(16, 4, 49, 49)`  | `(16, 4, 49, 49)` | -                                 |
| 7    | `MatMul` (Attn @ V) | `(16, 4, 49, 49)`  | `(16, 4, 49, 32)` | Apply weights to V.               |
| 8    | `Linear` (Proj)     | `(16, 49, 128)`    | `(16, 49, 128)`   | Merge heads.                      |
| 9    | `Window Reverse`    | `(16, 49, 128)`    | `(784, 128)`      | Reassemble image tokens.          |
| 10   | `Add`               | `(784, 128)`       | `(784, 128)`      | Residual 1 (Input + Attn).        |

#### Phase 2: Local Convolution

| Step | Operation         | Input Shape     | Output Shape    | Notes                        |
| :--- | :---------------- | :-------------- | :-------------- | :--------------------------- |
| 1    | `Reshape`         | `(784, 128)`    | `(128, 28, 28)` | Tokens to Image (NCHW).      |
| 2    | `Conv2d_BN` (3x3) | `(128, 28, 28)` | `(128, 28, 28)` | Depthwise Conv (Groups=128). |
| 3    | `Flatten`         | `(128, 28, 28)` | `(784, 128)`    | Image to Tokens.             |

#### Phase 3: MLP

| Step | Operation      | Input Shape  | Output Shape | Notes                            |
| :--- | :------------- | :----------- | :----------- | :------------------------------- |
| 1    | `LayerNorm`    | `(784, 128)` | `(784, 128)` | -                                |
| 2    | `Linear` (FC1) | `(784, 128)` | `(784, 512)` | Expand (Ratio 4).                |
| 3    | `GELU`         | `(784, 512)` | `(784, 512)` | -                                |
| 4    | `Linear` (FC2) | `(784, 512)` | `(784, 128)` | Project back.                    |
| 5    | `Add`          | `(784, 128)` | `(784, 128)` | Residual 2 (LocalConvOut + MLP). |
