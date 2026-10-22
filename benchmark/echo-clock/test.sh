#!/bin/sh
set -eu
cd "$(dirname "$0")"
./build.sh
case "$(uname -m)" in
    arm64) target=arm64mac ;;
    x86_64) target=x64mac ;;
esac
mimalloc=.build/mimalloc-8c532c32c3c96e5ba1f2283e032f69ead8add00f
"${CC:-cc}" -std=c11 -O1 -g -DMI_STATIC_LIB -Wall -Wextra -Werror \
    -fsanitize=undefined -I"$mimalloc/include" host-test.c "targets/$target/mimalloc.o" \
    -o .build/host-test
.build/host-test > .build/actual.txt
printf 'a\000b\nabcdefghijklmnopqrstuvwxyz\nabcdefghijklmnopqrstuvwxyz\ncdefghijklmnopqrstuvwxyz\n' > .build/expected.txt
cmp .build/expected.txt .build/actual.txt
for backend in dev speed; do
    "${ROC:-roc}" build --no-cache --opt="$backend" example.roc --output=".build/example-$backend"
    ".build/example-$backend"
done
