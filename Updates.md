# FCIToken_Tesis — Security & Optimization Updates

**File:** `FCIToken_Tesis_ERC3643.sol`  
**Review version:** 1.0.0 → **2.0.0**  
**Date:** 2026-06-07  

All changes are the result of a full security audit and gas optimization pass on the original contract. Each entry includes the severity classification, the root cause, and what was changed.

---

## Critical Fixes

### [CRITICAL-1] Frozen balance corruption in `burn` and `recoveryAddress`

**Root cause (burn):** `burn` checked `_balances[user] >= amount` but did not account for `_frozenBalances[user]`. Burning tokens that were partially or fully frozen left `_frozenBalances > _balances`, so any subsequent call to `balanceOf` or `availableBalanceOf` would revert with an arithmetic underflow, permanently bricking the account.

**Root cause (recoveryAddress):** When moving a balance to a new wallet, `_frozenBalances[_lostWallet]` was never reset. The old address retained a frozen-balance record pointing to a zero-balance account (orphaned state), and the new wallet received tokens with no freeze constraints applied.

**Fix in `burn`:**
```solidity
// Before — burns any balance, including frozen tokens
require(_balances[_userAddress] >= _amount, "Saldo insuficiente para quemar");

// After — only allows burning from the available (unfrozen) portion
uint256 totalBal  = _balances[_userAddress];
uint256 frozenBal = _frozenBalances[_userAddress];
if (totalBal - frozenBal < _amount) revert InsufficientAvailableBalance();
_balances[_userAddress] = totalBal - _amount;
```

**Fix in `recoveryAddress`:**
```solidity
// Before — only moved _balances, leaving _frozenBalances orphaned
_balances[_lostWallet] -= amountToRecover;
_balances[_newWallet]  += amountToRecover;

// After — migrates frozen balance atomically alongside the total balance
uint256 frozenToMigrate      = _frozenBalances[_lostWallet];
_balances[_lostWallet]       = 0;
_frozenBalances[_lostWallet] = 0;        // clears the orphan
_balances[_newWallet]       += amountToRecover;
_frozenBalances[_newWallet] += frozenToMigrate; // migrates freeze constraints
```

---

## High Severity Fixes

### [HIGH-2] Missing frozen-address check on transfer recipient

**Root cause:** `transfer()` verified that `msg.sender` was not frozen but did not check the recipient `_to`. A frozen address could freely receive tokens, partially defeating the freeze mechanism.

**Fix:**
```solidity
// Added immediately after the sender freeze check:
if (_frozenAddresses[_to]) revert AddressFrozenError(_to);
```
The same check was applied to the new `transferFrom` function.

---

### [HIGH-3] `_investorOnchainID` parameter ignored in `recoveryAddress`

**Root cause:** The ERC-3643 standard requires `_investorOnchainID` to be validated against the lost wallet's registered on-chain identity before executing a recovery. Without this check, the owner could transfer any investor's full balance to any arbitrary address with no cryptographic proof of ownership.

**Fix:**
```solidity
// Validates the on-chain identity matches the lost wallet
if (address(_identityRegistry.identity(_lostWallet)) != _investorOnchainID) {
    revert IdentityMismatch();
}
// Validates the new wallet is registered in the KYC system
if (!_identityRegistry.contains(_newWallet)) revert WalletNotRegistered();
```

---

### [HIGH-4] No zero-address validation on critical module setters

**Root cause:** Constructor and both `setIdentityRegistry` / `setCompliance` accepted `address(0)` silently. Setting either module to the zero address would cause all transfers, mints, and burns to fail with a low-level revert, effectively bricking the token with no recovery path.

**Fix:** Added `if (addr == address(0)) revert ZeroAddress();` guards in:
- `constructor`
- `setIdentityRegistry`
- `setCompliance`
- `approve`
- `transferOwnership`

---

### [HIGH-5] Missing ERC-20 allowance mechanism (`approve` / `allowance` / `transferFrom`)

**Root cause:** ERC-3643 extends ERC-20. Without `approve`, `allowance`, and `transferFrom`, standard wallets, block explorers, and protocol integrations (vaults, aggregators) are partially or fully non-functional.

**Fix:** Added the full ERC-20 allowance surface with the same compliance and freeze gates applied in `transfer`:
- `mapping(address => mapping(address => uint256)) private _allowances`
- `event Approval(address indexed owner, address indexed spender, uint256 value)`
- `function allowance(address _owner, address _spender) public view returns (uint256)`
- `function approve(address _spender, uint256 _amount) external returns (bool)`
- `function transferFrom(address _from, address _to, uint256 _amount) public whenNotPaused returns (bool)`

---

## Medium Severity Fixes

### [MEDIUM-1] `UpdatedTokenInformation` event never emitted

**Root cause:** The ERC-3643 standard defines this event so off-chain indexers (block explorers, subgraphs) can track token metadata changes. It was declared in the interface but never emitted.

