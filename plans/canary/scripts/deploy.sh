#!/bin/bash

# ============================================================
# 카나리 무중단 배포 스크립트
#
# 사용법: bash deploy.sh <이미지_태그>
# 예시:   bash deploy.sh v1.0.1
#
# 동작 흐름:
#   1. 배포할 버전(이미지 태그) 인자 확인
#   2. 현재 실행 중인 안정 환경(a/b) 감지
#   3. 반대 환경으로 카나리 컨테이너 1개 기동 후 헬스체크
#   4. 트래픽 비율을 단계적으로 확대 (5% → 20% → 50% → 100%)
#      - 각 단계마다 replica 수 증가 & 헬스체크 & 2분 대기
#      - 헬스체크 실패 시 자동 롤백
#   5. 구버전 컨테이너 종료
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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
TEMPLATES_DIR="$BASE_DIR/templates"
CANARY_ROUTERS="$BASE_DIR/dynamic/canary-routers.yaml"

# 각 단계 사이 안정화 대기 시간 (2분)
BAKE_TIME=120
# 헬스체크 최대 대기 시간 (초)
HEALTH_TIMEOUT=90
# 안정 환경 replica 수
STABLE_REPLICAS=3

# ============================================================
# 로그 함수
# ============================================================
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# ============================================================
# Bake 함수: 지정된 시간 동안 대기하며 안정화 확인
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
# 인자: $1 = 환경 이름 (a | b), $2 = 목표 healthy 컨테이너 수
# 반환: 0 = 성공, 1 = 실패(타임아웃)
# ============================================================
health_check() {
    local ENV_NAME="$1"
    local EXPECTED="$2"
    local ELAPSED=0

    log "🔍 [app-${ENV_NAME}] 헬스체크 시작 (최대 ${HEALTH_TIMEOUT}초, 목표: ${EXPECTED}개 healthy)..."

    while [ "$ELAPSED" -lt "$HEALTH_TIMEOUT" ]; do
        HEALTHY_COUNT=$(docker ps --format "{{.Names}} {{.Status}}" 2>/dev/null \
            | (grep "app-${ENV_NAME}" || true) \
            | (grep "(healthy)" || true) \
            | wc -l \
            | tr -d ' ')

        if [ "$HEALTHY_COUNT" -ge "$EXPECTED" ]; then
            log "✅ [app-${ENV_NAME}] 헬스체크 통과! (${HEALTHY_COUNT}/${EXPECTED}개 healthy)"
            return 0
        fi

        log "⏳ [app-${ENV_NAME}] 준비 중... (${ELAPSED}/${HEALTH_TIMEOUT}초, healthy: ${HEALTHY_COUNT}/${EXPECTED})"
        sleep 5
        ELAPSED=$((ELAPSED + 5))
    done

    log "❌ [app-${ENV_NAME}] 헬스체크 실패: ${HEALTH_TIMEOUT}초 안에 ${EXPECTED}개 컨테이너가 healthy 상태가 되지 않았습니다."
    docker ps --filter "name=app-${ENV_NAME}" 2>/dev/null || true
    return 1
}

# ============================================================
# 라우터 설정 교체 함수
# 인자: $1 = 템플릿 파일 이름, $2 = 설명
# ============================================================
apply_router_config() {
    local TEMPLATE_FILE="$1"
    local DESCRIPTION="$2"
    log "📄 라우터 설정 교체: $TEMPLATE_FILE"
    log "   → $DESCRIPTION"
    cat "$TEMPLATES_DIR/$TEMPLATE_FILE" > "$CANARY_ROUTERS"
}

