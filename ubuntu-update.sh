#!/bin/bash

# 색상 정의
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 로그 함수
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Docker 컨테이너 헬스체크 대기 함수
wait_for_healthy() {
    local compose_path=$1
    local max_wait=${2:-300}  # 기본 최대 대기 시간: 5분
    local min_uptime=${3:-15}  # health check 없는 컨테이너의 최소 실행 시간: 15초
    local interval=5
    local elapsed=0

    log_info "컨테이너 초기화 대기 중..."

    # 컨테이너 목록 가져오기
    local containers=$(docker-compose -f "$compose_path" ps -q)

    if [ -z "$containers" ]; then
        log_warn "실행 중인 컨테이너가 없습니다."
        return 0
    fi

    while [ $elapsed -lt $max_wait ]; do
        local all_healthy=true
        local status_info=""

        for container in $containers; do
            local health=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null | tr -d '\n\r' || echo "none")
            local status=$(docker inspect --format='{{.State.Status}}' "$container" 2>/dev/null | tr -d '\n\r' || echo "unknown")
            local name=$(docker inspect --format='{{.Name}}' "$container" 2>/dev/null | sed 's/\///' | tr -d '\n\r')

            # health check가 정의되지 않은 경우 (패턴 매칭 사용)
            if [[ "$health" == *"none"* ]] || [[ "$health" == *"no value"* ]] || [ -z "$health" ]; then
                if [[ "$status" != *"running"* ]]; then
                    all_healthy=false
                    status_info="${status_info}\n  - $name: $status (not running)"
                else
                    # 컨테이너 시작 시간 확인
                    local started_at=$(docker inspect --format='{{.State.StartedAt}}' "$container" 2>/dev/null | tr -d '\n\r')
                    local started_epoch=$(date -d "$started_at" +%s 2>/dev/null || echo "0")
                    local current_epoch=$(date +%s)
                    local uptime=$((current_epoch - started_epoch))

                    if [ $uptime -lt $min_uptime ]; then
                        all_healthy=false
                        status_info="${status_info}\n  - $name: running (uptime: ${uptime}s, waiting for ${min_uptime}s)"
                    else
                        status_info="${status_info}\n  - $name: running (uptime: ${uptime}s, no healthcheck)"
                    fi
                fi
            else
                # health check가 있는 경우
                if [[ "$health" != *"healthy"* ]]; then
                    all_healthy=false
                    status_info="${status_info}\n  - $name: $health"
                else
                    status_info="${status_info}\n  - $name: healthy"
                fi
            fi
        done

        if [ "$all_healthy" = true ]; then
            log_info "모든 컨테이너가 정상 상태입니다!"
            echo -e "$status_info"
            return 0
        fi

        echo -ne "\r대기 중... ${elapsed}/${max_wait}초 경과\n"
        echo -ne "$status_info"
        sleep $interval
        elapsed=$((elapsed + interval))
    done

    log_warn "최대 대기 시간(${max_wait}초) 초과. 현재 상태:"
    echo -e "$status_info"
    return 1
}

# 스크립트 실행 디렉토리
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 루트 권한 확인
if [ "$EUID" -ne 0 ]; then
    log_error "이 스크립트는 root 권한이 필요합니다. sudo를 사용해주세요."
    exit 1
fi


log_info "=== 시스템 업데이트 스크립트 시작 ==="
log_info "작업 디렉토리: $SCRIPT_DIR"

# 0. Git 저장소 업데이트 확인 및 자동 재실행
log_info "Step 0: 스크립트 업데이트 확인"

if [ -d "$SCRIPT_DIR/.git" ]; then
    log_info "Git 저장소에서 최신 버전 확인 중..."

    cd "$SCRIPT_DIR" || {
        log_error "작업 디렉토리로 이동 실패"
        exit 1
    }

    # 현재 커밋 해시 저장
    CURRENT_COMMIT=$(git rev-parse HEAD 2>/dev/null)

    # git pull 실행
    if git pull origin main 2>&1 | tee /tmp/git-pull-output.log; then
        # pull 후 커밋 해시 확인
        NEW_COMMIT=$(git rev-parse HEAD 2>/dev/null)

        if [ "$CURRENT_COMMIT" != "$NEW_COMMIT" ]; then
            log_info "스크립트가 업데이트되었습니다!"
            log_info "새 버전으로 재실행합니다..."
            echo ""

            # 스크립트 재실행 (모든 인자 전달)
            exec "$0" "$@"
        else
            log_info "이미 최신 버전입니다."
        fi
    else
        log_warn "Git pull 실패. 현재 버전으로 계속 진행합니다."
        log_warn "오류 내용: $(cat /tmp/git-pull-output.log)"
    fi
