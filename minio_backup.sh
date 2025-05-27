#!/bin/bash

############################
### 用户配置区域（必须修改）###
############################

declare -A MONITOR_DIRS=(
    # 格式：["本地目录"]="Minio存储路径 保留策略(delete/retain) 保留版本数"
    ["/www/backup/site"]="web_backups retain 3"         # 示例：删除源文件，保留5个版本
    #["/home/user/docs"]="documents delete 10"  # 保留源文件，保留10个版本
    #["/home/user/docs"]="documents delete"  # 保留源文件，保留所有版本
)

# 全局配置参数
GLOBAL_RETRIES=6                     # 所有操作默认重试次数
UPLOAD_RETRIES=6                     # 文件上传独立重试次数
MINIO_ALIAS="mybuckets"               # MinIO别名
ENDPOINT="https://minio.com"      # MinIO服务器地址
ACCESS_KEY="xxxxxx"             # 访问密钥
SECRET_KEY="xxxxxx"             # 私有密钥
BUCKET_NAME="buckets"             # 存储桶名称
LOG_DIR="/var/log/minio_backups"    # 日志目录
LOG_RETAIN_DAYS=7                  # 日志保留天数
TELEGRAM_BOT_TOKEN="xxxxxx" # Telegram机器人Token
TELEGRAM_CHAT_ID="xxxxxx"     # Telegram聊天ID
HOSTNAME="test"                # 主机名（可选）

##############################
### 脚本核心功能（无需修改）###
##############################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 新增通用重试函数
retry_operation() {
    local retries=$1
    local cmd="$2"
    local success_msg="$3"
    local failure_msg="$4"
    local log_level="${5:-ERROR}"
    local args=("${@:6}")

    local attempt=1
    while (( attempt <= retries )); do
        if eval "$cmd" "${args[@]}"; then
            [[ -n "$success_msg" ]] && log "INFO" "$success_msg"
            return 0
        else
            local error_output=$(eval "$cmd" "${args[@]}" 2>&1)
            if (( attempt < retries )); then
                log "WARN" "${failure_msg} (第 ${attempt}/${retries} 次重试)"
                sleep $(( attempt * 2 ))  # 指数退避
            else
                log "$log_level" "${failure_msg} (错误详情: ${error_output})"
            fi
            ((attempt++))
        fi
    done
    return 1
}

init_logging() {
    mkdir -p "$LOG_DIR" || {
        echo -e "${RED}✗ 无法创建日志目录: $LOG_DIR${NC}" >&2
        exit 1
    }
    find "$LOG_DIR" -name "minio_backup_*.log" -mtime +$LOG_RETAIN_DAYS -delete 2>/dev/null
    LOG_FILE="$LOG_DIR/minio_backup_$(date +%Y-%m-%d).log"
    touch "$LOG_FILE" || exit 1
}

send_telegram() {
    local msg="[MinIO Backup $1]
🕒 $(date +'%Y-%m-%d %H:%M:%S')
🖥️ "$HOSTNAME"
📝 $2"
    curl -s -X POST -H "Content-Type: application/json" \
        -d "{\"chat_id\": \"$TELEGRAM_CHAT_ID\", \"text\": \"$msg\"}" \
        "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" >/dev/null
}

log() {
    local level="$1"
    local message="$2"
    local entry="$(date +'%Y-%m-%d %H:%M:%S') [${level}] ${message}"
    echo "$entry" >> "$LOG_FILE"

    # 增强通知逻辑
    case "$level" in
        ERROR)
            send_telegram "🚨 严重错误" "${message}"
            ;;
        WARN)
            send_telegram "⚠️ 警告通知" "${message}"
            ;;
        INFO)
            if [[ "$message" =~ (上传成功|删除旧版本|服务启动|服务停止) ]]; then
                send_telegram "ℹ️ 操作通知" "${message}"
            fi
            ;;
    esac
}

