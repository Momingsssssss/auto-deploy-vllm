#!/bin/bash
#参数说明
#IMAGE_NAME="quay.io/ascend/vllm-ascend"                 镜像name
#IMAGE_TAG="v0.18.0rc1"                                  镜像tag
#FULL_IMAGE_NAME="${IMAGE_NAME}:${IMAGE_TAG}"
#CONTAINER_NAME="vllm-test-container"                    容器name
#START_DOCKER_SCRIPT="/opt/models/auto/docker.sh"        启动容器的脚本所在路径
#BUILD_CONTEXT="/opt/model/auto/imagebuild"              dockerfile所在路径
#TARGET_URL="http://localhost:8001/health"               模型ip和端口
#START_VLLM="/opt/models/auto/start-vllm.sh"             启动服务脚本路径
#VLLM_BENCH="/opt/models/auto/vllm-bench.sh"             压测脚本路径
#FUNCTIONAL_TEST_SCRIPT="/opt/models/auto/api-test.sh"   功能检测脚本路径
# ================= 配置区域 =================
IMAGE_NAME="quay.io/ascend/vllm-ascend"
IMAGE_TAG="v0.18.0rc1"
FULL_IMAGE_NAME="${IMAGE_NAME}:${IMAGE_TAG}"
CONTAINER_NAME="vllm-test-container"
START_DOCKER_SCRIPT="/opt/models/auto/docker.sh"
BUILD_CONTEXT="/opt/model/test"
TARGET_URL="http://localhost:8001/health"
START_VLLM="/opt/models/auto/start-vllm.sh"
VLLM_BENCH="/opt/models/auto/vllm-bench.sh"
FUNCTIONAL_TEST_SCRIPT="/opt/models/auto/api-test.sh"
# =============================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ================= 函数：等待容器就绪 =================
wait_for_container() {
    local name=$1
    local timeout=60
    local interval=2
    local elapsed=0

    echo -e "${YELLOW}⏳ 正在等待容器 ${name} 启动...${NC}"

    while [ $elapsed -lt $timeout ]; do
        if docker ps --format '{{.Names}}\t{{.Status}}' --filter "name=^${name}$" | grep -q "Up"; then
            echo -e "${GREEN}✅ 容器 ${name} 已正常运行！${NC}"
            return 0
        fi
        sleep $interval
        elapsed=$((elapsed + interval))
        echo -n "."
    done

    echo ""
    echo -e "${RED}❌ 错误：等待容器启动超时 (${timeout}秒)${NC}"
    docker logs --tail 20 "$name"
    return 1
}

# ================= 函数：等待模型服务就绪 =================
wait_for_service() {
    local name=$CONTAINER_NAME
    local url=$TARGET_URL
    local timeout=300
    local interval=5
    local elapsed=0

    echo -e "${YELLOW}⏳ 正在等待模型服务 (${url}) 就绪...${NC}"

    while [ $elapsed -lt $timeout ]; do
        if docker exec "$name" curl -s -o /dev/null -w "%{http_code}" "$url" | grep -q "200"; then
            echo -e "\n${GREEN}✅ 模型服务已就绪！(耗时 ${elapsed}秒)${NC}"
            return 0
        fi
        sleep $interval
        elapsed=$((elapsed + interval))
        echo -n "."
    done

    echo ""
    echo -e "${RED}❌ 错误：等待模型服务启动超时。${NC}"
    docker logs --tail 50 "$name"
    return 1
}

echo -e "${YELLOW}🚀 开始自动化流程...${NC}"

# ----------------- 第一步：检查镜像与构建 -----------------
if docker image inspect "$FULL_IMAGE_NAME" &> /dev/null; then
    echo -e "${GREEN}✅ 镜像 ${FULL_IMAGE_NAME} 已存在，跳过构建步骤。${NC}"
else
    echo -e "${YELLOW}⚠️  镜像 ${FULL_IMAGE_NAME} 不存在，正在进入构建流程...${NC}"
    if [ ! -d "$BUILD_CONTEXT" ]; then
        echo -e "${RED}❌ 错误：构建目录 ${BUILD_CONTEXT} 不存在！${NC}"
        exit 1
    fi
    docker build -t "$FULL_IMAGE_NAME" "$BUILD_CONTEXT"
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✅ 镜像构建成功！${NC}"
    else
        echo -e "${RED}❌ 镜像构建失败，退出脚本。${NC}"
        exit 1
    fi
fi

