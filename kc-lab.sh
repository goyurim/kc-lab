#!/usr/bin/env bash
# CKAD 실습 랩 설치 (Killercoda Playground 용). 사용: curl -fsSL <이 파일의 raw URL> | bash
set -e
D="${KC_LAB_DIR:-$HOME/kc-lab}"
rm -rf "$D"
mkdir -p "$D"
cat > "$D/README.md" <<'KCLAB_EOF_0'
# CKAD 실습 랩 (Killercoda용)

Killercoda의 CKAD(또는 Kubernetes) Playground에서 쓰는 드릴 15개.
세션이 끝나면 사라지므로, 세션마다 설치 한 줄을 다시 실행하세요.

  cd ~/kc-lab
  ./lab.sh env          # 환경 점검
  ./lab.sh list
  ./lab.sh start 01
  ./lab.sh check 01
  ./lab.sh solution 01
KCLAB_EOF_0
cat > "$D/lab.sh" <<'KCLAB_EOF_1'
#!/usr/bin/env bash
# CKAD practice lab runner for Killercoda playgrounds. Usage: ./lab.sh help
set -uo pipefail

LAB="$(cd "$(dirname "$0")" && pwd)"
export LAB
STATE="$LAB/.state"
mkdir -p "$STATE" "$LAB/answers"

B=$'\033[1m'; D=$'\033[2m'; G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; Z=$'\033[0m'

usage() {
  cat <<EOF
${B}CKAD 실습 랩 (Killercoda용)${Z}

  ./lab.sh env             환경 점검 (드릴별 지원 여부)
  ./lab.sh list            드릴 목록과 통과 여부 (이번 세션 기준)
  ./lab.sh start <번호>    드릴 환경 준비 + 문제 출력 + 타이머 시작
  ./lab.sh task <번호>     문제 다시 보기
  ./lab.sh check <번호>    채점 (걸린 시간 표시)
  ./lab.sh reset <번호>    드릴 환경 초기화 후 다시 시작
  ./lab.sh solution <번호> 모범 답안 보기 (다 풀고 나서!)
  ./lab.sh selftest [번호...]  모범 답안으로 드릴 자체 점검 (결과: selftest.log)

예) ./lab.sh start 09
EOF
}

drill_dir() {
  local id=$1 d
  case "$id" in [0-9]) id="0$id" ;; esac
  for d in "$LAB"/drills/"$id"-*; do
    if [ -d "$d" ]; then echo "$d"; return 0; fi
  done
  echo "${R}드릴 '$1' 을(를) 찾을 수 없습니다. ./lab.sh list 로 번호를 확인하세요.${Z}" >&2
  return 1
}

drill_id() { basename "$1" | cut -d- -f1; }

ensure_cluster() {
  if ! kubectl get --raw /readyz >/dev/null 2>&1; then
    echo "${R}클러스터에 연결할 수 없습니다. Killercoda의 Kubernetes/CKAD Playground에서 실행 중인지 확인하세요.${Z}"; exit 1
  fi
}

print_task() {
  local d=$1
  echo
  local ing node
  ing=$(cat "$STATE/ingress-url" 2>/dev/null || echo "(ingress 미설치)")
  node=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
  sed "s#{{LAB}}#$LAB#g; s#{{INGRESS_URL}}#$ing#g; s#{{NODE_IP}}#$node#g" "$d/task.md"
  echo
}

run_setup() {
  local d=$1
  (cd "$d" && DRILL_DIR="$d" bash "$d/setup.sh")
}

cmd_start() {
  local d; d=$(drill_dir "$1") || exit 1
  ensure_cluster
  echo "${D}환경 준비 중...${Z}"
  if ! run_setup "$d"; then echo "${R}환경 준비 실패${Z}"; exit 1; fi
  date +%s > "$STATE/$(drill_id "$d").start"
  rm -f "$STATE/$(drill_id "$d").pass"
  print_task "$d"
  echo "${Y}⏱  타이머 시작. 다 풀었으면: ./lab.sh check $(drill_id "$d")${Z}"
}

cmd_check() {
  local d id start now el rc; d=$(drill_dir "$1") || exit 1
  ensure_cluster
  id=$(drill_id "$d")
  echo "${B}[$(basename "$d")] 채점${Z}"
  (cd "$d" && DRILL_DIR="$d" bash "$d/check.sh")
  rc=$?
  if [ -f "$STATE/$id.start" ]; then
    start=$(cat "$STATE/$id.start"); now=$(date +%s); el=$((now - start))
    printf '%s⏱  경과 시간: %d분 %02d초%s' "$D" $((el / 60)) $((el % 60)) "$Z"
    if [ $el -gt 420 ]; then printf '  %s(실제 시험 기준 문제당 약 6~7분 — 반복 연습으로 단축해 보세요)%s' "$Y" "$Z"; fi
    echo
  fi
  if [ $rc -eq 0 ]; then date +%s > "$STATE/$id.pass"; fi
  exit $rc
}

cmd_list() {
  local d id title mark
  echo "${B}드릴 목록${Z}"
  for d in "$LAB"/drills/*/; do
    d=${d%/}
    id=$(drill_id "$d")
    title=$(head -n 1 "$d/task.md" | sed 's/^# *//')
    if [ -f "$STATE/$id.pass" ]; then mark="${G}✔${Z}"; else mark="${D}·${Z}"; fi
    printf ' %s %s\n' "$mark" "$title"
  done
}

cmd_solution() {
  local d; d=$(drill_dir "$1") || exit 1
  echo "${B}[$(basename "$d")] 모범 답안${Z} ${D}(정답은 여러 가지일 수 있습니다)${Z}"
  echo
  sed "s#\$DRILL_DIR#$d#g; s#\$LAB#$LAB#g" "$d/solution.sh" | grep -v '^#!/'
}

cmd_reset() {
  cmd_start "$1"
}

