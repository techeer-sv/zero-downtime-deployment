#!/bin/bash

# ============================================================
# 롤링 무중단 배포 스크립트 (start-first)
#
# 사용법: bash deploy-start-first.sh <이미지_태그>
# 예시:   bash deploy-start-first.sh v1.0.1
#
# 동작 흐름 (3회 반복):
#   1. 신버전 컨테이너 1개 추가 (총 4개)
#   2. 신버전 컨테이너 헬스체크
#   3. 헬스체크 실패시 방금 추가한 신버전 컨테이너만 제거 후 중단
#   4. 헬스체크 성공시 구버전 컨테이너 1개 제거 (총 3개)
# ============================================================

set -euo pipefail

# ============================================================
# 인자 확인
# ============================================================
if [ $# -lt 1 ]; then
    echo "❌ 오류: 배포할 이미지 태그를 인자로 전달해야 합니다."
    echo "   사용법: bash deploy-start-first.sh <이미지_태그>"
    echo "   예시:   bash deploy-start-first.sh v1.0.1"
    exit 1
fi

export IMAGE_TAG="$1"

log "🔄 롤링 배포 시작 (start-first) — 이미지 태그: ${IMAGE_TAG}"

# ============================================================
# 경로 설정
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"

HEALTH_TIMEOUT=60

# ============================================================
# 로그 함수
# ============================================================
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# ============================================================
# 헬스체크 함수: 신버전 이미지 컨테이너가 EXPECTED개 healthy가 될 때까지 대기
# 인자: $1 = 목표 healthy 컨테이너 수
# ============================================================
health_check_new() {
    local EXPECTED="$1"
    local ELAPSED=0

    log "🔍 신버전 헬스체크 (목표: ${EXPECTED}개 healthy, 최대 ${HEALTH_TIMEOUT}초)..."

    while [ "$ELAPSED" -lt "$HEALTH_TIMEOUT" ]; do
        HEALTHY_COUNT=$(docker ps --format "{{.Names}} {{.Image}} {{.Status}}" 2>/dev/null \
            | (grep "app-rolling" || true) \
            | (grep "zero-downtime-app:${IMAGE_TAG}" || true) \
            | (grep "(healthy)" || true) \
            | wc -l \
            | tr -d ' ')

        if [ "$HEALTHY_COUNT" -ge "$EXPECTED" ]; then
            log "✅ 신버전 헬스체크 통과! (healthy: ${HEALTHY_COUNT}/${EXPECTED}개)"
            return 0
        fi

        log "⏳ 신버전 준비 중... (${ELAPSED}/${HEALTH_TIMEOUT}초, healthy: ${HEALTHY_COUNT}/${EXPECTED})"
        sleep 5
        ELAPSED=$((ELAPSED + 5))
    done

    log "❌ 신버전 헬스체크 실패: ${HEALTH_TIMEOUT}초 안에 ${EXPECTED}개가 healthy 상태가 되지 않았습니다."
    docker ps --filter "name=app-rolling" 2>/dev/null || true
    return 1
}

# ============================================================
# 구버전 컨테이너 1개 가져오기 (신버전 이미지가 아닌 것)
# ============================================================
get_old_container() {
    docker ps --format "{{.Names}} {{.Image}}" \
        | (grep "app-rolling" || true) \
        | (grep -v "zero-downtime-app:${IMAGE_TAG}" || true) \
        | awk '{print $1}' \
        | head -1
}

# ============================================================
# 배포 시작
# ============================================================
log "================================================================"
log "🔄 롤링 배포 시작 (start-first) — 이미지 태그: ${IMAGE_TAG}"
log "================================================================"
log ""

CURRENT_COUNT=$(docker ps --format "{{.Names}}" 2>/dev/null | (grep "app-rolling" || true) | wc -l | tr -d ' ')
log "🔎 현재 실행 중인 app-rolling 컨테이너: ${CURRENT_COUNT}개"

if [ "$CURRENT_COUNT" -eq 0 ]; then
    log "ℹ️  실행 중인 컨테이너 없음 → 초기 배포"
    (cd "$BASE_DIR" && bash "$SCRIPT_DIR/deploy-rolling.sh" "$IMAGE_TAG")
    log "================================================================"
    log "🎉 초기 배포 완료! 이미지 태그: ${IMAGE_TAG}"
    log "================================================================"
    exit 0
fi

for ROUND in 1 2 3; do
    log ""
    log "--- [${ROUND}회차 / 3회차] start-first 교체 시작 ---"

    # 1. 신버전 컨테이너 1개 추가 전 목록 저장 (롤백용)
    BEFORE_NEW=$(docker ps --format "{{.Names}} {{.Image}}" \
        | (grep "app-rolling" || true) \
        | (grep "zero-downtime-app:${IMAGE_TAG}" || true) \
        | awk '{print $1}')

    # 2. 신버전 컨테이너 1개 추가
    log "🐳 신버전 컨테이너 1개 추가..."
    (cd "$BASE_DIR" && bash "$SCRIPT_DIR/deploy-extra.sh" "$IMAGE_TAG" 1)

    # 3. 방금 추가된 컨테이너 식별 (BEFORE에 없던 것)
    JUST_ADDED=""
    for C in $(docker ps --format "{{.Names}} {{.Image}}" \
        | (grep "app-rolling" || true) \
        | (grep "zero-downtime-app:${IMAGE_TAG}" || true) \
        | awk '{print $1}'); do
        if ! echo "$BEFORE_NEW" | grep -qxF "$C"; then
            JUST_ADDED="$C"
            break
        fi
    done
    log "   신규 컨테이너: ${JUST_ADDED}"

    # 4. 신버전 헬스체크 (ROUND개 healthy 기대)
    if ! health_check_new "$ROUND"; then
        log "❌ [${ROUND}회차] 헬스체크 실패 — 방금 추가한 컨테이너 제거 후 중단"
        if [ -n "$JUST_ADDED" ]; then
            docker stop "$JUST_ADDED" && docker rm "$JUST_ADDED"
            log "   🛑 제거: ${JUST_ADDED}"
        fi
        log "   이전 상태로 복귀됨"
        exit 1
    fi

    # 5. 구버전 컨테이너 1개 제거
    OLD_CONTAINER=$(get_old_container)
    if [ -z "$OLD_CONTAINER" ]; then
        log "✅ 구버전 컨테이너 없음, 교체 완료"
        break
    fi

    log "🛑 구버전 컨테이너 제거: ${OLD_CONTAINER}"
    bash "$SCRIPT_DIR/remove-old.sh" "$OLD_CONTAINER"

    log "✅ [${ROUND}회차] 교체 완료"
done

log ""
log "================================================================"
log "🎉 롤링 배포 완료 (start-first)!"
log "   신버전 3개 실행 중 | 이미지 태그: ${IMAGE_TAG}"
log "================================================================"