# ----------------- 第二步：获取镜像 ID 并启动/重启容器 -----------------
echo -e "${YELLOW}🔍 正在查询镜像 ID...${NC}"
IMAGE_ID=$(docker inspect --format='{{.Id}}' "$FULL_IMAGE_NAME" 2>/dev/null | sed 's/sha256://g')

if [ -z "$IMAGE_ID" ]; then
    echo -e "${RED}❌ 错误：无法获取镜像 ID。${NC}"
    exit 1
fi
echo -e "${GREEN}✅ 获取到镜像 ID: ${IMAGE_ID:0:12}... ${NC}"

# --- 容器状态检测与处理 ---
echo -e "${YELLOW}🔄 检查容器 ${CONTAINER_NAME} 状态...${NC}"

if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    CONTAINER_STATUS=$(docker inspect --format='{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null)
    
    if [ "$CONTAINER_STATUS" = "running" ]; then
        echo -e "${YELLOW}🔄 容器正在运行，正在重启...${NC}"
        docker restart "$CONTAINER_NAME"
        # 等待容器重启基本完成，避免端口冲突
        sleep 5 
    elif [ "$CONTAINER_STATUS" = "exited" ]; then
        echo -e "${YELLOW}🔄 发现已停止的容器，正在启动...${NC}"
        docker start "$CONTAINER_NAME"
    else
        echo -e "${YELLOW}ℹ️  发现容器处于 ${CONTAINER_STATUS} 状态，尝试启动...${NC}"
        docker start "$CONTAINER_NAME" || { echo -e "${RED}❌ 启动失败${NC}"; exit 1; }
    fi
    
    if ! wait_for_container "$CONTAINER_NAME"; then exit 1; fi
else
    echo -e "${YELLOW}🆕 容器不存在，正在创建...${NC}"
    if [ -f "$START_DOCKER_SCRIPT" ]; then
        chmod +x "$START_DOCKER_SCRIPT"
        bash "$START_DOCKER_SCRIPT" "$IMAGE_ID" "$CONTAINER_NAME"
        if ! wait_for_container "$CONTAINER_NAME"; then exit 1; fi
    else
        echo -e "${RED}❌ 未找到启动脚本${NC}"; exit 1
    fi
fi

# ----------------- 第三步：执行测试与双阶段日志监控 -----------------

echo "正在进入容器执行模型拉起与测试..."

CONTAINER_WORKDIR="/workspace"

# ==========================================
# 阶段 A: 监控 vllm.log (模型加载)
# ==========================================
echo -e "${YELLOW}>>> 正在后台启动模型...${NC}"
# 1. 启动模型 (后台)
docker exec "$CONTAINER_NAME" bash -c \
    "cd ${CONTAINER_WORKDIR} && chmod +x \"${START_VLLM}\" && nohup \"${START_VLLM}\" > vllm.log 2>&1 &"

# 2. 【无Sleep等待】利用 tail -F (大写) 阻塞等待文件出现
echo -e "${YELLOW}⏳ 等待日志文件 vllm.log 创建...${NC}"
docker exec "$CONTAINER_NAME" tail -F "${CONTAINER_WORKDIR}/vllm.log" > /dev/null 2>&1 &
WAIT_PID=$!

# 等待这个 tail 进程退出（意味着文件找到了），或者超时
timeout 30 tail --pid=$WAIT_PID -f /dev/null 2>/dev/null
kill $WAIT_PID 2>/dev/null

# 3. 开启实时监控管道
echo -e "${GREEN}🖨️  [监控中] 实时打印 vllm.log...${NC}"
docker exec "$CONTAINER_NAME" tail -f "${CONTAINER_WORKDIR}/vllm.log" | cat &
TAIL_PID=$!

# 4. 等待服务就绪
if ! wait_for_service "$CONTAINER_NAME" "$TARGET_URL"; then
    kill $TAIL_PID 2>/dev/null
    exit 1
fi

# 5. 停止第一阶段监控
echo -e "${YELLOW}⏹️  模型加载完成，停止打印 vllm.log。${NC}"
kill $TAIL_PID
wait $TAIL_PID 2>/dev/null

# ==========================================
# 阶段 A+: 功能检查 (Smoke Test) - 后台运行 + 实时监控
# ==========================================
echo -e "\n${YELLOW}🔍 正在进行功能自检 (Smoke Test)...${NC}"
echo -e "${YELLOW}ℹ️  启动后台任务，日志将保存至 api.log 并实时打印...${NC}"
echo "----------------------------------------"

# 1. 在容器内后台启动测试脚本，并重定向输出到 api.log
# 使用 nohup 防止进程挂起，使用 & 放入后台
docker exec "$CONTAINER_NAME" bash -c \
    "cd ${CONTAINER_WORKDIR} && chmod +x '$FUNCTIONAL_TEST_SCRIPT' && nohup '$FUNCTIONAL_TEST_SCRIPT' > api.log 2>&1 &"

# 2. 实时监控日志输出 (在宿主机显示)
# 这会像水流一样把容器内的 api.log 打印到当前屏幕
docker exec "$CONTAINER_NAME" tail -f "${CONTAINER_WORKDIR}/api.log" | cat &
TEST_TAIL_PID=$!

# 3. 等待测试进程结束
# 这里使用 pgrep 检查脚本进程是否还在运行
# 假设你的 api-test.sh 脚本名字里包含 "api-test" 或者你可以用 "bash" (如果唯一)
echo -e "${YELLOW}⏳ 功能测试进行中... (等待进程结束)${NC}"
while docker exec "$CONTAINER_NAME" pgrep -f "$(basename $FUNCTIONAL_TEST_SCRIPT)" > /dev/null 2>&1; do
    sleep 0.5
done

# 4. 收尾：停止日志监控
sleep 1 # 给最后几行日志一点缓冲时间
kill $TEST_TAIL_PID 2>/dev/null
wait $TEST_TAIL_PID 2>/dev/null

# 5. 获取测试结果 (读取 api.log 中的退出状态记录，或者直接读取 $?)
# 这里我们直接读取容器内脚本执行后的退出码最为准确
TEST_EXIT_CODE=$(docker exec "$CONTAINER_NAME" bash -c "cd $CONTAINER_WORKDIR && tail -n 1 api.log; echo \$?")

echo "----------------------------------------"

if [ "$TEST_EXIT_CODE" -ne "0" ]; then
    echo -e "${RED}❌ 功能检查未通过！(退出码: $TEST_EXIT_CODE)${NC}"
    echo -e "${RED}⛔ 阻止基准测试启动。请检查上方日志修复问题。${NC}"
    exit 1
else
    echo -e "${GREEN}✅ 功能检查完全通过！所有测试用例 OK！${NC}"
    echo -e "${GREEN}🚀 准备开始基准测试...${NC}"
fi

# ==========================================
# 阶段 B: 监控 bench.log (基准测试)
# ==========================================
echo -e "${YELLOW}>>> 正在执行基准测试...${NC}"

# 1. 启动测试 (后台)
docker exec "$CONTAINER_NAME" bash -c \
    "cd ${CONTAINER_WORKDIR} && chmod +x \"${VLLM_BENCH}\" && nohup \"${VLLM_BENCH}\" > bench.log 2>&1 &"

# 2. 【无Sleep等待】等待 bench.log 文件被创建
echo -e "${YELLOW}⏳ 等待日志文件 bench.log 创建...${NC}"
docker exec "$CONTAINER_NAME" tail -F "${CONTAINER_WORKDIR}/bench.log" > /dev/null 2>&1 &
BENCH_WAIT_PID=$!

# 等待文件出现（最多等 10 秒，通常很快）
timeout 10 tail --pid=$BENCH_WAIT_PID -f /dev/null 2>/dev/null
kill $BENCH_WAIT_PID 2>/dev/null

# 检查文件是否真的存在了
if ! docker exec "$CONTAINER_NAME" test -f "${CONTAINER_WORKDIR}/bench.log"; then
    echo -e "${RED}❌ 错误：基准测试未能生成日志文件。${NC}"
    exit 1
fi

# 3. 开启第二阶段实时监控管道
echo -e "${GREEN}🖨️  [监控中] 实时打印 bench.log...${NC}"
docker exec "$CONTAINER_NAME" tail -f "${CONTAINER_WORKDIR}/bench.log" | cat &
BENCH_TAIL_PID=$!

# 4. 【无Sleep等待】动态监测进程存活
echo -e "${YELLOW}⏳ 基准测试进行中...${NC}"
while docker exec "$CONTAINER_NAME" pgrep -f "vllm-bench" > /dev/null 2>&1; do
    sleep 0.5
done

# 5. 收尾
sleep 1 # 确保最后几行日志刷出来
kill $BENCH_TAIL_PID 2>/dev/null
wait $BENCH_TAIL_PID 2>/dev/null

echo -e "${GREEN}✅ 基准测试进程已结束。${NC}"
echo -e "${GREEN}🎉 所有流程执行完毕。${NC}"
