# 트러블슈팅 가이드

이 문서는 DKU CI/CD Infrastructure 프로젝트 구축 과정에서 발생할 수 있는 문제와 해결 방법을 정리합니다.

## 목차

- [빠른 진단 명령어](#빠른-진단-명령어)
- [Infrastructure 관련](#infrastructure-관련)
- [Kubernetes 클러스터 관련](#kubernetes-클러스터-관련)
- [DevOps 도구 관련](#devops-도구-관련)
- [CI/CD 파이프라인 관련](#cicd-파이프라인-관련)
- [네트워크 관련](#네트워크-관련)
- [리소스 최적화 가이드](#리소스-최적화-가이드)

---

## 관련 Command

문제 발생 시 아래 명령어로 상태를 빠르게 확인할 수 있습니다.

```bash
# Kubernetes 클러스터 상태
kubectl get nodes
kubectl get pods -n devops
kubectl describe pod <pod-name> -n devops
kubectl logs <pod-name> -n devops

# containerd 상태
crictl ps
crictl images
systemctl status containerd

# Docker Registry 확인
curl http://<YOUR_PUBLIC_IP>:30500/v2/_catalog
curl http://<YOUR_PUBLIC_IP>:30500/v2/testapp/tags/list

# Jenkins/GitLab 로그
kubectl logs -f deployment/jenkins -n devops -c jenkins
kubectl logs -f deployment/gitlab -n devops

# testapp 상태
kubectl get pods -n devops -l app=testapp
curl http://<METALLB_IP>  # 클러스터 내부에서
```

---

## Infrastructure 관련

### CloudStack 좀비 리소스 문제

**증상:**
- `terraform destroy` 실행 시 네트워크 리소스 삭제 실패
- `terraform apply` 실행 시 VM이 이미 존재하거나 스토리지 용량 초과 오류

**진단:**
- CloudStack UI에서 'Destroyed' 상태의 VM과 `ROOT-` 볼륨이 삭제되지 않고 남아있음
- 좀비 리소스가 스토리지 용량을 점유하고 VM 이름을 선점

**해결:**
1. CloudStack 콘솔에서 Destroyed 상태의 VM 확인
2. 관련 좀비 VM과 볼륨을 수동으로 영구 삭제(Expunge)
3. `terraform destroy` 재실행으로 환경 초기화

---

### VM 인터넷 연결 불가 (Egress 정책)

**증상:**
- Ansible `apt` 작업 실패
- 마스터 노드에서 `ping 8.8.8.8` 100% 패킷 손실

**근본 원인:**
- CloudStack 네트워크의 외부 통신 정책(Egress) 기본값이 'Deny'로 설정

**해결:**

`main.tf`에 Egress 방화벽 규칙 추가:

```hcl
resource "cloudstack_egress_firewall" "allow_all_outbound" {
  network_id = cloudstack_network.k8s_network.id
  rule {
    cidr_list = ["0.0.0.0/0"]
    protocol  = "all"
  }
}
```

---

### CloudStack CPU 리소스 제한

**증상:**

VM 스펙 변경 시 CPU 제한 초과 에러:

```
Maximum amount of resources of Type = 'cpu' for Account... is exceeded
```

**해결:**

Master를 먼저 축소(Large->Medium)한 후, Worker를 확장(Medium->Large):
- Terraform apply 두 번 실행으로 순차적 변경

---

## Kubernetes 클러스터 관련

### Ansible SSH 연결 문제

**증상:**

Ansible이 Worker 노드에 직접 연결 불가 (Isolated Network)

**해결:**

ProxyCommand를 사용하여 Master를 통한 SSH 터널링:

```ini
[k8s_cluster:vars]
ansible_ssh_common_args='-o ProxyCommand="ssh -i ~/.ssh/k8s_key -p 2222 -W %h:%p ubuntu@<YOUR_PUBLIC_IP>"'
```

---

### kubeadm join 토큰 만료

**증상:**

Worker 노드 조인 시 토큰 만료

**해결:**

새 토큰 생성:

```bash
kubeadm token create --print-join-command
```

---

### Cilium CNI 설치 중 네트워크 끊김

**증상:**
- Cilium 설치 중 "Wait for Cilium to be ready"에서 멈춤
- SSH 연결 끊김 및 Public IP로 ping 불가

**근본 원인:**

Cilium의 eBPF 기반 네트워크 제어가 CloudStack Virtual Router의 NAT와 충돌하여 **비대칭 라우팅(Asymmetric Routing)** 발생:
- Cilium이 kube-proxy를 대체하면서 VM의 iptables/eBPF 규칙 변경
- 외부에서 VM으로 들어온 요청은 도달하나, 응답 패킷이 Cilium에 의해 잘못된 경로로 전송

**해결:**

CloudStack 환경 대응 옵션으로 Cilium 설치:

```yaml
- name: Install Cilium
  command: >
    cilium install --version {{ cilium_version }}
    --set nativeRoutingCIDR=192.168.0.0/24
    --set tunnel=vxlan
    --set ipam.mode=kubernetes
```

| Option | 설명 |
|--------|------|
| `nativeRoutingCIDR` | CloudStack VM 네트워크 대역 지정, 해당 트래픽 제어 제외 |
| `tunnel=vxlan` | Pod 트래픽 VXLAN 캡슐화, CloudStack 인프라 충돌 방지 |
| `ipam.mode=kubernetes` | Kubernetes PodCIDR 사용, IP 관리 단순화 |

---

### VM 재부팅 후 Pod Unknown 상태

**증상:**

VM 스펙 변경(재부팅) 후 Pod들이 Unknown 상태

**해결:**

Unknown 상태의 Pod 강제 삭제:

```bash
kubectl delete pods -n devops --field-selector=status.phase=Unknown --force --grace-period=0
```

---

## DevOps 도구 관련

### GitLab Pod Pending

**증상:**

GitLab Pod가 Pending 상태로 스케줄링되지 않음

**원인:**

PV의 nodeAffinity가 이전 노드(k8s-m)를 가리킴

**해결:**

PV, PVC 삭제 후 새 노드(k8s-w1)로 재생성:

```bash
kubectl delete pvc gitlab-data-pvc -n devops
kubectl delete pv gitlab-data-pv
# PV의 nodeAffinity를 k8s-w1로 수정 후
kubectl apply -f manifests/gitlab/pvc.yaml
```

---

### Jenkins Pod CrashLoopBackOff - 볼륨 권한 문제

**증상:**

```
INSTALL WARNING: User: missing rw permissions on JENKINS_HOME: /var/jenkins_home
touch: cannot touch '/var/jenkins_home/copy_reference_file.log': Permission denied
```

**근본 원인:**
- Jenkins는 UID 1000으로 실행
- hostPath PersistentVolume이 root 소유로 생성되어 쓰기 권한 없음

**해결:**

`manifests/jenkins/deployment.yaml`에 initContainer 추가:

```yaml
initContainers:
  - name: fix-permissions
    image: busybox:latest
    command: ["sh", "-c", "chown -R 1000:1000 /var/jenkins_home"]
    securityContext:
      runAsUser: 0
    volumeMounts:
      - name: jenkins-data
        mountPath: /var/jenkins_home
```

---

### NodePort 불일치로 외부 접속 실패

**증상:**

Pod는 Running이지만 외부에서 서비스 접속 불가

**진단:**

실제 할당된 NodePort와 CloudStack 포트 포워딩 규칙 불일치:

| Service | 실제 NodePort | CloudStack 포워딩 |
|---------|--------------|------------------|
| Jenkins | 31673 | 30880 |
| GitLab | 30499 | 30080 |
| Registry | 30941 | 30500 |

**근본 원인:**
- Service 타입이 LoadBalancer로 설정되어 Kubernetes가 랜덤 NodePort 할당

**해결:**

Service 타입을 NodePort로 변경하고 포트 번호 명시적 지정:

```yaml
spec:
  type: NodePort
  ports:
    - name: http
      port: 8080
      targetPort: 8080
      nodePort: 30880
```

---

### GitLab OOMKilled - 메모리 부족

**증상:**

```
Last State:     Terminated
  Reason:       OOMKilled
  Exit Code:    137
```

**근본 원인:**
- GitLab CE는 메모리 집약적 (PostgreSQL, Redis, Puma, Sidekiq 등 내장)
- 초기 메모리 제한 4Gi가 GitLab 구동에 부족

**해결:**

메모리 제한을 5Gi로 증가:

```yaml
resources:
  requests:
    memory: "2Gi"
    cpu: "500m"
  limits:
    memory: "5Gi"
    cpu: "2000m"
```

---

### GitLab Root 비밀번호 환경변수 미작동

**증상:**
- `GITLAB_ROOT_PASSWORD` 환경변수 설정했으나 로그인 불가
- "Invalid login or password" 오류

**근본 원인:**
- `GITLAB_ROOT_PASSWORD`는 **최초 설치 시에만** 적용
- PersistentVolume에 기존 데이터가 있으면 환경변수 무시

**해결:**

PostgreSQL을 통해 직접 비밀번호 재설정:

```bash
kubectl exec -it gitlab -n devops -- bash
gitlab-rails console

user = User.find_by(username: 'root')
user.password = 'new_password'
user.password_confirmation = 'new_password'
user.save!
```

---

### GitLab 사용자 계정 승인 대기 상태

**증상:**

```
Your account is pending approval from your GitLab administrator and hence blocked.
```

**근본 원인:**
- GitLab 기본 설정에서 새 사용자 등록 시 관리자 승인 필요

**해결:**

PostgreSQL을 통해 직접 사용자 상태 변경:

```bash
kubectl exec -it gitlab -n devops -- bash
gitlab-psql

UPDATE users SET state = 'active' WHERE username = 'dongju';
UPDATE users SET admin = true WHERE username = 'dongju';
\q
```

---

## CI/CD 파이프라인 관련

### Jenkins Pipeline: Docker 명령어 not found

**증상:**

```
+ docker build -t <YOUR_PUBLIC_IP>:30500/testapp:1 .
docker: command not found
```

**근본 원인:**
- Jenkins 컨테이너 내부에 Docker CLI가 설치되어 있지 않음

**해결:**

Jenkins Deployment에 Docker-in-Docker (DinD) 사이드카 컨테이너 추가:

```yaml
spec:
  containers:
  - name: jenkins
    image: jenkins/jenkins:lts
    env:
    - name: DOCKER_HOST
      value: tcp://localhost:2375

  - name: docker
    image: docker:dind
    securityContext:
      privileged: true
    env:
    - name: DOCKER_TLS_CERTDIR
      value: ""
```

---

### Docker Registry: Insecure Registry 오류

**증상:**

```
Get "https://<YOUR_PUBLIC_IP>:30500/v2/": http: server gave HTTP response to HTTPS client
```

**근본 원인:**
- Docker는 기본적으로 HTTPS로 레지스트리 연결 시도
- Private Registry가 HTTP만 지원

**해결:**

Jenkins DinD 컨테이너에 insecure registry 설정:

```yaml
- name: docker
  image: docker:dind
  args:
  - "--insecure-registry=<YOUR_PUBLIC_IP>:30500"
```

---

### Worker 노드 ImagePullBackOff

**증상:**

```
Warning  Failed   Failed to pull image "<YOUR_PUBLIC_IP>:30500/testapp:5":
rpc error: http: server gave HTTP response to HTTPS client
```

**근본 원인:**
- Jenkins에서 이미지 push는 성공
- Worker 노드의 containerd가 insecure registry로 설정되지 않음

**해결:**

모든 Worker 노드에 containerd insecure registry 설정:

```bash
ansible workers -i inventory/hosts.ini -b -m shell -a '
cat >> /etc/containerd/config.toml << EOF

[plugins."io.containerd.grpc.v1.cri".registry]
  [plugins."io.containerd.grpc.v1.cri".registry.mirrors]
    [plugins."io.containerd.grpc.v1.cri".registry.mirrors."<YOUR_PUBLIC_IP>:30500"]
      endpoint = ["http://<YOUR_PUBLIC_IP>:30500"]
  [plugins."io.containerd.grpc.v1.cri".registry.configs]
    [plugins."io.containerd.grpc.v1.cri".registry.configs."<YOUR_PUBLIC_IP>:30500".tls]
      insecure_skip_verify = true
EOF
systemctl restart containerd
'
```

---

### Jenkinsfile Namespace 불일치

**증상:**

```
error: deployments.apps "testapp" not found
```

**근본 원인:**
- testapp이 `devops` namespace에 배포됨
- Jenkinsfile에서 namespace 미지정 (default 사용)

**해결:**

Jenkinsfile에서 명시적으로 namespace 지정:

```groovy
stage('Deploy to Kubernetes') {
    steps {
        script {
            sh """
                kubectl apply -f k8s/ -n devops
                kubectl set image deployment/testapp \
                    testapp=\${REGISTRY}/\${IMAGE_NAME}:\${IMAGE_TAG} \
                    -n devops
            """
        }
    }
}
```

---

### Git Push 충돌 및 SSH 설정

**증상:**

```
! [rejected]        main -> main (non-fast-forward)
error: failed to push some refs
```

**근본 원인:**
- GitLab UI에서 직접 파일 수정으로 원격에 로컬에 없는 커밋 존재

**해결:**

**SSH 키 기반 인증 설정:**

```bash
# SSH 키 생성
ssh-keygen -t ed25519 -C "gitlab@dku" -f ~/.ssh/gitlab_key

# SSH config 설정
cat >> ~/.ssh/config << 'EOF'
Host gitlab-dku
    HostName <YOUR_PUBLIC_IP>
    Port 30022
    User git
    IdentityFile ~/.ssh/gitlab_key
EOF

# Git remote URL 변경
git remote set-url origin git@gitlab-dku:dongju/testapp.git
```

**Rebase로 충돌 해결:**

```bash
git pull --rebase origin main
git push origin main
```

---

## 네트워크 관련

### Port Forwarding 네트워크 연결 문제

**증상:**

curl/ping으로 CloudStack Public IP에 접근 시 타임아웃 발생:

```bash
$ ping <YOUR_PUBLIC_IP>
PING <YOUR_PUBLIC_IP>: 56 data bytes
Request timeout for icmp_seq 0
--- <YOUR_PUBLIC_IP> ping statistics ---
2 packets transmitted, 0 packets received, 100.0% packet loss

$ curl -s --connect-timeout 5 http://<YOUR_PUBLIC_IP>:30080/users/sign_in
# Timeout (HTTP 000)
```

**진단 과정:**

1. **TCP 포트 연결 테스트:**
```bash
$ nc -zv -w 5 <YOUR_PUBLIC_IP> 2222
Connection to <YOUR_PUBLIC_IP> port 2222 [tcp/rockwell-csp2] succeeded!

$ nc -zv -w 5 <YOUR_PUBLIC_IP> 30080
# Timeout
```

2. **SSH 연결 테스트** (성공):
```bash
$ ssh -o IdentitiesOnly=yes -i ~/.ssh/k8s_key -p 2222 ubuntu@<YOUR_PUBLIC_IP>
# 접속 성공
```

3. **클러스터 내부에서 NodePort 테스트** (성공):
```bash
$ curl -s -o /dev/null -w "%{http_code}" http://<WORKER1_IP>:30080/users/sign_in
200
```

4. **CloudStack Port Forwarding 규칙 확인:** CloudStack 콘솔에서 모든 규칙이 Active 상태임을 확인

5. **Cilium eBPF NAT 충돌 여부 확인:**
```bash
$ kubectl logs -n kube-system -l k8s-app=cilium --tail=20 | grep -i "nat\|nodeport"
# NAT/NodePort 관련 에러 없음
```

**원인 분석:**
- VPN 라우팅 문제: 로컬 환경의 VPN 설정에 따라 10.0.x.x 대역으로의 라우팅이 불안정
- ICMP (ping)는 CloudStack에서 기본적으로 차단됨
- 일부 TCP 연결(HTTP)은 VPN 라우팅 설정에 따라 불안정할 수 있음
- 브라우저는 다른 네트워크 스택을 사용하므로 정상 접근 가능

**결론:**
- **Cilium eBPF와 NAT 충돌 없음:** 클러스터 내부에서 NodePort 테스트 성공 (HTTP 200)
- **CloudStack Port Forwarding 정상:** 모든 규칙이 Active 상태
- **브라우저 접근 정상:** Chrome에서 모든 서비스 (GitLab, Jenkins, Registry) 접근 성공
- 로컬 CLI 도구의 연결 불안정은 VPN 라우팅 설정 문제이며, 실제 서비스는 정상 작동

---

## 리소스 최적화

### 초기 구성의 문제점

초기에는 모든 노드를 Medium(2 CPU, 4GB)으로 구성했으나, 다음 문제가 발생:

1. **리소스 부족:** GitLab, Jenkins, Registry를 동시에 운영하기에 Worker 노드 리소스 부족
2. **OOMKilled 발생:** GitLab Pod가 메모리 부족으로 반복 재시작
3. **성능 저하:** DevOps 도구들의 응답 속도 저하

### 리소스 재배치

| 노드 | 변경 전 | 변경 후 | 역할 |
|------|---------|---------|------|
| k8s-m | Medium (2 CPU, 4GB) | Medium (2 CPU, 4GB) | Control Plane 전용 |
| k8s-w1 | Medium (2 CPU, 4GB) | Large (4 CPU, 8GB) | GitLab, Jenkins, Registry |
| k8s-w2 | Medium (2 CPU, 4GB) | Medium (2 CPU, 4GB) | testapp |

Master 노드는 처음부터 Medium으로 설정하고, DevOps 워크로드가 집중되는 k8s-w1만 Large로 업그레이드하여 리소스를 효율적으로 배분했습니다.

### 변경 절차

1. Terraform `variables.tf`에서 k8s-w1 서비스 오퍼링을 Large로 변경
2. `terraform apply` 실행하여 VM 스펙 업그레이드
3. Worker 노드 재시작 및 클러스터 재조인
4. DevOps 워크로드(GitLab, Jenkins, Registry)를 k8s-w1에 배치하도록 nodeSelector 설정
5. 매니페스트 재적용