# OpenCode Go no AIBar

Análise realizada em 30/10/2026.

O objetivo é acompanhar a assinatura Go Plus na barra sem abrir o console web.
A integração implementada consulta os três limites compartilhados da assinatura:
5 horas, semanal e mensal. O endpoint encontrado não fornece um histórico por
modelo, saldo de créditos ou identificação do plano Go versus Go Plus.

## Endpoint de leitura

```http
GET https://opencode.ai/zen/go/v1/usage
Authorization: Bearer <api-key>
Accept: application/json
User-Agent: opencode/2.2.1
x-org-id: <workspace-id>
```

O formato conhecido da resposta é:

```json
{
  "usage": {
    "rolling": {
      "status": "ok",
      "percent": 12,
      "resetsAt": "2026-11-01T05:00:00Z"
    },
    "weekly": {
      "status": "ok",
      "percent": 24,
      "resetsAt": "2026-11-02T00:00:00Z"
    },
    "monthly": {
      "status": "rate-limited",
      "percent": 100,
      "resetsAt": "2026-11-30T00:00:00Z"
    }
  }
}
```

Os valores acima são ilustrativos. `percent` é percentual usado, `resetsAt` é
um instante ISO 8601 e `status` distingue uso permitido de limite atingido.

O [código histórico oficial](https://github.com/anomalyco/opencode/blob/d21b0790a6c146815f28fea604e41e922f009590/packages/console/app/src/routes/zen/go/v1/usage.ts)
mostra autenticação por chave e esses três campos de resposta. Naquela versão,
uma chave ausente ou inválida retorna 401 e ausência de assinatura retorna 403.
O código foi substituído por um proxy e depois removido do repositório público,
portanto não deve ser tratado como a implementação atual completa do serviço.

A consulta autenticada foi validada na conta Go Plus deste computador. Retornou
HTTP 200 com os três percentuais e horários de reset. O serviço do AIBar também
salvou um snapshot novo após o Noctalia ser reiniciado. Não foram feitas chamadas
de geração nem renovação de credenciais.

## Credencial e configuração

A versão atual do OpenCode guarda a sessão OAuth em
`~/.local/share/opencode/opencode.db`, tabela `credential`, entrada `opencode`.
A hipótese inicial de que o login sempre criava `auth.json` estava incorreta
para esta instalação. O AIBar consulta o banco com `sqlite3 -readonly`, preferindo
a integração atual e a credencial ativa, com desempate por data e identificador.
Também reconhece a integração `opencode-go` e valores de tipo `key` ou `api`.

O token OAuth vem de `value.access`; o workspace vem de `value.metadata.orgID` e
é enviado no header `x-org-id`. O acesso é limitado ao serviço público oficial:
credenciais de servidores personalizados não são enviadas para ele. O teste
local confirmou que a consulta funciona com o `User-Agent` acima. A primeira
tentativa sem esse header retornou 403.

Referências da implementação atual do OpenCode:
[credenciais](https://github.com/anomalyco/opencode/blob/dev/packages/core/src/credential.ts)
e [headers do Console](https://github.com/anomalyco/opencode/blob/dev/packages/core/src/console-access.ts).

Quando o banco não existe, o AIBar mantém compatibilidade com a entrada
`opencode-go`, tipo `api`, campo `key`, em
`~/.local/share/opencode/auth.json`. Não copia a sessão para esse arquivo.
Uma sessão vencida pede que o usuário abra o OpenCode para renová-la; o AIBar
não usa o refresh token nem substitui a sessão por uma chave antiga.

Na configuração do AIBar, `show_opencode` controla a exibição e
`bar_provider = "opencode"` escolhe essa fonte para a barra. A aba Go aparece
primeiro e Claude em segundo. O banco é consultado no intervalo normal de
atualização ou pelo botão de atualizar, sem reagir a cada gravação de sessão.
Diretórios XDG personalizados e autenticação exclusiva por variável de ambiente
não foram implementados nesta integração.

## Interpretação dos limites

Os três percentuais representam a assinatura compartilhada. Os valores monetários
anunciados por modelo não devem ser apresentados como saldos independentes.
Há uma [confirmação atribuída ao suporte e reproduzida pelo autor da issue](https://github.com/anomalyco/opencode/issues/54875)
de que os modelos pagos consomem uma franquia comum com ponderação por modelo.
O link da issue é a evidência pública disponível; a mensagem do suporte não foi
verificada diretamente por esta análise.

O AIBar mostra o maior dos três percentuais na barra, pois qualquer um pode
bloquear o uso. O painel mostra os três e os respectivos horários de reset.
Não calcula ritmo de consumo para essas janelas: a API não fornece o início
de cada uma, e um mês não tem duração fixa de 30 dias. Também não inventa o
nome Go Plus a partir da chave ou dos percentuais.

## Detalhamento por modelo

Não foi localizado um endpoint público documentado que retorne, com essa mesma
chave, o histórico agregado de consumo do Go por modelo. Isso não prova que o
console não tenha uma rota interna para essa informação. A permissão `Usage: Read`
existe na [documentação de API keys](https://opencode.ai/v2/docs/console/api/),
mas sua existência, sozinha, não define uma URL nem um contrato de consulta.

A [API de inferência](https://opencode.ai/v2/docs/console/api/inference/)
documenta dados por resposta: tokens, `opencode.billing_source`,
`opencode.list_cost` e, para Go, `opencode.allowance`. `cost` pode ser zero
quando a chamada está incluída na assinatura. Portanto, somar somente `cost`
não mede o consumo da franquia.

Um coletor de respostas poderia agrupar o consumo por modelo, mas só observaria
as chamadas que passassem por ele. Não recuperaria automaticamente o histórico,
nem o uso em outros agentes ou computadores. Essa medição é parcial,
distinta dos limites oficiais retornados pelo servidor.

Para uma segunda etapa, é necessário confirmar uma API de histórico do console
com autenticação de leitura e comparar seus resultados com a página Activity.
O AIBar não coleta cookies do navegador, intercepta inferência ou apresenta uma
estimativa local como se fosse o consumo completo da assinatura.

## Segurança e validação

A consulta usa HTTPS e apenas GET. A chave fica em variáveis locais e no header
da requisição. Não vai para argumentos de processos, logs, notificações, estado
compartilhado ou snapshots. O parser rejeita campos ausentes, percentuais
inválidos, status desconhecido e timestamps ilegíveis. Falhas preservam o último
snapshot como desatualizado e seguem o backoff existente.

O ciclo de testes observou a falha da funcionalidade ausente antes da
implementação. A suíte completa passou com 214 testes Luau e 7 testes de shell.
`noctalia plugins lint .` passou sem erros ou avisos. A validação autenticada e o snapshot do plugin em execução confirmaram as três
janelas com 0% usado. A aparência do painel não foi inspecionada por captura de tela.