check_dependencies() {
    declare -A PKG_MAP=(
        [inotifywait]="inotify-tools"
        [jq]="jq"
        [curl]="curl"
    )

    detect_pkg_manager() {
        if command -v apt-get &>/dev/null; then echo "apt"
        elif command -v yum &>/dev/null; then
            if ! yum repolist | grep -q epel; then
                sudo yum install -y epel-release &>/dev/null
            fi
            echo "yum"
        elif command -v dnf &>/dev/null; then echo "dnf"
        else exit 1; fi
    }

    install_pkg() {
        local pkg=$1 manager=$(detect_pkg_manager)
        case $manager in
            apt) sudo apt-get install -y "$pkg" ;;
            yum|dnf) sudo $manager install -y "$pkg" ;;
        esac || {
            log "ERROR" "$pkg 安装失败"
            exit 1
        }
    }

    # 检查并安装mc客户端
    if ! command -v mc &>/dev/null; then
        log "WARN" "正在安装MinIO客户端(mc)..."
        install_mc
        command -v mc &>/dev/null || {
            log "ERROR" "mc客户端安装失败"
            exit 1
        }
    fi

    # 检查其他依赖
    for cmd in inotifywait jq curl; do
        if ! command -v "$cmd" &>/dev/null; then
            log "WARN" "正在安装 ${PKG_MAP[$cmd]}..."
            install_pkg "${PKG_MAP[$cmd]}"
            command -v "$cmd" &>/dev/null || {
                log "ERROR" "${PKG_MAP[$cmd]} 安装后验证失败"
                exit 1
            }
        fi
    done
}

install_mc() {
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) ARCH="amd64" ;;
        arm64|aarch64) ARCH="arm64" ;;
        *) log "ERROR" "不支持的架构: $ARCH"; exit 1 ;;
    esac

    MC_URL="https://dl.min.io/client/mc/release/linux-${ARCH}/mc"
    TEMP_FILE=$(mktemp)
    wget --show-progress -q "$MC_URL" -O "$TEMP_FILE" || {
        log "ERROR" "mc下载失败"; exit 1
    }
    sudo install -m 0755 "$TEMP_FILE" /usr/local/bin/mc || exit 1
    mc --version &>/dev/null || {
        log "ERROR" "mc验证失败"; exit 1
    }
}

parse_directory_config() {
    IFS=' ' read -ra parts <<< "$1"
    REMOTE_PATH="${parts[0]}"
    RETENTION_POLICY="${parts[1]:-delete}"
    RETAIN_VERSIONS="${parts[2]:-0}"
    [[ ! "$RETENTION_POLICY" =~ ^(delete|retain)$ ]] && {
        log "ERROR" "无效策略: $RETENTION_POLICY"; exit 1
    }
    [[ ! "$RETAIN_VERSIONS" =~ ^[0-9]+$ ]] && {
        log "ERROR" "无效版本数: $RETAIN_VERSIONS"; exit 1
    }
}

cleanup_versions() {
    local prefix="$1"
    local retain="$2"
    local full_path="${MINIO_ALIAS}/${BUCKET_NAME}/${prefix}"
    
    log "DEBUG" "开始清理路径: $full_path"

    if ! mc ls "$full_path" &>/dev/null; then
        log "WARN" "存储桶路径不存在: $full_path"
        return 1
    fi

    local total_versions=$(mc ls --json "$full_path" | jq -r 'select(.type == "file") | .key' | wc -l)
    log "DEBUG" "当前版本数: $total_versions | 保留数: $retain"

    if (( total_versions > retain )); then
        local delete_list=$(mc ls --json "$full_path" | \
            jq -r 'select(.type == "file") | .lastModified + " " + .key' | \
            sort -r | awk -v retain="$retain" 'NR>retain {print $2}')
        
        if [ -z "$delete_list" ]; then
            log "INFO" "无需要清理的旧版本"
            return
        fi

        while IFS= read -r object; do
            retry_operation $GLOBAL_RETRIES \
                "mc rm -r --force \"${full_path}/${object}\"" \
                "成功删除旧版本: $object" \
                "对象删除失败: $object" \
                "ERROR"
        done <<< "$delete_list"
    else
        log "INFO" "当前版本数 ${total_versions} ≤ 保留数 ${retain}，无需清理"
    fi
}

