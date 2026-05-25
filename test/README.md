# k6 Blue-Green Load Test

## 목적

블루그린 전환 중에도 요청이 끊기지 않고, 응답이 `blue`에서 `green`으로 잘 바뀌는지 확인한다.

## 시나리오

1. `TARGET_URL`로 테스트할 서버 주소를 정한다.

2. 5분 동안 초당 20번 요청을 보낸다.
   - 총 약 6000번 요청한다.

3. 매 요청마다 `/` 경로를 호출한다.

```js
http.get(targetUrl + '/')
```

4. 응답이 블루인지 그린인지 확인한다.
   - `version - 1.0.0` -> blue
   - `version - 1.0.1` -> green

5. 결과에서 응답 수를 확인한다.
   - `blue_responses`
   - `green_responses`
   - `unknown_responses`

6. 실패 여부를 확인한다.
   - HTTP 상태 코드가 200인지
   - 응답에 `version`이 있는지
   - 응답 시간이 너무 느리지 않은지
   - 실패율이 1% 미만인지

## 실행

```powershell
docker compose -f test\docker-compose.yaml run --rm k6 run bluegreen.js
```

테스트 실행 중 서버의 `routers.yaml`을 `blue 100 / green 0`에서 `blue 0 / green 100`으로 변경한다.

## 기대 결과

초반에는 `blue_responses`가 증가하고, 전환 후에는 `green_responses`가 증가해야 한다.

`http_req_failed`와 `unknown_responses`는 거의 없어야 한다.
