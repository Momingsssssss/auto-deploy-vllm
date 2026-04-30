#!/bin/bash

# ================= 配置区域 =================
API_URL="http://localhost:8001/v1/chat/completions"  #服务IP和端口
MODEL_NAME="qwen3.5-27b"                             #模型name
TEST_FILE="/opt/models/auto/test_case.json"          #修改为实际路径/test_case.json
LOG_DIR="./api_test_results"                             #结果保存在容器内的/workspace/api_test_results
# =============================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

mkdir -p "$LOG_DIR"

echo -e "${BLUE}🚀 开始 API 自动化测试 (修复版)...${NC}"
echo "目标地址: $API_URL"
echo "----------------------------------------"

if ! command -v jq &> /dev/null; then
    echo -e "${RED}❌ 错误: 请安装 jq (yum install jq -y)${NC}"
    exit 1
fi

if [ ! -f "$TEST_FILE" ]; then
    echo -e "${RED}❌ 错误: 找不到 $TEST_FILE${NC}"
    exit 1
fi

TOTAL_CASES=$(jq length "$TEST_FILE")
PASS_COUNT=0
FAIL_COUNT=0

# 清空旧报告
echo "# API 测试报告" > "$LOG_DIR/report.md"
echo "生成时间: $(date)" >> "$LOG_DIR/report.md"
echo "---" >> "$LOG_DIR/report.md"

for ((i=0; i<TOTAL_CASES; i++)); do
    # 1. 提取数据 (保持原样)
    CASE_ID=$(jq -r ".[$i].id" "$TEST_FILE")
    CASE_NAME=$(jq -r ".[$i].name" "$TEST_FILE")
    PROMPT=$(jq -r ".[$i].prompt" "$TEST_FILE")
    TOOLS_JSON=$(jq ".[$i].tools" "$TEST_FILE")
    EXPECTED=$(jq -r ".[$i].expected_check" "$TEST_FILE")
    RESP_FORMAT=$(jq -r ".[$i].response_format // empty" "$TEST_FILE")

    echo -e "\n${YELLOW}[$((i+1))/$TOTAL_CASES] 正在测试: $CASE_NAME${NC}"
    
    # 2. 【核心修复】使用 jq 构建 Payload，彻底解决转义问题
    # 先构建基础消息体
    PAYLOAD=$(jq -n \
        --arg model "$MODEL_NAME" \
        --arg content "$PROMPT" \
        '{model: $model, messages: [{role: "user", content: $content}]}')

    # 如果有 tools，合并进去
    if [ "$TOOLS_JSON" != "[]" ] && [ -n "$TOOLS_JSON" ]; then
        PAYLOAD=$(echo "$PAYLOAD" | jq --argjson tools "$TOOLS_JSON" '. + {tools: $tools}')
    fi

    # 如果有 response_format，合并进去
    if [ "$RESP_FORMAT" == "json_object" ]; then
         PAYLOAD=$(echo "$PAYLOAD" | jq '. + {response_format: {type: "json_object"}}')
    fi
    
    # 此时 $PAYLOAD 已经是完美的 JSON 字符串了

    # 3. 发送请求
    START_TIME=$(date +%s%N)
    RESPONSE_FILE="$LOG_DIR/${CASE_ID}_response.json"
    
    HTTP_CODE=$(curl -s -w "%{http_code}" -o "$RESPONSE_FILE" \
        -X POST "$API_URL" \
        -H "Content-Type: application/json" \
        -d "$PAYLOAD")

    END_TIME=$(date +%s%N)
    DURATION=$(( (END_TIME - START_TIME) / 1000000 ))

    # 4. 验证结果
    TEST_STATUS="✅ PASS"
    STATUS_COLOR=$GREEN

    if [ "$HTTP_CODE" != "200" ]; then
        TEST_STATUS="❌ FAIL (HTTP $HTTP_CODE)"
        STATUS_COLOR=$RED
    else
        CONTENT=$(jq -r '.choices[0].message.content // empty' "$RESPONSE_FILE")
        TOOL_CALLS=$(jq -r '.choices[0].message.tool_calls // empty' "$RESPONSE_FILE")
        
        if [[ "$EXPECTED" == tool_call:* ]]; then
            TARGET_TOOL="${EXPECTED#tool_call:}"
            if echo "$TOOL_CALLS" | grep -q "$TARGET_TOOL"; then
                TEST_STATUS="✅ PASS (触发工具: $TARGET_TOOL)"
            else
                TEST_STATUS="❌ FAIL (未触发工具)"
                STATUS_COLOR=$RED
            fi
            
        elif [[ "$EXPECTED" == contains:* ]]; then
            TARGET_TEXT="${EXPECTED#contains:}"
            if echo "$CONTENT" | grep -q "$TARGET_TEXT"; then
                TEST_STATUS="✅ PASS"
            else
                TEST_STATUS="❌ FAIL (未包含关键词)"
                STATUS_COLOR=$RED
            fi

        elif [[ "$EXPECTED" == is_json ]]; then
             if echo "$CONTENT" | jq . > /dev/null 2>&1; then
                 TEST_STATUS="✅ PASS (合法 JSON)"
             else
                 TEST_STATUS="❌ FAIL (非法 JSON)"
                 STATUS_COLOR=$RED
             fi
        fi
    fi

    echo -e "${STATUS_COLOR}$TEST_STATUS${NC} (耗时: ${DURATION}ms)"
    
    if [[ "$TEST_STATUS" == ✅* ]]; then
        ((PASS_COUNT++))
    else
        ((FAIL_COUNT++))
    fi

    # 5. 写入报告
    echo "### $CASE_NAME" >> "$LOG_DIR/report.md"
    echo "- **状态**: $TEST_STATUS" >> "$LOG_DIR/report.md"
    echo "- **耗时**: ${DURATION}ms" >> "$LOG_DIR/report.md"
    echo "- **输入**: $PROMPT" >> "$LOG_DIR/report.md"
    echo "- **响应预览**: \`\`\`json\n$(cat "$RESPONSE_FILE" | head -c 200)...\n\`\`\`" >> "$LOG_DIR/report.md"
    echo "---" >> "$LOG_DIR/report.md"
done

echo ""
echo "========================================"
echo -e "🏁 测试完成。总计: $TOTAL_CASES, 通过: ${GREEN}$PASS_COUNT${NC}, 失败: ${RED}$FAIL_COUNT${NC}"
echo "详细报告: $LOG_DIR/report.md"
echo "========================================"
