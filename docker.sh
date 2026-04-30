#!/bin/bash

# 1. 先检查参数数量
if [ $# -ne 2 ]; then
    echo "Usage: $0 <image_id> <container_name>"
    echo "Error: Need exactly 2 arguments."
    exit 1
fi

# 2. 再赋值参数
IMAGES_ID=$1
NAME=$2

# 3. 执行 docker run
docker run --name "${NAME}" \
    -it \
    -d \
    --net=host \
    --shm-size=500g \
    --privileged=true \
    -w /home \
	--device /dev/davinci0 \
    --device /dev/davinci1 \
    --device /dev/davinci2 \
    --device /dev/davinci3 \
    --device /dev/davinci4 \
    --device /dev/davinci5 \
    --device /dev/davinci6 \
    --device /dev/davinci7 \
    --device=/dev/davinci_manager \
    --device=/dev/hisi_hdc \
    --device=/dev/devmm_svm \
    --entrypoint=sh \
    -v /usr/local/Ascend/driver:/usr/local/Ascend/driver \
    -v /usr/local/dcmi:/usr/local/dcmi \
    -v /usr/local/bin/npu-smi:/usr/local/bin/npu-smi \
    -v /usr/local/sbin:/usr/local/sbin \
    -v /home/:/home \
    -v /tmp:/tmp \
    -v /usr/share/zoneinfo/Asia/Shanghai:/etc/localtime \
    -e http_proxy=$http_proxy \
    -e https_proxy=$https_proxy \
    "${IMAGES_ID}"

echo "Container '${NAME}' started successfully."

