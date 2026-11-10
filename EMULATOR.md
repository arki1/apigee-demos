# Apigee Local Emulator: Guia Técnico e Referência

Este documento descreve o funcionamento interno, arquitetura, endpoints REST e instruções de uso do **Apigee Emulator** (`gcr.io/apigee-release/hybrid/apigee-emulator`), utilizado para desenvolvimento e testes locais de proxies e automação em CI/CD.

---

## 1. Arquitetura e Funcionamento

O container do Apigee Emulator roda uma versão local do runtime híbrido do Apigee encapsulado com uma instância local do Apache Cassandra e o Microkernel do Apigee:

* **Microkernel Java (`com.apigee.server.RuntimeEmulator`)**: Gerencia o ciclo de vida dos serviços internos, compilação de proxies e injeção de dependências.
* **Apache Cassandra (local)**: Armazena dados de contratos, entidades e estados de runtime.
* **ConfigCompiler (`com.apigee.config.compiler.ConfigCompiler`)**: Compilador que lê os arquivos XML de proxies, políticas e ambientes, validando e ativando os contratos de execução na memória do message processor.

### Portas e Comunicação

O container opera com duas portas HTTP principais:

| Porta no Container | Porta no Host (Padrão) | Finalidade | Descrição |
| :--- | :--- | :--- | :--- |
| **`8080`** | `8080` | **Management REST API** | Endpoint de controle para deploy de proxies, carga de dados de teste (KVMs) e inspeção. |
| **`8998`** | `8999` | **Proxy Runtime Traffic** | Ponto de entrada HTTP para chamadas aos proxies implantados (ex: `http://localhost:8999/gcpreleases/v1/...`). |

> [!NOTE]
> O emulador não monitora volumes automaticamente para compilação contínua. Toda compilação e deploy é acionada via chamadas HTTP na porta de gerenciamento (`8080`).

---

## 2. Referência da API de Gerenciamento (`/v1/emulator/*`)

A API de gerenciamento responde sob o prefixo `/v1`:

### 2.1 Informações e Status

#### `GET /v1/emulator/version`
Retorna a versão do runtime e lista as features ativas no container:
```bash
curl -s http://localhost:8080/v1/emulator/version | jq .
```
Exemplo de resposta:
```json
{
  "releaseId": "1.11",
  "activeEnvironment": "dev",
  "emulatorFeatures": [
    "apigee-oauth",
    "google-service-accounts",
    "tls",
    "resource-references",
    "debug-trace",
    "feature-flags",
    "data-collectors",
    "analytics"
  ]
}
```

#### `GET /v1/emulator/tree`
Lista todos os proxies atualmente implantados no emulador e seus respectivos `basePath`s:
```bash
curl -s http://localhost:8080/v1/emulator/tree | jq .
```
Exemplo de resposta:
```json
[
  {
    "application": "gcpreleases-v1",
    "name": "default",
    "basePath": "gcpreleases/v1",
    "proxyUID": "1"
  }
]
```

---

### 2.2 Deploy de Proxies e Contratos

#### `POST /v1/emulator/deploy?environment={env}`
Recebe um arquivo `.zip` contendo a árvore `src/` (incluindo `src/main/apigee/apiproxies/` e `src/main/apigee/environments/{env}/deployments.json`). O emulador descompacta, valida via `ConfigCompiler` e faz o deploy a quente da revisão.

* **Content-Type**: `application/octet-stream`
* **Query Parameter**: `environment` (ex: `dev`)

Exemplo de deploy:
```bash
zip -r /tmp/bundle.zip src/
curl -s -X POST "http://localhost:8080/v1/emulator/deploy?environment=dev" \
  -H "Content-Type: application/octet-stream" \
  --data-binary "@/tmp/bundle.zip"
```
Resposta esperada:
```json
{ "revision" : "1" }
```

---

### 2.3 Dados de Teste e Mocks (KVMs, Apps, Products)

O emulador aceita mocks de runtime para emular chamadas a KVMs, desenvolvedores, produtos de API e apps.

#### `POST /v1/emulator/setup/tests`
Carrega dados de teste a partir de um `.zip` contendo um ou mais arquivos JSON suportados (`maps.json`, `products.json`, `developers.json`, `developerapps.json`):

* **Content-Type**: `application/octet-stream`

Exemplo (carregando KVMs):
```bash
cd src/tests/dev && zip -r /tmp/testdata.zip maps.json
curl -s -X POST "http://localhost:8080/v1/emulator/setup/tests" \
  -H "Content-Type: application/octet-stream" \
  --data-binary "@/tmp/testdata.zip"
```

