#!/bin/bash

# ============================================================
# 블루/그린 무중단 배포 스크립트
#
# 사용법: bash deploy.sh <이미지_태그>
# 예시:   bash deploy.sh v1.0.1
#
# 동작 흐름:
#   1. 배포할 버전(이미지 태그) 인자 확인
#   2. 현재 실행 중인 환경(블루/그린/없음) 감지
#   3. 반대 환경으로 신규 컨테이너 기동
#   4. 헬스체크로 신규 환경 정상 확인
#   5. Traefik 라우터를 3단계로 전환 (등록 → 트래픽 이동 → 구환경 제거)
#   6. 구환경 컨테이너 종료
# ============================================================

set -euo pipefail

# ============================================================
# 인자 확인
# ============================================================
if [ $# -lt 1 ]; then
    echo "❌ 오류: 배포할 이미지 태그를 인자로 전달해야 합니다."
    echo "   사용법: bash deploy.sh <이미지_태그>"
    echo "   예시:   bash deploy.sh v1.0.1"
    exit 1
fi

export IMAGE_TAG="$1"

# ============================================================
# 경로 설정
# ============================================================
# 이 스크립트가 위치한 디렉토리 (plans/bluegreen/scripts/)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 블루/그린 compose 파일들이 위치한 디렉토리 (plans/bluegreen/)
BASE_DIR="$(dirname "$SCRIPT_DIR")"
# Traefik 라우터 템플릿 디렉토리 (plans/bluegreen/templates/)
TEMPLATES_DIR="$BASE_DIR/templates"
# Traefik dynamic 설정 디렉토리 (plans/bluegreen/dynamic/)
BG_ROUTERS="$BASE_DIR/dynamic/bg-routers.yaml"

# Bake 대기 시간 (각 단계별 최소 안정화 대기 초)
BAKE_TIME=10
# 헬스체크 최대 대기 시간 (초)
HEALTH_TIMEOUT=90
# 배포 목표 컨테이너 수 (replica 3개)
REPLICA_COUNT=3

# ============================================================
# 로그 함수
# ============================================================
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# ============================================================
# Bake 함수: 지정된 시간 동안 대기하며 안정화 확인
# 인자: $1 = 대기 초, $2 = 대기 이유 설명
# ============================================================
bake() {
    local WAIT_SEC="$1"
    local REASON="$2"
    log "⏱️  Bake 대기: $REASON (${WAIT_SEC}초 안정화 대기 중...)"
    sleep "$WAIT_SEC"
    log "✅  Bake 완료: $REASON"
}

# ============================================================
# 헬스체크 함수
# docker compose healthcheck 결과를 이용해 컨테이너가
# 모두 (healthy) 상태가 될 때까지 대기한다.
#
# 인자: $1 = 환경 이름 (blue | green)
# ============================================================
health_check() {
    local ENV_NAME="$1"           # "blue" 또는 "green"
    local COMPOSE_FILE="$BASE_DIR/${ENV_NAME}.yaml"
    local ELAPSED=0

    log "🔍 [$ENV_NAME] 헬스체크 시작 (최대 ${HEALTH_TIMEOUT}초 대기, 목표: ${REPLICA_COUNT}개 healthy)..."

    while [ "$ELAPSED" -lt "$HEALTH_TIMEOUT" ]; do
        # docker compose ps 출력에서 "(healthy)" 상태 컨테이너 수 집계
        HEALTHY_COUNT=$(
            cd "$BASE_DIR" && \
            docker compose -f "${ENV_NAME}.yaml" ps 2>/dev/null \
            | grep -c "(healthy)" || true
        )

        if [ "$HEALTHY_COUNT" -ge "$REPLICA_COUNT" ]; then
            log "✅ [$ENV_NAME] 헬스체크 통과! (healthy 컨테이너: ${HEALTHY_COUNT}/${REPLICA_COUNT}개)"
            return 0
        fi

        log "⏳ [$ENV_NAME] 아직 준비 중... (${ELAPSED}/${HEALTH_TIMEOUT}초 경과, healthy: ${HEALTHY_COUNT}/${REPLICA_COUNT})"
        sleep 5
        ELAPSED=$((ELAPSED + 5))
    done

    # 타임아웃 — 컨테이너 상태 출력 후 종료
    log "❌ [$ENV_NAME] 헬스체크 실패: ${HEALTH_TIMEOUT}초 안에 모든 컨테이너가 healthy 상태가 되지 않았습니다."
    log "   현재 컨테이너 상태:"
    cd "$BASE_DIR" && docker compose -f "${ENV_NAME}.yaml" ps || true
    exit 1
}

# ============================================================
# Traefik 라우터 설정 교체 함수
# 인자: $1 = 템플릿 파일 이름 (예: green-deployed.yaml)
#       $2 = 로그에 출력할 설명
# ============================================================
apply_router_config() {
    local TEMPLATE_FILE="$1"
    local DESCRIPTION="$2"

    log "📄 라우터 설정 교체: $TEMPLATE_FILE → bg-routers.yaml"
    log "   → $DESCRIPTION"
    cat "$TEMPLATES_DIR/$TEMPLATE_FILE" > "$BG_ROUTERS"
}

# ============================================================
# 현재 실행 중인 환경 감지
# ============================================================
log "================================================================"
log "🚀 블루/그린 배포 시작 — 이미지 태그: ${IMAGE_TAG}"
log "================================================================"
log ""
log "🔎 현재 실행 중인 환경 확인 중..."

# 실행 중인(running 상태) 컨테이너 수 확인
BLUE_COUNT=$(cd "$BASE_DIR" && docker compose -f blue.yaml ps --status running 2>/dev/null | grep app-blue | wc -l | tr -d ' ')
log "   블루 실행 중인 컨테이너: ${BLUE_COUNT}개"
GREEN_COUNT=$(cd "$BASE_DIR" && docker compose -f green.yaml ps --status running 2>/dev/null | grep app-green | wc -l | tr -d ' ')

log "   블루 실행 중인 컨테이너: ${BLUE_COUNT}개"
log "   그린 실행 중인 컨테이너: ${GREEN_COUNT}개"

# ============================================================
# 배포 방향 결정
# ============================================================
DEPLOY_TARGET=""  # 새로 배포할 환경 (blue | green)
CURRENT=""        # 현재 트래픽을 받고 있는 환경 (blue | green | none)

if [ "$BLUE_COUNT" -eq 0 ] && [ "$GREEN_COUNT" -eq 0 ]; then
    # 아무것도 실행 중이지 않음 → 블루로 초기 배포
    DEPLOY_TARGET="blue"
    CURRENT="none"
    log "ℹ️  실행 중인 환경 없음 → 블루로 초기 배포를 시작합니다."

elif [ "$BLUE_COUNT" -gt 0 ] && [ "$GREEN_COUNT" -eq 0 ]; then
    # 블루만 실행 중 → 그린으로 배포
    DEPLOY_TARGET="green"
    CURRENT="blue"
    log "🔵 블루 환경 실행 중 → 그린으로 신규 버전을 배포합니다."

elif [ "$GREEN_COUNT" -gt 0 ] && [ "$BLUE_COUNT" -eq 0 ]; then
    # 그린만 실행 중 → 블루로 배포
    DEPLOY_TARGET="blue"
    CURRENT="green"
    log "🟢 그린 환경 실행 중 → 블루로 신규 버전을 배포합니다."

else
    # 블루/그린 동시 실행 — 비정상 상태
    log "⚠️  경고: 블루(${BLUE_COUNT}개)와 그린(${GREEN_COUNT}개)이 동시에 실행 중입니다."
    log "   이전 배포가 완료되지 않았거나 수동 개입이 필요한 상태입니다."
    log "   상태를 확인하고 불필요한 환경을 내린 뒤 다시 시도하세요."
    exit 1
fi

log ""

# ============================================================
# 신규 환경 컨테이너 기동
# ============================================================
log "🐳 [$DEPLOY_TARGET] 컨테이너 기동 시작 (버전: ${IMAGE_TAG}, replica: ${REPLICA_COUNT}개)..."
(cd "$BASE_DIR" && bash "$SCRIPT_DIR/deploy-${DEPLOY_TARGET}.sh")
log "✅ [$DEPLOY_TARGET] 컨테이너 기동 명령 완료. 헬스체크 대기 중..."
log ""

# ============================================================
# 헬스체크: 신규 환경이 정상인지 확인
# ============================================================
health_check "$DEPLOY_TARGET"
log ""

# ============================================================
# 초기 배포 처리 (기존 환경 없음)
# ============================================================
if [ "$CURRENT" = "none" ]; then
    log "📋 초기 배포: ${DEPLOY_TARGET}-only.yaml을 bg-routers.yaml에 적용합니다."
    apply_router_config "${DEPLOY_TARGET}-only.yaml" \
        "${DEPLOY_TARGET} 환경만 라우터에 등록 (트래픽 100% ${DEPLOY_TARGET})"
    log ""
    log "================================================================"
    log "🎉 초기 배포 완료!"
    log "   활성 환경: ${DEPLOY_TARGET} | 이미지 태그: ${IMAGE_TAG}"
    log "================================================================"
    exit 0
fi

# ============================================================
# Traefik 라우터 전환 — 3단계 무중단 전환
#
# [그린 배포 예시]
#   1단계: green-deployed.yaml → 그린을 라우터에 등록 (블루=100%, 그린=0%)
#   2단계: blue-deployed.yaml  → 트래픽을 그린으로 전환 (블루=0%, 그린=100%)
#   3단계: green-only.yaml     → 블루를 라우터에서 제거 (그린만 남김)
#
# [블루 배포 예시]
#   1단계: blue-deployed.yaml  → 블루를 라우터에 등록 (그린=100%, 블루=0%)
#   2단계: green-deployed.yaml → 트래픽을 블루로 전환 (그린=0%, 블루=100%)
#   3단계: blue-only.yaml      → 그린을 라우터에서 제거 (블루만 남김)
# ============================================================
log "🔀 Traefik 라우터 전환 시작 (3단계)..."
log ""

# ----- 1단계: 신규 환경을 라우터에 등록 (트래픽은 아직 구환경) -----
log "--- [1단계 / 3단계] ${DEPLOY_TARGET} 라우터 등록 ---"
apply_router_config "${DEPLOY_TARGET}-deployed.yaml" \
    "${DEPLOY_TARGET}을 Traefik에 등록. 트래픽은 아직 ${CURRENT}(100%)으로 흐름. ${DEPLOY_TARGET}은 0%."

bake "$BAKE_TIME" "${DEPLOY_TARGET} 라우터 등록 안정화"
log ""

# ----- 2단계: 트래픽을 신규 환경으로 전환 -----
log "--- [2단계 / 3단계] ${CURRENT} → ${DEPLOY_TARGET} 트래픽 전환 ---"
apply_router_config "${CURRENT}-deployed.yaml" \
    "트래픽을 ${CURRENT}(0%)에서 ${DEPLOY_TARGET}(100%)으로 전환. ${CURRENT}는 라우터에 남아있지만 트래픽 없음."

bake "$BAKE_TIME" "${DEPLOY_TARGET}으로 트래픽 전환 후 안정화"
log ""

# ----- 3단계: 구환경을 라우터에서 완전 제거 -----
log "--- [3단계 / 3단계] ${CURRENT} 라우터에서 제거 ---"
apply_router_config "${DEPLOY_TARGET}-only.yaml" \
    "${CURRENT}를 라우터에서 완전 제거. ${DEPLOY_TARGET}만 트래픽 수신(100%)."

bake "$BAKE_TIME" "${DEPLOY_TARGET} 단독 운영 최종 안정화"
log ""

# ============================================================
# 구환경 컨테이너 종료
# ============================================================
log "🛑 구환경 [${CURRENT}] 컨테이너 종료 중..."
(cd "$BASE_DIR" && bash "$SCRIPT_DIR/down-${CURRENT}.sh")
log "✅ [${CURRENT}] 컨테이너 종료 완료."
log ""

# ============================================================
# 배포 완료
# ============================================================
log "================================================================"
log "🎉 블루/그린 배포 완료!"
log "   이전 환경: ${CURRENT} → 현재 활성 환경: ${DEPLOY_TARGET}"
log "   이미지 태그: ${IMAGE_TAG}"
log "================================================================"
