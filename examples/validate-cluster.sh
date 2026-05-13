#!/bin/bash
# Cluster validation suite. Returns nonzero only on fatal errors.
export KUBECONFIG=/etc/kubernetes/admin.conf
KC="sudo kubectl"
PASS=0
FAIL=0

pass() { echo "  ✅ PASS: $*"; PASS=$((PASS+1)); }
fail() { echo "  ❌ FAIL: $*"; FAIL=$((FAIL+1)); }

echo ""
echo "============================================================"
echo "TEST 1: All nodes Ready"
echo "============================================================"
NOT_READY=$($KC get nodes --no-headers | grep -v ' Ready ' | wc -l)
TOTAL=$($KC get nodes --no-headers | wc -l)
$KC get nodes -o wide
if [ "$NOT_READY" -eq 0 ] && [ "$TOTAL" -eq 6 ]; then pass "all 6 nodes Ready"; else fail "$NOT_READY not-ready of $TOTAL total"; fi

echo ""
echo "============================================================"
echo "TEST 2: Control plane HA — 3 etcd + 3 apiserver pods"
echo "============================================================"
ETCD_RUNNING=$($KC get pods -n kube-system -l component=etcd --no-headers 2>/dev/null | grep Running | wc -l)
API_RUNNING=$($KC get pods -n kube-system -l component=kube-apiserver --no-headers 2>/dev/null | grep Running | wc -l)
$KC get pods -n kube-system -l component=etcd
$KC get pods -n kube-system -l component=kube-apiserver
[ "$ETCD_RUNNING" -eq 3 ] && pass "3 etcd pods Running" || fail "only $ETCD_RUNNING etcd pods Running"
[ "$API_RUNNING"  -eq 3 ] && pass "3 apiserver pods Running" || fail "only $API_RUNNING apiserver pods Running"

