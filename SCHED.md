# SCHEDULER TILER

## 1. Steps

**STEP 1:** PATCH EMBEDDING

- Class: Patch Embed
- Convo 1
- convo 2

**STEP 2:** STAGE 1 - CONV BLOCKS

1. Class: ConvLayer -> MBConv
2. Trong 1 block:

   - Convo 1 (Expand): Convo 1x1 -> BN -> GELU (Tăng Dim 4 lần)
   - Convo 2 (Depthwise): Convo 3x3, stride 1, group = dim -> BN -> GELU
   - Convo 3 (Project): Convo 1x1 -> BN (Giảm dim về cũ)
   - Residual: Output = Input + Result -> Output = 28 x 28 x 128

**STEP 3:** STAGE 2

1. Patch merging: Conv 1x1 -> Convo 3x3 (stride 2) -> Convo 1x1 => Output = 28 x 28 x 128 (???)
2. LayerNorm
3. Attention: Q, K, V -> Q x K^T -> Softmax x V
4. Local Convo: Conv 3x3 (Depthwise)
5. Residual 1
6. MLP: Norm -> Linear -> GELU -> Linear
7. Residual 2

**STEP 4-5:** STAGE 3-4
(Same with Stage 2)

1. Stage 3: Patch merging -> 7 x 7 x 320
2. Stage 4: Patch merging -> 7 x 7 x 320

**STEP 6:** CLASSIFIER HEAD

1. Global average pooling: Tính trung bình cộng của toàn bộ 7x7 token -> Ra 1 vector duy nhất 1 x 320
2. LayerNorm
3. Linear (FC): Nhân ma trận cuối cùng để ra 1000 lớp

## 2. Step 1: Convo 1 + 2

### 2.1. General

- Use GEMM Core, A is IMG, B is Weight for embedding (learned from AI)
- Set addresses to get & store data
- Trigger by `layer_cfg.block_role == 0000` & `layer_cfg.stage_id == 0000`

### 2.2. Setup

- Cnt = 0
- Kernel size = 3x3
- Tile size = 8x8

- Convo1:
  - Img input 224 x 224 x 3 -> Kernel size = 3 x 3 -> Total depth = 3 x 3 x 3 = 27
  - Common depth = 27
  - Weight = 27 x 32
  - Output img = 112 x 112 x 32
- Convo2:
  - Img input 112 x 112 x 32 -> Kernel size = 3 x 3 -> Total depth = 3 x 3 x 32 = 288
  - Common depth = 288
  - Weight = 288 x 64
  - Output img = 56 x 56 x 64

### 2.3. Problem

### 2.3.1. Buffer direction

Store Weight normally or transpose the Weight matrix (swap its rows and columns) when stored to the module Buffer?

> In this README file, it is assumed we use the transpose Weight matrix instead of the original one.

### 2.3.2. GEMM core

**STUCK HERE, CANNOT MOVE ON TO THE NEXT**
Trong module Buffer, mỗi địa chỉ là 1 byte, với 1 ô trong 224 x 224 ô cần 3 byte (cho 3 kênh). GEMM core lấy được 7 INT8 cho đầu vào A và 7 INT8 cho đầu vào B (hình và weight) của nó. Hình là A, mỗi lần truyền dô GEMM sẽ lấy được 7 INT8 là 7 bytes tất cả = 2 ô vuông trong tổng số 224 x 224 ô và 1 kênh từ ô thứ 3. **Thắc mắc: Weight có 27 x 32 giờ lấy 7 INT8 là lấy như thế nào?**

### 2.4. Pseudo-code

```text
while (cnt != 2)
    if (cnt == 0)
        in_size = 224
        out_size = 112
        token_depth = 3
        token_row = 122 * 122
        common_depth = 3 * 3 * 3 = 27
        weight_col = 32
    else
        in_size = 112
        out_size = 56
        token_depth = 32
        token_row = 56 * 56
        common_depth = 3 * 3 * 32 = 288
        weight_col = 64

    Loop 1: i = 0; i < token_row; i = i + 8
        Loop 2: j = 0; j < weight_col; j = j + 8
            Acc = 0
            Loop 3: k = 0; k < common_depth; k = k + 8
                //idx in img
                Row_out = i / out_size
                Col_out = i % out_size
                Row_in = Row_out * 2
                Col_in = Col_out * 2

                //kernel space
                Kernel_idx = k / token_depth
                Channel_idx = k % token_depth

                //offset in the kernel space
                Kernel_row_offset = Kernel_idx / 3
                Kernel_col_offset = Kernel_idx % 3

                Row_final = row_in + Kernel_row_offset
                Col_final = col_in + Kernel_col_offset

                Addr = Base_addr + (Row_final * in_size + Col_final) * token_depth + Channel_idx
                Load A = Load_from_buffer (Addr);
                Load B = Row (k), Col (j)
                Acc += A * B 
            
            //Norm ? GELU ? RELU ?
            Give Acc to Requant block 
            
    cnt = cnt + 1
```

