# k6 부하 테스트

배포 전환 중에도 요청이 끊기지 않는지 검증하는 k6 부하 테스트다.
현재 블루-그린 시나리오를 기준으로 작성되어 있으며, 다른 배포 방식에도 사용 가능하다.

## 목적

- 배포 전환 중 HTTP 요청이 끊기지 않는지 확인한다
- 응답이 구버전(`v1.0.0`)에서 신버전(`v1.0.1`)으로 올바르게 전환되는지 확인한다
- 실패율·응답 속도가 허용 기준 이내인지 검증한다

## 시나리오

1. `TARGET_URL`로 지정한 서버에 지속적으로 요청을 보낸다
2. 테스트 실행 중 배포 스크립트를 별도로 실행해 버전을 전환한다
3. 전환 전후로 응답의 버전 문자열이 바뀌는 것을 카운터로 추적한다

## 실행

```bash
# 기본 실행 (TARGET_URL 필수)
TARGET_URL=http://localhost docker compose -f test/docker-compose.yaml run --rm k6 run bluegreen.js

# 옵션 조정 예시
TARGET_URL=http://192.168.0.10 K6_DURATION=3m K6_RPS=50 \
  docker compose -f test/docker-compose.yaml run --rm k6 run bluegreen.js
```

## 환경 변수

| 변수 | 기본값 | 설명 |
|------|--------|------|
| `TARGET_URL` | **(필수)** | 테스트 대상 서버 주소 (예: `http://localhost`) |
| `K6_VUS` | `10` | 사전 할당 가상 유저(VU) 수 |
| `K6_MAX_VUS` | `K6_VUS × 2` | 최대 가상 유저 수 |
| `K6_DURATION` | `10m` | 테스트 총 실행 시간 |
| `K6_RPS` | `20` | 초당 요청 수 (requests per second) |
| `EXPECTED_VERSION` | `""` (검사 안 함) | 예상 버전 문자열 (예: `v1.0.1`). 지정 시 다른 버전 응답을 `unexpected_version_rate`로 집계 |

## 메트릭

| 메트릭 | 설명 |
|--------|------|
| `blue_responses` | `version - v1.0.0` 응답 수 (구버전) |
| `green_responses` | `version - v1.0.1` 응답 수 (신버전) |
| `unknown_responses` | 두 버전 모두 아닌 응답 수 |
| `unexpected_version_rate` | `EXPECTED_VERSION`과 다른 응답 비율 |
| `http_req_failed` | HTTP 요청 실패율 |
| `http_req_duration` | 응답 시간 분포 |

## 성공 기준 (Thresholds)

| 조건 | 기준 |
|------|------|
| `http_req_failed` | 실패율 1% 미만 |
| `http_req_duration p(95)` | 500ms 미만 |
| `unexpected_version_rate` | 1% 미만 |

## 기대 결과

```
전환 전:  blue_responses  ↑↑↑   green_responses  ---
전환 중:  blue_responses  ↓↓↓   green_responses  ↑↑↑
전환 후:  blue_responses  ---   green_responses  ↑↑↑

http_req_failed    → 거의 0에 가까워야 함
unknown_responses  → 거의 0에 가까워야 함
```

## 웹 대시보드

k6 실행 중 실시간 메트릭을 브라우저에서 확인할 수 있다.

```
http://localhost:5665
```

`docker-compose.yaml`에 `K6_WEB_DASHBOARD=true`로 설정되어 있어 자동으로 활성화된다.

## 다른 배포 방식에서 사용하기

현재 스크립트(`bluegreen.js`)는 `version - v1.0.0` / `version - v1.0.1` 응답을 구분해 카운팅한다.
카나리나 롤링 배포 테스트에도 그대로 사용할 수 있다.

```bash
# 카나리 테스트: 전환 중 두 버전이 동시에 응답하는 것을 확인
TARGET_URL=http://localhost K6_DURATION=15m \
  docker compose -f test/docker-compose.yaml run --rm k6 run bluegreen.js
```