cmd_selftest() {
  local log="$LAB/selftest.log" d id ok=0 bad=0 list
  ensure_cluster
  : > "$log"
  if [ $# -gt 0 ]; then
    list=""
    for id in "$@"; do d=$(drill_dir "$id") || exit 1; list="$list $d"; done
  else
    list=$(ls -d "$LAB"/drills/*/ | sed 's#/$##')
  fi
  echo "selftest 시작: $(date)" | tee -a "$log"
  for d in $list; do
    id=$(drill_id "$d")
    {
      echo; echo "===== $(basename "$d") ====="
      echo "--- setup"; run_setup "$d" 2>&1
      echo "--- solution"; (cd "$d" && DRILL_DIR="$d" bash "$d/solution.sh") 2>&1
      echo "--- check"
    } >> "$log" 2>&1
    if (cd "$d" && DRILL_DIR="$d" bash "$d/check.sh") >> "$log" 2>&1; then
      ok=$((ok + 1)); echo "$(basename "$d"): PASS" | tee -a "$log"
    else
      bad=$((bad + 1)); echo "$(basename "$d"): FAIL" | tee -a "$log"
    fi
    if [ -f "$d/ns" ]; then
      for ns in $(cat "$d/ns"); do kubectl delete namespace "$ns" --ignore-not-found --wait=false >/dev/null 2>&1; done
    fi
    rm -f "$STATE/$id.pass"
  done
  echo | tee -a "$log"
  echo "selftest 완료: PASS $ok / FAIL $bad  ($(date))" | tee -a "$log"
  echo "SELFTEST_DONE" >> "$log"
}

cmd_env() {
  local cr cni sc ic
  ensure_cluster
  echo "${B}환경 점검${Z}"
  kubectl version 2>/dev/null | grep -i server
  kubectl get nodes -o wide
  echo
  cr=""; for c in docker podman; do command -v $c >/dev/null 2>&1 && cr="$cr $c"; done
  if [ -n "$cr" ]; then echo "${G}✔${Z} 컨테이너 런타임:$cr  → 11번 가능"; else echo "${Y}!${Z} docker/podman 없음 → 11번 불가"; fi
  ic=$(kubectl get ingressclass -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
  if [ -n "$ic" ]; then echo "${G}✔${Z} IngressClass: $ic"; else echo "${D}·${Z} IngressClass 없음 → 08번 start 때 ingress-nginx 자동 설치(1~2분)"; fi
  sc=$(kubectl get pods -A --no-headers 2>/dev/null | grep -c local-path)
  if [ "$sc" -gt 0 ]; then echo "${G}✔${Z} local-path 스토리지 프로비저너"; else echo "${D}·${Z} local-path 없음 → 14번 start 때 자동 설치"; fi
  cni=$(kubectl get pods -A --no-headers 2>/dev/null | grep -Eo 'calico|cilium|canal|weave|flannel|kindnet|antrea' | sort -u | tr '\n' ' ')
  case "$cni" in
    *calico*|*cilium*|*canal*|*weave*|*antrea*|*kindnet*) echo "${G}✔${Z} CNI: $cni → NetworkPolicy(09·10) 지원" ;;
    *flannel*) echo "${Y}!${Z} CNI: flannel 단독 → NetworkPolicy 미지원, 09·10번 차단 항목은 실패할 수 있음" ;;
    *) echo "${Y}?${Z} CNI 확인 불가: $cni → 09·10번은 직접 결과를 보고 판단" ;;
  esac
}

case "${1:-help}" in
  env) cmd_env ;;
  status) ensure_cluster; kubectl get nodes; echo; kubectl get ingressclass 2>/dev/null ;;
  list) cmd_list ;;
  start) [ $# -ge 2 ] || { usage; exit 1; }; cmd_start "$2" ;;
  task) [ $# -ge 2 ] || { usage; exit 1; }; d=$(drill_dir "$2") || exit 1; print_task "$d" ;;
  check) [ $# -ge 2 ] || { usage; exit 1; }; cmd_check "$2" ;;
  reset) [ $# -ge 2 ] || { usage; exit 1; }; cmd_reset "$2" ;;
  solution) [ $# -ge 2 ] || { usage; exit 1; }; cmd_solution "$2" ;;
  selftest) shift; cmd_selftest "$@" ;;
  help|-h|--help) usage ;;
  *) usage; exit 1 ;;
esac
KCLAB_EOF_1
cat > "$D/lib.sh" <<'KCLAB_EOF_2'
#!/usr/bin/env bash
# Shared helpers for check.sh / setup.sh scripts. Compatible with macOS bash 3.2.

PASS=0
FAIL=0

if [ -t 1 ]; then
  C_OK=$'\033[32m'; C_NG=$'\033[31m'; C_DIM=$'\033[2m'; C_B=$'\033[1m'; C_0=$'\033[0m'
else
  C_OK=""; C_NG=""; C_DIM=""; C_B=""; C_0=""
fi

ok() { printf '  %s✔%s %s\n' "$C_OK" "$C_0" "$1"; PASS=$((PASS + 1)); }
ng() {
  printf '  %s✘%s %s\n' "$C_NG" "$C_0" "$1"
  if [ -n "${2:-}" ]; then printf '      %s→ %s%s\n' "$C_DIM" "$2" "$C_0"; fi
  FAIL=$((FAIL + 1))
}

# expect_eq "description" "actual" "expected" ["hint"]
expect_eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else ng "$1" "기대값 '$3' / 실제값 '$2'"; fi
}

# expect_contains "description" "haystack" "needle" ["hint"]
expect_contains() {
  case "$2" in
    *"$3"*) ok "$1" ;;
    *) ng "$1" "'$3' 이(가) 포함되어야 함" ;;
  esac
}

# expect_not_contains "description" "haystack" "needle" ["hint"]
expect_not_contains() {
  case "$2" in
    *"$3"*) ng "$1" "'$3' 이(가) 있으면 안 됨" ;;
    *) ok "$1" ;;
  esac
}

# 정답을 드러내지 않는 버전 (찾아내는 것 자체가 문제인 항목용)
expect_eq_h() { if [ "$2" = "$3" ]; then ok "$1"; else ng "$1"; fi; }
expect_contains_h() { case "$2" in *"$3"*) ok "$1" ;; *) ng "$1" ;; esac; }

# expect_true "description" command... (command exit code 0 => pass)
expect_true() {
  local desc=$1; shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; else ng "$desc"; fi
}

# jp <kubectl get args...> : prints value or empty string, never fails
jp() { kubectl get "$@" 2>/dev/null || true; }

exists() { kubectl get "$@" >/dev/null 2>&1; }

# probe <namespace> <labels> <shell command>
# Starts a short-lived busybox Pod with the given labels, runs the command inside it,
# prints output and returns the command's exit code.
probe() {
  local ns=$1 labels=${2:-probe=1} cmd=$3 name out rc
  name="probe-$(date +%s)-$RANDOM"
  kubectl -n "$ns" run "$name" --image=busybox:1.36 --restart=Never \
    --labels="$labels" --command -- sleep 300 >/dev/null 2>&1 || return 99
  if ! kubectl -n "$ns" wait --for=condition=Ready "pod/$name" --timeout=120s >/dev/null 2>&1; then
    kubectl -n "$ns" delete pod "$name" --now --wait=false >/dev/null 2>&1
    return 98
  fi
  out=$(kubectl -n "$ns" exec "$name" -- sh -c "$cmd" 2>&1)
  rc=$?
  kubectl -n "$ns" delete pod "$name" --now --wait=false >/dev/null 2>&1
  printf '%s' "$out"
  return $rc
}

# reset_ns ns... : delete (wait) and recreate namespaces
reset_ns() {
  local ns
  for ns in "$@"; do
    kubectl delete namespace "$ns" --ignore-not-found --wait=true >/dev/null 2>&1
  done
  for ns in "$@"; do
    kubectl create namespace "$ns" >/dev/null
  done
}

wait_deploy() { kubectl -n "$1" rollout status "deployment/$2" --timeout="${3:-180s}" >/dev/null 2>&1; }

summary() {
  local total=$((PASS + FAIL))
  echo
  if [ "$FAIL" -eq 0 ]; then
    printf '%s%s결과: PASS (%d/%d)%s\n' "$C_B" "$C_OK" "$PASS" "$total" "$C_0"
    return 0
  else
    printf '%s%s결과: FAIL (%d/%d 통과)%s\n' "$C_B" "$C_NG" "$PASS" "$total" "$C_0"
    return 1
  fi
}

# ---------- Killercoda 환경 보조 ----------
node_ip() {
  local ip
  ip=$(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
  [ -z "$ip" ] && ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
  printf '%s' "$ip"
}

container_runtime() {
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then echo docker; return; fi
  if command -v podman >/dev/null 2>&1; then echo podman; return; fi
  echo ""
}

# 인그레스 컨트롤러가 없으면 ingress-nginx(baremetal, NodePort) 설치 후 접속 URL 을 .state/ingress-url 에 저장
ensure_ingress() {
  mkdir -p "$LAB/.state"
  if ! kubectl get ingressclass -o name 2>/dev/null | grep -q .; then
    echo "인그레스 컨트롤러 설치 중 (1~2분)..."
    kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/baremetal/deploy.yaml >/dev/null || return 1
    kubectl -n ingress-nginx wait --for=condition=Ready pod -l app.kubernetes.io/component=controller --timeout=240s >/dev/null || return 1
    sleep 10   # admission webhook 준비 대기
  fi
  local ns svc port ip
  ns=$(kubectl get svc -A -l app.kubernetes.io/component=controller -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null)
  svc=$(kubectl get svc -A -l app.kubernetes.io/component=controller -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  if [ -n "$svc" ]; then
    port=$(kubectl -n "$ns" get svc "$svc" -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}' 2>/dev/null)
    ip=$(node_ip)
    if [ -n "$port" ]; then echo "http://$ip:$port" > "$LAB/.state/ingress-url"; fi
    echo "http://$svc.$ns.svc" > "$LAB/.state/ingress-incluster"
  fi
  return 0
}

ensure_local_path() {
  if ! kubectl get pods -A --no-headers 2>/dev/null | grep -q local-path-provisioner; then
    echo "local-path 스토리지 프로비저너 설치 중..."
    kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml >/dev/null || return 1
    kubectl -n local-path-storage rollout status deploy/local-path-provisioner --timeout=180s >/dev/null || return 1
  fi
  return 0
}
KCLAB_EOF_2
mkdir -p "$D/drills"
mkdir -p "$D/drills/01-configmap"
cat > "$D/drills/01-configmap/check.sh" <<'KCLAB_EOF_3'
#!/usr/bin/env bash
source "$LAB/lib.sh"
NS=cfg-01
expect_eq "ConfigMap app-config: APP_MODE=production" "$(jp -n $NS cm app-config -o jsonpath='{.data.APP_MODE}')" "production"
expect_eq "ConfigMap app-config: APP_PORT=8080" "$(jp -n $NS cm app-config -o jsonpath='{.data.APP_PORT}')" "8080"
html=$(jp -n $NS cm app-html -o jsonpath='{.data.index\.html}')
expect_contains "ConfigMap app-html: key index.html 에 파일 내용" "$html" "ckad-lab-01"
expect_eq "Pod web Running" "$(jp -n $NS pod web -o jsonpath='{.status.phase}')" "Running"
expect_contains "Pod web: envFrom 으로 app-config 전체 로드" "$(jp -n $NS pod web -o jsonpath='{.spec.containers[0].envFrom[*].configMapRef.name}')" "app-config"
expect_eq "Pod web 안에서 APP_MODE 환경변수" "$(kubectl -n $NS exec web -- printenv APP_MODE 2>/dev/null)" "production"
mp=$(jp -n $NS pod web -o jsonpath='{range .spec.volumes[?(@.configMap.name=="app-html")]}{.name}{end}')
mountpath=""
[ -n "$mp" ] && mountpath=$(jp -n $NS pod web -o jsonpath="{.spec.containers[0].volumeMounts[?(@.name==\"$mp\")].mountPath}")
expect_eq "app-html 볼륨이 /usr/share/nginx/html 에 마운트" "$mountpath" "/usr/share/nginx/html"
expect_contains "nginx 가 ConfigMap 파일을 서빙" "$(kubectl -n $NS exec web -- wget -qO- 127.0.0.1 2>/dev/null)" "ckad-lab-01"
summary
KCLAB_EOF_3
cat > "$D/drills/01-configmap/index.html" <<'KCLAB_EOF_4'
<html><body><h1>ckad-lab-01: served from a ConfigMap</h1></body></html>
KCLAB_EOF_4
cat > "$D/drills/01-configmap/ns" <<'KCLAB_EOF_5'
cfg-01
KCLAB_EOF_5
cat > "$D/drills/01-configmap/setup.sh" <<'KCLAB_EOF_6'
#!/usr/bin/env bash
source "$LAB/lib.sh"
reset_ns cfg-01
KCLAB_EOF_6
cat > "$D/drills/01-configmap/solution.sh" <<'KCLAB_EOF_7'
#!/usr/bin/env bash
kubectl -n cfg-01 create configmap app-config --from-literal=APP_MODE=production --from-literal=APP_PORT=8080
kubectl -n cfg-01 create configmap app-html --from-file=index.html=$DRILL_DIR/index.html

cat <<'YAML' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: web
  namespace: cfg-01
spec:
  containers:
  - name: web
    image: nginx:alpine
    envFrom:
    - configMapRef:
        name: app-config
    volumeMounts:
    - name: html
      mountPath: /usr/share/nginx/html
  volumes:
  - name: html
    configMap:
      name: app-html
YAML
kubectl -n cfg-01 wait --for=condition=Ready pod/web --timeout=120s
kubectl -n cfg-01 exec web -- wget -qO- 127.0.0.1
KCLAB_EOF_7
cat > "$D/drills/01-configmap/task.md" <<'KCLAB_EOF_8'
# 01 ConfigMap — env + volume  [Config & Security]

Namespace: cfg-01

1. Create a ConfigMap `app-config` with the data `APP_MODE=production` and `APP_PORT=8080`.
2. Create a ConfigMap `app-html` that contains the content of `{{LAB}}/drills/01-configmap/index.html` under the data key `index.html`.
3. Create a Pod `web` (image `nginx:alpine`) that
   - loads ALL keys of `app-config` as environment variables, and
   - mounts `app-html` at `/usr/share/nginx/html`.
4. Verify that the Pod serves the file (e.g. `kubectl exec web -- wget -qO- 127.0.0.1`).
KCLAB_EOF_8
mkdir -p "$D/drills/02-secret"
cat > "$D/drills/02-secret/check.sh" <<'KCLAB_EOF_9'
#!/usr/bin/env bash
source "$LAB/lib.sh"
NS=sec-02
expect_eq "Secret db-cred 타입 Opaque" "$(jp -n $NS secret db-cred -o jsonpath='{.type}')" "Opaque"
expect_eq "Secret db-cred: user=admin" "$(jp -n $NS secret db-cred -o jsonpath='{.data.user}' | base64 --decode 2>/dev/null)" "admin"
expect_eq "Secret db-cred: pass=S3cr3t!" "$(jp -n $NS secret db-cred -o jsonpath='{.data.pass}' | base64 --decode 2>/dev/null)" 'S3cr3t!'
expect_eq "Pod db-client Running" "$(jp -n $NS pod db-client -o jsonpath='{.status.phase}')" "Running"
expect_eq "DB_USER 가 secretKeyRef(db-cred/user) 로 주입" "$(jp -n $NS pod db-client -o jsonpath='{.spec.containers[0].env[?(@.name=="DB_USER")].valueFrom.secretKeyRef.name}/{.spec.containers[0].env[?(@.name=="DB_USER")].valueFrom.secretKeyRef.key}')" "db-cred/user"
expect_eq "Pod 안에서 DB_USER=admin" "$(kubectl -n $NS exec db-client -- printenv DB_USER 2>/dev/null)" "admin"
expect_eq "/etc/db-cred/pass 파일 내용" "$(kubectl -n $NS exec db-client -- cat /etc/db-cred/pass 2>/dev/null)" 'S3cr3t!'
vol=$(jp -n $NS pod db-client -o jsonpath='{range .spec.volumes[?(@.secret.secretName=="db-cred")]}{.name}{end}')
ro=""
[ -n "$vol" ] && ro=$(jp -n $NS pod db-client -o jsonpath="{.spec.containers[0].volumeMounts[?(@.name==\"$vol\")].readOnly}")
expect_eq "Secret 볼륨 readOnly: true" "$ro" "true"
expect_eq "answers/02-pass.txt 내용" "$(tr -d '\n' < "$LAB/answers/02-pass.txt" 2>/dev/null)" 'S3cr3t!'
summary
KCLAB_EOF_9
cat > "$D/drills/02-secret/ns" <<'KCLAB_EOF_10'
sec-02
KCLAB_EOF_10
cat > "$D/drills/02-secret/setup.sh" <<'KCLAB_EOF_11'
#!/usr/bin/env bash
source "$LAB/lib.sh"
reset_ns sec-02
rm -f "$LAB/answers/02-pass.txt"
KCLAB_EOF_11
cat > "$D/drills/02-secret/solution.sh" <<'KCLAB_EOF_12'
#!/usr/bin/env bash
kubectl -n sec-02 create secret generic db-cred --from-literal=user=admin --from-literal='pass=S3cr3t!'

cat <<'YAML' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: db-client
  namespace: sec-02
spec:
  containers:
  - name: db-client
    image: busybox:1.36
    command: ["sleep", "3600"]
    env:
    - name: DB_USER
      valueFrom:
        secretKeyRef:
          name: db-cred
          key: user
    volumeMounts:
    - name: cred
      mountPath: /etc/db-cred
      readOnly: true
  volumes:
  - name: cred
    secret:
      secretName: db-cred
YAML
kubectl -n sec-02 wait --for=condition=Ready pod/db-client --timeout=120s
kubectl -n sec-02 get secret db-cred -o jsonpath='{.data.pass}' | base64 --decode > "$LAB/answers/02-pass.txt"
KCLAB_EOF_12
cat > "$D/drills/02-secret/task.md" <<'KCLAB_EOF_13'
# 02 Secret — env + volume  [Config & Security]

Namespace: sec-02

1. Create a generic Secret `db-cred` with `user=admin` and `pass=S3cr3t!`
2. Create a Pod `db-client` (image `busybox:1.36`, command `sleep 3600`) that
   - exposes the Secret key `user` as environment variable `DB_USER`, and
   - mounts the whole Secret read-only at `/etc/db-cred`.
3. Write the decoded value of the key `pass` (read from the cluster, not typed by hand) into `{{LAB}}/answers/02-pass.txt`
KCLAB_EOF_13
mkdir -p "$D/drills/03-securitycontext"
cat > "$D/drills/03-securitycontext/check.sh" <<'KCLAB_EOF_14'
#!/usr/bin/env bash
source "$LAB/lib.sh"
NS=sec-03
P='{.spec.template.spec.securityContext'
C='{.spec.template.spec.containers[?(@.name=="app")].securityContext'
expect_eq "Pod 레벨 runAsUser=1000" "$(jp -n $NS deploy secure-app -o jsonpath="$P.runAsUser}")" "1000"
expect_eq "Pod 레벨 runAsGroup=3000" "$(jp -n $NS deploy secure-app -o jsonpath="$P.runAsGroup}")" "3000"
expect_eq "Pod 레벨 fsGroup=2000" "$(jp -n $NS deploy secure-app -o jsonpath="$P.fsGroup}")" "2000"
expect_eq "Container allowPrivilegeEscalation=false" "$(jp -n $NS deploy secure-app -o jsonpath="$C.allowPrivilegeEscalation}")" "false"
expect_eq "Container privileged=false" "$(jp -n $NS deploy secure-app -o jsonpath="$C.privileged}")" "false"
expect_eq "Container readOnlyRootFilesystem=true" "$(jp -n $NS deploy secure-app -o jsonpath="$C.readOnlyRootFilesystem}")" "true"
expect_contains "Container capabilities.drop 에 ALL" "$(jp -n $NS deploy secure-app -o jsonpath="$C.capabilities.drop}")" "ALL"
expect_eq "replicas=2, 모두 Ready" "$(jp -n $NS deploy secure-app -o jsonpath='{.spec.replicas}/{.status.readyReplicas}/{.status.updatedReplicas}')" "2/2/2"
pod=$(jp -n $NS pod -l app=secure-app --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
expect_eq "실행 중인 컨테이너의 uid" "$(kubectl -n $NS exec "$pod" -- id -u 2>/dev/null)" "1000"
summary
KCLAB_EOF_14
cat > "$D/drills/03-securitycontext/ns" <<'KCLAB_EOF_15'
sec-03
KCLAB_EOF_15
cat > "$D/drills/03-securitycontext/setup.sh" <<'KCLAB_EOF_16'
#!/usr/bin/env bash
source "$LAB/lib.sh"
reset_ns sec-03
cat <<'YAML' | kubectl apply -f - >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: secure-app
  namespace: sec-03
spec:
  replicas: 1
  selector:
    matchLabels:
      app: secure-app
  template:
    metadata:
      labels:
        app: secure-app
    spec:
      containers:
      - name: app
        image: busybox:1.36
        command: ["sh", "-c", "while true; do sleep 5; done"]
YAML
wait_deploy sec-03 secure-app
KCLAB_EOF_16
cat > "$D/drills/03-securitycontext/solution.sh" <<'KCLAB_EOF_17'
#!/usr/bin/env bash
# kubectl -n sec-03 edit deploy secure-app 로 직접 수정해도 됩니다. 아래는 patch 예시.
kubectl -n sec-03 patch deployment secure-app --type=strategic -p '
spec:
  replicas: 2
  template:
    spec:
      securityContext:
        runAsUser: 1000
        runAsGroup: 3000
        fsGroup: 2000
      containers:
      - name: app
        securityContext:
          allowPrivilegeEscalation: false
          privileged: false
          readOnlyRootFilesystem: true
          capabilities:
            drop: ["ALL"]
'
kubectl -n sec-03 rollout status deployment/secure-app --timeout=180s
KCLAB_EOF_17
cat > "$D/drills/03-securitycontext/task.md" <<'KCLAB_EOF_18'
# 03 SecurityContext — Pod vs Container level  [Config & Security]

Namespace: sec-03

Deployment `secure-app` already exists. Modify it so that:

1. Pod level (applies to all containers):
   `runAsUser: 1000`, `runAsGroup: 3000`, `fsGroup: 2000`
2. Container `app` level:
   `allowPrivilegeEscalation: false`, `privileged: false`, `readOnlyRootFilesystem: true`,
   and drop ALL Linux capabilities.
3. Scale the Deployment to 2 replicas and make sure the rollout completes.
KCLAB_EOF_18
mkdir -p "$D/drills/04-rbac"
cat > "$D/drills/04-rbac/check.sh" <<'KCLAB_EOF_19'
#!/usr/bin/env bash
source "$LAB/lib.sh"
NS=rbac-04
SA=system:serviceaccount:rbac-04:pod-reader-sa
expect_true "ServiceAccount pod-reader-sa 존재" exists -n $NS sa pod-reader-sa
expect_eq "Role pod-reader 리소스=pods" "$(jp -n $NS role pod-reader -o jsonpath='{.rules[*].resources[*]}')" "pods"
expect_eq "RoleBinding → Role pod-reader" "$(jp -n $NS rolebinding pod-reader-binding -o jsonpath='{.roleRef.kind}/{.roleRef.name}')" "Role/pod-reader"
expect_contains "RoleBinding subject = SA pod-reader-sa" "$(jp -n $NS rolebinding pod-reader-binding -o jsonpath='{range .subjects[*]}{.kind}:{.namespace}:{.name} {end}')" "ServiceAccount:rbac-04:pod-reader-sa"
expect_eq "SA 가 pods list 가능" "$(kubectl auth can-i list pods -n $NS --as=$SA 2>/dev/null)" "yes"
expect_eq "SA 가 pods watch 가능" "$(kubectl auth can-i watch pods -n $NS --as=$SA 2>/dev/null)" "yes"
expect_eq "SA 가 pods delete 불가" "$(kubectl auth can-i delete pods -n $NS --as=$SA 2>/dev/null)" "no"
expect_eq "SA 가 secrets get 불가" "$(kubectl auth can-i get secrets -n $NS --as=$SA 2>/dev/null)" "no"
expect_eq "SA 가 다른 namespace(default) pods list 불가" "$(kubectl auth can-i list pods -n default --as=$SA 2>/dev/null)" "no"
expect_eq "Pod monitor 의 serviceAccountName" "$(jp -n $NS pod monitor -o jsonpath='{.spec.serviceAccountName}')" "pod-reader-sa"
expect_eq "Pod monitor Running" "$(jp -n $NS pod monitor -o jsonpath='{.status.phase}')" "Running"
expect_eq "answers/04-can-delete.txt" "$(tr -d '\n ' < "$LAB/answers/04-can-delete.txt" 2>/dev/null)" "no"
summary
KCLAB_EOF_19
cat > "$D/drills/04-rbac/ns" <<'KCLAB_EOF_20'
rbac-04
KCLAB_EOF_20
cat > "$D/drills/04-rbac/setup.sh" <<'KCLAB_EOF_21'
#!/usr/bin/env bash
source "$LAB/lib.sh"
reset_ns rbac-04
rm -f "$LAB/answers/04-can-delete.txt"
KCLAB_EOF_21
cat > "$D/drills/04-rbac/solution.sh" <<'KCLAB_EOF_22'
#!/usr/bin/env bash
kubectl -n rbac-04 create serviceaccount pod-reader-sa
kubectl -n rbac-04 create role pod-reader --verb=get,list,watch --resource=pods
kubectl -n rbac-04 create rolebinding pod-reader-binding --role=pod-reader --serviceaccount=rbac-04:pod-reader-sa

cat <<'YAML' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: monitor
  namespace: rbac-04
spec:
  serviceAccountName: pod-reader-sa
  containers:
  - name: monitor
    image: busybox:1.36
    command: ["sleep", "3600"]
YAML
kubectl -n rbac-04 wait --for=condition=Ready pod/monitor --timeout=120s
kubectl auth can-i list pods -n rbac-04 --as=system:serviceaccount:rbac-04:pod-reader-sa
kubectl auth can-i delete pods -n rbac-04 --as=system:serviceaccount:rbac-04:pod-reader-sa > "$LAB/answers/04-can-delete.txt"
KCLAB_EOF_22
cat > "$D/drills/04-rbac/task.md" <<'KCLAB_EOF_23'
# 04 ServiceAccount + RBAC  [Config & Security]

Namespace: rbac-04

1. Create a ServiceAccount `pod-reader-sa`.
2. Create a Role `pod-reader` that allows only `get`, `list` and `watch` on `pods`.
3. Bind the Role to the ServiceAccount with a RoleBinding `pod-reader-binding`.
4. Create a Pod `monitor` (image `busybox:1.36`, command `sleep 3600`) that runs as ServiceAccount `pod-reader-sa`.
5. Verify the permissions with `kubectl auth can-i ... --as=system:serviceaccount:rbac-04:pod-reader-sa`
   and write the output of "can it delete pods?" (yes/no) into `{{LAB}}/answers/04-can-delete.txt`
KCLAB_EOF_23
mkdir -p "$D/drills/05-resources-quota"
cat > "$D/drills/05-resources-quota/check.sh" <<'KCLAB_EOF_24'
#!/usr/bin/env bash
source "$LAB/lib.sh"
NS=res-05
reason=$(cat "$LAB/answers/05-reason.txt" 2>/dev/null)
expect_contains_h "answers/05-reason.txt 에 Pod 가 생성되지 않는 사유" "$reason" "quota"
expect_eq "ResourceQuota 는 그대로 (requests.cpu=1)" "$(jp -n $NS resourcequota team-quota -o jsonpath='{.spec.hard.requests\.cpu}')" "1"
R='{.spec.template.spec.containers[0].resources'
expect_eq "worker requests" "$(jp -n $NS deploy worker -o jsonpath="$R.requests.cpu}/$R.requests.memory}")" "100m/64Mi"
expect_eq "worker limits" "$(jp -n $NS deploy worker -o jsonpath="$R.limits.cpu}/$R.limits.memory}")" "200m/128Mi"
expect_eq "worker 2/2 Ready" "$(jp -n $NS deploy worker -o jsonpath='{.status.readyReplicas}')" "2"
expect_eq "Pod api requests" "$(jp -n $NS pod api -o jsonpath='{.spec.containers[0].resources.requests.cpu}/{.spec.containers[0].resources.requests.memory}')" "200m/128Mi"
expect_eq "Pod api limits" "$(jp -n $NS pod api -o jsonpath='{.spec.containers[0].resources.limits.cpu}/{.spec.containers[0].resources.limits.memory}')" "500m/256Mi"
expect_eq "Pod api Running" "$(jp -n $NS pod api -o jsonpath='{.status.phase}')" "Running"
summary
KCLAB_EOF_24
cat > "$D/drills/05-resources-quota/ns" <<'KCLAB_EOF_25'
res-05
KCLAB_EOF_25
cat > "$D/drills/05-resources-quota/setup.sh" <<'KCLAB_EOF_26'
#!/usr/bin/env bash
source "$LAB/lib.sh"
reset_ns res-05
rm -f "$LAB/answers/05-reason.txt"
cat <<'YAML' | kubectl apply -f - >/dev/null
apiVersion: v1
kind: ResourceQuota
metadata:
  name: team-quota
  namespace: res-05
spec:
  hard:
    requests.cpu: "1"
    requests.memory: 1Gi
    limits.cpu: "2"
    limits.memory: 2Gi
    pods: "5"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: worker
  namespace: res-05
spec:
  replicas: 2
  selector:
    matchLabels:
      app: worker
  template:
    metadata:
      labels:
        app: worker
    spec:
      containers:
      - name: worker
        image: busybox:1.36
        command: ["sh", "-c", "while true; do sleep 5; done"]
YAML
KCLAB_EOF_26
cat > "$D/drills/05-resources-quota/solution.sh" <<'KCLAB_EOF_27'
#!/usr/bin/env bash
# 1) 원인 확인: Pod 는 ReplicaSet 이 만들므로 RS 이벤트를 봅니다
kubectl -n res-05 describe rs -l app=worker | tail -5
for i in 1 2 3 4 5 6 7 8 9 10; do   # (selftest 용 대기 루프 — 직접 풀 때는 한 줄이면 충분)
  msg=$(kubectl -n res-05 get events --field-selector reason=FailedCreate -o jsonpath='{.items[0].message}')
  [ -n "$msg" ] && break; sleep 3
done
echo "$msg" > "$LAB/answers/05-reason.txt"
cat "$LAB/answers/05-reason.txt"; echo

# 2) 리소스 지정
kubectl -n res-05 set resources deployment worker --requests=cpu=100m,memory=64Mi --limits=cpu=200m,memory=128Mi
kubectl -n res-05 rollout status deployment/worker --timeout=180s

# 3) Pod api
cat <<'YAML' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: api
  namespace: res-05
spec:
  containers:
  - name: api
    image: nginx:alpine
    resources:
      requests:
        cpu: 200m
        memory: 128Mi
      limits:
        cpu: 500m
        memory: 256Mi
YAML
kubectl -n res-05 wait --for=condition=Ready pod/api --timeout=120s

# 4) 사용량
kubectl -n res-05 describe resourcequota team-quota
KCLAB_EOF_27
cat > "$D/drills/05-resources-quota/task.md" <<'KCLAB_EOF_28'
# 05 Requests/Limits + ResourceQuota  [Config & Security]

Namespace: res-05 (a ResourceQuota `team-quota` already exists)

Deployment `worker` should run 2 replicas, but no Pods are being created.

1. Find out why. Write the reason (the event message) into `{{LAB}}/answers/05-reason.txt`
2. Without changing the quota, update Deployment `worker` so that its container requests
   `cpu: 100m, memory: 64Mi` and has limits `cpu: 200m, memory: 128Mi`. Both replicas must become Ready.
3. Create a Pod `api` (image `nginx:alpine`) with requests `cpu: 200m, memory: 128Mi` and limits `cpu: 500m, memory: 256Mi`.
4. Check the used/hard values of the quota.
KCLAB_EOF_28
mkdir -p "$D/drills/06-service-fix"
cat > "$D/drills/06-service-fix/check.sh" <<'KCLAB_EOF_29'
#!/usr/bin/env bash
source "$LAB/lib.sh"
NS=net-06
expect_eq "Deployment shop 의 selector 는 그대로 (app=shop,tier=web)" "$(jp -n $NS deploy shop -o jsonpath='{.spec.selector.matchLabels.app},{.spec.selector.matchLabels.tier}')" "shop,web"
eps=$(jp -n $NS endpointslices -l kubernetes.io/service-name=shop-svc -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]} {end}')
n=0; for a in $eps; do n=$((n + 1)); done
expect_eq_h "shop-svc 가 shop Pod 2개를 엔드포인트로 가짐" "$n" "2"
expect_eq_h "shop-svc 포트 설정이 Pod 와 일치" "$(jp -n $NS svc shop-svc -o jsonpath='{.spec.ports[0].targetPort}')" "80"
out=$(probe $NS probe=1 'wget -qO- -T 5 http://shop-svc.net-06:80')
expect_contains "임시 Pod 에서 shop-svc 접속 성공" "$out" "Welcome to nginx"
summary
KCLAB_EOF_29
cat > "$D/drills/06-service-fix/ns" <<'KCLAB_EOF_30'
net-06
KCLAB_EOF_30
cat > "$D/drills/06-service-fix/setup.sh" <<'KCLAB_EOF_31'
#!/usr/bin/env bash
source "$LAB/lib.sh"
reset_ns net-06
cat <<'YAML' | kubectl apply -f - >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: shop
  namespace: net-06
spec:
  replicas: 2
  selector:
    matchLabels:
      app: shop
      tier: web
  template:
    metadata:
      labels:
        app: shop
        tier: web
    spec:
      containers:
      - name: nginx
        image: nginx:alpine
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: shop-svc
  namespace: net-06
spec:
  selector:
    app: shopp
    tier: web
  ports:
  - port: 80
    targetPort: 8080
YAML
wait_deploy net-06 shop
KCLAB_EOF_31
cat > "$D/drills/06-service-fix/solution.sh" <<'KCLAB_EOF_32'
#!/usr/bin/env bash
kubectl -n net-06 get endpoints shop-svc          # <none> → selector 문제
kubectl -n net-06 get pod --show-labels           # 실제 라벨: app=shop,tier=web
kubectl -n net-06 patch svc shop-svc -p '{"spec":{"selector":{"app":"shop","tier":"web"},"ports":[{"port":80,"targetPort":80}]}}'
kubectl -n net-06 get endpoints shop-svc
kubectl -n net-06 run tmp --rm -i --restart=Never --image=busybox:1.36 -- wget -qO- -T 5 shop-svc | head -4
KCLAB_EOF_32
cat > "$D/drills/06-service-fix/task.md" <<'KCLAB_EOF_33'
# 06 Service 트러블슈팅 — selector / targetPort  [Services & Networking]

Namespace: net-06

Deployment `shop` (2 replicas, nginx) is running and Service `shop-svc` should expose it on port 80,
but requests to `shop-svc` time out.

1. Find out why and fix the Service so that `http://shop-svc.net-06:80` reaches the Pods of `shop`.
   Do NOT modify the Deployment.
2. Verify from a temporary Pod:
   `kubectl -n net-06 run tmp --rm -it --restart=Never --image=busybox:1.36 -- wget -qO- -T 3 shop-svc`
KCLAB_EOF_33
mkdir -p "$D/drills/07-nodeport"
cat > "$D/drills/07-nodeport/check.sh" <<'KCLAB_EOF_34'
#!/usr/bin/env bash
source "$LAB/lib.sh"
NS=net-07
expect_eq "echo-svc type=NodePort" "$(jp -n $NS svc echo-svc -o jsonpath='{.spec.type}')" "NodePort"
expect_eq "nodePort=30100" "$(jp -n $NS svc echo-svc -o jsonpath='{.spec.ports[0].nodePort}')" "30100"
expect_eq "port 80 / targetPort 5678 유지" "$(jp -n $NS svc echo-svc -o jsonpath='{.spec.ports[0].port}/{.spec.ports[0].targetPort}')" "80/5678"
nodeip=$(node_ip)
out=$(probe $NS probe=1 "wget -qO- -T 5 http://$nodeip:30100")
expect_contains "워커 노드 InternalIP:30100 접속" "$out" "hello from net-07"
expect_contains "answers/07-curl.txt 에 응답 저장" "$(cat "$LAB/answers/07-curl.txt" 2>/dev/null)" "hello from net-07"
summary
KCLAB_EOF_34
cat > "$D/drills/07-nodeport/ns" <<'KCLAB_EOF_35'
net-07
KCLAB_EOF_35
cat > "$D/drills/07-nodeport/setup.sh" <<'KCLAB_EOF_36'
#!/usr/bin/env bash
source "$LAB/lib.sh"
reset_ns net-07
rm -f "$LAB/answers/07-curl.txt"
cat <<'YAML' | kubectl apply -f - >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: echo
  namespace: net-07
spec:
  replicas: 1
  selector:
    matchLabels:
      app: echo
  template:
    metadata:
      labels:
        app: echo
    spec:
      containers:
      - name: echo
        image: hashicorp/http-echo:1.0
        args: ["-text=hello from net-07"]
        ports:
        - containerPort: 5678
---
apiVersion: v1
kind: Service
metadata:
  name: echo-svc
  namespace: net-07
spec:
  selector:
    app: echo
  ports:
  - port: 80
    targetPort: 5678
YAML
wait_deploy net-07 echo
KCLAB_EOF_36
cat > "$D/drills/07-nodeport/solution.sh" <<'KCLAB_EOF_37'
#!/usr/bin/env bash
kubectl -n net-07 patch svc echo-svc -p '{"spec":{"type":"NodePort","ports":[{"port":80,"targetPort":5678,"nodePort":30100}]}}'
kubectl -n net-07 get svc echo-svc
kubectl get nodes -o wide
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
curl -s "http://$NODE_IP:30100" > "$LAB/answers/07-curl.txt"
cat "$LAB/answers/07-curl.txt"
KCLAB_EOF_37
cat > "$D/drills/07-nodeport/task.md" <<'KCLAB_EOF_38'
# 07 ClusterIP → NodePort  [Services & Networking]

Namespace: net-07

Deployment `echo` is exposed by the ClusterIP Service `echo-svc` (port 80).

1. Change `echo-svc` to type NodePort so it is reachable on all nodes on port `30100`.
2. Test it on a node of the cluster: curl the node's internal IP on port 30100.
3. Write the response of the curl into `{{LAB}}/answers/07-curl.txt`
KCLAB_EOF_38
mkdir -p "$D/drills/08-ingress"
cat > "$D/drills/08-ingress/check.sh" <<'KCLAB_EOF_39'
#!/usr/bin/env bash
source "$LAB/lib.sh"
NS=net-08
cls=$(jp ingressclass -o jsonpath='{.items[0].metadata.name}')
expect_eq_h "Ingress app-ing 의 ingressClassName = 기존 IngressClass" "$(jp -n $NS ingress app-ing -o jsonpath='{.spec.ingressClassName}')" "$cls"
expect_eq "host=app.ckad.local" "$(jp -n $NS ingress app-ing -o jsonpath='{.spec.rules[0].host}')" "app.ckad.local"
expect_eq_h "/app1 → app1-svc (올바른 포트)" "$(jp -n $NS ingress app-ing -o jsonpath='{.spec.rules[0].http.paths[?(@.path=="/app1")].backend.service.name}:{.spec.rules[0].http.paths[?(@.path=="/app1")].backend.service.port.number}')" "app1-svc:80"
expect_eq_h "/app2 → app2-svc (올바른 포트)" "$(jp -n $NS ingress app-ing -o jsonpath='{.spec.rules[0].http.paths[?(@.path=="/app2")].backend.service.name}:{.spec.rules[0].http.paths[?(@.path=="/app2")].backend.service.port.number}')" "app2-svc:8080"
expect_eq "Service 는 2개 그대로" "$(jp -n $NS svc -o jsonpath='{.items[*].metadata.name}')" "app1-svc app2-svc"
url=$(cat "$LAB/.state/ingress-url" 2>/dev/null)
o1=""
for i in 1 2 3 4 5 6; do
  if [ -n "$url" ]; then
    o1="$(curl -s -m 5 -H 'Host: app.ckad.local' "$url/app1"; echo; curl -s -m 5 -H 'Host: app.ckad.local' "$url/app2")"
  else
    ctrl=$(cat "$LAB/.state/ingress-incluster" 2>/dev/null || echo http://ingress-nginx-controller.ingress-nginx.svc)
    o1=$(probe $NS probe=1 "wget -qO- -T 5 --header 'Host: app.ckad.local' $ctrl/app1; echo; wget -qO- -T 5 --header 'Host: app.ckad.local' $ctrl/app2")
  fi
  case "$o1" in *app1*app2*) break ;; esac
  sleep 5
done
expect_contains "Ingress 경유 /app1 응답" "$o1" "app1"
expect_contains "Ingress 경유 /app2 응답" "$o1" "app2"
summary
KCLAB_EOF_39
cat > "$D/drills/08-ingress/ns" <<'KCLAB_EOF_40'
net-08
KCLAB_EOF_40
cat > "$D/drills/08-ingress/setup.sh" <<'KCLAB_EOF_41'
#!/usr/bin/env bash
source "$LAB/lib.sh"
ensure_ingress || { echo "[오류] 인그레스 컨트롤러를 준비하지 못했습니다. 08번은 건너뛰세요."; exit 1; }
reset_ns net-08
for n in 1 2; do
  port=80; [ $n -eq 2 ] && port=8080
  cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app$n
  namespace: net-08
spec:
  replicas: 1
  selector:
    matchLabels:
      app: app$n
  template:
    metadata:
      labels:
        app: app$n
    spec:
      containers:
      - name: echo
        image: hashicorp/http-echo:1.0
        args: ["-text=app$n"]
        ports:
        - containerPort: 5678
---
apiVersion: v1
kind: Service
metadata:
  name: app$n-svc
  namespace: net-08
spec:
  selector:
    app: app$n
  ports:
  - port: $port
    targetPort: 5678
YAML
done
wait_deploy net-08 app1; wait_deploy net-08 app2
KCLAB_EOF_41
cat > "$D/drills/08-ingress/solution.sh" <<'KCLAB_EOF_42'
#!/usr/bin/env bash
kubectl get ingressclass                 # 이름 확인 (아래는 nginx 기준)
kubectl -n net-08 get svc                # app1-svc:80, app2-svc:8080

IC=$(kubectl get ingressclass -o jsonpath='{.items[0].metadata.name}')
cat <<YAML | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: app-ing
  namespace: net-08
spec:
  ingressClassName: $IC
  rules:
  - host: app.ckad.local
    http:
      paths:
      - path: /app1
        pathType: Prefix
        backend:
          service:
            name: app1-svc
            port:
              number: 80
      - path: /app2
        pathType: Prefix
        backend:
          service:
            name: app2-svc
            port:
              number: 8080
YAML
# 명령형 대안:
# kubectl -n net-08 create ingress app-ing --class=$IC \
#   --rule="app.ckad.local/app1*=app1-svc:80" --rule="app.ckad.local/app2*=app2-svc:8080"
sleep 5
curl -s -H 'Host: app.ckad.local' "$(cat "$LAB/.state/ingress-url")/app1" || true
KCLAB_EOF_42
cat > "$D/drills/08-ingress/task.md" <<'KCLAB_EOF_43'
# 08 Ingress — path routing  [Services & Networking]

Namespace: net-08

Deployments `app1`, `app2` and Services `app1-svc` (port 80), `app2-svc` (port 8080) already exist.
An Ingress controller is installed and reachable via {{INGRESS_URL}}

Create an Ingress `app-ing` in Namespace net-08:
- use and set the existing IngressClass
- host `app.ckad.local`
- path `/app1` (Prefix) → `app1-svc`, path `/app2` (Prefix) → `app2-svc`
- use the existing Services, do not create new ones

Test: `curl -H 'Host: app.ckad.local' {{INGRESS_URL}}/app1` → app1, `/app2` → app2
KCLAB_EOF_43
mkdir -p "$D/drills/09-networkpolicy"
cat > "$D/drills/09-networkpolicy/check.sh" <<'KCLAB_EOF_44'
#!/usr/bin/env bash
source "$LAB/lib.sh"
NS=net-09
expect_true "NetworkPolicy default-deny-ingress 존재" exists -n $NS networkpolicy default-deny-ingress
expect_eq "default-deny-ingress: 모든 Pod 선택 (podSelector {})" "$(jp -n $NS networkpolicy default-deny-ingress -o jsonpath='{.spec.podSelector}')" "{}"
expect_contains "default-deny-ingress: policyTypes 에 Ingress" "$(jp -n $NS networkpolicy default-deny-ingress -o jsonpath='{.spec.policyTypes}')" "Ingress"
expect_eq "backend-allow-frontend: app=backend 선택" "$(jp -n $NS networkpolicy backend-allow-frontend -o jsonpath='{.spec.podSelector.matchLabels.app}')" "backend"
expect_eq "backend-allow-frontend: 포트 5678" "$(jp -n $NS networkpolicy backend-allow-frontend -o jsonpath='{.spec.ingress[0].ports[0].port}')" "5678"
sleep 3
out=$(probe $NS role=frontend 'wget -qO- -T 4 http://backend')
expect_contains "role=frontend Pod → backend 접속 허용" "$out" "backend-ok"
out=$(probe $NS role=other 'wget -qO- -T 4 http://backend')
expect_not_contains "라벨 없는 Pod → backend 차단" "$out" "backend-ok"
summary
KCLAB_EOF_44
cat > "$D/drills/09-networkpolicy/ns" <<'KCLAB_EOF_45'
net-09
KCLAB_EOF_45
cat > "$D/drills/09-networkpolicy/setup.sh" <<'KCLAB_EOF_46'
#!/usr/bin/env bash
source "$LAB/lib.sh"
reset_ns net-09
cat <<'YAML' | kubectl apply -f - >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend
  namespace: net-09
spec:
  replicas: 1
  selector:
    matchLabels:
      app: backend
  template:
    metadata:
      labels:
        app: backend
    spec:
      containers:
      - name: echo
        image: hashicorp/http-echo:1.0
        args: ["-text=backend-ok"]
        ports:
        - containerPort: 5678
---
apiVersion: v1
kind: Service
metadata:
  name: backend
  namespace: net-09
spec:
  selector:
    app: backend
  ports:
  - port: 80
    targetPort: 5678
YAML
wait_deploy net-09 backend
KCLAB_EOF_46
cat > "$D/drills/09-networkpolicy/solution.sh" <<'KCLAB_EOF_47'
#!/usr/bin/env bash
cat <<'YAML' | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: net-09
spec:
  podSelector: {}
  policyTypes:
  - Ingress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: backend-allow-frontend
  namespace: net-09
spec:
  podSelector:
    matchLabels:
      app: backend
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          role: frontend
    ports:
    - protocol: TCP
      port: 5678
YAML
KCLAB_EOF_47
cat > "$D/drills/09-networkpolicy/task.md" <<'KCLAB_EOF_48'
# 09 NetworkPolicy — default deny + allow from label  [Services & Networking]

Namespace: net-09

Deployment `backend` (label `app=backend`, container port 5678) and Service `backend` (port 80) exist.

1. Create a NetworkPolicy `default-deny-ingress` that denies ALL incoming traffic to ALL Pods in net-09.
2. Create a NetworkPolicy `backend-allow-frontend` that allows incoming traffic to Pods with `app=backend`
   ONLY from Pods in the same Namespace that have the label `role=frontend`, and only on TCP port 5678.
3. Verify:
   - `kubectl -n net-09 run fe --rm -it --restart=Never --image=busybox:1.36 --labels=role=frontend -- wget -qO- -T 3 backend` → works
   - the same without the label → times out
KCLAB_EOF_48
mkdir -p "$D/drills/10-networkpolicy-ns-egress"
cat > "$D/drills/10-networkpolicy-ns-egress/check.sh" <<'KCLAB_EOF_49'
#!/usr/bin/env bash
source "$LAB/lib.sh"
expect_eq "net-10-app 라벨 team=app 유지" "$(jp ns net-10-app -o jsonpath='{.metadata.labels.team}')" "app"
expect_eq "db-allow-app: app=db 선택" "$(jp -n net-10-db networkpolicy db-allow-app -o jsonpath='{.spec.podSelector.matchLabels.app}')" "db"
expect_contains "db-allow-app: namespaceSelector team=app" "$(jp -n net-10-db networkpolicy db-allow-app -o jsonpath='{.spec.ingress[*].from[*].namespaceSelector.matchLabels}')" '"team":"app"'
expect_contains "app-egress: policyTypes 에 Egress" "$(jp -n net-10-app networkpolicy app-egress -o jsonpath='{.spec.policyTypes}')" "Egress"
expect_eq "app-egress: 모든 Pod 선택" "$(jp -n net-10-app networkpolicy app-egress -o jsonpath='{.spec.podSelector}')" "{}"
sleep 3
out=$(probe net-10-app probe=1 'wget -qO- -T 4 http://db.net-10-db')
expect_contains "net-10-app → db 허용" "$out" "db-ok"
out=$(probe net-10-other probe=1 'wget -qO- -T 4 http://db.net-10-db')
expect_not_contains "net-10-other → db 차단" "$out" "db-ok"
out=$(probe net-10-app probe=1 'wget -qO- -T 4 http://other.net-10-other')
expect_not_contains "net-10-app → other 차단 (egress)" "$out" "other-ok"
summary
KCLAB_EOF_49
cat > "$D/drills/10-networkpolicy-ns-egress/ns" <<'KCLAB_EOF_50'
net-10-db net-10-app net-10-other
KCLAB_EOF_50
cat > "$D/drills/10-networkpolicy-ns-egress/setup.sh" <<'KCLAB_EOF_51'
#!/usr/bin/env bash
source "$LAB/lib.sh"
reset_ns net-10-db net-10-app net-10-other
kubectl label namespace net-10-app team=app --overwrite >/dev/null
for pair in "net-10-db db" "net-10-other other"; do
  set -- $pair
  cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $2
  namespace: $1
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $2
  template:
    metadata:
      labels:
        app: $2
    spec:
      containers:
      - name: echo
        image: hashicorp/http-echo:1.0
        args: ["-text=$2-ok"]
        ports:
        - containerPort: 5678
---
apiVersion: v1
kind: Service
metadata:
  name: $2
  namespace: $1
spec:
  selector:
    app: $2
  ports:
  - port: 80
    targetPort: 5678
YAML
done
wait_deploy net-10-db db; wait_deploy net-10-other other
KCLAB_EOF_51
cat > "$D/drills/10-networkpolicy-ns-egress/solution.sh" <<'KCLAB_EOF_52'
#!/usr/bin/env bash
cat <<'YAML' | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: db-allow-app
  namespace: net-10-db
spec:
  podSelector:
    matchLabels:
      app: db
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          team: app
    ports:
    - protocol: TCP
      port: 5678
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: app-egress
  namespace: net-10-app
spec:
  podSelector: {}
  policyTypes:
  - Egress
  egress:
  - to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: net-10-db
    ports:
    - protocol: TCP
      port: 5678
  - ports:
    - protocol: UDP
      port: 53
    - protocol: TCP
      port: 53
YAML
KCLAB_EOF_52
cat > "$D/drills/10-networkpolicy-ns-egress/task.md" <<'KCLAB_EOF_53'
# 10 NetworkPolicy — namespaceSelector + egress  [Services & Networking]

Namespaces: net-10-db, net-10-app (label `team=app`), net-10-other

- net-10-db: Deployment `db` (label `app=db`, port 5678), Service `db` (port 80)
- net-10-other: Deployment `other` (port 5678), Service `other` (port 80)

1. In net-10-db create NetworkPolicy `db-allow-app`: Pods with `app=db` accept incoming traffic
   ONLY from Pods in Namespaces labeled `team=app`, on TCP 5678.
2. In net-10-app create NetworkPolicy `app-egress`: ALL Pods in net-10-app may send traffic ONLY to
   - Pods in Namespace `net-10-db` on TCP 5678, and
   - DNS (UDP and TCP 53) anywhere.
3. Result:
   - net-10-app → db.net-10-db works
   - net-10-other → db.net-10-db is blocked
   - net-10-app → other.net-10-other is blocked
KCLAB_EOF_53
mkdir -p "$D/drills/11-image-build"
cat > "$D/drills/11-image-build/check.sh" <<'KCLAB_EOF_54'
#!/usr/bin/env bash
source "$LAB/lib.sh"
CR=$(container_runtime)
if grep -Eq '^ENV[[:space:]]+APP_VERSION[[:space:]=]+"?v1"?[[:space:]]*$' "$DRILL_DIR/app/Dockerfile"; then
  ok "Dockerfile 에 ENV APP_VERSION=v1"
else
  ng "Dockerfile 에 ENV APP_VERSION=v1"
fi
tags=$(curl -s --max-time 5 http://localhost:5000/v2/hello-ckad/tags/list 2>/dev/null)
expect_contains "레지스트리에 hello-ckad:v1 push" "$tags" '"v1"'
expect_eq "컨테이너 hello-ckad 실행 중" "$($CR inspect -f '{{.State.Running}}' hello-ckad 2>/dev/null)" "true"
expect_contains "컨테이너 이미지" "$($CR inspect -f '{{.Config.Image}}' hello-ckad 2>/dev/null)" "localhost:5000/hello-ckad:v1"
expect_contains "컨테이너 로그에 'hello from v1'" "$($CR logs hello-ckad 2>&1)" "hello from v1"
expect_contains "answers/11-logs.txt" "$(cat "$LAB/answers/11-logs.txt" 2>/dev/null)" "hello from v1"
listing=$(tar tf "$LAB/answers/hello-ckad.tar" 2>/dev/null)
expect_contains "answers/hello-ckad.tar 이 이미지 아카이브" "$listing" "manifest.json"
summary
KCLAB_EOF_54
cat > "$D/drills/11-image-build/ns" <<'KCLAB_EOF_55'

KCLAB_EOF_55
cat > "$D/drills/11-image-build/setup.sh" <<'KCLAB_EOF_56'
#!/usr/bin/env bash
source "$LAB/lib.sh"
CR=$(container_runtime)
if [ -z "$CR" ]; then echo "[오류] 이 환경에는 docker/podman 이 없어 11번은 진행할 수 없습니다."; exit 1; fi
if ! $CR ps --format '{{.Names}}' 2>/dev/null | grep -qx kc-registry; then
  $CR rm -f kc-registry >/dev/null 2>&1
  $CR run -d --name kc-registry -p 5000:5000 docker.io/library/registry:2 >/dev/null || { echo "[오류] 레지스트리 시작 실패"; exit 1; }
fi
$CR rm -f hello-ckad >/dev/null 2>&1
$CR rmi -f localhost:5000/hello-ckad:v1 >/dev/null 2>&1
rm -rf "$DRILL_DIR/app" && cp -R "$DRILL_DIR/app.orig" "$DRILL_DIR/app"
rm -f "$LAB/answers/11-logs.txt" "$LAB/answers/hello-ckad.tar"
KCLAB_EOF_56
cat > "$D/drills/11-image-build/solution.sh" <<'KCLAB_EOF_57'
#!/usr/bin/env bash
CR=docker; command -v docker >/dev/null 2>&1 || CR=podman
cd "$DRILL_DIR/app" || exit 1
# 1) Dockerfile 수정 (vi 로 FROM 아래에 ENV APP_VERSION=v1 추가)
printf 'FROM busybox:1.36\nENV APP_VERSION=v1\nCOPY hello.sh /hello.sh\nCMD ["sh", "/hello.sh"]\n' > Dockerfile
# 2) build / push  (podman: push 에 --tls-verify=false)
$CR build -t localhost:5000/hello-ckad:v1 .
if [ "$CR" = podman ]; then $CR push --tls-verify=false localhost:5000/hello-ckad:v1; else $CR push localhost:5000/hello-ckad:v1; fi
# 3) 백그라운드 실행
$CR run -d --name hello-ckad localhost:5000/hello-ckad:v1
sleep 3
# 4) 로그
$CR logs hello-ckad > "$LAB/answers/11-logs.txt" 2>&1
# 5) save (불러오기는 load -i <파일>)
$CR save -o "$LAB/answers/hello-ckad.tar" localhost:5000/hello-ckad:v1
KCLAB_EOF_57
cat > "$D/drills/11-image-build/task.md" <<'KCLAB_EOF_58'
# 11 컨테이너 이미지 build / push / run / save  [Application Design and Build]

Files: `{{LAB}}/drills/11-image-build/app`   ·   Local registry: `localhost:5000`
Use `docker` (or `podman` if docker is not available; with podman push using `--tls-verify=false`).

1. Change the Dockerfile: set the ENV variable `APP_VERSION` to the hardcoded value `v1`.
2. Build the image, tag it `localhost:5000/hello-ckad:v1` and push it to the registry.
3. Run a container named `hello-ckad` from that image, which keeps running detached in the background.
4. Write the logs the container produces into `{{LAB}}/answers/11-logs.txt`
5. Save the image as a tar archive at `{{LAB}}/answers/hello-ckad.tar`
KCLAB_EOF_58
mkdir -p "$D/drills/11-image-build/app.orig"
cat > "$D/drills/11-image-build/app.orig/Dockerfile" <<'KCLAB_EOF_59'
FROM busybox:1.36
COPY hello.sh /hello.sh
CMD ["sh", "/hello.sh"]
KCLAB_EOF_59
cat > "$D/drills/11-image-build/app.orig/hello.sh" <<'KCLAB_EOF_60'
#!/bin/sh
while true; do
  echo "hello from ${APP_VERSION:-unknown}"
  sleep 5
done
KCLAB_EOF_60
mkdir -p "$D/drills/12-init-sidecar"
cat > "$D/drills/12-init-sidecar/check.sh" <<'KCLAB_EOF_61'
#!/usr/bin/env bash
source "$LAB/lib.sh"
NS=build-12
expect_eq "Pod log-app Running" "$(jp -n $NS pod log-app -o jsonpath='{.status.phase}')" "Running"
expect_eq "emptyDir 볼륨 logs" "$(jp -n $NS pod log-app -o jsonpath='{.spec.volumes[?(@.name=="logs")].emptyDir}')" "{}"
expect_contains "initContainer init-config 존재" "$(jp -n $NS pod log-app -o jsonpath='{.spec.initContainers[*].name}')" "init-config"
expect_eq "log-shipper 는 restartPolicy: Always 인 initContainer" "$(jp -n $NS pod log-app -o jsonpath='{.spec.initContainers[?(@.name=="log-shipper")].restartPolicy}')" "Always"
expect_eq "메인 컨테이너는 app 하나" "$(jp -n $NS pod log-app -o jsonpath='{.spec.containers[*].name}')" "app"
expect_eq "status.txt = initialized" "$(kubectl -n $NS exec log-app -c app -- cat /var/log/app/status.txt 2>/dev/null)" "initialized"
sleep 3
logs=$(kubectl -n $NS logs log-app -c log-shipper --tail=5 2>/dev/null)
expect_contains "log-shipper 가 app.log 를 출력" "$logs" "UTC"
summary
KCLAB_EOF_61
cat > "$D/drills/12-init-sidecar/ns" <<'KCLAB_EOF_62'
build-12
KCLAB_EOF_62
cat > "$D/drills/12-init-sidecar/setup.sh" <<'KCLAB_EOF_63'
#!/usr/bin/env bash
source "$LAB/lib.sh"
reset_ns build-12
KCLAB_EOF_63
cat > "$D/drills/12-init-sidecar/solution.sh" <<'KCLAB_EOF_64'
#!/usr/bin/env bash
cat <<'YAML' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: log-app
  namespace: build-12
spec:
  volumes:
  - name: logs
    emptyDir: {}
  initContainers:
  - name: init-config
    image: busybox:1.36
    command: ["sh", "-c", "echo initialized > /var/log/app/status.txt"]
    volumeMounts:
    - name: logs
      mountPath: /var/log/app
  - name: log-shipper
    image: busybox:1.36
    restartPolicy: Always
    command: ["sh", "-c", "touch /var/log/app/app.log; tail -F /var/log/app/app.log"]
    volumeMounts:
    - name: logs
      mountPath: /var/log/app
  containers:
  - name: app
    image: busybox:1.36
    command: ["sh", "-c", "while true; do date >> /var/log/app/app.log; sleep 2; done"]
    volumeMounts:
    - name: logs
      mountPath: /var/log/app
YAML
kubectl -n build-12 wait --for=condition=Ready pod/log-app --timeout=120s
sleep 4
kubectl -n build-12 logs log-app -c log-shipper --tail=3
KCLAB_EOF_64
cat > "$D/drills/12-init-sidecar/task.md" <<'KCLAB_EOF_65'
# 12 InitContainer + Sidecar  [Application Design and Build]

Namespace: build-12

Create a Pod `log-app` with an `emptyDir` volume named `logs`, mounted at `/var/log/app` in every container:

1. InitContainer `init-config` (busybox:1.36) writes the text `initialized` into `/var/log/app/status.txt`
2. Main container `app` (busybox:1.36) appends the current date to `/var/log/app/app.log` every 2 seconds
   (`sh -c 'while true; do date >> /var/log/app/app.log; sleep 2; done'`)
3. Sidecar container `log-shipper` (busybox:1.36) runs `tail -F /var/log/app/app.log`.
   Make it a native sidecar (an initContainer with `restartPolicy: Always`).

Verify: `kubectl -n build-12 logs log-app -c log-shipper` shows dates.
KCLAB_EOF_65
mkdir -p "$D/drills/13-job-cronjob"
cat > "$D/drills/13-job-cronjob/check.sh" <<'KCLAB_EOF_66'
#!/usr/bin/env bash
source "$LAB/lib.sh"
NS=build-13
J='{.spec'
expect_eq "Job completions=4, parallelism=2" "$(jp -n $NS job batch-calc -o jsonpath="$J.completions}/$J.parallelism}")" "4/2"
expect_eq "Job backoffLimit=2" "$(jp -n $NS job batch-calc -o jsonpath="$J.backoffLimit}")" "2"
expect_eq "Job activeDeadlineSeconds=60" "$(jp -n $NS job batch-calc -o jsonpath="$J.activeDeadlineSeconds}")" "60"
expect_eq "Job 4회 성공" "$(jp -n $NS job batch-calc -o jsonpath='{.status.succeeded}')" "4"
expect_eq "CronJob schedule" "$(jp -n $NS cronjob cleanup -o jsonpath='{.spec.schedule}')" "*/10 * * * *"
expect_eq "History limits 2/1" "$(jp -n $NS cronjob cleanup -o jsonpath='{.spec.successfulJobsHistoryLimit}/{.spec.failedJobsHistoryLimit}')" "2/1"
expect_eq "concurrencyPolicy=Forbid" "$(jp -n $NS cronjob cleanup -o jsonpath='{.spec.concurrencyPolicy}')" "Forbid"
expect_eq "startingDeadlineSeconds=30" "$(jp -n $NS cronjob cleanup -o jsonpath='{.spec.startingDeadlineSeconds}')" "30"
expect_eq "cleanup-manual 이 CronJob 에서 생성됨" "$(jp -n $NS job cleanup-manual -o jsonpath='{.metadata.annotations.cronjob\.kubernetes\.io/instantiate}')" "manual" "kubectl create job cleanup-manual --from=cronjob/cleanup"
summary
KCLAB_EOF_66
cat > "$D/drills/13-job-cronjob/ns" <<'KCLAB_EOF_67'
build-13
KCLAB_EOF_67
cat > "$D/drills/13-job-cronjob/setup.sh" <<'KCLAB_EOF_68'
#!/usr/bin/env bash
source "$LAB/lib.sh"
reset_ns build-13
KCLAB_EOF_68
cat > "$D/drills/13-job-cronjob/solution.sh" <<'KCLAB_EOF_69'
#!/usr/bin/env bash
cat <<'YAML' | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: batch-calc
  namespace: build-13
spec:
  completions: 4
  parallelism: 2
  backoffLimit: 2
  activeDeadlineSeconds: 60
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: calc
        image: busybox:1.36
        command: ["sh", "-c", "echo calc; sleep 2"]
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: cleanup
  namespace: build-13
spec:
  schedule: "*/10 * * * *"
  successfulJobsHistoryLimit: 2
  failedJobsHistoryLimit: 1
  concurrencyPolicy: Forbid
  startingDeadlineSeconds: 30
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: OnFailure
          containers:
          - name: cleanup
            image: busybox:1.36
            command: ["echo", "cleanup"]
YAML
# 뼈대 생성 팁: kubectl create job batch-calc --image=busybox:1.36 --dry-run=client -o yaml -- sh -c 'echo calc; sleep 2'
#             kubectl create cronjob cleanup --image=busybox:1.36 --schedule="*/10 * * * *" --dry-run=client -o yaml -- echo cleanup
kubectl -n build-13 wait --for=condition=complete job/batch-calc --timeout=120s
kubectl -n build-13 create job cleanup-manual --from=cronjob/cleanup
KCLAB_EOF_69
cat > "$D/drills/13-job-cronjob/task.md" <<'KCLAB_EOF_70'
# 13 Job / CronJob  [Application Design and Build]

Namespace: build-13

1. Create a Job `batch-calc` (image busybox:1.36, command `sh -c 'echo calc; sleep 2'`) that
   - must complete successfully 4 times, running 2 Pods in parallel
   - retries at most 2 times on failure (backoffLimit)
   - is terminated if it runs longer than 60 seconds
   Wait until it is complete.
2. Create a CronJob `cleanup` (image busybox:1.36, command `echo cleanup`) that
   - runs every 10 minutes
   - keeps only 2 successful and 1 failed finished Jobs
   - never runs two Jobs at the same time
   - skips a run if it could not start within 30 seconds of its scheduled time
3. Without waiting for the schedule, create a Job `cleanup-manual` from the CronJob `cleanup`.
KCLAB_EOF_70
mkdir -p "$D/drills/14-storage"
cat > "$D/drills/14-storage/check.sh" <<'KCLAB_EOF_71'
#!/usr/bin/env bash
source "$LAB/lib.sh"
NS=build-14
expect_eq "StorageClass retain-local" "$(jp sc retain-local -o jsonpath='{.provisioner}/{.reclaimPolicy}/{.volumeBindingMode}')" "rancher.io/local-path/Retain/WaitForFirstConsumer"
expect_eq "PVC data-pvc 설정" "$(jp -n $NS pvc data-pvc -o jsonpath='{.spec.storageClassName}/{.spec.accessModes[0]}/{.spec.resources.requests.storage}')" "retain-local/ReadWriteOnce/1Gi"
expect_contains_h "answers/14-pending.txt 에 Pending 사유" "$(cat "$LAB/answers/14-pending.txt" 2>/dev/null)" "first consumer"
expect_eq "PVC Bound" "$(jp -n $NS pvc data-pvc -o jsonpath='{.status.phase}')" "Bound"
pv=$(jp -n $NS pvc data-pvc -o jsonpath='{.spec.volumeName}')
expect_eq "PV reclaimPolicy=Retain" "$( [ -n "$pv" ] && jp pv "$pv" -o jsonpath='{.spec.persistentVolumeReclaimPolicy}')" "Retain"
expect_eq "Pod writer 가 data-pvc 사용" "$(jp -n $NS pod writer -o jsonpath='{.spec.volumes[*].persistentVolumeClaim.claimName}')" "data-pvc"
expect_eq "/data/out.txt = persisted" "$(kubectl -n $NS exec writer -- cat /data/out.txt 2>/dev/null)" "persisted"
summary
KCLAB_EOF_71
cat > "$D/drills/14-storage/ns" <<'KCLAB_EOF_72'
build-14
KCLAB_EOF_72
cat > "$D/drills/14-storage/setup.sh" <<'KCLAB_EOF_73'
#!/usr/bin/env bash
source "$LAB/lib.sh"
ensure_local_path || { echo "[오류] 스토리지 프로비저너를 준비하지 못했습니다. 14번은 건너뛰세요."; exit 1; }
kubectl delete namespace build-14 --ignore-not-found --wait=true >/dev/null 2>&1
kubectl delete storageclass retain-local --ignore-not-found >/dev/null 2>&1
for pv in $(kubectl get pv -o jsonpath='{range .items[?(@.spec.storageClassName=="retain-local")]}{.metadata.name} {end}' 2>/dev/null); do
  kubectl delete pv "$pv" --wait=false >/dev/null 2>&1
done
kubectl create namespace build-14 >/dev/null
rm -f "$LAB/answers/14-pending.txt"
KCLAB_EOF_73
cat > "$D/drills/14-storage/solution.sh" <<'KCLAB_EOF_74'
#!/usr/bin/env bash
cat <<'YAML' | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: retain-local
provisioner: rancher.io/local-path
reclaimPolicy: Retain
volumeBindingMode: WaitForFirstConsumer
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data-pvc
  namespace: build-14
spec:
  storageClassName: retain-local
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
YAML
kubectl -n build-14 describe pvc data-pvc | tail -3
for i in 1 2 3 4 5 6 7 8 9 10; do   # (selftest 용 대기 루프 — 직접 풀 때는 한 줄이면 충분)
  msg=$(kubectl -n build-14 get events --field-selector involvedObject.name=data-pvc -o jsonpath='{.items[0].message}')
  [ -n "$msg" ] && break; sleep 3
done
echo "$msg" > "$LAB/answers/14-pending.txt"
cat "$LAB/answers/14-pending.txt"; echo

cat <<'YAML' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: writer
  namespace: build-14
spec:
  containers:
  - name: writer
    image: busybox:1.36
    command: ["sleep", "3600"]
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: data-pvc
YAML
kubectl -n build-14 wait --for=condition=Ready pod/writer --timeout=180s
kubectl -n build-14 exec writer -- sh -c 'echo persisted > /data/out.txt'
kubectl -n build-14 get pvc data-pvc
kubectl get pv
KCLAB_EOF_74
cat > "$D/drills/14-storage/task.md" <<'KCLAB_EOF_75'
# 14 StorageClass + PVC + Volume  [Application Design and Build]

Namespace: build-14

1. Create a StorageClass `retain-local` with provisioner `rancher.io/local-path`, reclaimPolicy `Retain`
   and volumeBindingMode `WaitForFirstConsumer`.
2. Create a PersistentVolumeClaim `data-pvc` using that StorageClass, accessMode ReadWriteOnce, 1Gi.
3. The PVC stays Pending. Write the reason (event message) into `{{LAB}}/answers/14-pending.txt`
4. Create a Pod `writer` (busybox:1.36, `sleep 3600`) that mounts the PVC at `/data`,
   then write the text `persisted` into `/data/out.txt` from inside the Pod.
5. Confirm the PVC is now Bound and its PV has reclaim policy Retain.
KCLAB_EOF_75
mkdir -p "$D/drills/15-blue-green"
cat > "$D/drills/15-blue-green/check.sh" <<'KCLAB_EOF_76'
#!/usr/bin/env bash
source "$LAB/lib.sh"
NS=dep-15
expect_eq "web-green 이미지 nginx:1.28-alpine" "$(jp -n $NS deploy web-green -o jsonpath='{.spec.template.spec.containers[0].image}')" "nginx:1.28-alpine"
expect_eq "web-green 롤아웃 완료 (2/2)" "$(jp -n $NS deploy web-green -o jsonpath='{.status.updatedReplicas}/{.status.readyReplicas}')" "2/2"
expect_eq "web-blue 이미지는 그대로" "$(jp -n $NS deploy web-blue -o jsonpath='{.spec.template.spec.containers[0].image}')" "nginx:1.27-alpine"
expect_eq "Deployment 라벨 변경 없음" "$(jp -n $NS deploy web-blue -o jsonpath='{.spec.template.metadata.labels.version}')" "blue"
blue_ips=$(jp -n $NS pod -l app=web,version=blue -o jsonpath='{.items[*].status.podIP}')
ep_ips=$(jp -n $NS endpointslices -l kubernetes.io/service-name=web-svc -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]} {end}')
n=0; bad=0
for ip in $ep_ips; do
  n=$((n + 1))
  case " $blue_ips " in *" $ip "*) ;; *) bad=$((bad + 1)) ;; esac
