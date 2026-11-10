#!/bin/bash

# 색상 정의
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Docker 컨테이너 로그 크기 제한 (컨테이너를 (재)생성할 때 적용, json-file/local 드라이버 기준)
#   DOCKER_LOG_MAX_SIZE: 로그 파일 하나의 최대 크기 (예: 10m, 50m, 1g). 0이면 제한을 적용하지 않음
#   DOCKER_LOG_MAX_FILE: 로테이션으로 보관할 로그 파일 개수
# 환경변수로 덮어쓸 수 있다. 예: sudo DOCKER_LOG_MAX_SIZE=50m DOCKER_LOG_MAX_FILE=5 ./ubuntu-update.sh
DOCKER_LOG_MAX_SIZE="${DOCKER_LOG_MAX_SIZE:-10m}"
DOCKER_LOG_MAX_FILE="${DOCKER_LOG_MAX_FILE:-3}"

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

# 목록 파일(compose-list.txt, git-list.txt)에서 유효한 항목(한 줄에 경로 하나)만 출력
# CR 제거, 앞뒤 공백 제거, 빈 줄과 #으로 시작하는 주석 줄은 제외
read_list_entries() {
    local line

    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" || "$line" == \#* ]] && continue
        printf '%s\n' "$line"
    done < "$1"
}

# 디렉토리의 Git 저장소를 현재 브랜치 기준으로 pull (fast-forward만 허용)
# 무인 실행 중 병합 커밋이 생기거나 충돌 상태로 남지 않도록 하고, 실패하면 경고만 남긴다.
# 반환: 0=성공, 1=실패 (브랜치 감지 불가 / detached HEAD / pull 실패)
git_pull_repo() {
    local dir=$1
    local branch

    branch=$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    if [ -z "$branch" ]; then
        log_warn "현재 브랜치 정보를 얻을 수 없어 git pull을 건너뜁니다: $dir"
        return 1
    fi
    if [ "$branch" = "HEAD" ]; then
        log_warn "detached HEAD 상태라 git pull을 건너뜁니다: $dir"
        return 1
    fi

    log_info "Git 저장소 발견 (브랜치: $branch). 최신 커밋을 가져옵니다..."
    # stdin을 닫아 목록을 읽는 루프의 입력을 소비하거나 자격 증명 프롬프트에서 멈추는 일을 방지
    if GIT_TERMINAL_PROMPT=0 git -C "$dir" pull --ff-only origin "$branch" < /dev/null; then
        log_info "Git pull 성공: $dir (브랜치: $branch)"
    else
        log_warn "Git pull 실패 (fast-forward 불가·충돌·네트워크/인증 문제): $dir (브랜치: $branch). 계속 진행합니다. (상세: $RUN_LOG)"
        return 1
    fi
}

# Docker 컨테이너 헬스체크 대기 함수
wait_for_healthy() {
    local compose_path=$1
    local log_file=${2:-}
    local max_wait=${3:-300}  # 기본 최대 대기 시간: 5분
    local min_uptime=${4:-15}  # health check 없는 컨테이너의 최소 실행 시간: 15초
    local interval=5
    local elapsed=0

    log_info "컨테이너 초기화 대기 중..."

    # 컨테이너 목록 가져오기 (로그가 지정되면 stderr를 로그에 기록)
    local containers
    if [ -n "$log_file" ]; then
        containers=$(docker compose -f "$compose_path" ps -q 2>>"$log_file")
    else
        containers=$(docker compose -f "$compose_path" ps -q 2>/dev/null)
    fi

    if [ -z "$containers" ]; then
        log_warn "실행 중인 컨테이너가 없습니다."
        return 0
    fi

    while [ $elapsed -lt $max_wait ]; do
        local all_healthy=true
        local status_info=""

        for container in $containers; do
            local health
            local status
            local name
            if [ -n "$log_file" ]; then
                health=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>>"$log_file" | tr -d '\n\r' || echo "none")
                status=$(docker inspect --format='{{.State.Status}}' "$container" 2>>"$log_file" | tr -d '\n\r' || echo "unknown")
                name=$(docker inspect --format='{{.Name}}' "$container" 2>>"$log_file" | sed 's/\///' | tr -d '\n\r')
            else
                health=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null | tr -d '\n\r' || echo "none")
                status=$(docker inspect --format='{{.State.Status}}' "$container" 2>/dev/null | tr -d '\n\r' || echo "unknown")
                name=$(docker inspect --format='{{.Name}}' "$container" 2>/dev/null | sed 's/\///' | tr -d '\n\r')
            fi

            # health check가 정의되지 않은 경우 (패턴 매칭 사용)
            if [[ "$health" == *"none"* ]] || [[ "$health" == *"no value"* ]] || [ -z "$health" ]; then
                if [[ "$status" != *"running"* ]]; then
                    all_healthy=false
                    status_info="${status_info}\n  - $name: $status (not running)"
                else
                    # 컨테이너 시작 시간 확인
                    local started_at
                    if [ -n "$log_file" ]; then
                        started_at=$(docker inspect --format='{{.State.StartedAt}}' "$container" 2>>"$log_file" | tr -d '\n\r')
                    else
                        started_at=$(docker inspect --format='{{.State.StartedAt}}' "$container" 2>/dev/null | tr -d '\n\r')
                    fi
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

        echo "대기 중... ${elapsed}/${max_wait}초 경과"
        echo -e "$status_info"
        sleep $interval
        elapsed=$((elapsed + interval))
    done

    log_warn "최대 대기 시간(${max_wait}초) 초과. 현재 상태:"
    echo -e "$status_info"
    return 1
}

