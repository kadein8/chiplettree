#!/bin/bash
# Run HHT accuracy sweep experiment directly on VM
# Usage: bash run_accuracy_sweep.sh
# Results written to results/accuracy_sweep.log

set -e
cd /home/ICer/first/code/exp/HHT_confidence_and_speed

RESULTS_DIR=results
mkdir -p ${RESULTS_DIR}
LOG=${RESULTS_DIR}/accuracy_sweep.log

echo "=== HHT Prediction Accuracy vs Generation Speed ===" | tee ${LOG}
echo "Date: $(date)" | tee -a ${LOG}
echo "" | tee -a ${LOG}

for ACC in 0 25 50 75 100; do
    echo "--- PREDICT_ACCURACY=${ACC}% ---" | tee -a ${LOG}
    PREDICT_ACCURACY=${ACC} bash script/run_tc_compare.sh 2>&1 | grep -E "Token\[|round done|PASS|FAIL|cycles" | tee -a ${LOG}
    echo "" | tee -a ${LOG}
done

echo "=== DONE ===" | tee -a ${LOG}