process_file() {
    parse_directory_config "$3"
    local relative_path=$(realpath --relative-to="$2" "$1")
    local remote_path="${REMOTE_PATH%/}/${relative_path#/}"
    local file_name=$(basename "$1")

    log "DEBUG" "尝试上传到: ${MINIO_ALIAS}/${BUCKET_NAME}/${remote_path}"
    
    # 使用重试函数处理上传
    if retry_operation $UPLOAD_RETRIES \
        "mc cp \"$1\" \"${MINIO_ALIAS}/${BUCKET_NAME}/${remote_path}\"" \
        "文件上传成功: $1 → ${remote_path}" \
        "文件上传失败: $file_name" \
        "ERROR"; then

        if (( RETAIN_VERSIONS > 0 )); then
            cleanup_versions "$(dirname "${remote_path}")" "${RETAIN_VERSIONS}"
        fi

        case "$RETENTION_POLICY" in
            delete)
                retry_operation $GLOBAL_RETRIES \
                    "rm -f \"$1\"" \
                    "已删除源文件: $file_name" \
                    "源文件删除失败: $file_name" \
                    "ERROR" \
                    || log "DEBUG" "文件状态: $(ls -l \"$1\" 2>&1)"
                ;;
            retain)
                log "INFO" "保留源文件: $file_name"
                ;;
        esac
        return 0
    else
        return 1
    fi
}

start_monitoring() {
    local monitor_dirs=""
    for dir in "${!MONITOR_DIRS[@]}"; do
        monitor_dirs+=" \"$dir\""
    done

    eval inotifywait -m -r -e close_write --format '%w%f' ${monitor_dirs} | \
    while read -r file; do
        [ -d "$file" ] && continue
        for dir in "${!MONITOR_DIRS[@]}"; do
            if [[ "$file" == "$dir"* ]]; then
                log "INFO" "检测到新文件: $file"
                process_file "$file" "$dir" "${MONITOR_DIRS[$dir]}"
                break
            fi
        done
    done
}

validate_environment() {
    # 强制覆盖MinIO别名配置
    if mc alias list | grep -q "$MINIO_ALIAS"; then
        mc alias remove "$MINIO_ALIAS" >/dev/null 2>&1
    fi

    # 配置MinIO连接（静默模式）
    if ! mc alias set "$MINIO_ALIAS" "$ENDPOINT" "$ACCESS_KEY" "$SECRET_KEY" --api s3v4 >/dev/null 2>&1; then
        log "ERROR" "MinIO连接配置失败（检查地址/密钥/网络）"
        exit 1
    fi

    # 存储桶名称校验
    if [[ ! "$BUCKET_NAME" =~ ^[a-z0-9-]{3,63}$ ]]; then
        log "ERROR" "存储桶名称非法：需小写字母、数字、短横线(3-63字符)"
        exit 1
    fi

    # 创建存储桶（带静默检测）
    if ! mc ls "${MINIO_ALIAS}/${BUCKET_NAME}" >/dev/null 2>&1; then
        if ! mc mb "${MINIO_ALIAS}/${BUCKET_NAME}" >/dev/null 2>&1; then
            log "ERROR" "存储桶创建失败（名称冲突或权限不足）"
            exit 1
        fi
    fi

    # 设置存储桶策略
    if ! mc policy set readwrite "${MINIO_ALIAS}/${BUCKET_NAME}" >/dev/null 2>&1; then
        log "ERROR" "存储桶权限配置失败"
        exit 1
    fi

    # 验证监控目录
    for dir in "${!MONITOR_DIRS[@]}"; do
        if [ ! -d "$dir" ]; then
            log "ERROR" "监控目录不存在：$dir"
            exit 1
        fi
        if [ ! -w "$dir" ]; then
            log "ERROR" "目录不可写：$dir"
            exit 1
        fi
    done

    # 最终连接验证
    if ! mc ls "$MINIO_ALIAS" >/dev/null 2>&1; then
        log "ERROR" "MinIO服务不可用"
        exit 1
    fi
}

main() {
    init_logging
    check_dependencies
    validate_environment
    log "INFO" "🟢 服务启动"
    start_monitoring
}

trap 'log "INFO" "🔴 服务停止"; exit 0' SIGINT SIGTERM
main
