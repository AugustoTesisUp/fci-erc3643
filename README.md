# FCIToken — Tokenización de Fondos Comunes de Inversión bajo ERC-3643

> **Trabajo de Tesis** · Solidity `^0.8.19` · ERC-3643 (T-REX) · Foundry · Versión 2.0.0

---

## Índice

1. [Contexto](#1-contexto)
2. [Estándar ERC-3643 (T-REX)](#2-estándar-erc-3643-t-rex)
3. [Arquitectura del contrato](#3-arquitectura-del-contrato)
4. [Variables de estado y storage layout](#4-variables-de-estado-y-storage-layout)
5. [Interfaces y módulos externos](#5-interfaces-y-módulos-externos)
6. [Flujos principales](#6-flujos-principales)
7. [Revisión de seguridad — hallazgos y correcciones](#7-revisión-de-seguridad--hallazgos-y-correcciones)
8. [Decisiones de diseño clave](#8-decisiones-de-diseño-clave)
9. [Optimizaciones de gas](#9-optimizaciones-de-gas)
10. [Proyecto Foundry — estructura y tests](#10-proyecto-foundry--estructura-y-tests)
11. [Cómo ejecutar los tests](#11-cómo-ejecutar-los-tests)
12. [Consideraciones para producción](#12-consideraciones-para-producción)
13. [Archivos del proyecto](#13-archivos-del-proyecto)

---

## 1. Contexto

Los Fondos Comunes de Inversión (FCI) son vehículos de inversión colectiva regulados en Argentina por la Comisión Nacional de Valores (CNV). Un FCI Cerrado limita las suscripciones a una ventana inicial y no permite rescates hasta su vencimiento, lo que genera un problema estructural de iliquidez para el inversor que necesita liquidez antes del plazo.

Este proyecto implementa el contrato inteligente central de una arquitectura de tokenización para FCI Cerrados en el contexto del Sandbox regulatorio habilitado por la Resolución General 1069/2025 de la CNV — y su complemento RG 1081/2025 — que habilita la representación digital de valores negociables sobre infraestructura blockchain, exigiendo identificación plena del inversor y la figura de un Proveedor de Servicios de Activos Virtuales (PSAV) registrado como custodio.

El contrato fue diseñado como componente central del MVP validado en la tesis, desplegado en entorno de simulación EVM (Remix VM) sobre una arquitectura de referencia basada en Polygon PoS. En la narrativa de la tesis (Capítulos 5 y 6) el contrato se denomina **FimaToken** — ese es el nombre de negocio del activo tokenizado. En el código, el identificador técnico del contrato es `FCIToken_Tesis`. La tokenización permite:

- **Transferibilidad controlada** entre inversores verificados en un mercado secundario OTC, resolviendo el problema de iliquidez de los FCI Cerrados.
- **Compliance embebido**: las reglas de KYC/AML se codifican on-chain como pre-condición de cada transferencia, eliminando el control ex-post típico de la banca tradicional.
- **Colateralización programable**: las cuotas-partes tokenizadas pueden pigñorarse como garantía de préstamos mediante `freezePartialTokens()`, con bloqueo automático e irrevocable sin intervención humana.
- **Trazabilidad inmutable** de todas las operaciones, accesible para el regulador en tiempo real.

El contrato implementa el estándar **ERC-3643** (también conocido como T-REX: Token for Regulated EXchanges), seleccionado por ser el único estándar que satisface simultáneamente identidad obligatoria del destinatario, compatibilidad KYC/AML nativa y cumplimiento de la RG 1069/2025.

---

## 2. Estándar ERC-3643 (T-REX)

ERC-3643 extiende ERC-20 con una capa de identidad y compliance que actúa como gate en cada movimiento de tokens:

```
                    ┌──────────────────────────────────┐
                    │        FCIToken (ERC-3643)       │
                    │  - Mint / Burn                   │
                    │  - Transfer / TransferFrom        │
                    │  - Freeze parcial y total         │
                    │  - Pause / Recovery              │
                    │  - ForcedTransfer (RF-03)        │
                    └────────────┬──────────┬──────────┘
                                 │          │
              ┌──────────────────▼──┐  ┌────▼─────────────────┐
              │  IIdentityRegistry  │  │     ICompliance       │
              │  ─────────────────  │  │  ──────────────────── │
              │  KYC / Whitelist    │  │  Reglas del Fondo     │
              │  Identity on-chain  │  │  Límites de posición  │
              │  País del inversor  │  │  Lock-up periods      │
              └─────────────────────┘  └───────────────────────┘
```

### Principio fundamental

> **Ninguna transferencia puede ejecutarse si el destinatario no está verificado en el KYC o si el módulo de compliance la rechaza.**

Esto hace que el token sea **no composable con DeFi abierto por diseño**: un pool de Uniswap o Aave no es una dirección KYC-verificada, por lo que cualquier intento de integración es rechazado en `canTransfer` antes de ejecutar la transferencia. La composabilidad existe únicamente dentro del ecosistema regulado (mercado secundario entre inversores verificados, préstamos colateralizados con contratos del propio sistema).

---

## 3. Arquitectura del contrato

```
src/FCIToken_Tesis_ERC3643.sol
│
├── interface IIdentity                  (placeholder T-REX)
├── interface IIdentityRegistryStorage   (placeholder T-REX)
├── interface ITrustedIssuersRegistry    (placeholder T-REX)
├── interface IClaimTopicsRegistry       (placeholder T-REX)
│
├── interface IIdentityRegistry
│     contains(), isVerified(), identity(), investorCountry()
│     registerIdentity(), deleteIdentity(), updateIdentity()
│
├── interface ICompliance
│     bindToken(), canTransfer()
│     transferred(), created(), destroyed()
│
├── interface IERC3643
│     Todos los eventos y funciones del estándar
│
└── contract FCIToken_Tesis is IERC3643
      Implementación completa
```

### Separación de responsabilidades

| Componente | Responsabilidad |
|---|---|
| `FCIToken_Tesis` | Contabilidad on-chain: balances, transferencias, eventos, control de acceso |
| `IIdentityRegistry` | KYC: quién está verificado, qué identidad on-chain tiene, de qué país es |
| `ICompliance` | Reglas de negocio: ¿puede esta transferencia ocurrir? (límites, lock-ups, jurisdicción) |

El contrato delega toda la lógica de elegibilidad a los módulos externos. Si se necesita agregar una nueva regla (p. ej. máximo 500 inversores o lock-up de 12 meses), se despliega un nuevo `ICompliance` y se apunta al token con `setCompliance`, sin modificar el contrato del token.

---

## 4. Variables de estado y storage layout

El contrato aplica **storage packing** para minimizar el número de slots EVM utilizados, reduciendo el costo de `SLOAD` y `SSTORE`:

```
Slot 0  [ onchainID 20b ][ decimals 1b ][ _paused 1b ][ padding 10b ]
Slot 1  [ owner 20b ][ padding 12b ]
Slot 2  [ pendingOwner 20b ][ padding 12b ]
Slot 3  [ totalSupply 32b ]
Slot 4  [ name — string dinámica ]
Slot 5  [ symbol — string dinámica ]
Slot 6  [ version — string dinámica ]
```

`onchainID`, `decimals` y `_paused` comparten el Slot 0 (22 de 32 bytes), ahorrando dos slots respecto al layout original sin empaquetar.

> **Nota sobre `decimals`:** El valor de `decimals` es configurable al momento del despliegue mediante el tercer parámetro del constructor (`uint8 _decimals`). No tiene un valor fijo en el código — se asigna en el constructor, lo que permite reutilizar el contrato para distintos tipos de fondos sin modificarlo. Para este FCI se utiliza `6`, valor que ofrece suficiente granularidad para expresar el NAV con precisión operativa (p. ej. $1.234,567891 por cuota) sin incurrir en los 18 decimales típicos de tokens de liquidez.

### Mappings

```solidity
mapping(address => uint256) private _balances;         // saldo total por inversor
mapping(address => uint256) private _frozenBalances;   // tokens congelados (colateral LTV)
mapping(address => bool)    private _frozenAddresses;  // freeze total de dirección
mapping(address => mapping(address => uint256)) private _allowances; // ERC-20 allowances
```

---

## 5. Interfaces y módulos externos

### IIdentityRegistry — funciones usadas por el contrato

| Función | Dónde se usa |
|---|---|
| `identity(address)` | `recoveryAddress` — valida que `_investorOnchainID` coincide con la identidad de la billetera perdida |
| `contains(address)` | `recoveryAddress` — verifica que la nueva billetera está registrada en el KYC |

### ICompliance — funciones usadas por el contrato

| Función | Cuándo se llama |
|---|---|
| `bindToken(address)` | Constructor — registra el token en el módulo |
| `canTransfer(from, to, amount)` | `transfer`, `transferFrom`, `mint` — gate de elegibilidad (NO llamado en `forcedTransfer`) |
| `transferred(from, to, amount)` | Post-`transfer`, post-`transferFrom`, post-`forcedTransfer`, post-`recoveryAddress` — actualiza estado interno del módulo |
| `created(to, amount)` | Post-`mint` |
| `destroyed(from, amount)` | Post-`burn` |

---

## 6. Flujos principales

### Transferencia entre inversores

```
Alice.transfer(bob, 1000)
  │
  ├── ¿Alice está congelada (dirección)?   → revert AddressFrozenError(alice)
  ├── ¿Bob está congelado (dirección)?     → revert AddressFrozenError(bob)
  ├── ¿Alice.available >= 1000?            → revert InsufficientAvailableBalance
  ├── compliance.canTransfer(alice, bob, 1000)
  │     └── ¿Bob tiene KYC? ¿Límites OK?  → revert "Falla en Compliance o KYC"
  │
  ├── _balances[alice] -= 1000
  ├── _balances[bob]   += 1000
  ├── compliance.transferred(alice, bob, 1000)
  └── emit Transfer(alice, bob, 1000)
```

### Congelamiento para colateral LTV

```
Owner.freezePartialTokens(alice, 5000)
  │
  ├── ¿availableBalanceOf(alice) >= 5000?  → revert InsufficientAvailableBalance
  ├── _frozenBalances[alice] += 5000
  └── emit TokensFrozen(alice, 5000)

  Estado resultante:
    balanceOf(alice)          = 10.000  ← total, ERC-20 estándar, incluye congelados
    availableBalanceOf(alice) =  5.000  ← transferible
    getFrozenTokens(alice)    =  5.000  ← colateral
```

### Transferencia forzada por mandato judicial (RF-03)

```
Owner.forcedTransfer(deudor, acreedor, 500)
  │
  │  ← NO verifica freeze de dirección (la orden judicial lo supera)
  │  ← NO llama canTransfer() (la orden judicial supera las reglas del fondo)
  │
  ├── ¿deudor.availableBalance >= 500?   → revert InsufficientAvailableBalance
  │      (tokens pignorados como colateral LTV no son alcanzables —
  │       una orden de descongelamiento separada debe preceder)
  │
  ├── _balances[deudor]   -= 500
  ├── _balances[acreedor] += 500
  ├── compliance.transferred(deudor, acreedor, 500)   ← notifica al módulo
  ├── emit ForcedTransfer(deudor, acreedor, 500)      ← trail de auditoría judicial
  └── emit Transfer(deudor, acreedor, 500)            ← compatibilidad ERC-20
```

**Diferencia clave con `recoveryAddress`:**

| | `forcedTransfer` | `recoveryAddress` |
|---|---|---|
| Propósito | Ejecución judicial parcial | Migración de billetera perdida |
| Cuánto mueve | Monto específico | Saldo total |
| Prueba de identidad | No requerida | Sí — valida `_investorOnchainID` |
| Tokens congelados | No los toca | Los migra al nuevo wallet |

---

### Recuperación de billetera

```
Owner.recoveryAddress(lostWallet, newWallet, investorOnchainID)
  │
  ├── identity(lostWallet) == investorOnchainID?  → revert IdentityMismatch
  ├── idRegistry.contains(newWallet)?             → revert WalletNotRegistered
  ├── _balances[lostWallet] > 0?                  → revert NoBalanceToRecover
  │
  ├── frozen = _frozenBalances[lostWallet]
  ├── _balances[lostWallet]       = 0
  ├── _frozenBalances[lostWallet] = 0              ← limpia estado huérfano
  ├── _balances[newWallet]       += total
  ├── _frozenBalances[newWallet] += frozen         ← migra restricciones de colateral
  └── compliance.transferred(lostWallet, newWallet, total)
```

---

## 7. Revisión de seguridad — hallazgos y correcciones

El contrato original (v1.0.0) fue sometido a una revisión completa de seguridad y performance. Se identificaron **15 hallazgos** entre críticos y optimizaciones de gas. Todos fueron corregidos en v2.0.0.

### Críticos

#### [CRITICAL-1] Balance congelado huérfano tras `burn` y `recoveryAddress`

**Problema en `burn`:** La función verificaba `_balances[user] >= amount` sin considerar `_frozenBalances[user]`. Ejemplo: usuario con 10.000 tokens y 5.000 congelados; owner llama `burn(user, 8.000)`. Resultado: `_balances = 2.000`, `_frozenBalances = 5.000`. Cualquier llamada posterior a `availableBalanceOf` computaba `2.000 - 5.000` y **revertía con underflow aritmético**, bloqueando permanentemente la cuenta.

**Problema en `recoveryAddress`:** La función movía `_balances[lostWallet]` a `newWallet` pero nunca limpiaba `_frozenBalances[lostWallet]`. El saldo congelado quedaba apuntando a una dirección con balance cero (estado huérfano), y la nueva billetera recibía todos los tokens sin las restricciones de freeze.

```solidity
// CORRECCIÓN en burn — solo quema saldo disponible
uint256 totalBal  = _balances[_userAddress];
uint256 frozenBal = _frozenBalances[_userAddress];
if (totalBal - frozenBal < _amount) revert InsufficientAvailableBalance();

// CORRECCIÓN en recoveryAddress — migra y limpia _frozenBalances
uint256 frozenToMigrate      = _frozenBalances[_lostWallet];
_balances[_lostWallet]       = 0;
_frozenBalances[_lostWallet] = 0;                    // elimina el huérfano
_balances[_newWallet]       += amountToRecover;
_frozenBalances[_newWallet] += frozenToMigrate;      // migra restricciones
```

---

### Altos

#### [HIGH-2] Destinatario congelado podía recibir tokens en `transfer`

`transfer` verificaba que `msg.sender` no estuviera congelado pero no verificaba `_to`. Se agregó:

```solidity
if (_frozenAddresses[_to]) revert AddressFrozenError(_to);
```

#### [HIGH-3] `_investorOnchainID` ignorado en `recoveryAddress`

Sin validar el parámetro de identidad, el owner podía mover cualquier balance a cualquier dirección sin prueba criptográfica de propiedad del inversor. Se agregó:

```solidity
if (address(_identityRegistry.identity(_lostWallet)) != _investorOnchainID)
    revert IdentityMismatch();
if (!_identityRegistry.contains(_newWallet)) revert WalletNotRegistered();
```

#### [HIGH-4] Sin validación de `address(0)` en setters críticos

Constructor y setters de módulos aceptaban `address(0)`, lo que bloqueaba todas las operaciones del token si se configuraba un módulo nulo. Se agregaron guards `if (addr == address(0)) revert ZeroAddress()` en todos los setters críticos.

#### [HIGH-5] Sin mecanismo ERC-20 de allowance (`approve` / `transferFrom`)

ERC-3643 extiende ERC-20. Se agregaron `approve`, `allowance` y `transferFrom` con las mismas verificaciones de freeze y compliance que `transfer`.

---

### Medios y bajos

| ID | Problema | Corrección |
|---|---|---|
| MEDIUM-1 | `UpdatedTokenInformation` nunca emitido | `setName`, `setSymbol`, `setOnchainID` ahora emiten el evento |
| MEDIUM-2 | Sin eventos al cambiar módulos críticos | Agregados `IdentityRegistrySet` y `ComplianceSet` |
| MEDIUM-3 | Inversores podían auto-descongelar su colateral | `freeze` y `unfreeze` restringidos a `onlyOwner` |
| LOW-1 | Sin mecanismo de transferencia de propiedad | Implementado Ownable2Step (`transferOwnership` + `acceptOwnership`) |
| LOW-2 | `balanceOf` retornaba saldo disponible, violando ERC-20 | `balanceOf` = total, `availableBalanceOf` = disponible |
| LOW-3 | `bindToken` no llamado en el constructor | `_complianceModule.bindToken(address(this))` agregado al constructor |

---

## 8. Decisiones de diseño clave

### Por qué `balanceOf` retorna el saldo total (incluyendo tokens congelados)

Esta es la pregunta más frecuente al leer el contrato. El resumen:

**1. Invariante contable ERC-20:** `Σ balanceOf(holders) == totalSupply` debe cumplirse. Si `balanceOf` devolviera el saldo disponible, el delta de tokens congelados quedaría "perdido", rompiendo cualquier herramienta de auditoría o prueba de reservas.

**2. Propiedad ≠ transferibilidad:** Cuando un inversor pignora cuotas como colateral de un préstamo, sigue siendo el propietario legal de esos tokens — cobra dividendos sobre ellos, tributa, son parte de su patrimonio declarado. Lo que pierde temporalmente es la *capacidad de disposición*. `balanceOf` reporta tenencia; `availableBalanceOf` reporta disponibilidad.

**3. Compatibilidad con el ecosistema:** Etherscan, MetaMask, Bloomberg Terminal y herramientas de tax reporting asumen semántica ERC-20 estándar. Una semántica no estándar muestra números incorrectos en cada herramienta existente.

**4. Convención de EIP-3643:** La implementación de referencia de Tokeny (T-REX) define `balanceOf` como saldo total.

**La protección real está en `transfer` y `transferFrom`**, no en `balanceOf`:

```solidity
uint256 senderBalance = _balances[msg.sender];
uint256 senderFrozen  = _frozenBalances[msg.sender];
if (senderBalance - senderFrozen < _amount) revert InsufficientAvailableBalance();
```

**API de balance:**

| Función | Retorna | Para qué |
|---|---|---|
| `balanceOf(address)` | Saldo total | Contabilidad, exploradores, reconciliación regulatoria |
| `availableBalanceOf(address)` | Saldo no congelado | Pre-validación en apps, UI del sistema |
| `getFrozenTokens(address)` | Saldo congelado | Gestión de colateral, reportes de garantías |

### Transferencia de propiedad en dos pasos (Ownable2Step)

La transferencia directa de ownership presenta el riesgo de transferir a una dirección incorrecta o inaccesible, perdiendo el control permanentemente. El patrón Ownable2Step requiere que el destinatario confirme activamente la transferencia:

```
owner → transferOwnership(newOwner)  →  pendingOwner = newOwner
                                                  ↓
                              newOwner → acceptOwnership()  →  owner = newOwner
```

Si `newOwner` es incorrecto, el owner actual puede llamar `transferOwnership` con otra dirección. El control nunca se pierde hasta que la transferencia sea aceptada.

---

## 9. Optimizaciones de gas

### Custom errors

Todos los `require(condition, "string")` fueron reemplazados por custom errors. Ahorro: 50–200 gas por revert al eliminar el costo de hashear y encodear strings en tiempo de ejecución.

```solidity
// v1.0.0
require(msg.sender == owner, "Solo administrador autorizado");

// v2.0.0
error Unauthorized();
if (msg.sender != owner) revert Unauthorized();
```

Errors definidos: `Unauthorized`, `ZeroAddress`, `ContractPaused`, `AddressFrozenError(address)`, `InsufficientAvailableBalance`, `InsufficientFrozenBalance`, `InsufficientAllowance`, `NoBalanceToRecover`, `IdentityMismatch`, `WalletNotRegistered`.

### Storage packing

Variables de menos de 32 bytes declaradas consecutivamente se empaquetan en un mismo slot, reduciendo los `SLOAD` fríos (2.100 gas cada uno):

| Variable | Tipo | Slot (v1) | Slot (v2) |
|---|---|---|---|
| `onchainID` | address (20b) | 6 | 0 — empaquetado |
| `decimals` | uint8 (1b) | 2 | 0 — empaquetado |
| `_paused` | bool (1b) | 4 | 0 — empaquetado |

Ahorro: 2 slots de storage (64 bytes) y hasta 4.200 gas en lecturas frías.

### Caché de storage en caminos calientes

En `transfer` y `transferFrom`, `_balances` y `_frozenBalances` del remitente se leen una sola vez y se guardan en variables locales:

```solidity
uint256 senderBalance = _balances[msg.sender];   // 1 SLOAD = 2.100 gas
uint256 senderFrozen  = _frozenBalances[msg.sender]; // 1 SLOAD = 2.100 gas
if (senderBalance - senderFrozen < _amount) revert InsufficientAvailableBalance();
_balances[msg.sender] = senderBalance - _amount;  // usa valor cacheado, no re-lee
```

### `!= 0` en lugar de `> 0`

Para verificaciones de cero en `uint256`, `!= 0` compila a una instrucción EVM ligeramente más barata.

---

## 10. Proyecto Foundry — estructura y tests

### Estructura de archivos

```
fci_erc3643/
│
├── src/
│   └── FCIToken_Tesis_ERC3643.sol      ← contrato principal v2.0.0
│
├── test/
│   ├── FCIToken.t.sol                   ← 106 tests (101 unitarios + 5 × 256 fuzz)
│   └── mocks/
│       ├── MockCompliance.sol           ← ICompliance configurable + contadores de llamadas
│       └── MockIdentityRegistry.sol    ← IIdentityRegistry con mockRegister()
│
├── lib/
│   └── forge-std/                       ← biblioteca de tests de Foundry (v1.16.1)
│
├── foundry.toml                         ← configuración del proyecto
│
└── README.md                            ← este archivo
```

### Mocks

**`MockCompliance`** simula el módulo de compliance:
- `setTransferAllowed(bool)`: activa/desactiva `canTransfer` en tiempo de test.
- Contadores `bindCallCount`, `transferredCallCount`, `createdCallCount`, `destroyedCallCount`: verifican que el token llama correctamente a los hooks del módulo.

**`MockIdentityRegistry`** simula el registro KYC:
- `mockRegister(address user, address identityAddr, uint16 country)`: registra un inversor con una dirección de identidad on-chain arbitraria. `identity(user)` devuelve `IIdentity(identityAddr)`, permitiendo testear la validación de `recoveryAddress`.
- Implementa todas las funciones de `IIdentityRegistry`; las no críticas son no-ops.

### Estado base de cada test

`setUp()` configura el mismo estado de partida para todos los tests:

```
MockCompliance       → desplegado, transferAllowed = true
MockIdentityRegistry → desplegado
FCIToken_Tesis       → desplegado con (idRegistry, compliance, decimals=6)

alice    → registrada (aliceId, país 32 = Argentina), 10.000 tokens
bob      → registrado  (bobId,   país 32 = Argentina), 0 tokens
carol    → NO registrada (usada como newWallet en recovery y como recipiente genérico)
attacker → EOA sin permisos
```

### Cobertura de tests

| Sección | Tests | Qué verifica |
|---|---|---|
| **[A] Constructor** | 7 | Owner, bindToken, módulos, estado inicial, zero-address guards |
| **[B] Mint** | 7 | Supply, balance, eventos Minted+Transfer, compliance created hook, acceso, freeze dest. — **RF-01** (solo MINTER_ROLE emite) |
| **[C] Burn** | 6 | Supply, balance, eventos Burned+Transfer, **CRITICAL-1** (freeze+burn), acceso |
| **[D] Transfer** | 8 | Happy path, eventos, **HIGH-2** (freeze destinatario), balance disponible, pausa, compliance — **RF-01** (solo wallets KYC reciben) |
| **[E] Allowance** | 8 | `approve`, `transferFrom`, deducción allowance, freeze source/dest, pausa, zero spender |
| **[F] Freeze parcial** | 8 | Freeze/unfreeze, eventos, límites, **MEDIUM-3** (no self-unfreeze) — **RF-04** (colateralización programable) |
| **[G] Freeze total** | 5 | Set/lift, bloqueo de transfer, evento AddressFrozen |
| **[H] Recovery** | 7 | Happy path, **CRITICAL-1** (migra frozen), **HIGH-3** (valida identidad), zero bal, access |
| **[I] Pause** | 6 | Flag, bloqueo de transfer y transferFrom, restauración, acceso |
| **[J] Ownership** | 6 | Two-step, pendingOwner, acceptOwnership, zero addr, access |
| **[K] Módulos** | 7 | setIdentityRegistry, setCompliance, eventos, zero addr, access |
| **[L] Info setters** | 5 | name, symbol, onchainID, evento UpdatedTokenInformation, access |
| **[M] Balance semántico** | 4 | `balanceOf` = total, `availableBalanceOf` = disponible, totalSupply invariante |
| **[N] Fuzz** | 4 × 256 | Mint, transfer, **CRITICAL-1 invariante** (freeze+burn), approve+transferFrom |
| **[O] forcedTransfer** | 9 + 1 × 256 | **RF-03** happy path, bypass de freeze emisor/receptor, bypass compliance, colateral LTV intacto, revert, acceso, fuzz. *Nota: la tesis declara RF-03 fuera del alcance del MVP original (v1.0.0). La función `forcedTransfer` fue incorporada en la revisión de seguridad v2.0.0 y está completamente testeada en esta versión del contrato.* |
| **Total** | **106 tests** | **0 fallos** |

### Tests de regresión para hallazgos críticos

Los tests más importantes son los que fijan el comportamiento corregido y detectarían una regresión si el fix fuera revertido:

```
test_RevertWhen_Burn_ExceedsAvailableBalance_WhenFrozenPresent
  → CRITICAL-1: burn no consume tokens congelados (underflow)

test_Burn_WithPartialFreeze_DoesNotBrickAccount
  → CRITICAL-1: después de burn parcial, availableBalanceOf no underflowea

test_RecoveryAddress_MigratesFrozenBalance
  → CRITICAL-1: recovery migra _frozenBalances y limpia el estado huérfano

testFuzz_FreezeAndBurn_NeverBricksAccount  (256 runs)
  → CRITICAL-1 invariante: ninguna combinación de freeze+burn brickea una cuenta

test_RevertWhen_Transfer_RecipientFrozen
  → HIGH-2: dirección destinataria congelada bloquea la transferencia

test_RevertWhen_RecoveryAddress_IdentityMismatch
  → HIGH-3: _investorOnchainID inválido revierte la recuperación

test_RevertWhen_UnfreezePartialTokens_NotOwner
  → MEDIUM-3: el inversor no puede autodescongelar su propio colateral

test_ForcedTransfer_BypassesSenderAddressFreeze
test_ForcedTransfer_BypassesComplianceCanTransfer
  → RF-03: la orden judicial supera freeze y reglas del fondo

test_ForcedTransfer_RespectsLTVCollateral
test_RevertWhen_ForcedTransfer_ExceedsAvailableBalance_FrozenPresent
testFuzz_ForcedTransfer_MovesExactAmountRegardlessOfFreeze  (256 runs)
  → RF-03: el colateral LTV nunca es alcanzado por una transferencia forzada
```

---

## 11. Cómo ejecutar los tests

### Prerequisitos

- [Foundry](https://getfoundry.sh/) instalado (`forge`, `cast`, `anvil`)
- `git` disponible (forge-std ya está instalado en `lib/`)

### Comandos

```bash
# Compilar el proyecto
forge build

# Correr todos los tests
forge test

# Tests con nombres y gas por test
forge test -v

# Tests con trazas completas de EVM (útil para debug de fallos)
forge test -vvvv

# Filtrar por patrón de nombre
forge test --match-test "Burn"
forge test --match-test "Recovery"
forge test --match-test "testFuzz"

# Fuzz tests con más iteraciones (por defecto: 256)
forge test --match-test "testFuzz" --fuzz-runs 10000

# Reporte de gas por función
forge test --gas-report

# Snapshot de gas (para comparar antes/después de un cambio)
forge snapshot
```

### Resultado esperado

```
Ran 106 tests for test/FCIToken.t.sol:FCITokenTest
[PASS] testFuzz_ApproveAndTransferFrom_... (runs: 256, μ: 122157)
[PASS] testFuzz_ForcedTransfer_MovesExactAmountRegardlessOfFreeze (runs: 256)
[PASS] testFuzz_FreezeAndBurn_NeverBricksAccount (runs: 256, μ: 82503)
[PASS] testFuzz_Mint_UpdatesSupplyAndBalance (runs: 256, μ: 67466)
[PASS] testFuzz_Transfer_MovesExactAmount (runs: 256, μ: 91246)
[PASS] test_Constructor_InitialState  ← decimals() == 6
[PASS] test_ForcedTransfer_BypassesComplianceCanTransfer
[PASS] test_ForcedTransfer_BypassesRecipientAddressFreeze
[PASS] test_ForcedTransfer_BypassesSenderAddressFreeze
[PASS] test_ForcedTransfer_RespectsLTVCollateral
[PASS] test_RecoveryAddress_MigratesFrozenBalance (gas: 192499)
... (106 tests en total)
Suite result: ok. 106 passed; 0 failed; 0 skipped; finished in 84ms
```

---

## 12. Consideraciones para producción

Este contrato fue diseñado para demostrar los principios del estándar ERC-3643 en el contexto de la tesis. Para un despliegue en mainnet o en un piloto regulado se deben agregar las siguientes capas:

### Control de acceso con roles (RBAC)

El patrón `onlyOwner` del MVP concentra todo el poder administrativo en una única clave — simplificación deliberada para la validación lógica. En producción se recomienda un sistema de roles separados tal como lo define la arquitectura de la tesis:

| Rol | Asignado a | Operaciones |
|---|---|---|
| **Owner / Multisig** | Sociedad Gerente + PSAV | Governance: reemplazar módulos, transferir ownership |
| **AGENT_ROLE** | PSAV | Gestión de la Whitelist (KYC): agregar o remover inversores, ejecutar `forcedTransfer` bajo resolución judicial |
| **MINTER_ROLE** | Core Bancario de la Gerente | Emisión de cuotas-partes (`mint`) al detectar pago fiat confirmado, sin poder modificar la gobernanza del fondo |

Esta separación de roles garantiza que el PSAV no pueda emitir tokens y que el Core Bancario no pueda modificar la whitelist — principio de mínimo privilegio aplicado a la operatoria del fondo.

### Timelock en cambios críticos

Reemplazar `ICompliance` o `IIdentityRegistry` debería tener un delay obligatorio (p. ej. 48 horas) para darles a los inversores tiempo de revisar el cambio antes de que tome efecto. Esto previene que una clave comprometida realice cambios silenciosos de forma instantánea.

### Multisig para el owner — especialmente crítico para `forcedTransfer`

En lugar de un EOA, el owner debería ser un Safe (Gnosis Safe) multisig con al menos esquema 2-of-3 o 3-of-5. Esto es especialmente importante para `forcedTransfer` (RF-03): en producción, la firma del multisig debería requerir adjuntar el hash de la resolución judicial como dato de la transacción, creando un vínculo inmutable entre la orden del juez y la ejecución on-chain. Sin este wrapper de governance, `forcedTransfer` con `onlyOwner` es un vector de abuso si la clave se compromete.

### Auditoría formal

Antes de cualquier lanzamiento con fondos reales se requiere una auditoría de seguridad por parte de una firma especializada (Trail of Bits, OpenZeppelin, Hacken, etc.).

### Implementaciones reales de los módulos externos

Los mocks de tests (`MockCompliance`, `MockIdentityRegistry`) son simplificaciones para testing. En producción se usarían las implementaciones de Tokeny:

- [T-REX Identity Registry](https://github.com/TokenySolutions/T-REX/tree/main/contracts/registry)
- [T-REX Compliance Modules](https://github.com/TokenySolutions/T-REX/tree/main/contracts/compliance)

---

## 13. Archivos del proyecto

| Archivo | Descripción |
|---|---|
| [src/FCIToken_Tesis_ERC3643.sol](src/FCIToken_Tesis_ERC3643.sol) | Contrato principal v2.0.0 con todas las correcciones de seguridad |
| [test/FCIToken.t.sol](test/FCIToken.t.sol) | Suite de 106 tests Foundry (unitarios + fuzz) |
| [test/mocks/MockCompliance.sol](test/mocks/MockCompliance.sol) | Mock del módulo de compliance para testing |
| [test/mocks/MockIdentityRegistry.sol](test/mocks/MockIdentityRegistry.sol) | Mock del registro de identidad KYC para testing |
| [README.md](README.md) | Documentación completa del proyecto |

---

*Trabajo de Tesis — Maestría en Tecnología de la Información*
*Universidad de Palermo · 2026*
