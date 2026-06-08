# Decisión de Diseño: `balanceOf` retorna el saldo total

**Contexto:** `FCIToken_Tesis v2.0.0` — ERC-3643 FCI Cerrado Simple Estate

---

## La premisa que hay que invertir

La confusión más frecuente al leer este contrato es asumir que `balanceOf` debería esconder los tokens congelados para "proteger" contra transferencias indebidas. La regla operativa real es la inversa:

> **`balanceOf` informa cuántos tokens posee el inversor. `transfer` y `transferFrom` deciden si se pueden mover.**

El contrato ya implementa esto correctamente. En `transfer` y `transferFrom`:

```solidity
uint256 senderBalance = _balances[msg.sender];
uint256 senderFrozen  = _frozenBalances[msg.sender];
if (senderBalance - senderFrozen < _amount) revert InsufficientAvailableBalance();
```

Si una billetera tiene 10.000 tokens con 5.000 congelados y un router intenta `transferFrom(user, pool, 6.000)`, el contrato evalúa `10.000 − 5.000 = 5.000 < 6.000` y revierte. Los tokens congelados **no se mueven**, aunque `balanceOf` los informe. El freeze actúa en la capa de **transferibilidad**, no en la capa de **contabilidad**. Ocultarlos en `balanceOf` no añadiría ninguna línea de protección: solo desplazaría dónde aparece el error.

---

## Por qué `balanceOf` debe ser el saldo total

### 1. Invariante contable

ERC-20 garantiza que `Σ balanceOf(holders) == totalSupply`. Auditores externos, oráculos contables, herramientas de prueba de reservas y reguladores que corren nodos observadores dependen de esta propiedad. Si `balanceOf` retornara el saldo disponible, la suma de todos los balances sería menor que `totalSupply` cada vez que existan tokens congelados. El delta quedaría "perdido" en una cuenta invisible que solo `getFrozenTokens` revelaría. Cualquier reconciliación entre el ledger on-chain y el sistema bancario fallaría hasta que el auditor descubra la semántica no estándar — y nadie la advertiría.

### 2. Propiedad ≠ transferibilidad

Cuando un inversor pignora cuotas como garantía de un préstamo, **sigue siendo el dueño**. Cobra dividendos sobre ellas, tributa sobre ellas, son parte de su patrimonio declarado, y figuran en su Reporte de Operaciones Patrimoniales. Lo que pierde temporalmente es la *capacidad de disposición*. Reportar solo el saldo disponible como `balanceOf` equivale a ocultar activos legalmente del dueño. En los propios términos del sistema:

> *"Sus tokens NO se venden ni se queman. Siguen siendo propiedad del inversor, pero quedan técnicamente inmovilizados."*

La semántica del código debe reflejar esa prosa. El freeze es una restricción de movimiento, no una expropiación.

### 3. Compatibilidad con el ecosistema

Etherscan/Polygonscan, MetaMask, Bloomberg Terminal, Chainalysis, plataformas de tax reporting y bridges asumen semántica ERC-20 estándar. Una implementación que desvíe `balanceOf` muestra números incorrectos en cada herramienta existente sin advertencia alguna. Si el regulador consulta el explorador de bloques para auditar, verá saldos que no coinciden con los registros del fondo.

### 4. Convención explícita de EIP-3643

La implementación de referencia de Tokeny (T-REX) y la spec del EIP definen `balanceOf` como el saldo total. Desviarse rompe la conformidad con el estándar que el contrato declara cumplir.

---

## La preocupación de DeFi, en detalle

Hay un escenario válido en la pregunta: una integración ingenua podría comportarse así:

1. Una app consulta `balanceOf(user) == 10.000`
2. Propone al usuario un swap de 10.000 tokens
3. El contrato revierte porque 5.000 están congelados
4. El usuario ve "Swap Failed" sin entender el motivo

Esto es indeseable en UX. Pero la solución no es esconder los congelados en `balanceOf`; es que las apps integradoras consulten `availableBalanceOf` o `getFrozenTokens` antes de proponer un monto. La app propia del sistema hará esto porque se controla el front-end. Una app externa que no lo contemple fallará, lo cual es exactamente el comportamiento correcto para un security token: **no es composable con DeFi abierto por diseño**.

Además, existe una primera barrera antes del freeze: el módulo de compliance. Cualquier dirección que no esté verificada en el KYC — como la dirección de un pool de Uniswap, Aave o Curve — es rechazada por `canTransfer` antes de que el problema del freeze siquiera se evalúe. El swap no fracasa por el freeze; fracasa por compliance. El freeze es la segunda barrera.

Cuando sí existe composabilidad — dentro del ecosistema regulado (préstamos colateralizados, mercado secundario OTC entre inversores KYC'd) — los contratos integradores son los del propio sistema, que conocen el estándar y consultan `availableBalanceOf`.

---

## Separación de funciones en el contrato

| Función | Retorna | Uso esperado |
|---|---|---|
| `balanceOf(address)` | Saldo total (incluyendo congelados) | Contabilidad, exploradores, reportes regulatorios, `totalSupply` reconciliation |
| `availableBalanceOf(address)` | Saldo no congelado | Apps integradoras, pre-validación de transferencias, UI del sistema |
| `getFrozenTokens(address)` | Saldo congelado | Gestión de colateral, reporting de garantías |

---

## Mejoras de UX posibles (sin cambiar el comportamiento)

**(a) NatSpec claro.** Documentar en `balanceOf` y `availableBalanceOf` la distinción exacta para que cualquier integrador entienda la semántica de un solo vistazo.

**(b) Helper `maxTransferable`.** Una función `maxTransferable(address _from, address _to) returns (uint256)` que devuelva el monto máximo que `_from` puede transferir a `_to` *en este momento*, contemplando freeze parcial de origen, freeze de destino, y el resultado de `canTransfer`. Esto da a las apps un único punto de consulta.

**(c) Escucha de eventos.** El evento `TokensFrozen(address, uint256)` ya existe. Las apps clientes deben escucharlo para actualizar su cache de "available" en tiempo real. Sin esto, una app que cachea balances mostrará información obsoleta durante el lapso entre el freeze y el siguiente refresco.

---

## Conclusión

`balanceOf` = total, `availableBalanceOf` = disponible, `getFrozenTokens` = bloqueado. Es la decisión correcta y es lo que establece el estándar.

La protección real contra movimientos de tokens congelados reside en el bloque `if` de `transfer` / `transferFrom` y en la llamada a `canTransfer` del módulo de compliance — no en la función de lectura.

> **Nota para la defensa:** `balanceOf` reporta tenencia total; la transferibilidad se evalúa en cada transferencia mediante el freeze parcial (`availableBalanceOf`) y el módulo de compliance (`canTransfer`). Propiedad y capacidad de disposición son conceptos distintos, y el contrato los modela por separado de forma deliberada.