done
expect_eq_h "web-svc 가 web-blue Pod 로만 트래픽 전송" "$n/$bad" "2/0"
summary
KCLAB_EOF_76
cat > "$D/drills/15-blue-green/ns" <<'KCLAB_EOF_77'
dep-15
KCLAB_EOF_77
cat > "$D/drills/15-blue-green/setup.sh" <<'KCLAB_EOF_78'
#!/usr/bin/env bash
source "$LAB/lib.sh"
reset_ns dep-15
for color in blue green; do
  cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-$color
  namespace: dep-15
spec:
  replicas: 2
  selector:
    matchLabels:
      app: web
      version: $color
  template:
    metadata:
      labels:
        app: web
        version: $color
    spec:
      containers:
      - name: nginx
        image: nginx:1.27-alpine
        ports:
        - containerPort: 80
YAML
done
cat <<'YAML' | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Service
metadata:
  name: web-svc
  namespace: dep-15
spec:
  selector:
    app: web
  ports:
  - port: 80
    targetPort: 80
YAML
wait_deploy dep-15 web-blue; wait_deploy dep-15 web-green
KCLAB_EOF_78
cat > "$D/drills/15-blue-green/solution.sh" <<'KCLAB_EOF_79'
#!/usr/bin/env bash
kubectl -n dep-15 get deploy web-green -o jsonpath='{.spec.template.spec.containers[*].name}'; echo   # → nginx
kubectl -n dep-15 set image deployment/web-green nginx=nginx:1.28-alpine
kubectl -n dep-15 rollout status deployment/web-green --timeout=180s
kubectl -n dep-15 get pod --show-labels
kubectl -n dep-15 patch svc web-svc -p '{"spec":{"selector":{"app":"web","version":"blue"}}}'
kubectl -n dep-15 get endpoints web-svc
KCLAB_EOF_79
cat > "$D/drills/15-blue-green/task.md" <<'KCLAB_EOF_80'
# 15 (보너스) Blue-Green 전환  [Application Deployment]

Namespace: dep-15

Deployments `web-blue` and `web-green` run two versions of an app. Service `web-svc` currently points to both.

1. Update the image of Deployment `web-green` from `nginx:1.27-alpine` to `nginx:1.28-alpine` and wait for the rollout.
2. In blue-green fashion, change Service `web-svc` so it sends traffic ONLY to the Pods of `web-blue`.
   Do not change the Deployments' labels.
KCLAB_EOF_80
chmod +x "$D"/lab.sh "$D"/drills/*/*.sh
mkdir -p "$D/answers" "$D/.state"
echo
echo "설치 완료: $D"
echo
"$D/lab.sh" env || true
echo
echo "시작: cd ~/kc-lab && ./lab.sh list"
