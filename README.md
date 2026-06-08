# FCIToken — Tokenización de FCI Cerrados bajo ERC-3643

> **Trabajo de Tesis** · Solidity `^0.8.19` · ERC-3643 (T-REX) · Foundry · Versión 2.0.0  
> Maestría en Tecnología de la Información · Universidad de Palermo · 2026

---

## Descripción

Este repositorio contiene el contrato inteligente central del MVP desarrollado en la tesis *"Modelo Técnico para la Tokenización de FCI Cerrados en Argentina: Integración de Estándares Blockchain bajo la RG 1069/2025"*.

El contrato implementa el estándar **ERC-3643 (T-REX)** para la representación digital de cuotas-partes de Fondos Comunes de Inversión Cerrados, en el marco del Sandbox regulatorio habilitado por la RG 1069/2025 de la CNV y su complemento RG 1081/2025.

En la narrativa de la tesis (Capítulos 5 y 6) el contrato se denomina **FimaToken** — ese es el nombre de negocio del activo tokenizado. En el código, el identificador técnico es `FCIToken_Tesis`.

---

## Funcionalidades verificadas en el MVP

El MVP valida la correctitud lógica del núcleo del contrato en entorno de simulación EVM (Remix VM). Se verificaron completamente tres requisitos funcionales:

| Función | Descripción | RF |
|---|---|---|
| `mint()` | Emisión de cuotas-partes exclusivamente a inversores KYC-verificados. Solo ejecutable por el rol autorizado. | RF-01 |
| `transfer()` / `transferFrom()` | Transferencia P2P con verificación automática de identidad embebida. El IdentityRegistry rechaza cualquier transferencia a billeteras no autorizadas. | RF-01 |
| `freezePartialTokens()` | Bloqueo de tokens como garantía de préstamos (colateralización programable). Los tokens bloqueados no pueden transferirse mientras la garantía está activa. | RF-04 |

> El ciclo de vida completo del activo (emisión y transferencia) fue verificado. El rescate/quema de tokens corresponde a una etapa productiva posterior y no fue validado en el MVP.

---

## Funcionalidades adicionales del contrato v2.0.0

El contrato incluye las siguientes funciones incorporadas en la revisión de seguridad v2.0.0, que pertenecen al diseño de producción y no fueron parte de la validación del MVP:

- `burn()` — Rescate/quema de cuotas-partes
- `recoveryAddress()` — Recuperación de billetera con validación de identidad on-chain
- `forcedTransfer()` — Transferencia forzada por mandato judicial (RF-03). Requiere Multisig en producción
- `pause()` / `unpause()` — Pausa de emergencia del contrato
- `approve()` / `allowance()` — Mecanismo estándar ERC-20 de delegación
- `transferOwnership()` / `acceptOwnership()` — Transferencia de propiedad en dos pasos (Ownable2Step)

---

## Revisión de seguridad — resumen

El contrato original (v1.0.0) fue sometido a una revisión completa de seguridad. Se identificaron y corregieron 15 hallazgos en v2.0.0:

| Severidad | Cantidad | Ejemplos |
|---|---|---|
| Crítico | 2 | Corrupción de saldo congelado en `burn` y `recoveryAddress` |
| Alto | 4 | Verificación de destinatario congelado, validación de identidad en recovery, zero-address guards, allowance ERC-20 |
| Medio | 3 | Eventos de módulos críticos, auto-descongelamiento de colateral, eventos de metadata |
| Bajo | 3 | Ownable2Step, semántica de `balanceOf`, `bindToken` en constructor |
| Gas | 4 | Custom errors, storage packing, caché de storage, optimización de zero-checks |

---

## Contexto técnico

- **Red de referencia:** Polygon PoS (arquitectura de referencia para producción)
- **Entorno de validación:** Remix VM / EVM local (simulación controlada sin costos de gas reales)
- **Estándar de token:** ERC-3643 con módulos `IIdentityRegistry` e `ICompliance`
- **Gestión de identidad:** Compatible con W3C DID / ONCHAINID
- **Decimales:** Configurables en el constructor (6 para este FCI)
- **Roles de producción:** `AGENT_ROLE` (PSAV — gestión de whitelist), `MINTER_ROLE` (Core Banking — emisión)
- **Gobernanza de producción:** Multisig 2-de-3 (Sociedad Gerente + PSAV + Auditor Externo)

---

## Estructura del proyecto

```
fci_erc3643/
├── src/
│   └── FCIToken_Tesis_ERC3643.sol   ← contrato principal v2.0.0
├── test/
│   ├── FCIToken.t.sol                ← 106 tests (unitarios + fuzz)
│   └── mocks/
│       ├── MockCompliance.sol        ← ICompliance configurable para testing
│       └── MockIdentityRegistry.sol  ← IIdentityRegistry con mockRegister()
├── lib/forge-std/                    ← biblioteca de tests Foundry
├── foundry.toml
└── README.md
```

---

## Cómo ejecutar los tests

**Requisitos:** [Foundry](https://getfoundry.sh/) instalado.

```bash
# Correr todos los tests
forge test

# Con detalle por test
forge test -v

# Con trazas completas (útil para debug)
forge test -vvvv
```

**Resultado esperado:**
```
Suite result: ok. 106 passed; 0 failed; 0 skipped
```

Los tests cubren: constructor, mint, burn, transfer, allowance, freeze parcial y total, recovery, pause, ownership, módulos, setters, semántica de balances, fuzz tests y `forcedTransfer` (RF-03, incorporado en v2.0.0).

---

*Fornari Augusto · Director: Claudio Zamosczyk · Universidad de Palermo · 2026*
