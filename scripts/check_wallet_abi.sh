#!/bin/bash
# Verify the wallet2 static library exports every symbol MoneroKit's
# critical wallet-creation paths call into.
#
# Why this exists: the May 2026 library rebuild silently dropped the fork
# statics (Monero::Wallet::generateAddress/generateKey/bytesToWords). The
# resulting undefined symbols were "fixed" with stubs returning "" instead
# of failing the build — which broke every BIP39 wallet creation and burned
# user funds at the null-key address. A dropped symbol must fail CI, never
# link quietly.
#
# Run from anywhere; checks both slices of Monero.xcframework.

set -euo pipefail

cd "$(dirname "$0")/.."

# Mangled-name fragments of symbols that must be DEFINED (nm type T) in the
# library. These back the seed-type creation paths:
#   bip39   -> createDeterministicWalletFromSpendKey
#   legacy  -> recoveryWallet + ElectrumWords decode
#   polyseed-> createPolyseed + createWalletFromPolyseed
REQUIRED_SYMBOLS=(
    "WalletManagerImpl37createDeterministicWalletFromSpendKey"
    "WalletImpl38recoverDeterministicWalletFromSpendKey"
    "WalletManagerImpl14recoveryWallet"
    "WalletManagerImpl24createWalletFromPolyseed"
    "N6Monero6Wallet14createPolyseed"
    "ElectrumWords14words_to_bytes"
    "ElectrumWords14bytes_to_words"
)

SLICES=(
    "Monero.xcframework/ios-arm64/libMoneroCombined.a"
    "Monero.xcframework/ios-arm64-simulator/libMoneroCombined.a"
)

failures=0
for slice in "${SLICES[@]}"; do
    if [[ ! -f "$slice" ]]; then
        echo "MISSING SLICE: $slice"
        failures=$((failures + 1))
        continue
    fi
    symbols=$(nm "$slice" 2>/dev/null | grep " T " || true)
    for sym in "${REQUIRED_SYMBOLS[@]}"; do
        if ! grep -q "$sym" <<< "$symbols"; then
            echo "MISSING SYMBOL in $slice: $sym"
            failures=$((failures + 1))
        fi
    done
done

if [[ $failures -gt 0 ]]; then
    echo "ABI check FAILED: $failures problem(s). The wallet library no longer"
    echo "exports symbols the wallet-creation paths depend on. Do not stub"
    echo "them — restore the implementation or fix the library build."
    exit 1
fi

echo "ABI check passed: all required wallet2 symbols present in both slices."
