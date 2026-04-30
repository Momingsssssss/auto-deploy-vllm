#!/bin/bash

# 基础配置
MODEL_PATH="/opt/models/Qwen3.5-27B/"
SERVED_MODEL_NAME="qwen3.5-27b"
BASE_URL="http://localhost:8001"
BASE_RESULT_DIR="./log-auto"

# 参数组：格式 "max_concurrency request_rate input_len output_len num_prompt"
PARAM_GROUPS=(
    "5 5 1024 1024 20"
    "5 5 512 512 50"
)

# 确保结果目录存在
mkdir -p "$BASE_RESULT_DIR"

# 遍历每组参数
for group in "${PARAM_GROUPS[@]}"; do
    read -r max_conc req_rate input_len output_len num_prompt <<< "$group"

    # 构建目标文件名（不含路径）
    TARGET_FILENAME="${max_conc}-${req_rate}-${input_len}-${output_len}-${num_prompt}.json"
    TARGET_PATH="$BASE_RESULT_DIR/$TARGET_FILENAME"
    echo "Running benchmark for group: $max_conc-$req_rate-$input_len-$output_len-$num_prompt"
    echo "Will save result as: $TARGET_PATH"

    # 运行 vLLM bench，结果保存到统一目录
    vllm bench serve \
        --model "$MODEL_PATH" \
        --served-model-name "$SERVED_MODEL_NAME" \
        --dataset-name random \
        --max_concurrency "$max_conc" \
        --request-rate "$req_rate" \
        --random-input-len "$input_len" \
        --random-output-len "$output_len" \
        --num-prompt "$num_prompt" \
        --trust-remote-code \
        --base-url "$BASE_URL" \
        --save-result \
        --disable-tqdm \
        --result-dir "$BASE_RESULT_DIR"

    mv "$BASE_RESULT_DIR"/openai* "$TARGET_PATH"
    echo "Completed group: $max_conc-$req_rate-$input_len-$output_len-$num_prompt"
    echo "----------------------------------------"
done

echo "All groups completed."