## 3. Step 2

## 4. Step 3: Stage 2

### 4.1. LayerNorm

### 4.2. Attention

#### 4.2.1. Setup

- Block
  
```text
    case (stage_id)
        0001: block = 2
        0010: block = 2
        0011: block = 6
        0100: block = 2
    if (block != 0) Cannot config stage_id values
```

- Loop 1: Window
  
```text
    case (stage_id)
        0001: window = 7
        0010: window = 7
        0011: window = 14
        0100: window = 7
```

- Loop 2: Head
  
```text
case (stage_id)
    0001: head = 2, dim = 64
    0010: head = 4, dim = 128
    0011: head = 5, dim = 160
    0100: head = 10, dim = 320
=> Dim in each tile loop = dim / head = 32 in every case
```

- Loop 3: Tile
  
```text
    Tile size = 8x8
```

#### 4.2.2. Q/K/V projection

- Use GEMM Core, A is IMG, B_q, B_k, B_v are Weight for Q/K/V projection (learned from AI)
- Set addresses to get & store data
- Trigger by `layer_cfg.block_role == 0010` & `layer_cfg.stage_id == 0010/0011/0100` & `tile_cfg.op_class == 000`

```text
Loop 1: j = 0; j < window; j = j + 1
    Loop 2: k = 0; k < head; k = k + 1
        Loop 3: f = 0; f < ?; f = f + 8
            Loop 4: m = 0; m < ?; m = m + 8
                Acc_q = 0
                Acc_k = 0
                Acc_v = 0
                
                Loop 5: n = 0; n < ?; n = n + 8
                    Load A = Row (f : f + 7), Col (n : n + 7)
                    Load B_q = Row (m : m + 7), Col (n : n + 7)
                    Load B_k = Row (m : m + 7), Col (n : n + 7)
                    Load B_v = Row (m : m + 7), Col (n : n + 7)

                    Acc_q += A * B_q
                    Acc_k += A * B_k
                    Acc_v += A * B_v
                Give Acc_q, Acc_k, Acc_v to Requant block
```
  
#### 4.2.3. Q x K^T

- Use GEMM Core, A is Q, B is K
- Set addresses to get & store data
- Trigger by `layer_cfg.block_role == 0010` & `layer_cfg.stage_id == 0010/0011/0100` & `tile_cfg.op_class == 001`

```text
Loop 1: j = 0; j < window; j = j + 1
    Loop 2: k = 0; k < head; k = k + 1
        Loop 3: f = 0; f < ?; f = f + 8
            Loop 4: m = 0; m < ?; m = m + 8
                Acc = 0
                
                Loop 5: n = 0; n < ?; n = n + 8
                    Load A = Row (f : f + 7), Col (n : n + 7)
                    Load B = Row (m : m + 7), Col (n : n + 7)
                    Acc += A * B
                Give Acc to Requant block
```

#### 4.2.4. Softmax

- Use Softmax
- Trigger by `layer_cfg.block_role == 0010` & `layer_cfg.stage_id == 0010/0011/0100` & `tile_cfg.op_class == 010`
- Store to buffer at address for score (softmax)

#### 4.2.5. Softmax x V

- Use GEMM Core, A is Softmax, B is V
- Set addresses to get & store data
- Trigger by `layer_cfg.block_role == 0010` & `layer_cfg.stage_id == 0010/0011/0100` & `tile_cfg.op_class = 011`

```text
Loop 1: j = 0; j < window; j = j + 1
    Loop 2: k = 0; k < head; k = k + 1
        Loop 3: f = 0; f < ?; f = f + 8
            Loop 4: m = 0; m < ?; m = m + 8
                Acc = 0

                Loop 5: n = 0; n < ?; n = n + 8
                    Load A = Row (f : f + 7), Col (n : n + 7)
                    Load B = Row (m : m + 7), Col (n : n + 7)
                    Acc += A * B
                Give Acc to Requant block
```

#### 4.2.6. Residual

- Set addresses to get & store data
- Case 1: Trigger by `layer_cfg.block_role == 0010` & `layer_cfg.stage_id == 0010/0011/0100` & `tile_cfg.op_class == 110`
- Case 2: Trigger by `layer_cfg.block_role == 0011` & `layer_cfg.stage_id == 0010/0011/0100` & `tile_cfg.op_class == 011`

```text
if (case 1) Output from Attention + Residual
else if (case 2) Output from MLP + Residual
```

### 4.3. CONVO

### 4.4. MLP

#### 4.4.1. Linear expand (MLP1)

