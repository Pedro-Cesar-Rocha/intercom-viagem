#!/usr/bin/env bash
# Gera os arquivos de plataforma que faltam (Gradle, projeto Xcode, etc.).
# O `flutter create` não sobrescreve arquivos existentes, então o manifesto,
# o código nativo (Kotlin/Swift), os ícones e o Info.plist do Comboio que
# estão no repositório são mantidos.
set -euo pipefail
cd "$(dirname "$0")/.."
flutter create \
  --org com.pedrocesar \
  --project-name comboio \
  --platforms=android,ios \
  --no-pub \
  .
echo "Plataformas prontas."
