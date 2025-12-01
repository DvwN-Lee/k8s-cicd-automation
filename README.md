# DKU CI/CD Infrastructure

<p align="center">
  <img src="screenshots/testapp.png" alt="DKU CI/CD Infrastructure" width="800">
</p>

CloudStack 환경에서 Kubernetes 클러스터를 구축하고, Jenkins, GitLab, Docker Registry를 배포하여 완전한 CI/CD 파이프라인을 구현한 Infrastructure as Code 프로젝트입니다.

![Terraform](https://img.shields.io/badge/Terraform-7B42BC?style=flat&logo=terraform&logoColor=white)
![Ansible](https://img.shields.io/badge/Ansible-EE0000?style=flat&logo=ansible&logoColor=white)
![Kubernetes](https://img.shields.io/badge/Kubernetes-326CE5?style=flat&logo=kubernetes&logoColor=white)
![Cilium](https://img.shields.io/badge/Cilium-F8C517?style=flat&logo=cilium&logoColor=black)
![Jenkins](https://img.shields.io/badge/Jenkins-D24939?style=flat&logo=jenkins&logoColor=white)
![GitLab](https://img.shields.io/badge/GitLab-FC6D26?style=flat&logo=gitlab&logoColor=white)

---

## 목차

- [프로젝트 개요](#프로젝트-개요)
- [인프라 아키텍처](#인프라-아키텍처)
- [사전 요구사항](#사전-요구사항)
- [빠른 시작](#빠른-시작)
- [디렉토리 구조](#디렉토리-구조)
- [서비스 접근 정보](#서비스-접근-정보)
- [주요 설정 참조](#주요-설정-참조)
- [참고 문서](#참고-문서)

---

## 프로젝트 개요

### 수행 목표

CloudStack 환경에서 Kubernetes 클러스터를 구축하고, Jenkins, GitLab, Docker Registry를 배포하여 완전한 CI/CD 파이프라인을 구현합니다.

### 항목별 성공 여부

| 과제 | 항목 | 상태 | 비고 |
|------|------|------|------|
| **과제 #1** | CloudStack Provider 설정 | 완료 | API endpoint, API key, secret key 설정 |
| | Isolated Network 생성 | 완료 | k8s-network (192.168.0.0/24) |
| | Port Forwarding 규칙 생성 | 완료 | 7개 규칙 (SSH, K8s API, Jenkins, GitLab, Registry, TestApp) |
| | Firewall 규칙 생성 | 완료 | 7개 포트 개방 (0.0.0.0/0) |
| | VM 생성 (Master 1대, Worker 2대) | 완료 | k8s-m, k8s-w1, k8s-w2 |
| | Terraform Output | 완료 | ansible_inventory 자동 생성 |
| **과제 #2** | Ansible Inventory 생성 | 완료 | Terraform output 기반 자동 생성 |
| | containerd, kubeadm 설치 | 완료 | v1.28.15 |
| | kubeadm init | 완료 | Control Plane 초기화 |
| | Worker 노드 조인 | 완료 | 2대 조인 완료 |
| | CNI (Cilium) 구성 | 완료 | v1.14.5, kube-proxy 대체 모드 |
| | MetalLB 구성 | 완료 | L2 모드, 192.168.0.200-250 |
| **과제 #3** | Jenkins 배포 | 완료 | NodePort 30880 |
| | GitLab 배포 | 완료 | NodePort 30080, 30022 |
| | Docker Registry 배포 | 완료 | NodePort 30500 |
| | PVC 구성 | 완료 | hostPath 기반 |
| **과제 #4** | GitLab 테스트 프로젝트 | 완료 | testapp |
| | Jenkins Pipeline | 완료 | Build, Push, Deploy |
| | Registry 이미지 Push | 완료 | testapp:latest |
| | Kubernetes 배포 | 완료 | 2 replicas (k8s-w1, k8s-w2 분산) |

### 기술 스택

- **IaC (Infrastructure as Code):** Terraform
- **Configuration Management:** Ansible
- **Container Orchestration:** Kubernetes v1.28.15
- **Container Runtime:** containerd (apt 패키지 최신 버전)
- **CNI:** Cilium v1.14.5
- **Load Balancer:** MetalLB
- **CI/CD Tools:** Jenkins, GitLab CE, Docker Registry

---

## 인프라 아키텍처

### 전체 아키텍처

```mermaid
graph TB
    subgraph CloudStack["CloudStack Cloud"]
        subgraph PublicNetwork["Public Network"]
            PIP["Public IP<br/><YOUR_PUBLIC_IP>"]
        end

        subgraph IsolatedNetwork["Isolated Network (192.168.0.0/24)"]
            subgraph Master["k8s-m (Control Plane)"]
                M_SPEC["Medium: 2 CPU, 4GB RAM"]
                M_IP["<MASTER_IP>"]
            end

            subgraph Worker1["k8s-w1 (DevOps Node)"]
                W1_SPEC["Large: 4 CPU, 8GB RAM"]
                W1_IP["<WORKER1_IP>"]
                GitLab["GitLab CE"]
                Jenkins["Jenkins"]
                Registry["Docker Registry"]
            end

            subgraph Worker2["k8s-w2 (App Node)"]
                W2_SPEC["Medium: 2 CPU, 4GB RAM"]
                W2_IP["<WORKER2_IP>"]
                TestApp["testapp"]
            end
        end
    end

    User["User"] --> PIP
    PIP -->|"2222, 6443"| Master
    PIP -->|"30080, 30022, 30880, 30500"| Worker1
    PIP -->|"30800"| Worker2
```

### 네트워크 구성

```mermaid
graph LR
    subgraph External["외부 접근"]
        Internet["Internet/VPN"]
    end

    subgraph CloudStack["CloudStack"]
        NAT["NAT/Port Forward<br/><YOUR_PUBLIC_IP>"]

        subgraph K8sNetwork["k8s-network (192.168.0.0/24)"]
            Master["k8s-m<br/><MASTER_IP>"]
            W1["k8s-w1<br/><WORKER1_IP>"]
            W2["k8s-w2<br/><WORKER2_IP>"]
        end
    end

    Internet -->|Port Forward| NAT
    NAT -->|"2222 -> 22"| Master
    NAT -->|"30080 -> 30080"| W1
    NAT -->|"30022 -> 30022"| W1
    NAT -->|"30880 -> 30880"| W1
    NAT -->|"30500 -> 30500"| W1
    NAT -->|"6443 -> 6443"| Master
    NAT -->|"30800 -> 30800"| W2
```

### Port Forwarding 규칙

| 서비스 | 외부 포트 | NodePort | Container Port | 포트 포워딩 대상 | Pod 배치 |
|--------|-----------|----------|----------------|-----------------|---------|
| SSH (Jump) | 2222 | - | 22 | k8s-m | - |
| Kubernetes API | 6443 | - | 6443 | k8s-m | - |
| GitLab HTTP | 30080 | 30080 | 80 | k8s-w1 | k8s-w1 |
| GitLab SSH | 30022 | 30022 | 22 | k8s-w1 | k8s-w1 |
| Jenkins | 30880 | 30880 | 8080 | k8s-w1 | k8s-w1 |
| Docker Registry | 30500 | 30500 | 5000 | k8s-w1 | k8s-w1 |
| TestApp | 30800 | 30800 | 80 | k8s-w2 | k8s-w2 |

**노드 역할 분리:**
- **k8s-w1 (DevOps Node):** GitLab, Jenkins, Registry 등 DevOps 도구 배치 (Large: 4 CPU, 8GB RAM)
- **k8s-w2 (App Node):** testapp 등 애플리케이션 워크로드 배치 (Medium: 2 CPU, 4GB RAM)

---

## 사전 요구사항

### CloudStack 환경

- CloudStack 계정 및 API 액세스
- Zone, Network Offering 정보
- SSH 키페어 생성

### 로컬 환경

- **Terraform:** v1.0 이상
- **Ansible:** v2.9 이상
- **kubectl:** v1.28 이상
- **SSH 클라이언트**

### SSH 키 설정

```bash
# SSH 키 생성 (이미 있다면 생략)
ssh-keygen -t rsa -b 4096 -f ~/.ssh/k8s_key -N ""
```

---

## 빠른 시작

### 1. 인프라 프로비저닝 (Terraform)

#### 1.1 Terraform 변수 설정

`terraform/terraform.tfvars` 파일 생성:

```hcl
# CloudStack API 설정
api_url    = "https://your-cloudstack-api-url/client/api"
api_key    = "<YOUR_API_KEY>"
secret_key = "<YOUR_SECRET_KEY>"

# 네트워크 설정
zone_name         = "YOUR_ZONE"
network_offering  = "DefaultIsolatedNetworkOfferingWithSourceNatService"

# SSH 키
ssh_public_key = "~/.ssh/k8s_key.pub"
```

#### 1.2 Terraform 실행

```bash
cd terraform

# 초기화
terraform init

# 플랜 확인
terraform plan

# 인프라 생성
terraform apply

# Ansible Inventory 자동 생성
terraform output -raw ansible_inventory > ../ansible/inventory/hosts.ini
```

### 2. Kubernetes 클러스터 구성 (Ansible)

#### 2.1 Ansible 변수 확인

`ansible/group_vars/all.yml`에서 버전 확인:

```yaml
kubernetes_version: "1.28.15-1.1"
cilium_version: "1.14.5"
metallb_ip_range: "192.168.0.200-192.168.0.250"
```

#### 2.2 Ansible Playbook 실행

```bash
cd ansible

# 클러스터 구성 (containerd, K8s, Cilium, MetalLB)
ansible-playbook -i inventory/hosts.ini site.yml

# 클러스터 상태 확인 (Master 노드에서)
ssh -i ~/.ssh/k8s_key -p 2222 ubuntu@<YOUR_PUBLIC_IP>
kubectl get nodes
```

예상 결과:

```
NAME     STATUS   ROLES           AGE   VERSION
k8s-m    Ready    control-plane   1h    v1.28.15
k8s-w1   Ready    <none>          1h    v1.28.15
k8s-w2   Ready    <none>          1h    v1.28.15
```

### 3. DevOps 도구 배포

#### 3.1 Jenkins 배포

```bash
kubectl apply -f manifests/jenkins/

# 초기 비밀번호 확인
kubectl logs deployment/jenkins -n devops -c jenkins | grep -A 5 "Jenkins initial setup"
```

접속: `http://<YOUR_PUBLIC_IP>:30880`

#### 3.2 GitLab 배포

```bash
kubectl apply -f manifests/gitlab/

# Root 비밀번호 확인
kubectl get secret gitlab-root-password -n devops -o jsonpath="{.data.password}" | base64 -d
```

접속: `http://<YOUR_PUBLIC_IP>:30080`

#### 3.3 Docker Registry 배포

```bash
kubectl apply -f manifests/registry/

# Registry 확인
curl http://<YOUR_PUBLIC_IP>:30500/v2/_catalog
```

### 4. CI/CD 파이프라인 검증

#### 4.1 testapp 프로젝트 생성

1. GitLab에서 `testapp` 프로젝트 생성
2. 로컬에서 testapp 디렉토리를 GitLab에 push:

```bash
cd testapp
git init
git remote add origin http://<YOUR_PUBLIC_IP>:30080/<username>/testapp.git
git add .
git commit -m "Initial commit"
git push -u origin main
```

#### 4.2 Jenkins Pipeline 구성

1. Jenkins에서 New Item → Pipeline 선택
2. Pipeline 섹션에서:
   - Definition: `Pipeline script from SCM`
   - SCM: `Git`
   - Repository URL: `http://<YOUR_PUBLIC_IP>:30080/<username>/testapp.git`
   - Script Path: `Jenkinsfile`

#### 4.3 빌드 실행

Jenkins에서 "Build Now" 클릭 후 결과 확인:

```bash
# Registry에 이미지 확인
curl http://<YOUR_PUBLIC_IP>:30500/v2/testapp/tags/list

# Kubernetes 배포 확인
kubectl get pods -n devops -l app=testapp
```

---

## 디렉토리 구조

```
/
├── terraform/                 # Terraform IaC 코드
│   ├── provider.tf            # CloudStack Provider 설정
│   ├── main.tf                # 리소스 정의 (VM, Network, Port Forward)
│   ├── variables.tf           # 변수 정의
│   ├── terraform.tfvars       # 변수 값 (API 키 - .gitignore 권장)
│   └── outputs.tf             # 출력 정의
├── ansible/                   # Ansible 구성
│   ├── site.yml               # 메인 플레이북
│   ├── group_vars/
│   │   └── all.yml            # 전역 변수
│   ├── inventory/
│   │   └── hosts.ini          # Terraform에서 생성된 인벤토리
│   └── roles/                 # Ansible Roles
│       ├── common/            # 공통 설정 (swap 비활성화 등)
│       ├── containerd/        # containerd 런타임 설치
│       ├── kubernetes/        # kubeadm, kubelet, kubectl 설치
│       ├── k8s_master/        # Master 노드 초기화
│       ├── k8s_worker/        # Worker 노드 조인
│       ├── cni/               # Cilium CNI 설치
│       └── metallb/           # MetalLB 설치
├── manifests/                 # Kubernetes 매니페스트
│   ├── jenkins/               # Jenkins 배포
│   │   ├── namespace.yaml
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   ├── pvc.yaml
│   │   └── config.yaml
│   ├── gitlab/                # GitLab 배포
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   ├── pvc.yaml
│   │   └── secret.yaml
│   ├── registry/              # Docker Registry 배포
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   └── pvc.yaml
│   └── metallb/               # MetalLB 설정
│       ├── metallb-native.yaml
│       └── config.yaml.j2
├── testapp/                   # 테스트 애플리케이션
│   ├── Dockerfile
│   ├── Jenkinsfile            # CI/CD 파이프라인 정의
│   ├── html/                  # 정적 HTML 파일
│   └── k8s/                   # Kubernetes 배포 매니페스트
├── docs/                      # 문서
│   └── TROUBLESHOOTING.md     # 트러블슈팅 가이드
└── README.md                  # 본 문서
```

---

## 서비스 접근 정보

### 접근 URL

| 서비스 | URL | 비고 |
|--------|-----|------|
| GitLab | http://\<YOUR_PUBLIC_IP\>:30080 | root / (Secret에 정의) |
| Jenkins | http://\<YOUR_PUBLIC_IP\>:30880 | 초기 비밀번호 확인 필요 |
| Docker Registry | http://\<YOUR_PUBLIC_IP\>:30500 | 비보안 레지스트리 |
| Kubernetes API | https://\<YOUR_PUBLIC_IP\>:6443 | kubeconfig 필요 |

### SSH 접근

```bash
# Master 노드 접속
ssh -i ~/.ssh/k8s_key -p 2222 ubuntu@<YOUR_PUBLIC_IP>

# Worker 노드 접속 (ProxyJump)
ssh -i ~/.ssh/k8s_key -o ProxyCommand='ssh -i ~/.ssh/k8s_key -p 2222 -W %h:%p ubuntu@<YOUR_PUBLIC_IP>' ubuntu@<WORKER1_IP>
```

---

## 주요 설정 참조

### Terraform 변수

| 변수명 | 기본값 | 설명 |
|--------|--------|------|
| `network_name` | `k8s-network` | 네트워크 이름 |
| `network_cidr` | `192.168.0.0/24` | 네트워크 CIDR 대역 |
| `network_gateway` | `192.168.0.1` | 게이트웨이 주소 |
| `zone_name` | `DKU` | CloudStack Zone 이름 |

### Ansible 변수

`ansible/group_vars/all.yml`:

```yaml
kubernetes_version: "1.28.15-1.1"
cilium_version: "1.14.5"
native_routing_cidr: "192.168.0.0/24"
metallb_ip_range: "192.168.0.200-192.168.0.250"
```

### Kubernetes 리소스 요약

| 서비스 | Namespace | Replicas | Memory Limit | CPU Limit | 배포 노드 |
|--------|-----------|----------|--------------|-----------|----------|
| Jenkins | devops | 1 | 2Gi | 1000m | k8s-w1 |
| GitLab | devops | 1 | 5Gi | 2000m | k8s-w1 |
| Registry | devops | 1 | 512Mi | 500m | k8s-w1 |
| testapp | devops | 2 | - | - | k8s-w1, k8s-w2 |

---

## 참고 문서

### 프로젝트 문서

- [트러블슈팅 가이드](docs/TROUBLESHOOTING.md)

### 공식 문서

- [Terraform CloudStack Provider](https://registry.terraform.io/providers/cloudstack/cloudstack/latest/docs)
- [Ansible Documentation](https://docs.ansible.com/)
- [Kubernetes Documentation](https://kubernetes.io/docs/)
- [Cilium Documentation](https://docs.cilium.io/)
- [MetalLB Documentation](https://metallb.universe.tf/)
- [Jenkins Documentation](https://www.jenkins.io/doc/)
- [GitLab Documentation](https://docs.gitlab.com/)