- Use GEMM Core, A is img, B is weight_expand
- Tile size = 8x8
- Set addresses to get & store data
- Trigger by `layer_cfg.block_role == 0011` & `layer_cfg.stage_id == 0010/0011/0100` & `tile_cfg.op_class == 100`
- Setup:
  - Loop 1: h = Total number of tokens (height of img)
  - Loop 2: w = Total features of weight (width of weight (4C))
  - Loop 3: d = Commom depth of img & weight (C)

```text
    Loop 1: i = 0; i < h; i = i + 8
        Loop 2: j = 0; j < w; j = j + 8
        Acc = 0
            Loop 3: k = 0; k < d; k = k + 8
                Load A = Row (i : i + 7), Col (k : k + 7)
                Load B = Row (k : k + 7), Col (j : j + 7)
                Acc += A * B
            Give Acc to Requant block
```

#### 4.4.2. GELU

- GELU xử lý xong store vào bộ nhớ buffer

#### 4.4.3. Linear contract (MLP2)

- Use GEMM Core, A is img, B is weight_contract
- Tile size = 8x8
- Set addresses to get & store data
- Trigger by `layer_cfg.block_role == 0011` & `layer_cfg.stage_id == 0010/0011/0100` & `tile_cfg.op_class == 101`
- Setup:
  - Loop 1: h = Total number of tokens (height of img)
  - Loop 2: w = Total features of weight (width of weight (2C))
  - Loop 3: d = Commom depth of img & weight (C)

```text
Loop 1: i = 0; i < h; i = i + 8
    Loop 2: j = 0; j < w; j = j + 8
    Acc = 0
        Loop 3: k = 0; k < d; k = k + 8
            Load A = Row (i : i + 7), Col (k : k + 7)
            Load B = Row (k : k + 7), Col (j : j + 7)
            Acc += A * B
        Give Acc to Requant block

block = block - 1
if (block != 0) Go back to norm
```

### 4.5. PATCH MERGING

- Use GEMM Core, A is IMG, B is Weight_merge
- Tile size = 8x8
- Set addresses to get & store data
- Trigger by `layer_cfg.block_role == 0100` & `layer_cfg.stage_id == 0010/0011/0100` & `tile_cfg.op_class == 111`
- Setup:
  - Loop 1: Number of tokens: New_token_size = Old_token_size / 2 (ex: New_token_size = 56/2 = 28 => Total_tokens = 28x28 = 784)
  - Loop 2: Number of features: New_feature_size = Old_feature_size*2 (ex: New_feature_size = 64\*2 = 128)
  - Loop 3: Common depth: Total_depth = Depth of 1 token \* 4 (ex: 64 \* 4 = 256)

```text
Loop 1: i = 0; i < Total_tokens; i = i + 8
    Loop 2: j = 0; j < New_feature_size; j = j + 8
        Acc = 0
        Loop 3: k = 0; k < Total_depth; k = k + 8
            Offset_row = (k / Old_feature_size) / 2
            Offset_col = (k / Old_feature_size) % 2 
            Real_depth = k % Old_feature_size

            Loop 4: token_idx = 0; token_idx < 8; token_idx = token_idx + 1
                Current_token_idx = i + token_idx;
                New_row = Current_token_idx / New_token_size
                New_col = Current_token_idx % New_token_size
                Old_row = (New_row*2) + Offset_row
                Old_col = (New_col*2) + Offset_col

                Addr =  Base_addr + (Old_row * width * Old_feature_size) + (Old_col * Old_feature_size) + Real_depth;
                Load A[token_idx] = Burst (Addr, len = 8);
                Load B = Load weigth (Row = k, Col = j);
                Acc += A * B
            Store buffer (Acc, row = i, col = j)    
```

### 4.6. REQUANT

- Nhận data từ các block, xử lý thành INT8 rồi store giá trị đó vô lại buffer.
- Truyền địa chỉ để lưu sau khi requant xử lý xong:
  - Patch embedding: Lấy địa chỉ gốc, ghi đè lên vì mình k cần dùng data của ảnh gốc sau khi embedding nữa (tiết kiệm buffer)
  - Q/K/V projection: Lần đầu thì lưu vào địa chỉ mới, các lần sau Lấy địa chỉ này, ghi đè dữ liệu lên vì mình k cần dùng data của Q/K/V trước đó nữa (tiết kiệm buffer)
  - Q\*K^T: Lần đầu thì lưu vào địa chỉ mới, các lần sau Lấy địa chỉ này, ghi đè dữ liệu lên vì mình không cần dùng data của Q*K^T trước đó nữa (tiết kiệm buffer)
  - Softmax\*V: Lần đầu thì lưu vào địa chỉ mới, các lần sau Lấy địa chỉ này, ghi đè dữ liệu lên vì mình không cần dùng data của Q*K^T trước đó nữa (tiết kiệm buffer)
  - MLP1: Đưa kết quả cho khối GELU
  - MLP2: Store vào buffer