#### `GET /v1/emulator/test/maps`
Consulta os Key-Value Maps carregados:
```bash
curl -s http://localhost:8080/v1/emulator/test/maps | jq .
```

#### `DELETE /v1/emulator/clear/test`
Remove os dados de teste carregados:
```bash
curl -s -X DELETE http://localhost:8080/v1/emulator/clear/test
```

---

### 2.4 Trace e Debug Local

#### `POST /v1/emulator/trace?environment={env}`
Inicia uma sessão de trace/debug local.

#### `GET /v1/emulator/trace/transactions`
Lista os dados coletados de transações que passaram pelo emulador durante a sessão de debug.

---

### 2.5 Reset do Emulador

#### `POST /v1/emulator/reset`
Limpa os proxies e restaura o estado inicial do emulador sem precisar reiniciar o container.

---

## 3. Autenticação com Service Account do Google Cloud

Quando uma política ou TargetEndpoint utiliza autenticação Google (ex: `<GoogleAccessToken>` para acessar BigQuery, Cloud Storage ou Cloud Logging):

```xml
<Authentication>
  <GoogleAccessToken>
    <Scopes>
      <Scope>https://www.googleapis.com/auth/bigquery</Scope>
    </Scopes>
  </GoogleAccessToken>
</Authentication>
```

O emulador exige:

1. **Chave JSON montada no container**: Um diretório local contendo a chave (ex: `./cert/service-account.json`) montado em `/emulator/keys`.
2. **Variável de Ambiente configurada no container**:
   ```bash
   -e GOOGLE_APPLICATION_CREDENTIALS=/emulator/keys/service-account.json
   ```
   > [!IMPORTANT]
   > Durante a inicialização do Microkernel Java (`RuntimeEmulator.main`), o emulador verifica se o arquivo apontado por `GOOGLE_APPLICATION_CREDENTIALS` existe no disco (`Files.exists`). Se existir, ele instancia o serviço `GoogleTokenService`. Se não existir, o serviço não é registrado e chamadas autenticadas falharão com erro interno (`NullPointerException`).
3. **Mapeamento no `deployments.json`**:
   O arquivo `src/main/apigee/environments/<env>/deployments.json` deve conter o e-mail exato da Service Account da chave:
   ```json
   {
     "proxies": [
       {
         "name": "gcpreleases-v1",
         "serviceAccount": "apigee-demos@SEU_PROJECT_ID.iam.gserviceaccount.com"
       }
     ]
   }
   ```

---

## 4. Gerenciamento via CLI (`ci/apigee-emulator.sh`)

O script [`ci/apigee-emulator.sh`](file:///home/ronoaldo/workspace/apigee-demos/ci/apigee-emulator.sh) abstrai todas as operações acima em uma CLI prática:

```bash
# Iniciar emulador e aguardar healthcheck
./ci/apigee-emulator.sh start

# Fazer deploy do bundle atual e carregar mocks (KVMs)
./ci/apigee-emulator.sh deploy dev

# Inspecionar status e proxies ativos
./ci/apigee-emulator.sh status

# Fazer chamada de teste
./ci/apigee-emulator.sh test /gcpreleases/v1/echo

# Parar o emulador
./ci/apigee-emulator.sh stop
```

### Variáveis de Configuração Suportadas

* `EMULATOR_IMAGE`: Imagem Docker (padrão: `gcr.io/apigee-release/hybrid/apigee-emulator:1.16.2`)
* `EMULATOR_CONTAINER`: Nome do container (padrão: `apigee-localhost`)
* `EMULATOR_MGMT_PORT`: Porta host da API de gerenciamento (padrão: `8080`)
* `EMULATOR_RUNTIME_PORT`: Porta host do tráfego de proxies (padrão: `8999`)
* `EMULATOR_KEYS_DIR`: Pasta local montada em `/emulator/keys` (padrão: `./cert`)
* `EMULATOR_SA_KEY`: Nome do arquivo da chave no diretório de chaves (padrão: `service-account.json`)
* `TIMEOUT_SECONDS`: Tempo limite para o healthcheck (padrão: `120`)

---

## 5. Uso em Pipelines de CI/CD

Exemplo de execução em pipelines (Cloud Build, GitHub Actions ou GitLab CI):

```bash
# 1. Inicia o emulador
./ci/apigee-emulator.sh start

# 2. Deploy do proxy e mocks
./ci/apigee-emulator.sh deploy dev

# 3. Execução dos testes automatizados contra o emulador local
export APIGEE_PROTO=http
export APIGEE_HOST=localhost:8999/gcpreleases/v1
npm run integration-test

# 4. Encerra o container
./ci/apigee-emulator.sh stop
```

