# Veyon Fix 4.11.2 - build reproduzível no Windows

Este branch contém a correção do Veyon Fix para manter o hostname como identidade permanente e fazer uma nova resolução IPv4 no Windows antes de cada tentativa VNC, usando `DNS_QUERY_BYPASS_CACHE` e fallback para o hostname original.

As alterações funcionais já fazem parte do próprio branch. Em um clone novo deste branch **não execute `patches/apply_veyon_fix.py`**. O script foi usado em uma etapa anterior do desenvolvimento e não é necessário para a build atual.

## Ambiente suportado

O fluxo reproduzível local foi preparado para **MSYS2 UCRT64 / Windows x64**. Não execute o script pelo terminal MINGW64 ou pelo Git Bash comum; ele valida `MSYSTEM=UCRT64` e aborta se estiver no ambiente errado.

Um conjunto de pacotes equivalente ao ambiente testado pode ser instalado no terminal MSYS2 UCRT64 com:

```bash
pacman -S --needed \
  mingw-w64-ucrt-x86_64-toolchain \
  mingw-w64-ucrt-x86_64-cmake \
  mingw-w64-ucrt-x86_64-ninja \
  mingw-w64-ucrt-x86_64-qt6-base \
  mingw-w64-ucrt-x86_64-qt6-5compat \
  mingw-w64-ucrt-x86_64-qt6-tools \
  mingw-w64-ucrt-x86_64-qt6-httpserver \
  mingw-w64-ucrt-x86_64-qca-qt6 \
  mingw-w64-ucrt-x86_64-openssl \
  mingw-w64-ucrt-x86_64-zlib \
  mingw-w64-ucrt-x86_64-libpng \
  mingw-w64-ucrt-x86_64-libjpeg-turbo \
  mingw-w64-ucrt-x86_64-lzo2 \
  mingw-w64-ucrt-x86_64-openldap \
  mingw-w64-ucrt-x86_64-cyrus-sasl \
  mingw-w64-ucrt-x86_64-nsis \
  mingw-w64-ucrt-x86_64-ntldd \
  git python
```

## Build a partir de um clone novo

No terminal **MSYS2 UCRT64**:

```bash
git clone https://github.com/marcus-piccoli/veyon.git
cd veyon
git checkout veyon-fix/fresh-dns-windows
./scripts/build-veyon-fix-windows.sh
```

O script executa todo o processo:

1. valida se o terminal é UCRT64 e se as alterações do Veyon Fix estão presentes;
2. inicializa todos os submódulos;
3. aplica `patches/libvncserver-mingw-unicode.patch` ao LibVNCServer somente durante a build e restaura o submódulo ao terminar;
4. baixa o Interception e fixa a fonte no commit `39eecbbc46a52e0402f783b872ef62b0254a896a`;
5. compila `interception.dll` e instala temporariamente header/import library/runtime no prefixo `/ucrt64`;
6. cria uma build limpa em `build-veyon-fix/` com Qt 6, LibVNC embutido, testes desativados e traduções da aplicação desativadas;
7. compila o Veyon;
8. monta a árvore redistribuível com executáveis, plugins, drivers e plugins Qt;
9. usa `ntldd -R` para coletar recursivamente apenas as DLLs resolvidas em `/ucrt64/bin`;
10. converte os caminhos de entrada do NSIS para caminhos baseados em `${__FILEDIR__}`, tornando a geração independente do diretório corrente;
11. torna `translations/*.qm` e `styles/*.dll` opcionais nesta build;
12. executa `makensis` e gera o instalador;
13. calcula SHA-256 do instalador.

## Saída

Quando tudo termina corretamente:

```text
artifacts/veyon-4.11.2.0-win64-setup.exe
artifacts/veyon-4.11.2.0-win64-setup.exe.sha256
```

A árvore intermediária do pacote fica em:

```text
build-veyon-fix/veyon-win64-4.11.2.0/
```

Os diretórios `build/`, `build-veyon-fix/`, `.veyon-fix-cache/` e `artifacts/` são artefatos locais e não devem ser versionados.

## Detalhes importantes

### Patch do LibVNCServer

A definição `UNICODE` usada pelo Veyon faz com que `GetComputerName` seja expandido para `GetComputerNameW`, enquanto o buffer legado do LibVNCServer é `char*`. O patch preservado no repositório muda explicitamente essa chamada para `GetComputerNameA`.

O script aplica esse patch de forma idempotente. Se o patch já estiver aplicado, ele não o aplica novamente. Se o submódulo contiver alterações locais não relacionadas, a build é interrompida em vez de sobrescrevê-las.

### Interception

A biblioteca de usuário do Interception não está presente no submódulo `3rdparty/interception` do Veyon. O fluxo clona o projeto original e usa um commit fixo para evitar que uma alteração futura no upstream mude silenciosamente a build.

### Dependências redistribuíveis

O empacotamento não usa os caminhos antigos de `WindowsInstaller.cmake` feitos para a imagem de CI do Veyon. Em vez disso, analisa os binários gerados e copia as dependências reais encontradas no prefixo UCRT64.

Entradas `ext-ms-win-*` vistas pelo `ntldd` são API Sets do Windows e não são copiadas para o pacote.

### LibVNC

A configuração usa:

```text
WITH_BUNDLED_LIBVNC=ON
```

Por isso o pacote não adiciona `libvncclient.dll` ou `libvncserver.dll` externos.

### Traduções

A build reproduzível usa `WITH_TRANSLATIONS=OFF` porque a geração de traduções apresentou incompatibilidade no ambiente nativo UCRT64 usado durante o desenvolvimento. O instalador NSIS continua podendo mostrar os idiomas próprios do instalador, mas os arquivos `.qm` da aplicação não são obrigatórios nesta variante.

## Como confirmar que a correção DNS está presente

No source:

```bash
grep -n "DNS_QUERY_BYPASS_CACHE" core/src/VncConnection.cpp
grep -n -- "-ldnsapi" core/CMakeLists.txt
```

A correção força nova consulta DNS no lado que inicia a conexão. Ela não corrige um registro que permaneça desatualizado no servidor DNS/DHCP nem problemas de roteamento entre VLANs/sub-redes.