# ============================================================
# 롤백 함수: 카나리를 내리고 안정 환경 100%로 복구
# 인자: $1 = 안정 환경 (a | b), $2 = 카나리 환경 (a | b)
# ============================================================
rollback() {
    local STABLE="$1"
    local CANARY="$2"
    log ""
    log "🔙 ======== 롤백 시작 ========"
    log "   안정 환경 [app-${STABLE}] 100% 복구 중..."
    apply_router_config "${STABLE}-100.yaml" "app-${STABLE} 100% 복구 (롤백)"
    sleep 10  # 라우터가 변경 사항을 반영할 시간을 잠시 대기
    log "📄 라우터에서 카나리 [app-${CANARY}] 제거 중..."
    apply_router_config "${STABLE}-only.yaml" "app-${STABLE}만 라우터에 등록 (롤백 완료)"
    log "🛑 카나리 환경 [app-${CANARY}] 종료 중..."
    (cd "$BASE_DIR" && bash "$SCRIPT_DIR/down-${CANARY}.sh")
    log "✅ 롤백 완료. 안정 환경 [app-${STABLE}]이 트래픽 100%를 처리합니다."
    log "================================"
    exit 1
}

# ============================================================
# 현재 실행 중인 환경 감지
# ============================================================
log "================================================================"
log "🐤 카나리 배포 시작 — 이미지 태그: ${IMAGE_TAG}"
log "================================================================"
log ""
log "🔎 현재 실행 중인 환경 확인 중..."

A_COUNT=$(docker ps --format "{{.Names}}" 2>/dev/null | (grep "app-a" || true) | wc -l | tr -d ' ')
B_COUNT=$(docker ps --format "{{.Names}}" 2>/dev/null | (grep "app-b" || true) | wc -l | tr -d ' ')

log "   app-a 실행 중인 컨테이너: ${A_COUNT}개"
log "   app-b 실행 중인 컨테이너: ${B_COUNT}개"

STABLE=""  # 현재 안정 환경 (a | b)
CANARY=""  # 카나리로 배포할 환경 (a | b)

if [ "$A_COUNT" -eq 0 ] && [ "$B_COUNT" -eq 0 ]; then
    # 아무것도 없음 → app-a로 초기 배포
    log "ℹ️  실행 중인 환경 없음 → app-a로 초기 배포를 시작합니다."
    log ""
    log "🐳 [app-a] 컨테이너 기동 (replica: ${STABLE_REPLICAS}개)..."
    (cd "$BASE_DIR" && bash "$SCRIPT_DIR/deploy-a.sh")
    (cd "$BASE_DIR" && bash "$SCRIPT_DIR/scale-a.sh" "$STABLE_REPLICAS")
    health_check "a" "$STABLE_REPLICAS"
    # 초기 배포는 app-b가 없으므로 -only 템플릿으로 라우터에 단독 등록
    apply_router_config "a-only.yaml" "app-a 100% 트래픽 (초기 배포)"
    log ""
    log "================================================================"
    log "🎉 초기 배포 완료! 활성 환경: app-a | 이미지 태그: ${IMAGE_TAG}"
    log "================================================================"
    exit 0

elif [ "$A_COUNT" -gt 0 ] && [ "$B_COUNT" -eq 0 ]; then
    STABLE="a"
    CANARY="b"
    log "🅰️  app-a 안정 실행 중 → app-b를 카나리로 배포합니다."

elif [ "$B_COUNT" -gt 0 ] && [ "$A_COUNT" -eq 0 ]; then
    STABLE="b"
    CANARY="a"
    log "🅱️  app-b 안정 실행 중 → app-a를 카나리로 배포합니다."

else
    log "⚠️  경고: app-a(${A_COUNT}개)와 app-b(${B_COUNT}개)가 동시에 실행 중입니다."
    log "   이전 배포가 완료되지 않았거나 수동 개입이 필요한 상태입니다."
    log "   불필요한 환경을 내린 뒤 다시 시도하세요."
    exit 1
fi

log ""