# 컨테이너 로그 크기 제한 사용 여부 판단 및 준비. 결과는 LOG_LIMIT_ENABLED(true/false)에 저장한다.
# 설정이 잘못됐거나 기본 로깅 드라이버가 json-file/local이 아니면 제한 없이 기존 방식대로 진행한다.
init_docker_log_limit() {
    local driver
    LOG_LIMIT_ENABLED=false

    if [ "$DOCKER_LOG_MAX_SIZE" = "0" ]; then
        log_info "Docker 로그 크기 제한: 사용 안 함 (DOCKER_LOG_MAX_SIZE=0)"
        return 0
    fi

    if ! [[ "$DOCKER_LOG_MAX_SIZE" =~ ^[1-9][0-9]*[kKmMgG]?$ ]] || ! [[ "$DOCKER_LOG_MAX_FILE" =~ ^[1-9][0-9]*$ ]]; then
        log_warn "DOCKER_LOG_MAX_SIZE='$DOCKER_LOG_MAX_SIZE' / DOCKER_LOG_MAX_FILE='$DOCKER_LOG_MAX_FILE' 형식이 올바르지 않아 로그 크기 제한을 적용하지 않습니다. (예: 10m / 3)"
        return 0
    fi

    # 드라이버를 지정하지 않고 옵션만 주입하므로, 기본 드라이버가 max-size/max-file을 지원해야 한다
    driver=$(docker info --format '{{.LoggingDriver}}' 2>/dev/null)
    case "$driver" in
        json-file|local) ;;
        *)
            log_warn "Docker 기본 로깅 드라이버가 '${driver:-확인 불가}'이라 로그 크기 제한을 적용하지 않습니다."
            return 0
            ;;
    esac

    LOG_OVERRIDE_DIR=$(mktemp -d) || {
        log_warn "임시 디렉토리 생성 실패. 로그 크기 제한을 적용하지 않습니다."
        return 0
    }
    trap 'rm -rf "$LOG_OVERRIDE_DIR"' EXIT

    LOG_LIMIT_ENABLED=true
    log_info "Docker 로그 크기 제한: max-size=$DOCKER_LOG_MAX_SIZE, max-file=$DOCKER_LOG_MAX_FILE (compose에 logging이 없는 서비스에만 적용)"
}

