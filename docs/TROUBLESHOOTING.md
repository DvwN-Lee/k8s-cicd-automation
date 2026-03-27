# 트러블슈팅 가이드

이 문서는 Kubernetes CI/CD Infrastructure 프로젝트 구축 과정에서 실제로 마주친 문제들과 그 해결 과정을 기록합니다. 단순한 해결책 모음이 아니라, 각 문제를 어떻게 진단하고 근본 원인을 찾았는지의 과정을 담습니다.

---

## 이 문서의 활용법

각 케이스는 "증상 -> 진단 -> 근본 원인 -> 해결 -> 교훈" 구조로 서술합니다.

**등급 기준:**
- A등급 (★ 또는 ★★): 단순 설정 오류가 아닌 레이어 간 충돌, 아키텍처 결정, 기술 개념 이해를 요구한 케이스. 심층 분석 포함.
- B등급: 원인 파악에 일정 시간이 필요했으나 해결 경로가 명확한 케이스.
- C등급: 절차적 실수 또는 단순 설정 누락으로 인한 케이스.

---

## 케이스 인덱스

| ID | 케이스 | 난이도 | 등급 | 카테고리 |
|----|--------|--------|------|----------|
| [CASE-01](#case-01-cloudstack-좀비-리소스-문제) | CloudStack 좀비 리소스 문제 | 2/5 | B | Infrastructure |
| [CASE-02](#case-02-vm-인터넷-연결-불가---egress-deny-정책-) | VM 인터넷 연결 불가 - Egress Deny 정책 | 3/5 | A | Infrastructure |
| [CASE-03](#case-03-cloudstack-cpu-리소스-제한) | CloudStack CPU 리소스 제한 | 1/5 | C | Infrastructure |
| [CASE-04](#case-04-ansible-ssh-연결-문제---proxycommand) | Ansible SSH 연결 문제 - ProxyCommand | 2/5 | B | Kubernetes |
| [CASE-05](#case-05-kubeadm-join-토큰-만료) | kubeadm join 토큰 만료 | 1/5 | C | Kubernetes |
| [CASE-06](#case-06-cilium-cni-설치-중-네트워크-끊김---ebpf-비대칭-라우팅-) | Cilium CNI 설치 중 네트워크 끊김 - eBPF 비대칭 라우팅 | 5/5 | A★★ | Kubernetes |
| [CASE-07](#case-07-vm-재부팅-후-pod-unknown-상태) | VM 재부팅 후 Pod Unknown 상태 | 1/5 | C | Kubernetes |
| [CASE-08](#case-08-gitlab-pod-pending---pv-nodeaffinity) | GitLab Pod Pending - PV nodeAffinity | 2/5 | B | DevOps 도구 |
| [CASE-09](#case-09-jenkins-crashloopbackoff---initcontainer-볼륨-권한-) | Jenkins CrashLoopBackOff - initContainer 볼륨 권한 | 3/5 | A | DevOps 도구 |
| [CASE-10](#case-10-nodeport-불일치로-외부-접속-실패) | NodePort 불일치로 외부 접속 실패 | 2/5 | B | DevOps 도구 |
| [CASE-11](#case-11-gitlab-oomkilled---메모리-튜닝) | GitLab OOMKilled - 메모리 튜닝 | 2/5 | B | DevOps 도구 |
| [CASE-12](#case-12-gitlab-비밀번호-환경변수-미작동---애플리케이션-수명주기-) | GitLab 비밀번호 환경변수 미작동 - 애플리케이션 수명주기 | 3/5 | A | DevOps 도구 |
| [CASE-13](#case-13-gitlab-사용자-계정-승인-대기) | GitLab 사용자 계정 승인 대기 | 2/5 | B | DevOps 도구 |
| [CASE-14](#case-14-jenkins에서-docker-명령-실행---dind-아키텍처-) | Jenkins에서 Docker 명령 실행 - DinD 아키텍처 | 4/5 | A | CI/CD 파이프라인 |
| [CASE-15](#case-15-docker-registry-insecure-설정) | Docker Registry Insecure 설정 | 2/5 | B | CI/CD 파이프라인 |
| [CASE-16](#case-16-worker-노드-imagepullbackoff---containerd-설정-) | Worker 노드 ImagePullBackOff - containerd 설정 | 3/5 | A | CI/CD 파이프라인 |
| [CASE-17](#case-17-jenkinsfile-namespace-불일치) | Jenkinsfile Namespace 불일치 | 1/5 | C | CI/CD 파이프라인 |
| [CASE-18](#case-18-git-push-충돌-및-ssh-설정) | Git Push 충돌 및 SSH 설정 | 1/5 | C | CI/CD 파이프라인 |
| [CASE-19](#case-19-curl-타임아웃-vs-브라우저-정상---5계층-체계적-진단-) | curl 타임아웃 vs 브라우저 정상 - 5계층 체계적 진단 | 4/5 | A | 네트워크 진단 |

---

## 빠른 진단 명령어

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

## Part 1: Infrastructure 레이어

### CASE-01: CloudStack 좀비 리소스 문제

**태그:** #cloudstack #terraform #리소스관리
**난이도:** 2/5
**등급:** B

**증상:**
- `terraform destroy` 실행 시 네트워크 리소스 삭제 실패
- `terraform apply` 실행 시 VM이 이미 존재하거나 스토리지 용량 초과 오류

**원인:**
CloudStack UI에서 'Destroyed' 상태의 VM과 `ROOT-` 볼륨이 삭제되지 않고 남아 있어 스토리지 용량을 점유하고 VM 이름을 선점합니다. CloudStack의 VM 삭제는 즉시 물리 삭제가 아닌 Soft Delete(Destroyed 상태)로 처리되므로, Terraform은 이를 삭제된 것으로 인식하지만 실제 리소스는 잔존합니다.

**해결:**
1. CloudStack 콘솔에서 Destroyed 상태의 VM 확인
2. 관련 좀비 VM과 볼륨을 수동으로 영구 삭제(Expunge)
3. `terraform destroy` 재실행으로 환경 초기화

---

### CASE-02: VM 인터넷 연결 불가 - Egress Deny 정책 ★

**태그:** #cloudstack #egress #firewall #terraform
**난이도:** 3/5
**등급:** A
**해결 소요:** 약 1시간

**발생 맥락**

Terraform으로 CloudStack VM을 프로비저닝하고 Ansible로 Kubernetes 환경을 구성하는 단계에서 발생했습니다. VM은 정상 생성되었고 SSH 접속도 가능했으나, 패키지 설치 단계에서 전혀 예상하지 못한 실패가 나타났습니다.

**증상:**
- Ansible의 `apt` 작업이 연결 오류로 실패
- 마스터 노드에서 `ping 8.8.8.8` 실행 시 100% 패킷 손실
- `curl https://get.helm.sh/...` 타임아웃

**진단 과정**

가설 1 - VM 자체 방화벽 문제: `iptables -L`로 VM 내부 방화벽 확인 -> 기본 정책 ACCEPT, 특별한 DROP 규칙 없음. 기각.

가설 2 - DNS 문제: `nslookup google.com` 타임아웃 -> DNS 응답 자체가 오지 않으므로 DNS 서버 문제가 아닌 네트워크 레이어 문제. 기각(부분).

가설 3 - CloudStack 네트워크 정책: CloudStack 콘솔에서 Network -> Egress Rules 확인. 기본값이 'Deny All'로 설정되어 있음을 발견. 원인 확인.

**근본 원인**

CloudStack의 Isolated Network는 기본적으로 Ingress(외부->내부) 방향의 규칙만 관리자가 명시적으로 열도록 설계되어 있습니다. 그런데 Egress(내부->외부) 방향도 기본값이 'Deny'로 설정된 환경에서는 VM이 외부 인터넷으로 어떤 패킷도 내보낼 수 없습니다. SSH 접속이 가능했던 이유는 포트 포워딩 규칙이 적용된 것이며, 이는 Egress 정책과 별개의 경로입니다.

**해결**

`main.tf`에 Egress 방화벽 규칙을 명시적으로 추가합니다:

```hcl
resource "cloudstack_egress_firewall" "allow_all_outbound" {
  network_id = cloudstack_network.k8s_network.id
  rule {
    cidr_list = ["0.0.0.0/0"]
    protocol  = "all"
  }
}
```

**교훈:**
- CloudStack Isolated Network에서는 Ingress와 Egress 정책이 독립적으로 적용됩니다. SSH 접속 성공이 곧 인터넷 연결 가능을 의미하지 않습니다.
- Terraform으로 네트워크를 프로비저닝할 때 Egress 허용 규칙을 기본 템플릿에 포함시켜야 합니다.

---

### CASE-03: CloudStack CPU 리소스 제한

**태그:** #cloudstack #quota #terraform
**난이도:** 1/5
**등급:** C

**증상:**

VM 스펙 변경 시 CPU 제한 초과 에러:

```
Maximum amount of resources of Type = 'cpu' for Account... is exceeded
```

**원인:**

계정에 할당된 CPU 쿼터를 동시에 초과할 수 없습니다. 모든 노드를 동시에 대형 인스턴스로 변경하면 일시적으로 쿼터를 초과합니다.

**해결:**

Master를 먼저 축소(Large -> Medium)한 후, Worker를 확장(Medium -> Large):
- `terraform apply`를 두 번 실행하여 순차적으로 변경합니다.

---

## Part 2: Kubernetes 레이어

### CASE-04: Ansible SSH 연결 문제 - ProxyCommand

**태그:** #ansible #ssh #networking #isolated-network
**난이도:** 2/5
**등급:** B

**증상:**

Ansible이 Worker 노드에 직접 연결 불가합니다. CloudStack Isolated Network 구성에서 Worker 노드는 Public IP가 없으며 Master 노드의 포트 포워딩을 통해서만 접근 가능합니다.

**원인:**

Worker 노드가 외부에서 직접 접근 불가능한 Isolated Network에 위치합니다. Ansible은 기본적으로 직접 SSH 연결을 시도합니다.

**해결:**

ProxyCommand를 사용하여 Master를 통한 SSH 터널링을 구성합니다:

```ini
[k8s_cluster:vars]
ansible_ssh_common_args='-o ProxyCommand="ssh -i ~/.ssh/k8s_key -p 2222 -W %h:%p ubuntu@<YOUR_PUBLIC_IP>"'
```

---

### CASE-05: kubeadm join 토큰 만료

**태그:** #kubeadm #kubernetes #token
**난이도:** 1/5
**등급:** C

**증상:**

Worker 노드 조인 시 토큰 만료 오류가 발생합니다. `kubeadm init` 실행 후 24시간이 경과하면 토큰이 자동 만료됩니다.

**해결:**

새 토큰을 생성하여 조인 명령을 다시 실행합니다:

```bash
kubeadm token create --print-join-command
```

---

### CASE-06: Cilium CNI 설치 중 네트워크 끊김 - eBPF 비대칭 라우팅 ★★

**태그:** #cilium #ebpf #cloudstack #nat #asymmetric-routing #cni
**난이도:** 5/5
**등급:** A (최고난도)
**해결 소요:** 약 3시간

**발생 맥락**

Kubernetes 클러스터를 구성하고 CNI로 Cilium을 설치하는 과정에서 발생했습니다. 여러 CNI 중 Cilium을 선택한 이유는 eBPF 기반의 고성능과 기본 kube-proxy 대체 기능 때문이었습니다. 그런데 설치 도중 예상치 못하게 SSH 연결 자체가 끊겼습니다.

**증상:**
- Cilium 설치 중 "Wait for Cilium to be ready" 단계에서 응답 없이 멈춤
- 동시에 SSH 연결이 끊기고 이후 재연결 불가
- Public IP로 ping이 100% 손실
- VM은 CloudStack 콘솔에서 Running 상태이나 외부 접근 완전 불가

**진단 과정**

1단계 - Cilium 설치 전후 비교: 설치 전에는 SSH 정상, 설치 시작과 동시에 연결 끊김. Cilium 설치가 트리거임을 확인.

2단계 - CloudStack 콘솔에서 VM 직접 콘솔 접근: VM 내부는 정상 동작. Cilium 데몬은 Running 상태. 문제는 외부 도달 불가.

3단계 - 네트워크 패킷 흐름 분석:
```
외부 -> CloudStack Virtual Router -> NAT -> VM eth0 -> 응답 패킷 생성
응답 패킷 -> Cilium eBPF hook -> ?
```

4단계 - Cilium 로그 분석:
```bash
kubectl logs -n kube-system -l k8s-app=cilium --tail=50 | grep -i "nat\|route\|drop"
```
패킷 드롭 관련 로그에서 비대칭 라우팅 관련 경고 발견.

5단계 - 네트워킹 계층 충돌 가설 수립: Cilium의 eBPF가 kube-proxy를 완전히 대체하면서 VM의 iptables 규칙을 재작성합니다. CloudStack Virtual Router는 NAT를 통해 외부 패킷을 VM으로 전달하는데, 이 과정에서 응답 패킷의 라우팅 경로가 Cilium의 eBPF 규칙과 충돌.

**근본 원인**

비대칭 라우팅(Asymmetric Routing) 문제입니다. 패킷 흐름이 다음과 같이 됩니다:

```
인바운드: 외부 클라이언트 -> CloudStack Virtual Router (DNAT) -> VM eth0
아웃바운드: VM eth0 -> Cilium eBPF 처리 -> ? (Cilium이 예상하지 못한 소스 IP)
```

Cilium은 자신이 관리하지 않는 NAT 변환(CloudStack Virtual Router의 DNAT)에 의해 들어온 패킷의 응답을 처리할 때, 해당 패킷의 출처를 올바르게 추적하지 못합니다. 결과적으로 응답 패킷이 잘못된 경로로 전송되거나 드롭됩니다.

CloudStack의 Virtual Router는 VM 내부 iptables와 독립적으로 동작하는 별도의 NAT 레이어입니다. Cilium은 VM 내부 네트워크 스택만 제어할 수 있으므로, 외부 NAT 계층의 존재를 인식시켜야 합니다.

**해결**

CloudStack 환경의 NAT 특성을 Cilium에 명시적으로 알려주는 옵션들로 설치합니다:

```yaml
- name: Install Cilium
  command: >
    cilium install --version {{ cilium_version }}
    --set nativeRoutingCIDR=192.168.0.0/24
    --set tunnel=vxlan
    --set ipam.mode=kubernetes
```

| 옵션 | 역할 | 이유 |
|------|------|------|
| `nativeRoutingCIDR` | CloudStack VM 네트워크 대역 지정 | 이 대역 트래픽에 대해 Cilium의 직접 라우팅 제어를 제외하여 CloudStack NAT와의 충돌 방지 |
| `tunnel=vxlan` | Pod 트래픽을 VXLAN으로 캡슐화 | Pod 간 트래픽을 오버레이 네트워크로 격리, CloudStack 인프라 충돌 방지 |
| `ipam.mode=kubernetes` | Kubernetes PodCIDR 사용 | IP 관리 단순화, Cilium 독자 IPAM과 CloudStack DHCP 간 충돌 방지 |

**교훈:**
- CNI는 단순한 Pod 네트워킹 도구가 아닙니다. eBPF 기반 CNI는 VM의 커널 네트워크 스택 전체를 재구성할 수 있으며, 이 과정에서 하위 인프라(CloudStack Virtual Router)와 충돌할 수 있습니다.
- 가상화 인프라 위에 Kubernetes를 구성할 때는 NAT 레이어가 몇 겹으로 쌓이는지 명확히 파악해야 합니다. 이 환경은 "외부 -> CloudStack NAT -> VM eth0 -> Cilium eBPF -> Pod" 의 4계층 NAT 구조였습니다.

---

### CASE-07: VM 재부팅 후 Pod Unknown 상태

**태그:** #kubernetes #pod #재부팅
**난이도:** 1/5
**등급:** C

**증상:**

VM 스펙 변경(재부팅) 후 Pod들이 Unknown 상태로 남아 있습니다. 노드가 일시적으로 NotReady가 되면서 Pod 상태가 Unknown으로 전환되고, 노드 복구 후에도 자동 정리되지 않습니다.

**해결:**

Unknown 상태의 Pod를 강제 삭제하여 재스케줄링을 유도합니다:

```bash
kubectl delete pods -n devops --field-selector=status.phase=Unknown --force --grace-period=0
```

---

## Part 3: DevOps 도구 레이어

### CASE-08: GitLab Pod Pending - PV nodeAffinity

**태그:** #kubernetes #pv #pvc #nodeaffinity #gitlab
**난이도:** 2/5
**등급:** B

**증상:**

GitLab Pod가 Pending 상태로 스케줄링되지 않습니다. `kubectl describe pod`에서 "0/2 nodes are available: 1 node(s) had volume node affinity conflict" 메시지가 나타납니다.

**원인:**

PersistentVolume의 nodeAffinity가 이전 노드(k8s-m)를 가리키고 있습니다. GitLab을 Worker 노드(k8s-w1)로 이동하면서 PV는 갱신하지 않아 발생합니다.

**해결:**

PV, PVC를 삭제하고 새 노드(k8s-w1)에 맞게 재생성합니다:

```bash
kubectl delete pvc gitlab-data-pvc -n devops
kubectl delete pv gitlab-data-pv
# PV의 nodeAffinity를 k8s-w1로 수정 후
kubectl apply -f manifests/gitlab/pvc.yaml
```

---

### CASE-09: Jenkins CrashLoopBackOff - initContainer 볼륨 권한 ★

**태그:** #kubernetes #jenkins #permissions #initcontainer #security-context
**난이도:** 3/5
**등급:** A
**해결 소요:** 약 1시간

**발생 맥락**

Jenkins를 Kubernetes에 hostPath PersistentVolume으로 배포한 직후 발생했습니다. Jenkins 이미지 자체는 정상이고, 볼륨 마운트도 설정상 문제가 없어 보였습니다. 그러나 컨테이너는 기동을 반복하며 실패했습니다.

**증상:**

```
INSTALL WARNING: User: missing rw permissions on JENKINS_HOME: /var/jenkins_home
touch: cannot touch '/var/jenkins_home/copy_reference_file.log': Permission denied
```

Pod가 CrashLoopBackOff 상태로 반복 재시작합니다.

**진단 과정**

1단계 - 로그 확인: 권한 오류가 명확합니다. Jenkins 프로세스가 `/var/jenkins_home`에 쓸 수 없습니다.

2단계 - 볼륨 소유권 확인:
```bash
# 노드에서 직접 확인
ls -la /data/jenkins/
# drwxr-xr-x 2 root root 4096 ...
```
hostPath 볼륨은 호스트 파일시스템의 디렉토리를 그대로 사용하므로, 처음 생성 시 root 소유입니다.

3단계 - Jenkins 프로세스 UID 확인:
```bash
docker inspect jenkins/jenkins:lts | grep -i user
# "User": "jenkins" -> UID 1000
```
Jenkins 컨테이너는 UID 1000(jenkins 사용자)으로 실행되므로 root 소유 디렉토리에 쓰기 권한이 없습니다.

**근본 원인**

hostPath PersistentVolume의 디렉토리는 root 소유로 생성됩니다. Jenkins 컨테이너는 UID 1000으로 실행되어 해당 디렉토리에 쓰기 권한이 없습니다. `securityContext.fsGroup`으로도 해결 가능하나, 컨테이너 기동 전 디렉토리 소유권을 명시적으로 변경하는 initContainer 패턴이 더 명확합니다.

**해결**

`manifests/jenkins/deployment.yaml`에 initContainer를 추가하여 컨테이너 기동 전 소유권을 변경합니다:

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

initContainer는 root(UID 0)로 실행되어 디렉토리 소유권을 1000:1000으로 변경한 뒤 종료됩니다. 이후 메인 Jenkins 컨테이너가 UID 1000으로 기동되면 정상적으로 쓰기가 가능합니다.

**교훈:**
- Kubernetes에서 호스트 파일시스템을 볼륨으로 사용할 때는 컨테이너의 실행 UID와 호스트 디렉토리 소유권이 일치해야 합니다.
- initContainer 패턴은 "메인 컨테이너 기동 전 환경 준비"라는 명확한 책임 분리를 가능하게 합니다. 권한 수정, 설정 파일 복사, 의존 서비스 대기 등 다양한 용도로 활용됩니다.
- `securityContext.fsGroup`을 사용하면 initContainer 없이도 해결 가능하지만, 그 의미를 이해하지 못한 채 사용하면 더 복잡한 문제로 이어질 수 있습니다.

---

### CASE-10: NodePort 불일치로 외부 접속 실패

**태그:** #kubernetes #nodeport #cloudstack #port-forwarding #service
**난이도:** 2/5
**등급:** B

**증상:**

Pod는 Running 상태이고 클러스터 내부에서는 서비스에 접근 가능하나, 외부에서 CloudStack Public IP로 접속이 불가합니다.

**진단:**

실제 할당된 NodePort와 CloudStack 포트 포워딩 규칙의 포트 번호가 불일치합니다:

| Service | 실제 NodePort | CloudStack 포워딩 |
|---------|--------------|------------------|
| Jenkins | 31673 | 30880 |
| GitLab | 30499 | 30080 |
| Registry | 30941 | 30500 |

**근본 원인:**

Service 타입이 LoadBalancer로 설정되면 Kubernetes가 랜덤 NodePort를 자동 할당합니다. CloudStack 포트 포워딩 규칙에 사전 정의한 포트 번호와 불일치가 발생합니다.

**해결:**

Service 타입을 NodePort로 변경하고 포트 번호를 명시적으로 지정합니다:

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

### CASE-11: GitLab OOMKilled - 메모리 튜닝

**태그:** #gitlab #kubernetes #oom #resources #memory
**난이도:** 2/5
**등급:** B

**증상:**

```
Last State:     Terminated
  Reason:       OOMKilled
  Exit Code:    137
```

GitLab Pod가 시작 직후 또는 사용 중 반복적으로 OOMKilled로 종료됩니다.

**원인:**

GitLab CE는 단일 컨테이너 안에 PostgreSQL, Redis, Puma(Ruby on Rails), Sidekiq 등 여러 서비스를 내장합니다. 초기 메모리 제한 4Gi는 이 모든 서비스를 동시에 운영하기에 부족합니다.

**해결:**

메모리 제한을 5Gi로 증가합니다:

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

### CASE-12: GitLab 비밀번호 환경변수 미작동 - 애플리케이션 수명주기 ★

**태그:** #gitlab #kubernetes #lifecycle #persistentvolume #환경변수
**난이도:** 3/5
**등급:** A
**해결 소요:** 약 1시간

**발생 맥락**

GitLab을 재배포하거나 환경을 재구성할 때, Deployment에 `GITLAB_ROOT_PASSWORD` 환경변수를 설정했음에도 해당 비밀번호로 로그인이 불가능했습니다. 환경변수가 분명히 주입되고 있는데 왜 적용되지 않는지 파악이 필요했습니다.

**증상:**
- `GITLAB_ROOT_PASSWORD` 환경변수를 Kubernetes Secret으로 주입했으나 로그인 불가
- "Invalid login or password" 오류가 반복
- GitLab Pod 로그에서 오류는 보이지 않음

**진단 과정**

1단계 - 환경변수 주입 확인:
```bash
kubectl exec -it <gitlab-pod> -n devops -- env | grep GITLAB_ROOT
# GITLAB_ROOT_PASSWORD=mypassword -> 정상 주입 확인
```

2단계 - GitLab 문서 검색: `GITLAB_ROOT_PASSWORD`의 동작 방식을 공식 문서에서 확인.

3단계 - PersistentVolume 상태 확인:
```bash
kubectl get pv gitlab-data-pv
# STATUS: Bound, RECLAIM POLICY: Retain
```
이전 실행에서의 데이터가 PV에 잔존.

4단계 - 원인 파악: GitLab 초기화 스크립트는 데이터베이스가 이미 존재하면 환경변수를 무시하고 건너뜁니다.

**근본 원인**

`GITLAB_ROOT_PASSWORD`는 GitLab의 최초 설치 시(데이터베이스 초기화 시)에만 적용되는 일회성 환경변수입니다. PersistentVolume에 기존 GitLab 데이터가 존재하면 GitLab은 이미 초기화된 인스턴스로 판단하여 해당 환경변수를 완전히 무시합니다. 이는 GitLab 애플리케이션의 수명주기 설계 때문이며, 환경변수 주입 자체의 문제가 아닙니다.

**해결**

GitLab Rails 콘솔을 통해 직접 비밀번호를 재설정합니다:

```bash
kubectl exec -it gitlab -n devops -- bash
gitlab-rails console

user = User.find_by(username: 'root')
user.password = 'new_password'
user.password_confirmation = 'new_password'
user.save!
```

**교훈:**
- "환경변수를 설정했다"는 것이 "환경변수가 적용됐다"를 의미하지 않습니다. 애플리케이션이 해당 환경변수를 어느 시점에, 어떤 조건에서 처리하는지 이해해야 합니다.
- Stateful 애플리케이션은 수명주기(lifecycle) 개념이 있습니다. 초기화용 설정은 최초 기동 시에만 적용되며, 이후에는 애플리케이션 내부 메커니즘(Rails Console, Admin UI 등)으로 변경해야 합니다.

---

### CASE-13: GitLab 사용자 계정 승인 대기

**태그:** #gitlab #user-management #database
**난이도:** 2/5
**등급:** B

**증상:**

```
Your account is pending approval from your GitLab administrator and hence blocked.
```

새로 생성한 GitLab 계정이 관리자 승인 대기 상태로 로그인 불가합니다.

**원인:**

GitLab의 기본 설정에서 새 사용자 등록 시 관리자 승인이 필요합니다. Admin UI에 접근 가능하면 UI에서 승인 가능하지만, 접근이 어려운 경우 DB 직접 수정이 필요합니다.

**해결:**

PostgreSQL을 통해 직접 사용자 상태를 변경합니다:

```bash
kubectl exec -it gitlab -n devops -- bash
gitlab-psql

UPDATE users SET state = 'active' WHERE username = '<USERNAME>';
UPDATE users SET admin = true WHERE username = '<USERNAME>';
\q
```

---

## Part 4: CI/CD 파이프라인 레이어

### CASE-14: Jenkins에서 Docker 명령 실행 - DinD 아키텍처 ★

**태그:** #jenkins #docker #dind #kubernetes #pipeline
**난이도:** 4/5
**등급:** A
**해결 소요:** 약 2시간

**발생 맥락**

Jenkins 파이프라인에서 Docker 이미지 빌드 및 레지스트리 push 단계를 구현하려 했습니다. Jenkins가 Kubernetes Pod로 동작하고 있어, 컨테이너 내부에서 Docker를 실행하는 방법을 결정해야 했습니다.

**증상:**

```
+ docker build -t <YOUR_PUBLIC_IP>:30500/testapp:1 .
docker: command not found
```

Jenkins 컨테이너 내부에 Docker CLI가 없어 파이프라인의 Docker 빌드 단계가 실패합니다.

**진단 과정**

1단계 - 접근 방법 검토: 컨테이너에서 Docker를 실행하는 방법은 크게 세 가지입니다.
- Docker Socket 마운트(DooD): 호스트의 `/var/run/docker.sock`을 컨테이너에 마운트
- Docker-in-Docker(DinD): 컨테이너 내에서 독립적인 Docker 데몬 실행
- Kaniko/Buildah: Docker 없이 이미지 빌드

2단계 - 각 방법의 장단점 분석:

| 방법 | 장점 | 단점 |
|------|------|------|
| DooD | 간단, 빠름 | 호스트 Docker 데몬 공유로 보안 취약 |
| DinD | 격리된 환경 | privileged 컨테이너 필요 |
| Kaniko | 권한 불필요 | 학습 비용, 일부 기능 제한 |

3단계 - 환경 고려: CloudStack 환경의 제한된 리소스와 Kaniko 도입 비용을 감안하여 DinD 선택.

**근본 원인**

Jenkins 공식 이미지(`jenkins/jenkins:lts`)는 Docker CLI를 포함하지 않습니다. Kubernetes 환경에서 Jenkins Pod는 컨테이너이므로, 호스트의 Docker를 직접 사용하거나 별도 Docker 실행 환경이 필요합니다.

**해결**

Jenkins Deployment에 Docker-in-Docker(DinD) 사이드카 컨테이너를 추가합니다:

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

`DOCKER_HOST` 환경변수를 통해 Jenkins 컨테이너는 DinD 데몬(localhost:2375)으로 Docker 명령을 전달합니다. TLS를 비활성화(`DOCKER_TLS_CERTDIR=""`)하여 설정을 단순화합니다.

**교훈:**
- Kubernetes 환경에서 CI/CD를 구성할 때 "컨테이너 안에서 컨테이너를 빌드"하는 문제는 반드시 고려해야 할 아키텍처 결정 사항입니다.
- DinD의 privileged 컨테이너는 보안 위험이 있습니다. 프로덕션 환경에서는 Kaniko, Buildah, 또는 클라우드 네이티브 빌드 서비스를 검토해야 합니다.

---

### CASE-15: Docker Registry Insecure 설정

**태그:** #docker #registry #https #tls
**난이도:** 2/5
**등급:** B

**증상:**

```
Get "https://<YOUR_PUBLIC_IP>:30500/v2/": http: server gave HTTP response to HTTPS client
```

Docker가 레지스트리에 HTTPS로 연결을 시도하나 레지스트리는 HTTP만 지원합니다.

**원인:**

Docker는 기본적으로 모든 레지스트리에 HTTPS 연결을 시도합니다. Private Registry가 TLS 인증서 없이 HTTP로만 운영되면 이 오류가 발생합니다.

**해결:**

Jenkins DinD 컨테이너에 insecure registry를 등록합니다:

```yaml
- name: docker
  image: docker:dind
  args:
  - "--insecure-registry=<YOUR_PUBLIC_IP>:30500"
```

---

### CASE-16: Worker 노드 ImagePullBackOff - containerd 설정 ★

**태그:** #kubernetes #containerd #imagepullbackoff #registry #insecure
**난이도:** 3/5
**등급:** A
**해결 소요:** 약 1.5시간

**발생 맥락**

Jenkins 파이프라인에서 Docker 이미지를 빌드하고 Private Registry에 push하는 것까지는 성공했습니다. 그런데 Kubernetes가 해당 이미지를 Worker 노드에 pull하는 단계에서 실패했습니다. Jenkins에서는 정상 동작하는데 왜 Kubernetes에서 실패하는지 원인 파악이 필요했습니다.

**증상:**

```
Warning  Failed   Failed to pull image "<YOUR_PUBLIC_IP>:30500/testapp:5":
rpc error: http: server gave HTTP response to HTTPS client
```

Pod가 ImagePullBackOff 상태로 이미지를 가져오지 못합니다.

**진단 과정**

1단계 - Jenkins에서 push 확인:
```bash
curl http://<YOUR_PUBLIC_IP>:30500/v2/testapp/tags/list
# {"name":"testapp","tags":["5"]}
```
이미지는 정상적으로 Registry에 존재합니다.

2단계 - 오류 메시지 분석: Jenkins의 Docker(DinD)는 `--insecure-registry` 옵션으로 HTTP를 허용하도록 설정되어 있습니다. 그러나 Worker 노드의 컨테이너 런타임(containerd)은 별도의 설정이 없으면 기본적으로 HTTPS만 허용합니다.

3단계 - 설정 계층 확인: Jenkins 사이드카 Docker와 Kubernetes Worker 노드의 containerd는 완전히 별개의 컨테이너 런타임입니다. Jenkins용 Docker에 insecure registry를 설정해도 Worker 노드의 containerd에는 영향이 없습니다.

**근본 원인**

Jenkins 파이프라인(DinD 컨테이너)과 Kubernetes Worker 노드(containerd)는 서로 독립적인 컨테이너 런타임을 사용합니다. Jenkins에 insecure registry를 설정해도 Worker 노드의 containerd에는 별도로 같은 설정을 해야 합니다. 이는 "설정 불일치" 패턴의 전형적인 사례입니다.

**해결**

모든 Worker 노드에 containerd insecure registry 설정을 추가합니다:

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

**교훈:**
- 파이프라인의 각 단계(빌드, push, pull)는 서로 다른 컨테이너 런타임을 사용할 수 있습니다. 각 단계의 런타임 설정이 일치하는지 확인해야 합니다.
- CASE-10(NodePort 불일치)과 동일한 "설정 불일치" 패턴입니다. 한 곳에서 설정하면 다른 곳에서도 동일하게 적용해야 한다는 교훈이 반복되었습니다.

---

### CASE-17: Jenkinsfile Namespace 불일치

**태그:** #jenkins #kubernetes #namespace #jenkinsfile
**난이도:** 1/5
**등급:** C

**증상:**

```
error: deployments.apps "testapp" not found
```

Jenkins 파이프라인에서 kubectl 명령이 배포를 찾지 못합니다.

**원인:**

testapp이 `devops` namespace에 배포되어 있으나, Jenkinsfile에서 namespace를 지정하지 않아 기본값인 `default` namespace에서 검색합니다.

**해결:**

Jenkinsfile에서 namespace를 명시적으로 지정합니다:

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

### CASE-18: Git Push 충돌 및 SSH 설정

**태그:** #git #ssh #gitlab #conflict
**난이도:** 1/5
**등급:** C

**증상:**

```
! [rejected]        main -> main (non-fast-forward)
error: failed to push some refs
```

**원인:**

GitLab UI에서 직접 파일을 수정하여 로컬에 없는 커밋이 원격에 존재합니다.

**해결**

SSH 키 기반 인증 설정:

```bash
# SSH 키 생성
ssh-keygen -t ed25519 -C "gitlab@k8s-cicd" -f ~/.ssh/gitlab_key

# SSH config 설정
cat >> ~/.ssh/config << 'EOF'
Host gitlab-k8s
    HostName <YOUR_PUBLIC_IP>
    Port 30022
    User git
    IdentityFile ~/.ssh/gitlab_key
EOF

# Git remote URL 변경
git remote set-url origin git@gitlab-k8s:<USERNAME>/testapp.git
```

Rebase로 충돌 해결:

```bash
git pull --rebase origin main
git push origin main
```

---

## Part 5: 네트워크 진단 방법론

### CASE-19: curl 타임아웃 vs 브라우저 정상 - 5계층 체계적 진단 ★

**태그:** #networking #diagnostic #vpn #curl #browser #methodology
**난이도:** 4/5
**등급:** A
**해결 소요:** 약 2시간

**발생 맥락**

GitLab, Jenkins, Registry 서비스를 구성한 후 외부 접속 테스트 단계에서 발생했습니다. curl로 테스트하면 타임아웃이 발생하는데, 브라우저로 동일한 URL에 접속하면 정상 동작하는 이상한 상황이었습니다. 처음에는 Kubernetes 또는 CloudStack 설정 문제라고 생각했습니다.

**증상:**

```bash
$ ping <YOUR_PUBLIC_IP>
PING <YOUR_PUBLIC_IP>: 56 data bytes
Request timeout for icmp_seq 0
--- <YOUR_PUBLIC_IP> ping statistics ---
2 packets transmitted, 0 packets received, 100.0% packet loss

$ curl -s --connect-timeout 5 http://<YOUR_PUBLIC_IP>:30080/users/sign_in
# Timeout (HTTP 000)
```

그러나 Chrome에서 동일 URL 접속 시 GitLab 로그인 페이지가 정상 표시됩니다.

**진단 과정**

체계적으로 레이어를 분리하여 각 레이어가 정상인지 확인합니다.

1계층 - TCP 포트 연결 테스트:
```bash
$ nc -zv -w 5 <YOUR_PUBLIC_IP> 2222
Connection to <YOUR_PUBLIC_IP> port 2222 [tcp/rockwell-csp2] succeeded!

$ nc -zv -w 5 <YOUR_PUBLIC_IP> 30080
# Timeout
```
SSH 포트(2222)는 연결되나 HTTP 포트(30080)는 타임아웃. CloudStack 포트 포워딩 문제를 의심.

2계층 - SSH 연결 테스트:
```bash
$ ssh -o IdentitiesOnly=yes -i ~/.ssh/k8s_key -p 2222 ubuntu@<YOUR_PUBLIC_IP>
# 접속 성공
```
SSH는 정상이므로 네트워크 기본 연결은 문제없음.

3계층 - 클러스터 내부에서 NodePort 직접 테스트:
```bash
$ curl -s -o /dev/null -w "%{http_code}" http://<WORKER1_IP>:30080/users/sign_in
200
```
클러스터 내부에서 NodePort 접근 성공. Kubernetes 서비스와 Pod는 정상.

4계층 - CloudStack 포트 포워딩 규칙 확인:
CloudStack 콘솔에서 모든 포트 포워딩 규칙이 Active 상태 확인.

5계층 - Cilium eBPF와 CloudStack NAT 충돌 여부 확인:
```bash
$ kubectl logs -n kube-system -l k8s-app=cilium --tail=20 | grep -i "nat\|nodeport"
# NAT/NodePort 관련 에러 없음
```

최종 분석 - 로컬 클라이언트 차이: curl과 브라우저의 동작 차이를 분석합니다.

| 클라이언트 | 동작 | 결과 |
|-----------|------|------|
| ping | ICMP 프로토콜 | CloudStack에서 기본 차단 |
| curl | 단일 TCP 연결 | VPN 라우팅에 따라 불안정 |
| 브라우저 | OS 네트워크 스택 사용, 재시도 로직 포함 | 정상 |

**근본 원인**
- ICMP(ping)는 CloudStack에서 기본적으로 차단됩니다. ping 실패가 곧 네트워크 문제를 의미하지 않습니다.
- 로컬 환경의 VPN 설정에 따라 특정 포트 범위(30000+)의 TCP 연결이 불안정할 수 있습니다.
- 브라우저는 OS의 네트워크 스택을 사용하며 자체 재시도 로직이 있어, 간헐적 연결 실패에 더 관대합니다.

**해결**
- Cilium eBPF와 NAT 충돌 없음: 클러스터 내부에서 NodePort 테스트 성공(HTTP 200)
- CloudStack 포트 포워딩 정상: 모든 규칙 Active 상태
- 브라우저 접근 정상: Chrome에서 모든 서비스(GitLab, Jenkins, Registry) 접근 성공
- 로컬 CLI 도구의 연결 불안정은 VPN 라우팅 설정 문제이며, 실제 서비스는 정상 작동

**교훈:**
- "curl이 실패한다"는 것이 "서비스가 비정상"임을 의미하지 않습니다. 진단 도구 자체의 동작 방식과 한계를 이해해야 합니다.
- 네트워크 문제는 레이어를 분리하여 각 레이어가 정상인지 독립적으로 검증해야 합니다. (ICMP -> TCP -> HTTP -> 애플리케이션)
- 로컬 환경(VPN, 방화벽 등)이 테스트 결과에 영향을 줄 수 있습니다. 항상 클러스터 내부에서의 테스트로 교차 검증해야 합니다.

---

## Part 6: 리소스 최적화 가이드

### 초기 구성의 문제점

초기에는 모든 노드를 Medium(2 CPU, 4GB)으로 구성했으나, 다음 문제가 발생했습니다:

1. **리소스 부족:** GitLab, Jenkins, Registry를 동시에 운영하기에 Worker 노드 리소스 부족
2. **OOMKilled 발생:** GitLab Pod가 메모리 부족으로 반복 재시작(CASE-11 참조)
3. **성능 저하:** DevOps 도구들의 응답 속도 저하로 파이프라인 실행 시간 증가

### 의사결정 근거

**왜 k8s-w1만 Large로 올렸는가?**

- Control Plane(k8s-m)은 클러스터 관리 역할만 하며, 실제 워크로드를 처리하지 않아 Medium으로 충분합니다.
- DevOps 도구(GitLab, Jenkins, Registry)는 메모리 집약적이어서 동일 노드에 배치하고 해당 노드만 확장합니다.
- testapp은 경량 웹 애플리케이션이므로 Medium 노드(k8s-w2)로 충분합니다.
- CloudStack 계정 CPU 쿼터 제한 내에서 최대 효율을 내기 위해 집중 배치를 선택했습니다.

### 리소스 재배치

| 노드 | 변경 전 | 변경 후 | 역할 |
|------|---------|---------|------|
| k8s-m | Medium (2 CPU, 4GB) | Medium (2 CPU, 4GB) | Control Plane 전용 |
| k8s-w1 | Medium (2 CPU, 4GB) | Large (4 CPU, 8GB) | GitLab, Jenkins, Registry |
| k8s-w2 | Medium (2 CPU, 4GB) | Medium (2 CPU, 4GB) | testapp |

### 변경 절차

1. Terraform `variables.tf`에서 k8s-w1 서비스 오퍼링을 Large로 변경
2. `terraform apply` 실행하여 VM 스펙 업그레이드
3. Worker 노드 재시작 및 클러스터 재조인
4. DevOps 워크로드(GitLab, Jenkins, Registry)를 k8s-w1에 배치하도록 nodeSelector 설정
5. 매니페스트 재적용