**Fix:** Each metadata setter now emits the full event:
```solidity
function setName(string calldata _name) external override onlyOwner {
    name = _name;
    emit UpdatedTokenInformation(_name, symbol, decimals, version, onchainID);
}
// Same pattern applied to setSymbol and setOnchainID.
```

---

### [MEDIUM-2] No events emitted when swapping critical modules

**Root cause:** Replacing the identity registry or compliance module — the two most security-sensitive dependencies — produced no on-chain log. An owner whose key was compromised could silently swap in a malicious compliance module.

**Fix:** Added dedicated events and emit them in the setters:
```solidity
event IdentityRegistrySet(address indexed newIdentityRegistry);
event ComplianceSet(address indexed newCompliance);
```

---

### [MEDIUM-3] Users could self-unfreeze collateral tokens

**Root cause:** Both `freezePartialTokens` and `unfreezePartialTokens` permitted `msg.sender == _userAddress`. When used for LTV collateral enforcement, this allowed the borrower to immediately unfreeze their own collateral, rendering the mechanism ineffective.

**Fix:** Both functions are now `onlyOwner`. The collateral manager (owner or an authorized agent) is the sole party that can freeze or release collateral.

---

## Low Severity Fixes

### [LOW-1] No ownership transfer mechanism

**Root cause:** With no `transferOwnership`, a lost or compromised deployer key would permanently brick all administrative functions.

**Fix:** Implemented a two-step ownership transfer (Ownable2Step pattern):
```solidity
function transferOwnership(address _newOwner) external onlyOwner { ... }
function acceptOwnership() external { ... } // must be called by pendingOwner
```
This pattern prevents accidentally transferring ownership to an address that cannot call `acceptOwnership`.

---

### [LOW-2] `balanceOf` deviated from ERC-20 semantics

**Root cause:** The original `balanceOf` returned only the *available* (unfrozen) balance. Standard ERC-20 `balanceOf` returns the *total* balance. This caused third-party tooling (wallets, explorers) to display incorrect holdings.

**Fix:** Split into two functions:
- `balanceOf(address)` → returns `_balances[account]` (total, ERC-20 compliant)
- `availableBalanceOf(address)` → returns `_balances[account] - _frozenBalances[account]` (transferable)

All internal checks that previously called `balanceOf` (freeze guards, transfer checks, burn guards) were updated to call `availableBalanceOf`.

---

### [LOW-3] `compliance.bindToken()` not called in constructor

**Root cause:** The ERC-3643 standard expects the token to register itself with the compliance module at deployment. Compliance modules that guard their callbacks with `onlyToken` (i.e., reject calls from unregistered tokens) would silently reject all `created`, `destroyed`, and `transferred` calls.

**Fix:**
```solidity
constructor(address _idRegistry, address _compModule) {
    ...
    _complianceModule.bindToken(address(this));
}
```

---

## Gas Optimizations

### [GAS-1] Custom errors replace `require` string messages

All `require(condition, "string")` calls were replaced with custom errors, saving 50–200 gas per revert path by eliminating string hashing and ABI encoding at runtime.

```solidity
// Before
require(msg.sender == owner, "Solo administrador autorizado");

// After
error Unauthorized();
if (msg.sender != owner) revert Unauthorized();
```

Errors defined: `Unauthorized`, `ZeroAddress`, `ContractPaused`, `AddressFrozenError`, `InsufficientAvailableBalance`, `InsufficientFrozenBalance`, `InsufficientAllowance`, `NoBalanceToRecover`, `IdentityMismatch`, `WalletNotRegistered`.

---

### [GAS-2] Storage variable packing

Small-typed variables were reordered so they share a single 32-byte storage slot instead of each occupying a dedicated slot. This saves one cold `SLOAD` (2,100 gas) per grouped read.

| Before (separate slots) | After (packed into Slot 0) |
|---|---|
| `uint8 decimals` — slot 2 | `address onchainID` (20 bytes) |
| `bool paused` — slot 4 | `uint8 decimals` (1 byte) |
| `address onchainID` — slot 6 | `bool _paused` (1 byte) |

Total slot savings: **2 storage slots** (64 bytes).

---

### [GAS-3] Cached storage reads in hot paths

In `transfer` and `transferFrom`, multiple reads of `_balances[sender]` and `_frozenBalances[sender]` were replaced with local variable caches, turning repeated cold `SLOAD`s (2,100 gas each) into cheap `MLOAD`s (3 gas):

```solidity
uint256 senderBalance = _balances[msg.sender]; // single SLOAD
uint256 senderFrozen  = _frozenBalances[msg.sender]; // single SLOAD
if (senderBalance - senderFrozen < _amount) revert InsufficientAvailableBalance();
_balances[msg.sender] = senderBalance - _amount; // uses cached value, no re-read
```