echo ""
echo "============================================================"
echo "TEST 3: etcd cluster health (member list + endpoint health)"
echo "============================================================"
ETCD_POD=$($KC get pods -n kube-system -l component=etcd -o jsonpath='{.items[0].metadata.name}')
$KC -n kube-system exec "$ETCD_POD" -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  member list -w table
ETCD_HEALTHY=$($KC -n kube-system exec "$ETCD_POD" -- etcdctl \
  --endpoints=https://10.0.1.4:2379,https://10.0.1.5:2379,https://10.0.1.6:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint health 2>&1 | grep -c "is healthy")
[ "$ETCD_HEALTHY" -eq 3 ] && pass "all 3 etcd endpoints healthy" || fail "only $ETCD_HEALTHY etcd endpoints healthy"

echo ""
echo "============================================================"
echo "TEST 4: CoreDNS pods Running"
echo "============================================================"
COREDNS_RUNNING=$($KC get pods -n kube-system -l k8s-app=kube-dns --no-headers | grep Running | wc -l)
$KC get pods -n kube-system -l k8s-app=kube-dns
[ "$COREDNS_RUNNING" -ge 2 ] && pass "CoreDNS replicas Running" || fail "only $COREDNS_RUNNING CoreDNS Running"

echo ""
echo "============================================================"
echo "TEST 5: Pod scheduling spread (3 nginx replicas land on 3 nodes)"
echo "============================================================"
$KC create deployment netest --image=nginx:latest --replicas=3 2>&1 || true
# Anti-affinity to spread
$KC patch deployment netest -p '{"spec":{"template":{"spec":{"affinity":{"podAntiAffinity":{"preferredDuringSchedulingIgnoredDuringExecution":[{"weight":100,"podAffinityTerm":{"labelSelector":{"matchLabels":{"app":"netest"}},"topologyKey":"kubernetes.io/hostname"}}]}}}}}}' 2>&1 || true
$KC rollout status deployment/netest --timeout=120s
$KC get pods -l app=netest -o wide
DISTINCT_NODES=$($KC get pods -l app=netest -o jsonpath='{.items[*].spec.nodeName}' | tr ' ' '\n' | sort -u | wc -l)
[ "$DISTINCT_NODES" -eq 3 ] && pass "pods spread across 3 distinct nodes" || fail "pods only on $DISTINCT_NODES nodes"

echo ""
echo "============================================================"
echo "TEST 6: Pod-to-pod networking ACROSS nodes (Calico VXLAN)"
echo "============================================================"
SRC=$($KC get pods -l app=netest -o jsonpath='{.items[0].metadata.name}')
SRC_NODE=$($KC get pods -l app=netest -o jsonpath='{.items[0].spec.nodeName}')
DST_IP=$($KC get pods -l app=netest -o jsonpath='{.items[1].status.podIP}')
DST_NODE=$($KC get pods -l app=netest -o jsonpath='{.items[1].spec.nodeName}')
echo "  curl from pod on $SRC_NODE -> pod $DST_IP on $DST_NODE"
if $KC exec "$SRC" -- curl -sS --max-time 5 "http://${DST_IP}" >/dev/null 2>&1; then
  pass "pod-to-pod across nodes OK"
else
  fail "pod-to-pod across nodes FAILED"
fi

echo ""
echo "============================================================"
echo "TEST 7: ClusterIP service routing (kube-proxy)"
echo "============================================================"
$KC expose deployment netest --port=80 --target-port=80 --name=netest-svc --type=ClusterIP 2>&1 || true
sleep 3
CIP=$($KC get svc netest-svc -o jsonpath='{.spec.clusterIP}')
echo "  ClusterIP: $CIP"
if $KC exec "$SRC" -- curl -sS --max-time 5 "http://${CIP}" >/dev/null 2>&1; then
  pass "ClusterIP service reachable"
else
  fail "ClusterIP service unreachable"
fi

echo ""
echo "============================================================"
echo "TEST 8: DNS resolution (CoreDNS + service discovery)"
echo "============================================================"
DNS_OUT=$($KC run dnstest --image=busybox:1.36 --rm -i --restart=Never --timeout=60s --command -- nslookup netest-svc.default.svc.cluster.local 2>&1)
echo "$DNS_OUT" | tail -15
if echo "$DNS_OUT" | grep -q "Address.*${CIP}"; then
  pass "DNS resolved service to ClusterIP"
else
  fail "DNS resolution failed"
fi

echo ""
echo "============================================================"
echo "TEST 9: NodePort service (external reachability via worker IP)"
echo "============================================================"
$KC patch svc netest-svc -p '{"spec":{"type":"NodePort"}}' 2>&1 || true
sleep 3
NP=$($KC get svc netest-svc -o jsonpath='{.spec.ports[0].nodePort}')
# Auto-detect any worker node's internal IP
WORKER_IP=$($KC get nodes -l '!node-role.kubernetes.io/control-plane' \
  -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
echo "  NodePort: $NP   Worker IP: $WORKER_IP"
HIT=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" "http://${WORKER_IP}:${NP}" || echo "FAIL")
echo "  HTTP $HIT against ${WORKER_IP}:${NP}"
[ "$HIT" = "200" ] && pass "NodePort reachable on worker IP" || fail "NodePort returned $HIT"

echo ""
echo "============================================================"
echo "TEST 10: Control-plane HA failover — leader election still works"
echo "============================================================"
LEASE=$($KC -n kube-system get lease kube-controller-manager -o jsonpath='{.spec.holderIdentity}' 2>/dev/null)
echo "  controller-manager leader: $LEASE"
[ -n "$LEASE" ] && pass "controller-manager has elected leader" || fail "no leader elected"
LEASE_SCH=$($KC -n kube-system get lease kube-scheduler -o jsonpath='{.spec.holderIdentity}' 2>/dev/null)
echo "  scheduler leader:          $LEASE_SCH"
[ -n "$LEASE_SCH" ] && pass "scheduler has elected leader" || fail "no scheduler leader"

echo ""
echo "============================================================"
echo "TEST 11: API server reachable through LB (external endpoint)"
echo "============================================================"
# Run from a pod (worker node) to bypass Azure Standard LB hairpin restriction.
# A VM in the LB backend pool cannot reach its own LB frontend IP — so curling
# from a CP node yields 000. Pods route via Calico pod-IP source, which Azure
# treats as external traffic and routes correctly through the LB.
LB_IP=$(sudo grep 'server:' /etc/kubernetes/admin.conf | head -1 | sed -E 's|.*https://([^:]+):.*|\1|')
if [ -z "$LB_IP" ]; then
  echo "  (could not auto-detect LB IP; skipping Test 11)"
else
  echo "  LB IP: $LB_IP"
  LB_HTTP=$($KC run lbtest-$$ --image=curlimages/curl:8.5.0 --rm -i --restart=Never --quiet \
    --command -- curl -sk --max-time 8 -o /dev/null -w "%{http_code}" "https://${LB_IP}:6443/livez" 2>/dev/null \
    | tail -1)
  echo "  https://${LB_IP}:6443/livez -> HTTP $LB_HTTP"
  [ "$LB_HTTP" = "200" ] && pass "apiserver healthy via LB (from worker pod)" || fail "apiserver via LB returned $LB_HTTP"
fi

echo ""
echo "============================================================"
echo "Cleanup"
echo "============================================================"
$KC delete deployment netest --wait=false 2>&1 || true
$KC delete svc netest-svc --wait=false 2>&1 || true

echo ""
echo "============================================================"
echo "RESULT: $PASS passed, $FAIL failed"
echo "============================================================"
exit $FAIL
