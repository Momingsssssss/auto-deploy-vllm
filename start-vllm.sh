export TASK_QUEUE_ENABLE=1
export OMP_NUM_THREADS=1
export PYTORCH_NPU_ALLOC_CONF=expandable_segments:True
export ASCEND_RT_VISIBLE_DEVICES=6,7

vllm serve /opt/models/Qwen3.5-27B/ \
--host 0.0.0.0 \
--port 8001 \
--data-parallel-size 1 \
--tensor-parallel-size 2 \
--seed 1024 \
--served-model-name qwen3.5-27b \
--max-num-seqs 32 \
--max-model-len 65536 \
--max-num-batched-tokens 16384 \
--trust-remote-code \
--enable-prefix-caching \
--enable-auto-tool-choice \
--tool-call-parser qwen3_coder \
--enable-chunked-prefill \
--default-chat-template-kwargs '{"enable_thinking":true}' \
--gpu-memory-utilization 0.92 \
--compilation-config '{"cudagraph_mode": "FULL_DECODE_ONLY"}'