# compose 파일에서 logging이 정의되지 않은 서비스에 로그 크기 제한을 주입하는 override 파일을 생성한다.
# compose 파일에 logging이 이미 있는 서비스는 그 설정을 존중하여 건드리지 않는다.
# 반드시 compose 디렉토리로 이동한 뒤 호출할 것 (-f 없이 docker compose가 찾는 파일과 비교하기 때문).
# 반환: 0=override 생성 (docker compose -f <compose_path> -f <out> 으로 사용), 1=주입하지 않음
build_log_limit_override() {
    local compose_path=$1
    local out=$2
    local explicit_cfg default_cfg line svc
    local -a applied=() kept=()

    explicit_cfg=$(docker compose -f "$compose_path" config 2>/dev/null) || return 1

    # pull/down/up은 -f 없이 실행되어 docker-compose.override.yml 이나 COMPOSE_FILE 도 함께 읽는다.
    # 그 결과가 compose_path 단독 결과와 다르면 -f 로 고정할 때 동작이 달라지므로 주입하지 않는다.
    default_cfg=$(docker compose config 2>/dev/null) || default_cfg=""
    if [ "$explicit_cfg" != "$default_cfg" ]; then
        log_warn "docker compose 기본 탐색 결과가 목록의 파일과 달라(override 파일 또는 COMPOSE_FILE 사용 추정) 로그 크기 제한을 주입하지 않습니다. 필요하면 해당 compose 파일에 logging을 직접 지정하세요."
        return 1
    fi

    # 서비스별 logging 정의 여부 분류: "+서비스" = 주입 대상, "=서비스" = 기존 설정 유지
    while IFS= read -r line; do
        case "$line" in
            +*) applied+=("${line#+}") ;;
            =*) kept+=("${line#=}") ;;
        esac
    done < <(printf '%s\n' "$explicit_cfg" | awk '
        /^services:/ { in_services=1; next }
        in_services && /^[^ #]/ { in_services=0 }
        !in_services { next }
        /^  [^ ]/ { svc=$1; gsub(/[\047":]/, "", svc); order[n++]=svc; next }
        /^    logging:/ { has_logging[svc]=1 }
        END { for (i = 0; i < n; i++) print (has_logging[order[i]] ? "=" : "+") order[i] }')

    if [ ${#kept[@]} -gt 0 ]; then
        log_info "기존 logging 설정 유지: ${kept[*]}"
    fi
    if [ ${#applied[@]} -eq 0 ]; then
        return 1
    fi

    {
        echo "services:"
        for svc in "${applied[@]}"; do
            printf '  "%s":\n    logging:\n      options:\n        max-size: "%s"\n        max-file: "%s"\n' \
                "$svc" "$DOCKER_LOG_MAX_SIZE" "$DOCKER_LOG_MAX_FILE"
        done
    } > "$out"

    # 생성한 override가 유효한지 확인. 문제가 있으면 쓰지 않고 기존 방식대로 진행한다.
    if ! docker compose -f "$compose_path" -f "$out" config -q >/dev/null 2>&1; then
        log_warn "로그 크기 제한 override가 유효하지 않아 적용하지 않습니다: $compose_path"
        rm -f -- "$out"
        return 1
    fi

    log_info "로그 크기 제한 적용 (max-size=$DOCKER_LOG_MAX_SIZE, max-file=$DOCKER_LOG_MAX_FILE): ${applied[*]}"
    return 0
}

# dpkg/apt 자동 복구에 사용하는 공통 옵션
# DPkg::Lock::Timeout: 다른 패키지 관리 프로세스가 락을 잡고 있으면 최대 5분 대기
APT_LOCK_OPTS=(-o DPkg::Lock::Timeout=300)
# 복구 중에는 설정 파일 충돌 시 기존 설정을 유지 (비대화형 환경에서 멈추지 않도록)
APT_FIX_OPTS=("${APT_LOCK_OPTS[@]}" -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

# 다른 패키지 관리 프로세스(unattended-upgrades 등)가 dpkg 락을 잡고 있으면 끝날 때까지 대기
# (작업 중인 패키지는 일시적으로 미설정 상태로 보이므로, 끝나기 전에 점검하면 오탐이 생긴다)
wait_for_dpkg_lock() {
    local max_wait=${1:-300}
    local interval=5
    local elapsed=0
    local locks=(/var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock)

    # fuser가 없으면 확인을 건너뜀 (apt 쪽은 DPkg::Lock::Timeout이 처리)
    command -v fuser >/dev/null 2>&1 || return 0

    while fuser "${locks[@]}" >/dev/null 2>&1; do
        if [ $elapsed -ge $max_wait ]; then
            return 1
        fi
        if [ $elapsed -eq 0 ]; then
            log_info "다른 패키지 관리 작업이 진행 중입니다. 끝날 때까지 대기합니다..."
        fi
        sleep $interval
        elapsed=$((elapsed + interval))
    done
    return 0
}

# dpkg/apt 상태가 정상인지 확인 (정상이면 0)
dpkg_is_healthy() {
    [ -z "$(dpkg --audit 2>/dev/null)" ] && apt-get check >/dev/null 2>&1
}

# 실행 중인 커널보다 낮은 버전의 커널 헤더 패키지인지 확인 (강제 제거해도 안전한 대상)
# 이미지/모듈 패키지, 메타 패키지, 실행 중이거나 더 새로운 커널의 헤더는 해당하지 않는다.
is_stale_kernel_headers() {
    local pkg=$1
    local running_ver ver

    # 예: 6.17.0-1019-oracle -> 6.17.0-1019
    running_ver="$(uname -r)"
    running_ver="${running_ver%-*}"

    [[ "$pkg" =~ ^linux-(.+-)?headers-[0-9] ]] || return 1
    [[ "$pkg" =~ ([0-9]+\.[0-9]+\.[0-9]+-[0-9]+) ]] || return 1
    ver="${BASH_REMATCH[1]}"

    dpkg --compare-versions "$ver" lt "$running_ver"
}

# 복구 전 dpkg 상태 파일 백업 (최근 5개만 유지)
backup_dpkg_status() {
    local backup="$LOG_DIR/dpkg-status-$(date '+%Y%m%d-%H%M%S').bak"

    if cp -p /var/lib/dpkg/status "$backup" 2>/dev/null; then
        log_info "dpkg 상태 백업: $backup"
        ls -1t "$LOG_DIR"/dpkg-status-*.bak 2>/dev/null | tail -n +6 | xargs -r rm -f --
    else
        log_warn "dpkg 상태 백업에 실패했습니다. 계속 진행합니다."
    fi
}

# apt-get install -f 실행. 패키지를 제거해야 하는 경우에는 자동 진행하지 않는다.
apt_fix_broken() {
    local removals
    removals=$(apt-get -s -f install 2>/dev/null | grep '^Remv' || true)

    if [ -n "$removals" ]; then
        log_error "apt-get install -f 가 아래 패키지를 제거하려고 하여 자동으로 진행하지 않습니다:"
        echo "$removals"
        return 1
    fi

    DEBIAN_FRONTEND=noninteractive apt-get install -f -y "${APT_FIX_OPTS[@]}"
}

# dpkg/apt 상태 점검 및 자동 복구. 정상이면 아무것도 하지 않고 0을 반환한다.
# 복구 후에도 문제가 남으면 1을 반환한다.
#   1) dpkg --configure -a   : 중단된 패키지 설정 재개
#   2) apt-get install -f    : 깨진 의존성 수정
#   3) reinstreq 패키지 처리 : 재설치, 실패하면 오래된 커널 헤더에 한해 강제 제거
repair_dpkg() {
    wait_for_dpkg_lock || log_warn "dpkg 락 대기 시간을 초과했습니다. 그대로 진행합니다."

    if dpkg_is_healthy; then
        return 0
    fi

    log_warn "dpkg/apt 상태에 문제가 감지되었습니다. 자동 복구를 시도합니다."
    dpkg --audit 2>&1
    backup_dpkg_status

    log_info "복구 1/3: 미설정 패키지 설정 (dpkg --configure -a)"
    DEBIAN_FRONTEND=noninteractive dpkg --configure -a || log_warn "dpkg --configure -a 가 실패했습니다. 다음 단계를 진행합니다."
    if dpkg_is_healthy; then
        log_info "dpkg/apt 상태 복구 완료"
        return 0
    fi

    log_info "복구 2/3: 깨진 의존성 수정 (apt-get install -f)"
    apt_fix_broken || log_warn "apt-get install -f 가 완료되지 않았습니다. 다음 단계를 진행합니다."
    if dpkg_is_healthy; then
        log_info "dpkg/apt 상태 복구 완료"
        return 0
    fi

    log_info "복구 3/3: 재설치가 필요한(reinstreq) 패키지 처리"
    local pkg
    for pkg in $(dpkg-query -W -f='${db:Status-Eflag} ${binary:Package}\n' 2>/dev/null | awk '$1 == "reinstreq" {print $2}'); do
        log_warn "재설치가 필요한 패키지: $pkg"
        if DEBIAN_FRONTEND=noninteractive apt-get install --reinstall -y "${APT_FIX_OPTS[@]}" "$pkg"; then
            log_info "재설치 완료: $pkg"
        elif is_stale_kernel_headers "$pkg"; then
            log_warn "재설치에 실패했습니다. 실행 중인 커널보다 오래된 헤더 패키지이므로 강제 제거합니다: $pkg"
            dpkg --remove --force-remove-reinstreq "$pkg" || log_error "강제 제거 실패: $pkg"
        else
            log_error "자동으로 복구할 수 없는 패키지입니다 (수동 확인 필요): $pkg"
        fi
    done

    # 재설치/제거 후 남은 의존성 문제 마무리
    if ! dpkg_is_healthy; then
        apt_fix_broken || true
    fi

    if dpkg_is_healthy; then
        log_info "dpkg/apt 상태 복구 완료"
        return 0
    fi

    log_error "자동 복구 후에도 dpkg/apt 상태에 문제가 남아 있습니다:"
    dpkg --audit 2>&1
    apt-get check 2>&1
    return 1
}

# 패키지 이름에서 커널 버전 추출 (예: linux-image-6.17.0-1020-oracle -> 6.17.0-1020)
# 버전이 없는 메타 패키지(linux-image-oracle, linux-oracle-6.17-headers 등)는 빈 문자열
kernel_pkg_version() {
    [[ "$1" =~ ^linux-.*-([0-9]+\.[0-9]+\.[0-9]+-[0-9]+)(-[a-z0-9]+)?$ ]] && echo "${BASH_REMATCH[1]}"
}

# 설치된 linux-* 패키지 이름 목록
installed_linux_pkgs() {
    dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 'linux-*' 2>/dev/null | awk '$1 ~ /^.i/ {print $2}'
}

# 오래된 커널 패키지 제거
# 유지 대상: 실행 중인 커널, 그보다 새로운 커널(재부팅 대기), 실행 중인 커널 직전 버전 1개(예비 부팅용)
purge_old_kernels() {
    local running_ver pkg ver fallback=""
    local -a versions=() targets=()

    running_ver="$(uname -r)"
    running_ver="${running_ver%-*}"

    mapfile -t versions < <(installed_linux_pkgs | while read -r pkg; do kernel_pkg_version "$pkg"; done | sort -uV)

    for ver in "${versions[@]}"; do
        dpkg --compare-versions "$ver" lt "$running_ver" && fallback="$ver"
    done

    for pkg in $(installed_linux_pkgs); do
        ver="$(kernel_pkg_version "$pkg")"
        [ -n "$ver" ] || continue
        dpkg --compare-versions "$ver" lt "$running_ver" || continue
        [ "$ver" = "$fallback" ] && continue
        targets+=("$pkg")
    done

    log_info "커널 유지: 실행 중 $running_ver, 예비 ${fallback:-없음}"

    if [ ${#targets[@]} -eq 0 ]; then
        log_info "제거할 오래된 커널이 없습니다."
        return 0
    fi

    # 대상 외의 패키지(메타 패키지 등)까지 함께 제거되는 경우에는 진행하지 않는다
    local extra
    extra=$(apt-get -s purge "${targets[@]}" 2>/dev/null | awk '/^(Purg|Remv) /{print $2}' | grep -vxF -f <(printf '%s\n' "${targets[@]}") || true)
    if [ -n "$extra" ]; then
        log_warn "오래된 커널 제거 시 아래 패키지도 함께 제거되어 건너뜁니다:"
        echo "$extra"
        return 1
    fi

    log_info "오래된 커널 패키지 제거: ${targets[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get purge -y "${APT_LOCK_OPTS[@]}" "${targets[@]}"
}

# 제거 후 설정 파일만 남은(rc) 커널 패키지 정리
purge_residual_kernel_configs() {
    local -a residual
    mapfile -t residual < <(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 'linux-*' 2>/dev/null | awk '$1 == "rc" {print $2}')

    if [ ${#residual[@]} -eq 0 ]; then
        return 0
    fi

    log_info "설정 파일만 남은 커널 패키지 ${#residual[@]}개 정리"
    dpkg --purge "${residual[@]}" >/dev/null
}

# 어떤 패키지에도 속하지 않는 /lib/modules/<버전> 디렉토리 삭제 (실행 중인 커널은 제외)
remove_orphan_kernel_modules() {
    local dir name

    for dir in /lib/modules/*/; do
        dir="${dir%/}"
        name="$(basename "$dir")"
        [ "$name" = "$(uname -r)" ] && continue
        dpkg -S "$dir" >/dev/null 2>&1 && continue

        log_info "패키지 없이 남은 모듈 디렉토리 삭제: $dir"
        rm -rf -- "$dir"
    done
}

# snap의 비활성(disabled) 옛 리비전 제거. hold된 snap은 건너뛴다.
remove_disabled_snap_revisions() {
    command -v snap >/dev/null 2>&1 || return 0

    # 앞으로 리비전을 2개까지만 유지
    snap set system refresh.retain=2 2>/dev/null || true

    local name rev
    snap list --all 2>/dev/null | awk 'NR > 1 && $NF ~ /disabled/ && $NF !~ /held/ {print $1, $3}' |
    while read -r name rev; do
        log_info "snap 옛 리비전 제거: $name (revision $rev)"
        snap remove "$name" --revision="$rev" || log_warn "snap 리비전 제거 실패: $name ($rev)"
    done
}

# systemd 저널 용량 제한 (설정 파일이 없을 때만 추가하고 journald 재시작)
limit_journal_size() {
    local max_use=${1:-200M}
    local conf=/etc/systemd/journald.conf.d/size.conf

    command -v journalctl >/dev/null 2>&1 || return 0

    if [ ! -f "$conf" ]; then
        mkdir -p "$(dirname "$conf")"
        printf '[Journal]\nSystemMaxUse=%s\n' "$max_use" > "$conf"
        systemctl restart systemd-journald
        log_info "저널 최대 용량을 $max_use 로 설정했습니다: $conf"
    fi

    journalctl --vacuum-size="$max_use" 2>&1 | tail -1
}

# VS Code Server 옛 버전 정리. 사용자별로 최신 버전 2개만 남기고, 실행 중인 버전은 건드리지 않는다.
remove_old_vscode_servers() {
    local servers dir

    for servers in /home/*/.vscode-server/cli/servers /root/.vscode-server/cli/servers; do
        [ -d "$servers" ] || continue

        ls -1dt "$servers"/Stable-* 2>/dev/null | tail -n +3 | while read -r dir; do
            if pgrep -f "$(basename "$dir")" >/dev/null 2>&1; then
                log_info "실행 중인 VS Code Server는 유지: $dir"
                continue
            fi
            log_info "VS Code Server 옛 버전 삭제: $dir"
            rm -rf -- "$dir"
        done
    done
}

# 스크립트 실행 디렉토리
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 로그 디렉토리 (스크립트가 있는 곳 기준)
LOG_DIR="$SCRIPT_DIR/log"
# NOTE: LOG_DIR will be created after root permission check to avoid ownership issues.

# 루트 권한 확인
if [ "$EUID" -ne 0 ]; then
    log_error "이 스크립트는 root 권한이 필요합니다. sudo를 사용해주세요."
    exit 1
fi

# 로그 디렉토리 생성 (루트 권한 보장된 이후)
mkdir -p "$LOG_DIR" 2>/dev/null || {
    log_warn "로그 디렉토리 생성 실패: $LOG_DIR"
}

# 실행 단위 통합 로그 파일 (한 번 실행 시 모든 로그를 이 파일에 기록)
# 분리 실행된 워커는 부모가 지정한 로그 파일을 그대로 사용 (자체 업데이트 재실행 시에도 유지)
if [ -n "${UPDATE_RUN_LOG:-}" ]; then
    RUN_LOG="$UPDATE_RUN_LOG"
else
    RUN_LOG="$LOG_DIR/run-$(date '+%Y%m%d-%H%M%S').log"
    : > "$RUN_LOG" 2>/dev/null || {
        log_error "로그 파일 생성 실패: $RUN_LOG"
        exit 1
    }
fi

# 터미널(SSH 포함)에서 실행된 경우 별도 세션으로 분리 실행.
# SSH 연결이 끊겨도(예: apt가 tailscale을 업그레이드하며 tailscaled 재시작)
# 워커는 SIGHUP을 받지 않고 끝까지 실행되며, 현재 터미널에는 로그를 실시간 표시한다.
if [ -z "${UPDATE_DETACHED:-}" ] && [ -t 1 ] && command -v setsid >/dev/null 2>&1; then
    log_info "실행 로그: $RUN_LOG"
    log_info "연결이 끊겨도 작업이 계속되도록 분리 실행합니다."

    UPDATE_DETACHED=1 UPDATE_RUN_LOG="$RUN_LOG" \
        setsid "$BASH" "$SCRIPT_DIR/$(basename "$0")" "$@" >> "$RUN_LOG" 2>&1 < /dev/null &
    WORKER_PID=$!

    log_info "작업 PID: $WORKER_PID — 연결이 끊기면 재접속 후 확인: tail -f $RUN_LOG"
    echo ""

    # 워커가 끝날 때까지 로그를 실시간 표시. 이 tail(현재 세션)이 끊겨도 워커는 계속된다.
    tail --pid="$WORKER_PID" -n +1 -f "$RUN_LOG"
    wait "$WORKER_PID"
    exit $?
fi

# 여기서부터는 실제 작업 프로세스. 터미널 없이 직접 실행된 경우(cron 등)도
# 모든 출력이 로그 파일에 남도록 리다이렉트한다. (분리 실행된 워커는 부모가 이미 처리,
# setsid가 없어 터미널에서 직접 실행 중이면 화면 출력을 유지)
if [ -z "${UPDATE_DETACHED:-}" ] && [ ! -t 1 ]; then
    exec >> "$RUN_LOG" 2>&1
fi

log_info "실행 로그: $RUN_LOG"


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

    # 현재 브랜치 감지 및 커밋 해시 저장
    CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    CURRENT_COMMIT=$(git rev-parse HEAD 2>/dev/null)

    if [ -z "$CURRENT_BRANCH" ]; then
        CURRENT_BRANCH="main"
        log_warn "현재 브랜치를 감지할 수 없어 'main' 브랜치로 pull을 시도합니다."
    fi

    if git pull origin "$CURRENT_BRANCH"; then
        # pull 후 커밋 해시 확인
        NEW_COMMIT=$(git rev-parse HEAD 2>/dev/null)

        if [ "$CURRENT_COMMIT" != "$NEW_COMMIT" ]; then
            log_info "스크립트가 업데이트되었습니다!"
            log_info "새 버전으로 재실행합니다..."
            echo ""

            # 스크립트 재실행: bash로 스크립트 경로를 명확히 지정
            exec "$BASH" "$SCRIPT_DIR/$(basename "$0")" "$@"
        else
            log_info "이미 최신 버전입니다."
        fi
    else
        log_warn "Git pull 실패. 현재 버전으로 계속 진행합니다."
    fi
else
    log_warn "Git 저장소가 아닙니다. 업데이트 확인을 건너뜁니다."
fi

echo ""

# 1. Git 저장소 업데이트 (docker compose와 무관하게 git pull이 필요한 폴더 목록)
# git-list.txt 형식: 한 줄에 저장소 폴더의 절대 경로 하나, 빈 줄과 #으로 시작하는 줄은 무시
# Docker 단계보다 먼저 실행하여 빌드/마운트되는 소스가 최신 상태로 컨테이너가 재시작되도록 한다.
log_info "Step 1: Git 저장소 업데이트"

GIT_LIST="$SCRIPT_DIR/git-list.txt"

if [ -f "$GIT_LIST" ]; then
    log_info "git-list.txt에서 경로 목록을 읽어옵니다..."

    GIT_SUCCESS_COUNT=0
    GIT_FAIL_COUNT=0
    GIT_TOTAL_COUNT=0

    while IFS= read -r git_dir; do
        GIT_TOTAL_COUNT=$((GIT_TOTAL_COUNT + 1))
        log_info "[$GIT_TOTAL_COUNT] 처리 중: $git_dir"

        if [ ! -d "$git_dir" ]; then
            log_warn "디렉토리를 찾을 수 없습니다: $git_dir"
            GIT_FAIL_COUNT=$((GIT_FAIL_COUNT + 1))
            continue
        fi

        if [ ! -e "$git_dir/.git" ]; then
            log_warn "Git 저장소의 최상위 폴더가 아닙니다 (.git 없음): $git_dir"
            GIT_FAIL_COUNT=$((GIT_FAIL_COUNT + 1))
            continue
        fi

        if git_pull_repo "$git_dir"; then
            GIT_SUCCESS_COUNT=$((GIT_SUCCESS_COUNT + 1))
        else
            GIT_FAIL_COUNT=$((GIT_FAIL_COUNT + 1))
        fi
    done < <(read_list_entries "$GIT_LIST")

    log_info "Git 저장소 업데이트 완료 - 성공: $GIT_SUCCESS_COUNT, 실패: $GIT_FAIL_COUNT, 전체: $GIT_TOTAL_COUNT"

    if [ $GIT_FAIL_COUNT -gt 0 ]; then
        log_warn "일부 Git 저장소 업데이트가 실패했습니다."
    fi
else
    log_info "git-list.txt 파일이 없습니다. Git 저장소 업데이트를 건너뜁니다."
fi

echo ""

# 2. Docker Compose 이미지 업데이트
log_info "Step 2: Docker Compose 이미지 업데이트 시작"

COMPOSE_LIST="$SCRIPT_DIR/compose-list.txt"

if [ -f "$COMPOSE_LIST" ]; then
    log_info "compose-list.txt에서 경로 목록을 읽어옵니다..."

    # 컨테이너 로그 크기 제한 준비
    init_docker_log_limit

    # 성공/실패 카운터
    SUCCESS_COUNT=0
    FAIL_COUNT=0
    TOTAL_COUNT=0

    while IFS= read -r compose_path; do
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

        # 실행 통합 로그에 섹션 헤더 추가
        echo "===== $compose_path - $(date '+%Y-%m-%d %H:%M:%S') =====" >> "$RUN_LOG" 2>/dev/null || true

        # 해당 디렉토리에 Git 저장소가 있으면 현재 브랜치로 pull 시도
        if [ -d "$COMPOSE_DIR/.git" ]; then
            git_pull_repo "$COMPOSE_DIR" || true   # 실패해도 기존 이미지/소스로 계속 진행
        fi

        # 컨테이너 로그 크기 제한 주입 (pull로 compose 파일이 바뀔 수 있으므로 pull 이후에 생성)
        # 주입할 수 없으면 기존과 동일하게 -f 없이 docker compose를 실행한다.
        COMPOSE_CMD=(docker compose)
        if [ "$LOG_LIMIT_ENABLED" = true ]; then
            LOG_OVERRIDE_FILE="$LOG_OVERRIDE_DIR/log-limit-$TOTAL_COUNT.yml"
            if build_log_limit_override "$compose_path" "$LOG_OVERRIDE_FILE"; then
                COMPOSE_CMD=(docker compose -f "$compose_path" -f "$LOG_OVERRIDE_FILE")
            fi
        fi

        # Dockerfile 빌드 서비스 감지 및 재빌드
        # image: 없이 build:만 있는 서비스가 하나라도 있을 때만 빌드 실행
        # (image: + build: 둘 다 있으면 registry에서 pull 가능하므로 빌드 불필요)
        BUILD_NEEDED=false
        if docker compose -f "$compose_path" config > /dev/null 2>&1; then
            BUILD_NEEDED=$(docker compose -f "$compose_path" config 2>/dev/null | awk '
            BEGIN { in_services=0; has_build=0; has_image=0; needs_build=0 }
            /^services:/ { in_services=1; next }
            !in_services { next }
            /^[a-zA-Z]/ { in_services=0; next }
            /^  [a-zA-Z_-]/ {
                if (has_build && !has_image) needs_build=1
                has_build=0; has_image=0
            }
            /^    build:/ { has_build=1 }
            /^    image:/ { has_image=1 }
            END {
                if (has_build && !has_image) needs_build=1
                print (needs_build ? "true" : "false")
            }')
        else
            # docker compose config 실패 시 기존 방식으로 fallback
            if grep -qE '^\s+build:' "$compose_path" 2>/dev/null; then
                BUILD_NEEDED=true
            fi
        fi

        if [ "$BUILD_NEEDED" = "true" ]; then
            log_info "빌드 전용 서비스 감지됨 (image 없이 build만 존재). 재빌드를 진행합니다..."
            if docker compose -f "$compose_path" build --pull; then
                log_info "재빌드 완료: $compose_path"
            else
                log_error "빌드 실패: $compose_path"
                FAIL_COUNT=$((FAIL_COUNT + 1))
                continue
            fi
        fi

        log_info "최신 이미지 다운로드 중..."
        if "${COMPOSE_CMD[@]}" pull; then
            log_info "컨테이너 재시작 중..."
            if "${COMPOSE_CMD[@]}" down && "${COMPOSE_CMD[@]}" up -d; then
                # 컨테이너 초기화 대기
                if wait_for_healthy "$compose_path" "$RUN_LOG"; then
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
    done < <(read_list_entries "$COMPOSE_LIST")

    # 결과 요약
    log_info "Docker Compose 업데이트 완료 - 성공: $SUCCESS_COUNT, 실패: $FAIL_COUNT, 전체: $TOTAL_COUNT"

    if [ $FAIL_COUNT -gt 0 ]; then
        log_warn "일부 Docker Compose 업데이트가 실패했습니다."
    fi
else
    log_warn "compose-list.txt 파일을 찾을 수 없습니다. Docker 업데이트를 건너뜁니다."
fi

# 3. 사용하지 않는 Docker 이미지 및 빌드 캐시 제거
log_info "Step 3: 사용하지 않는 Docker 이미지 및 빌드 캐시 제거"
if docker image prune -af; then
    log_info "Docker 이미지 정리 완료"
else
    log_warn "Docker 이미지 정리 중 오류가 발생했습니다. 상세 로그: $RUN_LOG"
fi
if docker builder prune -af; then
    log_info "Docker 빌드 캐시 정리 완료"
else
    log_warn "Docker 빌드 캐시 정리 중 오류가 발생했습니다. 상세 로그: $RUN_LOG"
fi

# 4. APT 업데이트
log_info "Step 4: APT 패키지 목록 업데이트"
if apt update; then
    log_info "APT 업데이트 완료"
else
    log_error "APT 업데이트 실패"
    exit 1
fi

# 5. APT 업그레이드
log_info "Step 5: APT 패키지 업그레이드"

# 이전 실행 등으로 dpkg 상태가 깨져 있으면 업그레이드 전에 복구
if ! repair_dpkg; then
    log_error "dpkg 상태 복구 실패. APT 업그레이드를 중단합니다."
    exit 1
fi

if DEBIAN_FRONTEND=noninteractive apt upgrade -y "${APT_LOCK_OPTS[@]}"; then
    log_info "APT 업그레이드 완료"
else
    log_error "APT 업그레이드 실패"

    # 업그레이드 도중 패키지 설정이 실패해 dpkg 상태가 깨진 경우에만 복구 후 한 번 재시도
    if dpkg_is_healthy; then
        exit 1
    fi

    log_warn "dpkg 상태가 깨져 있습니다. 복구 후 업그레이드를 한 번 재시도합니다."
    if repair_dpkg && DEBIAN_FRONTEND=noninteractive apt upgrade -y "${APT_LOCK_OPTS[@]}"; then
        log_info "APT 업그레이드 완료 (복구 후 재시도)"
    else
        log_error "APT 업그레이드 재시도 실패"
        exit 1
    fi
fi

# 6. 불필요한 패키지 제거 및 캐시 정리
log_info "Step 6: 시스템 정리"
apt autoremove -y
apt autoclean -y

purge_old_kernels || log_warn "오래된 커널 제거가 완료되지 않았습니다. 계속 진행합니다."
purge_residual_kernel_configs || log_warn "커널 잔여 설정 정리 중 오류가 발생했습니다."
remove_orphan_kernel_modules
remove_disabled_snap_revisions
limit_journal_size 200M || log_warn "저널 정리 중 오류가 발생했습니다."
remove_old_vscode_servers
log_info "시스템 정리 완료"

# 7. 재부팅 필요 여부 확인
log_info "Step 7: 재부팅 필요 여부 확인"
if [ -f /var/run/reboot-required ]; then
    log_warn "시스템 재부팅이 필요합니다."
    # 분리 실행 중에는 터미널의 Ctrl+C가 워커에 전달되지 않으므로 kill로 취소해야 한다.
    log_info "10초 후 자동으로 재부팅됩니다... (취소하려면: sudo kill $$)"

    for i in {10..1}; do
        echo "재부팅까지 ${i}초 남음..."
        sleep 1
    done

    log_info "시스템 재부팅 중..."
    reboot
else
    log_info "재부팅이 필요하지 않습니다."
fi

log_info "=== 모든 업데이트 작업 완료 ==="