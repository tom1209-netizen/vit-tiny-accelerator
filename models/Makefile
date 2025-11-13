MAKEFILE_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
MODELS_DIR := $(patsubst %/,%,$(MAKEFILE_DIR))

PYTHON ?= python3

# Default paths
CFG ?= $(MODELS_DIR)/configs/tiny_vit_5m.yaml
CKPT ?= $(MODELS_DIR)/checkpoints/tiny_vit_5m_1k.pth

# PTQ export parameters
CALIB_DIR ?= $(MODELS_DIR)/dumps/sample_image/train
OUT_DIR ?= $(MODELS_DIR)/checkpoints/int8_5m
CALIB_BATCHES ?= 50
BATCH_SIZE ?= 16
PER_CHANNEL ?= 1    # set to 0 to disable per-channel quant

# Golden inference parameters
IMG ?= $(MODELS_DIR)/dumps/sample_image/example.jpg
IMG_SIZE ?= 224
NUM_CLASSES ?= 1000
DUMP_DIR ?= $(MODELS_DIR)/dumps/golden
SCALES_JSON ?=

.PHONY: ptq golden

ptq:
	$(PYTHON) $(MODELS_DIR)/tools/ptq_int8_export.py \
		--cfg $(CFG) \
		--ckpt $(CKPT) \
		--calib-dir $(CALIB_DIR) \
		--out-dir $(OUT_DIR) \
		--calib-batches $(CALIB_BATCHES) \
		--batch-size $(BATCH_SIZE) \
		$$( [ "$(PER_CHANNEL)" = "1" ] && echo "--per-channel" )

golden:
	$(PYTHON) $(MODELS_DIR)/tools/cpu_golden_infer.py \
		--cfg $(CFG) \
		--ckpt $(CKPT) \
		--img $(IMG) \
		--img-size $(IMG_SIZE) \
		--num-classes $(NUM_CLASSES) \
		--dump-dir $(DUMP_DIR) \
		$$( [ -n "$(SCALES_JSON)" ] && echo "--scales-json $(SCALES_JSON)" )