---

### [GAS-4] `!= 0` instead of `> 0` for zero checks

```solidity
// Before
require(amountToRecover > 0, "No hay saldo para recuperar");

// After
if (amountToRecover == 0) revert NoBalanceToRecover();
```

`!= 0` compiles to a slightly cheaper opcode path on most EVM implementations.

---

---

## [FEAT] `forcedTransfer` — RF-03 Transferencia por Mandato Judicial

**Date:** 2026-06-08

**Motivation:** EIP-3643 mandates `forcedTransfer(address _from, address _to, uint256 _amount) returns (bool)` as a first-class function in the interface. The contract was missing it entirely. `recoveryAddress` does not cover this requirement — it migrates a whole wallet under identity-proof protection (lost key). `forcedTransfer` covers RF-03 specifically: a judge orders a *partial* transfer of a specific amount from a debtor's wallet to a creditor's wallet, bypassing freeze and compliance checks because the court order supersedes fund rules.

**What was added:**

1. **`ForcedTransfer` event in `IERC3643`** — distinguishes judicial transfers from ordinary ones in the on-chain log, making regulatory audits possible without off-chain metadata.

2. **`forcedTransfer` function signature in `IERC3643`** — fills the architectural slot mandated by the EIP so a reviewer can see the standard is fully implemented.

3. **`forcedTransfer` implementation in `FCIToken_Tesis`** — `onlyOwner` gated (production wrapper: multisig with judicial resolution as signing condition).

**Semantics vs `transfer` and `recoveryAddress`:**

| | `transfer` | `recoveryAddress` | `forcedTransfer` |
|---|---|---|---|
| Who calls | Investor | Owner | Owner |
| How much | Any available | Entire wallet | Any partial amount |
| Identity proof | — | Required | — |
| Respects address freeze | No (reverts) | Yes (bypasses) | Yes (bypasses) |
| Respects `canTransfer` | No (reverts) | Bypasses | Bypasses |
| Respects LTV collateral | Yes | Migrates | Yes — frozen tokens NOT touched |
| Use case | Normal P2P transfer | Lost key / bankruptcy recovery | Court-ordered debt execution |

**Design decision — why frozen (collateral) tokens are NOT transferable via `forcedTransfer`:**

Frozen tokens represent pledged LTV collateral under a separate legal agreement. A court-ordered execution against *different* debt should not automatically pierce collateral pledged to another creditor. If the court order encompasses the frozen collateral, a separate `unfreezePartialTokens` call (itself requiring `onlyOwner`) precedes the `forcedTransfer`, creating an unambiguous on-chain audit trail — one action = one court order.

**Implementation:**

```solidity
function forcedTransfer(address _from, address _to, uint256 _amount)
    external override onlyOwner returns (bool)
{
    uint256 totalBal  = _balances[_from];
    uint256 frozenBal = _frozenBalances[_from];
    if (totalBal - frozenBal < _amount) revert InsufficientAvailableBalance();

    _balances[_from] -= _amount;
    _balances[_to]   += _amount;

    _complianceModule.transferred(_from, _to, _amount);
    emit ForcedTransfer(_from, _to, _amount);
    emit Transfer(_from, _to, _amount);
    return true;
}
```

**Tests added (section [O] in `FCIToken.t.sol`):** 9 tests covering happy path, bypass of sender/recipient freeze, bypass of `canTransfer`, LTV collateral integrity, revert on insufficient available balance, access control, plus 1 fuzz test (256 runs) validating that frozen collateral is always preserved after a forced transfer.

---

## Summary Table

| ID | Severity | Area | Status |
|----|----------|------|--------|
| CRITICAL-1 | Critical | `burn` / `recoveryAddress` frozen balance | Fixed |
| HIGH-2 | High | Frozen destination check in `transfer` | Fixed |
| HIGH-3 | High | `_investorOnchainID` unused in `recoveryAddress` | Fixed |
| HIGH-4 | High | Zero-address validation on setters | Fixed |
| HIGH-5 | High | ERC-20 `approve`/`allowance`/`transferFrom` | Fixed |
| MEDIUM-1 | Medium | `UpdatedTokenInformation` event missing | Fixed |
| MEDIUM-2 | Medium | No events for module swaps | Fixed |
| MEDIUM-3 | Medium | User self-unfreeze of collateral | Fixed |
| LOW-1 | Low | No ownership transfer mechanism | Fixed |
| LOW-2 | Low | `balanceOf` ERC-20 semantics mismatch | Fixed |
| LOW-3 | Low | `bindToken` not called in constructor | Fixed |
| GAS-1 | Gas | Custom errors | Applied |
| GAS-2 | Gas | Storage packing | Applied |
| GAS-3 | Gas | Hot-path storage caching | Applied |
| GAS-4 | Gas | `!= 0` zero checks | Applied |
