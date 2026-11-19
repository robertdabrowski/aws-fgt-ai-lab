# AWS FortiGate AI Lab

Lab pozwala obserwować na FortiGate ruch A2A pomiędzy dwoma agentami, wywołania MCP do serwera narzędzi i zapytania do OpenAI. Terraform tworzy VPC oraz cztery maszyny EC2 w `eu-central-1a`. Każdy workload ma własny segment i osobny port inspekcyjny FortiGate.

[Pełna instrukcja angielska i topologia](../README.md) · [Komendy do OpenAI i Deep Inspection](openai-and-deep-inspection.md)

## 1. Utwórz infrastrukturę

Wymagane są uprawnienia AWS do EC2, VPC, IAM i Systems Manager, Terraform 1.10+, AWS CLI v2, Bash i `jq`, a do sesji interaktywnych również Session Manager Plugin. W `eu-central-1` potrzebujesz istniejącego EC2 Key Pair i dostępu do obrazu BYOL w AWS Marketplace. Domyślny obraz to FortiOS 8.0.2 build0251.

W katalogu projektu ustaw w `terraform.tfvars` nazwę klucza `fgt_key_name` oraz `admin_cidr` odpowiadający adresowi lub sieci, z której zarządzasz FortiGate. Następnie zweryfikuj i zastosuj plan.

```bash
cp terraform.tfvars.example terraform.tfvars
```

### Katalog roboczy Terraform w AWS CloudShell

CloudShell udostępnia 1 GB trwałego miejsca w katalogu domowym na region. Przed `terraform init` wykonaj poniższy blok w głównym katalogu repozytorium, aby zainstalować provider AWS w `/tmp`.

```bash
lab_tf_data_dir="$(mktemp -d /tmp/aws-fgt-ai-lab.XXXXXX)" &&
export TF_DATA_DIR="$lab_tf_data_dir"
```

Używaj tej samej wartości `TF_DATA_DIR` w kolejnych poleceniach Terraform w bieżącej sesji.

Jeżeli wcześniejsza instalacja zakończyła się błędem `no space left on device`, a Terraform zgłasza teraz niezgodność sum kontrolnych, zwolnij miejsce zajęte przez niekompletną kopię. W katalogu repozytorium wykonaj:

```bash
rm -rf -- .terraform/providers/registry.terraform.io/hashicorp/aws/6.66.0/linux_amd64
```

Zachowaj plik `.terraform.lock.hcl` z repozytorium. Uruchom inicjalizację i zapisz plan:

```bash
terraform init -input=false -lockfile=readonly &&
terraform fmt -check -recursive &&
terraform validate &&
terraform plan -input=false -out=lab.tfplan &&
terraform show -no-color lab.tfplan
```

Po sprawdzeniu planu zastosuj go:

```bash
terraform apply lab.tfplan
terraform output
```

### Wznów pracę w nowej sesji CloudShell

Wróć do tego samego katalogu z klonem repozytorium. Zmienna `TF_DATA_DIR` obowiązywała tylko w poprzedniej sesji. Utwórz nowy katalog tymczasowy i zainicjalizuj Terraform:

```bash
lab_tf_data_dir="$(mktemp -d /tmp/aws-fgt-ai-lab.XXXXXX)" &&
export TF_DATA_DIR="$lab_tf_data_dir" &&
terraform init -input=false -lockfile=readonly
```

Plik `terraform.tfvars`, lokalny stan i zapisane plany pozostają w katalogu projektu. Jeśli sesja została przerwana podczas `terraform apply`, upewnij się, że poprzednie wykonanie się zakończyło. Wygeneruj i przejrzyj świeży plan przed zastosowaniem pozostałych zmian:

```bash
terraform plan -input=false -out=resume.tfplan &&
terraform show -no-color resume.tfplan
```

## 2. Skonfiguruj FortiGate ręcznie

- Otwórz GUI na aktualnym `fgt_public_ip`. Dla domyślnego obrazu AWS zaloguj się jako `admin`, używając bieżącego `fgt_instance_id` jako początkowego hasła. Ustaw własne hasło w GUI.
- Wprowadź token FortiFlex w GUI lub przez `execute vm-license <TOKEN>` w CLI. Przy innej zgodnej licencji BYOL wgraj plik `.lic` do FortiGate. Po aktywacji sprawdź `get system status`, `show system interface` i `get router info routing-table all`.
- Wklej [forward-policies.conf](../fortigate/forward-policies.conf) do CLI w VDOM `root`. Plik jest przeznaczony dla świeżej instancji. Sprawdź dostępność identyfikatorów 701, 702, 703, 704 i 707. Potwierdź konfigurację przez `show firewall policy`.

| Polityka | Kierunek | Ruch | Cel | SNAT |
|---|---|---|---|---|
| 701 | `port2 → port3` | A2A TCP/8081 | Agent B | Wyłączony |
| 702 | `port3 → port4` | MCP TCP/8082 | Serwer MCP | Wyłączony |
| 703, 704, 707 | `port2/port3/port4 → port1` | HTTPS TCP/443 | `all` | Włączony |

HTTPS dopasowujemy według źródła /32, interfejsów i portu. OpenAI i SSM korzystają z tej samej reguły dla danego źródła, więc zmieniające się adresy IP endpointów AWS nie wymagają aktualizacji polityk.

## 3. Wdróż aplikację i potwierdź ruch

```bash
lab_ids="$(terraform output -json workload_instance_ids | jq -er '[.[]] | join(",")')" &&
aws ssm describe-instance-information --region eu-central-1 \
  --filters "Key=InstanceIds,Values=$lab_ids" \
  --query 'sort_by(InstanceInformationList,&IPAddress)[].{IP:IPAddress,Instance:InstanceId,Status:PingStatus}' \
  --output table --no-cli-pager
```

Po uzyskaniu statusu `Online` dla wszystkich trzech maszyn uruchom:

```bash
bash app/stage8b.sh deploy
bash app/stage8b.sh test
```

Test powinien zwrócić `Agent A [mock]: payments-demo: degraded, INC LAB-1042.` W FortiGate obserwuj reguły 701 i 702 w Forward Traffic lub przechwyć pakiety poleceniem:

```text
diagnose sniffer packet any 'tcp and (port 8081 or port 8082)' 4 0 l
```

[Instrukcja OpenAI i Deep Inspection](openai-and-deep-inspection.md) zawiera polecenia do otwarcia sesji SSM, uruchomienia obu agentów i instalacji CA na Agencie B. Przed włączeniem deszyfrowania na polityce 704 dodaj `*.amazonaws.com` do wyjątków profilu SSL/SSH, aby zachować dostęp SSM. Test `curl` bez klucza powinien zwrócić HTTP 401 po prawidłowej weryfikacji certyfikatu.

## 4. Usuń lab

```bash
terraform plan -destroy -out=destroy.tfplan
terraform show -no-color destroy.tfplan
terraform apply destroy.tfplan
```
