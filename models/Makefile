MAKEFILE_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
MODELS_DIR := $(patsubst %/,%,$(MAKEFILE_DIR))

PYTHON ?= python3

# Default paths
CFG ?= $(MODELS_DIR)/configs/tiny_vit_5m.yaml
CKPT ?= $(MODELS_DIR)/checkpoints/tiny_vit_5m_1k.pth

# PTQ export parameters
CALIB_DIR ?= $(MODELS_DIR)/dumps/sample_image/val
OUT_DIR ?= $(MODELS_DIR)/checkpoints/int8_5m
CALIB_BATCHES ?= 100   # <=0 means iterate over entire calibration set
BATCH_SIZE ?= 16
PER_CHANNEL ?= 1    # set to 0 to disable per-channel quant
OBSERVER_PERCENTILE ?= 99.9

# Golden inference parameters
IMG ?= $(MODELS_DIR)/dumps/sample_image/example.jpeg
IMG_SIZE ?= 224
NUM_CLASSES ?= 1000
DUMP_DIR ?= $(MODELS_DIR)/dumps/golden
SCALES_JSON ?= $(MODELS_DIR)/checkpoints/int8_5m/scales.json

# QDQ report parameters
QDQ_EPS ?= 1e-12
QDQ_SORT ?= error
QDQ_JSON ?= $(MODELS_DIR)/checkpoints/int8_5m/qdq_report.json
QDQ_SCALES_JSON ?= $(SCALES_JSON)

VAL_DIR ?= $(CALIB_DIR)            
VAL_BATCH_SIZE ?= 128

# QAT defaults
QAT_TRAIN_DIR ?= $(MODELS_DIR)/dumps/sample_image/train
QAT_VAL_DIR   ?= $(MODELS_DIR)/dumps/sample_image/val
QAT_OUT_DIR   ?= $(MODELS_DIR)/checkpoints/qat_int8
QAT_EPOCHS    ?= 10
QAT_BATCH     ?= 64
QAT_LR        ?= 1e-4
QAT_WORKERS   ?= 8
QAT_SAVE_CONVERTED ?= 0

# Logging
LOG_DIR ?= $(MODELS_DIR)/logs
LOG_FILE ?= $(LOG_DIR)/ptq_$(shell date +%Y%m%d_%H%M%S).log
QAT_LOG_FILE ?= $(LOG_DIR)/qat_$(shell date +%Y%m%d_%H%M%S).log
QAT_EXPORT_LOG_FILE ?= $(LOG_DIR)/qat_export_$(shell date +%Y%m%d_%H%M%S).log

.PHONY: ptq golden qdq_report eval qat qat_export help

ptq: | $(LOG_DIR)
	@echo "Logging to $(LOG_FILE)"
	@$(PYTHON) $(MODELS_DIR)/tools/ptq_int8_export.py \
		--cfg $(CFG) \
		--ckpt $(CKPT) \
		--calib-dir $(CALIB_DIR) \
		--out-dir $(OUT_DIR) \
		--calib-batches $(CALIB_BATCHES) \
		--batch-size $(BATCH_SIZE) \
		--observer-percentile $(OBSERVER_PERCENTILE) \
		--device cuda \
		$$( [ "$(PER_CHANNEL)" = "1" ] && echo "--per-channel" ) 2>&1 | tee $(LOG_FILE)

golden:
	@$(PYTHON) $(MODELS_DIR)/tools/cpu_golden_infer.py \
		--cfg $(CFG) \
		--ckpt $(CKPT) \
		--img $(IMG) \
		--img-size $(IMG_SIZE) \
		--num-classes $(NUM_CLASSES) \
		--dump-dir $(DUMP_DIR) \
		$$( [ -n "$(SCALES_JSON)" ] && echo "--scales-json $(SCALES_JSON)" )

eval:
	@$(PYTHON) $(MODELS_DIR)/tools/cpu_golden_infer.py \
		--cfg $(CFG) \
		--ckpt $(CKPT) \
		--img-size $(IMG_SIZE) \
		--num-classes $(NUM_CLASSES) \
		--val-dir $(VAL_DIR) \
		--batch-size $(VAL_BATCH_SIZE) \
		$$( [ -n "$(SCALES_JSON)" ] && echo "--scales-json $(SCALES_JSON)" )

qdq_report:
	@$(PYTHON) $(MODELS_DIR)/tools/qdq_error_report.py \
		--dump-dir $(DUMP_DIR) \
		--eps $(QDQ_EPS) \
		--sort $(QDQ_SORT) \
		$$( [ -n "$(QDQ_SCALES_JSON)" ] && echo "--scales-json $(QDQ_SCALES_JSON)" ) \
		$$( [ -n "$(QDQ_JSON)" ] && echo "--save-json $(QDQ_JSON)" )

qat: | $(LOG_DIR)
	@echo "Logging to $(QAT_LOG_FILE)"
	@$(PYTHON) $(MODELS_DIR)/tools/qat_train.py \
		--cfg $(CFG) \
		--train-dir $(QAT_TRAIN_DIR) \
		--val-dir $(QAT_VAL_DIR) \
		--out-dir $(QAT_OUT_DIR) \
		--epochs $(QAT_EPOCHS) \
		--batch-size $(QAT_BATCH) \
		--lr $(QAT_LR) \
		--img-size $(IMG_SIZE) \
		--num-classes $(NUM_CLASSES) \
		--workers $(QAT_WORKERS) \
		$$( [ -n "$(CKPT)" ] && echo "--ckpt $(CKPT)" ) \
		$$( [ "$(QAT_SAVE_CONVERTED)" = "1" ] && echo "--save-converted" ) 2>&1 | tee $(QAT_LOG_FILE)

qat_export: | $(LOG_DIR)
	@echo "Logging to $(QAT_EXPORT_LOG_FILE)"
	@$(PYTHON) $(MODELS_DIR)/tools/ptq_int8_export.py \
		--cfg $(CFG) \
		--ckpt $(QAT_OUT_DIR)/qat_best.pth \
		--calib-dir $(QAT_VAL_DIR) \
		--out-dir $(QAT_OUT_DIR) \
		--calib-batches $(CALIB_BATCHES) \
		--batch-size $(BATCH_SIZE) \
		--observer-percentile $(OBSERVER_PERCENTILE) \
		--device cuda \
		--per-channel 2>&1 | tee $(QAT_EXPORT_LOG_FILE)

help:
	@echo ""
	@echo "**********************************************************"
	@echo "** make ptq        : export an INT8 PTQ model"
	@echo "** make golden     : run golden inference on a single image"
	@echo "** make eval       : evaluate the model on a validation set"
	@echo "** make qdq_report : generate QDQ error/scale report"
	@echo "** make qat        : run QAT fine-tuning"
	@echo "** make qat_export : export INT8 from the best QAT ckpt"
	@echo "**********************************************************"

$(LOG_DIR):
	@mkdir -p $(LOG_DIR)
