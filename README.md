# Comboio — intercom de viagem

App em Flutter (Android e iOS) que transforma os celulares em um intercom:
um celular liga o **hotspot** e cria a sala, os outros entram no Wi-Fi dele e o
áudio começa sozinho. Até **4 pessoas**, sem internet, com a tela apagada.

## Instalar

As builds saem automaticamente na página **Releases** deste repositório
(release `latest`) a cada push na `main`. A pré-release "Logs de compilação"
guarda só a saída dos builds, para diagnóstico.

### Android
1. Baixe `Comboio.apk` no celular.
2. Abra o arquivo e permita "instalar apps desconhecidos" para o navegador/arquivos.
3. Atualizações instalam por cima (a assinatura é sempre a mesma).

### iPhone (sem conta paga)
O `Comboio-unsigned.ipa` não é assinado; a assinatura é feita com o **seu Apple
ID** na hora de instalar:

1. Instale o [Sideloadly](https://sideloadly.io) (Windows ou Mac) e o iTunes
   (versão do site da Apple, no Windows).
2. Ligue o iPhone no computador pelo cabo e confie no computador.
3. Arraste o `.ipa` para o Sideloadly, informe seu Apple ID e clique em Start.
4. No iPhone: Ajustes › Geral › VPN e Gerenciamento de Dispositivos › confie no
   seu Apple ID. Em iOS 16+, ative também Ajustes › Privacidade › Modo de
   Desenvolvedor.

Com Apple ID gratuito o app vale por **7 dias** (é só reinstalar). Com a conta
paga de desenvolvedor vale 1 ano. Alternativa: AltStore.

## Usar
1. **Host:** liga o Hotspot / Roteador Wi-Fi, abre o Comboio e toca em
   **Criar sala**.
2. **Os outros:** conectam no Wi-Fi do hotspot (mesmo que apareça "sem
   internet") e tocam em **Entrar na sala**. A sala é encontrada sozinha.
3. Fale. Dá para silenciar, alternar viva-voz/fone e ajustar o volume de cada
   pessoa tocando no cartão dela.

Dicas: fones (com fio ou Bluetooth) deixam o som mais limpo. No iPhone, permita
"Rede Local" quando o app pedir. Se a sala não aparecer, dá para digitar o
endereço mostrado na tela do host.

## Como funciona por dentro
- **Áudio:** WebRTC (Opus) via `flutter_webrtc`, com cancelamento de eco,
  redução de ruído e controle de ganho. Malha completa: cada pessoa tem uma
  conexão com cada uma das outras (no máximo 3).
- **Sala (no host):** servidor de sinalização WebSocket (porta TCP 47800) que
  controla quem entra (até 4), repassa as ofertas/respostas SDP e segura por 20 s
  o lugar de quem cai, para voltar sem derrubar ninguém.
- **Túnel de mídia:** o celular que faz o hotspot não é tratado como "Wi-Fi"
  pelo WebRTC (a interface do hotspot é filtrada). Por isso todo o WebRTC só
  conversa por loopback com um túnel UDP em Dart, e o túnel leva os pacotes até
  o hub do host (porta UDP 47801), que repassa ao destino. Quedas curtas do
  Wi-Fi não derrubam as chamadas.
- **Descoberta:** cada convidado manda um pacote UDP para o gateway e para os
  endereços da sub-rede; o hub responde com o nome da sala.
- **Segundo plano:** no Android, serviço em primeiro plano (microfone) com
  travas de CPU e Wi-Fi e ações na notificação (silenciar/sair). No iOS, modo de
  áudio em segundo plano.

Estrutura:

```
lib/
  core/   protocolo binário, preferências, ponte nativa
  net/    servidor da sala, hub UDP, túnel, descoberta, cliente WebSocket
  call/   WebRTC (áudio e conexões) e o controlador da sala
  ui/     telas e componentes
android/app/src/main/kotlin/…  serviço em 1º plano, rede, permissões
ios/Runner/AppDelegate.swift   permissão do microfone e tela ligada
test/   testes da parte de rede (rodam no CI)
```

## Compilar no seu computador
Requer Flutter estável (3.38+).

```bash
bash tool/setup_platforms.sh   # gera Gradle/Xcode que faltam, sem sobrescrever nada
flutter pub get
flutter test                   # testes de rede
flutter build apk --release    # Android
flutter build ios --release    # iOS (no Mac, com Xcode)
```

No Windows, rode o `setup_platforms.sh` pelo Git Bash, ou o mesmo comando
direto: `flutter create --org com.pedrocesar --project-name comboio --platforms=android,ios --no-pub .`