# ============================================================
# [1단계] 카나리 컨테이너 기동 (replica: 1) + 헬스체크
# ============================================================
log "--- [1단계 / 5단계] 카나리 [app-${CANARY}] 기동 (replica: 1) ---"
(cd "$BASE_DIR" && bash "$SCRIPT_DIR/deploy-${CANARY}.sh")
(cd "$BASE_DIR" && bash "$SCRIPT_DIR/scale-${CANARY}.sh" 1)

if ! health_check "$CANARY" 1; then
    log "❌ 카나리 초기 기동 실패."
    rollback "$STABLE" "$CANARY"
fi
log ""

# ============================================================
# [2단계] 트래픽 5% 전환 (카나리 replica: 1, 안정: 3)
# ============================================================
log "--- [2단계 / 5단계] 트래픽 5% 카나리 전환 ---"
apply_router_config "${CANARY}-5.yaml" "app-${CANARY}=5%, app-${STABLE}=95%"
bake "$BAKE_TIME" "5% 카나리 트래픽 안정화"

if ! health_check "$CANARY" 1; then
    log "❌ 5% 단계 헬스체크 실패."
    rollback "$STABLE" "$CANARY"
fi
log ""

# ============================================================
# [3단계] 트래픽 20% 전환 (카나리 replica: 2, 안정: 3)
# ============================================================
log "--- [3단계 / 5단계] 트래픽 20% 카나리 전환 (replica: 2) ---"
(cd "$BASE_DIR" && bash "$SCRIPT_DIR/scale-${CANARY}.sh" 2)
apply_router_config "${CANARY}-20.yaml" "app-${CANARY}=20%, app-${STABLE}=80%"
bake "$BAKE_TIME" "20% 카나리 트래픽 안정화"

if ! health_check "$CANARY" 2; then
    log "❌ 20% 단계 헬스체크 실패."
    rollback "$STABLE" "$CANARY"
fi
log ""

# ============================================================
# [4단계] 트래픽 50% 전환 (카나리 replica: 3, 안정: 3)
# ============================================================
log "--- [4단계 / 5단계] 트래픽 50% 카나리 전환 (replica: 3) ---"
(cd "$BASE_DIR" && bash "$SCRIPT_DIR/scale-${CANARY}.sh" 3)
apply_router_config "${CANARY}-50.yaml" "app-${CANARY}=50%, app-${STABLE}=50%"
bake "$BAKE_TIME" "50% 카나리 트래픽 안정화"

if ! health_check "$CANARY" 3; then
    log "❌ 50% 단계 헬스체크 실패."
    rollback "$STABLE" "$CANARY"
fi
log ""

# ============================================================
# [5단계] 트래픽 100% 카나리로 완전 전환
# ============================================================
log "--- [5단계 / 5단계] 트래픽 100% 카나리 완전 전환 ---"
apply_router_config "${CANARY}-100.yaml" "app-${CANARY}=100%, app-${STABLE}=0%"
bake "$BAKE_TIME" "100% 카나리 최종 안정화"

if ! health_check "$CANARY" 3; then
    log "❌ 100% 단계 헬스체크 실패."
    rollback "$STABLE" "$CANARY"
fi
log ""

# ============================================================
# 구버전 컨테이너 종료 + 라우터에서 제거
# ============================================================
log "📄 라우터에서 구버전 [app-${STABLE}] 제거 중..."
apply_router_config "${CANARY}-only.yaml" "app-${CANARY}만 라우터에 등록 (배포 완료)"
log "🛑 구버전 [app-${STABLE}] 컨테이너 종료 중..."
(cd "$BASE_DIR" && bash "$SCRIPT_DIR/down-${STABLE}.sh")
log "✅ [app-${STABLE}] 종료 완료."
log ""

# ============================================================
# 배포 완료
# ============================================================
log "================================================================"
log "🎉 카나리 배포 완료!"
log "   구버전: app-${STABLE} → 신버전: app-${CANARY}"
log "   이미지 태그: ${IMAGE_TAG}"
log "================================================================"
