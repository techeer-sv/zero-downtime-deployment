# 블루 그린 배포 뭐가 필요할까?

1. 서버 여러개 (일단 replica 3개씩 x 2)

# 어떻게 업데이트 될까?
1. 버젼 1.0.0 일단 돌아가고 있음 (블루)
2. 버젼 1.0.1로 올려야됨 (그린)
3. 그러면 일단 그린을 3개 실행 한다 (v1.0.1)
4. 그린을 검사 한다. 근데 어떻게?
    - health check?
    - 로그 분석?
    - 메트릭 분석?
5. 그린으로 요청들을 돌린다.
6. 그린 요청들이 멀쩡한거 같으면 블루를 내린다
7. 연결 끊겼는지/연결 됐는지 리버스 프록시에서 확인!

배포방법
1.blue.yaml를 띄운다  bash scripts/deploy-blue.sh
2.cat templates/blue-only.yaml > dynamic/routers.yaml수행
3.green을 띄운다  bash scripts/deploy-green.sh실행
4.green이 잘 돌아가는지 확인
5.green띄우기 cat templates/green-deployed.yaml > dynamic/routers.yaml수행
6.green에 weight 100 주기 cat templates/blue-deployed.yaml > dynamic/routers.yaml수행
7.블루 컨테이너를 라우터에서 제거 cat templates/green-only.yaml > dynamic/routers.yaml
8.블루 컨테이너 내리기 docker compose -f blue.yaml down
9.1.0.2v를 배포할 경우 블루에다가 올려서 위에 방법들을 반대로 진행
