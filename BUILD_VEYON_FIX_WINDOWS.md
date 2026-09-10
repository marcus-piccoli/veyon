# Veyon Fix 4.11.2 - Build local no Windows

Este branch contém a correção de resolução DNS para Windows usada no projeto Veyon Fix.

## Objetivo

Manter o hostname como identidade permanente e obter um IPv4 temporário e atualizado antes de cada tentativa VNC no Windows, usando `DNS_QUERY_BYPASS_CACHE` e fallback para o hostname original.

## Opção recomendada: build com MSYS2/MinGW-w64

O Veyon 4.11.2 usa Qt 6 e CMake. Para reproduzir o ambiente do projeto com o mínimo de diferenças, prefira uma toolchain MinGW-w64 x86_64 com Qt 6, Ninja, CMake e NSIS.

### 1. Instalar ferramentas

Instale:

- Git for Windows
- CMake
- Ninja
- Python 3
- NSIS
- MSYS2
- Qt 6 para MinGW 64-bit, incluindo Qt Network, Widgets, Concurrent e LinguistTools

No MSYS2, instale a toolchain MinGW-w64 x86_64 e dependências de desenvolvimento exigidas pelo Veyon conforme os erros reportados pelo CMake.

### 2. Obter o source completo

Se estiver usando o ZIP gerado pelo workflow `Veyon Fix Source Bundle`, extraia-o para um caminho curto, por exemplo:

`C:\dev\veyon-fix`

Se estiver usando Git:

```bash
git clone --recurse-submodules https://github.com/marcus-piccoli/veyon.git
cd veyon
git checkout veyon-fix/fresh-dns-windows
git submodule update --init --recursive
python patches/apply_veyon_fix.py
```

O ZIP gerado pelo workflow já vem com a transformação aplicada, portanto não execute novamente `apply_veyon_fix.py` nele.

### 3. Configurar build

Abra um terminal onde `qt-cmake`, `cmake`, `ninja` e o compilador MinGW estejam no PATH.

```bash
mkdir build
cd build
qt-cmake .. -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo
```

Se o CMake apontar uma dependência ausente, instale o pacote correspondente e execute o comando novamente.

### 4. Compilar

```bash
ninja
```

Para os alvos de empacotamento Windows fornecidos pelo Veyon, consulte os alvos disponíveis:

```bash
ninja -t targets | findstr /I "windows package installer nsis"
```

O script oficial usado pelo projeto para cross-build é `.ci/windows/build.sh`; ele chama o alvo `windows-binaries` por padrão.

### 5. Gerar binários/instalador

Tente primeiro:

```bash
ninja windows-binaries
```

Caso o projeto exponha um alvo NSIS separado na sua configuração, execute também esse alvo conforme listado por `ninja -t targets`.

Os artefatos Windows do pipeline oficial usam nomes `veyon-*win*`.

## Como confirmar que a correção está presente

No source modificado, `core/src/VncConnection.cpp` deve conter mensagens de log com:

`Veyon Fix fresh DNS:`

E `core/CMakeLists.txt` deve vincular `dnsapi` no Windows.

## Observação importante

A correção força nova consulta ao DNS local sem reutilizar o cache do resolvedor Windows. Ela não consegue corrigir um registro que já esteja desatualizado no servidor DNS autoritativo/DHCP. Os logs foram adicionados justamente para distinguir esses dois casos.