else
    log_warn "Git 저장소가 아닙니다. 업데이트 확인을 건너뜁니다."
fi

echo ""

# 1. Docker Compose 이미지 업데이트
log_info "Step 1: Docker Compose 이미지 업데이트 시작"

COMPOSE_LIST="$SCRIPT_DIR/compose-list.txt"

if [ -f "$COMPOSE_LIST" ]; then
    log_info "compose-list.txt에서 경로 목록을 읽어옵니다..."

    # 성공/실패 카운터
    SUCCESS_COUNT=0
    FAIL_COUNT=0
    TOTAL_COUNT=0

    while IFS= read -r compose_path || [ -n "$compose_path" ]; do
        # 빈 줄이나 주석(#으로 시작) 건너뛰기
        [[ -z "$compose_path" || "$compose_path" =~ ^[[:space:]]*# ]] && continue

        TOTAL_COUNT=$((TOTAL_COUNT + 1))
        COMPOSE_DIR="$(dirname "$compose_path")"

        log_info "[$TOTAL_COUNT] 처리 중: $compose_path"

        if [ ! -f "$compose_path" ]; then
            log_warn "파일을 찾을 수 없습니다: $compose_path"
            FAIL_COUNT=$((FAIL_COUNT + 1))
            continue
        fi

        cd "$COMPOSE_DIR" || {
            log_error "디렉토리 이동 실패: $COMPOSE_DIR"
            FAIL_COUNT=$((FAIL_COUNT + 1))
            continue
        }

        log_info "최신 이미지 다운로드 중..."
        if docker-compose pull; then
            log_info "컨테이너 재시작 중..."
            if docker-compose down && docker-compose up -d; then
                # 컨테이너 초기화 대기
                if wait_for_healthy "$compose_path"; then
                    log_info "업데이트 완료: $compose_path"
                    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
                else
                    log_warn "컨테이너가 완전히 초기화되지 않았지만 계속 진행합니다: $compose_path"
                    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
                fi
            else
                log_error "컨테이너 재시작 실패: $compose_path"
                FAIL_COUNT=$((FAIL_COUNT + 1))
            fi
        else
            log_error "이미지 다운로드 실패: $compose_path"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi

        echo ""
    done < "$COMPOSE_LIST"

    # 결과 요약
    log_info "Docker Compose 업데이트 완료 - 성공: $SUCCESS_COUNT, 실패: $FAIL_COUNT, 전체: $TOTAL_COUNT"

    if [ $FAIL_COUNT -gt 0 ]; then
        log_warn "일부 Docker Compose 업데이트가 실패했습니다."
    fi
else
    log_warn "compose-list.txt 파일을 찾을 수 없습니다. Docker 업데이트를 건너뜁니다."
fi

# 2. 사용하지 않는 Docker 이미지 제거
log_info "Step 2: 사용하지 않는 Docker 이미지 제거"
docker image prune -af
log_info "Docker 이미지 정리 완료"

# 3. APT 업데이트
log_info "Step 3: APT 패키지 목록 업데이트"
if apt update; then
    log_info "APT 업데이트 완료"
else
    log_error "APT 업데이트 실패"
    exit 1
fi

# 4. APT 업그레이드
log_info "Step 4: APT 패키지 업그레이드"
if DEBIAN_FRONTEND=noninteractive apt upgrade -y; then
    log_info "APT 업그레이드 완료"
else
    log_error "APT 업그레이드 실패"
    exit 1
fi

# 5. 불필요한 패키지 제거 및 캐시 정리
log_info "Step 5: 시스템 정리"
apt autoremove -y
apt autoclean -y
log_info "시스템 정리 완료"

# 6. 재부팅 필요 여부 확인
log_info "Step 6: 재부팅 필요 여부 확인"
if [ -f /var/run/reboot-required ]; then
    log_warn "시스템 재부팅이 필요합니다."
    log_info "10초 후 자동으로 재부팅됩니다..."

    for i in {10..1}; do
        echo -ne "\r재부팅까지 ${i}초 남음... (Ctrl+C로 취소 가능)"
        sleep 1
    done
    echo ""

    log_info "시스템 재부팅 중..."
    reboot
else
    log_info "재부팅이 필요하지 않습니다."
fi

log_info "=== 모든 업데이트 작업 완료 ==="