// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../src/FCIToken_Tesis_ERC3643.sol";
import "./mocks/MockCompliance.sol";
import "./mocks/MockIdentityRegistry.sol";

/**
 * @title FCITokenTest
 *
 * Test coverage map:
 *  [A] Constructor & initial state
 *  [B] Mint
 *  [C] Burn  ← includes CRITICAL-1 regression
 *  [D] Transfer  ← includes HIGH-2 regression
 *  [E] ERC-20 allowance (approve / transferFrom)
 *  [F] Partial freeze / unfreeze  ← includes MEDIUM-3 regression
 *  [G] Address-level freeze
 *  [H] Recovery address  ← includes CRITICAL-1 & HIGH-3 regressions
 *  [I] Pause / Unpause
 *  [J] Two-step ownership transfer  ← LOW-1
 *  [K] Module setters (IdentityRegistry, Compliance)
 *  [L] Token-info setters (name, symbol, onchainID)
 *  [M] balanceOf / availableBalanceOf semantics  ← LOW-2
 *  [N] Fuzz tests
 */
contract FCITokenTest is Test {

    // =========================================================
    // State
    // =========================================================

    FCIToken_Tesis        internal token;
    MockCompliance        internal compliance;
    MockIdentityRegistry  internal idRegistry;

    address internal owner;    // = address(this) — test contract deploys
    address internal alice;
    address internal bob;
    address internal carol;    // used as a new-wallet in recovery tests
    address internal attacker;

    // On-chain identity addresses (just EOAs used as identifiers in the mock)
    address internal aliceId;
    address internal bobId;

    uint256 constant MINT = 10_000; // initial mint to Alice

    // =========================================================
    // Setup
    // =========================================================

    function setUp() public {
        owner    = address(this);
        alice    = makeAddr("alice");
        bob      = makeAddr("bob");
        carol    = makeAddr("carol");
        attacker = makeAddr("attacker");
        aliceId  = makeAddr("aliceIdentity");
        bobId    = makeAddr("bobIdentity");

        compliance = new MockCompliance();
        idRegistry = new MockIdentityRegistry();
        token      = new FCIToken_Tesis(address(idRegistry), address(compliance), 6);

        // Register KYC investors (ISO 3166-1 numeric: 032 = Argentina)
        idRegistry.mockRegister(alice, aliceId, 32);
        idRegistry.mockRegister(bob,   bobId,   32);

        // Fund Alice for transfer/freeze/burn tests
        token.mint(alice, MINT);
    }

    // =========================================================
    // [A] Constructor & initial state
    // =========================================================

    function test_Constructor_SetsOwner() public view {
        assertEq(token.owner(), owner);
    }

    function test_Constructor_BindsToken_OnComplianceModule() public view {
        assertTrue(compliance.isTokenBound(address(token)));
        assertEq(compliance.bindCallCount(), 1);
    }

    function test_Constructor_SetsIdentityRegistry() public view {
        assertEq(address(token.identityRegistry()), address(idRegistry));
    }

    function test_Constructor_SetsCompliance() public view {
        assertEq(address(token.compliance()), address(compliance));
    }

    function test_Constructor_InitialState() public view {
        assertEq(token.name(),     "FCI Cerrado Simple Estate");
        assertEq(token.symbol(),   "FCIE");
        assertEq(token.decimals(), 6);
        assertEq(token.version(),  "1.0.0");
        assertFalse(token.paused());
    }

    function test_RevertWhen_Constructor_ZeroIdentityRegistry() public {
        vm.expectRevert(FCIToken_Tesis.ZeroAddress.selector);
        new FCIToken_Tesis(address(0), address(compliance), 6);
    }

    function test_RevertWhen_Constructor_ZeroCompliance() public {
        vm.expectRevert(FCIToken_Tesis.ZeroAddress.selector);
        new FCIToken_Tesis(address(idRegistry), address(0), 6);
    }

    // =========================================================
    // [B] Mint
    // =========================================================

    function test_Mint_IncreasesTotalSupply() public {
        uint256 before = token.totalSupply();
        token.mint(bob, 500);
        assertEq(token.totalSupply(), before + 500);
    }

    function test_Mint_CreditsRecipientBalance() public {
        token.mint(bob, 500);
        assertEq(token.balanceOf(bob), 500);
    }

    function test_Mint_CallsComplianceCreated() public {
        uint256 before = compliance.createdCallCount();
        token.mint(bob, 500);
        assertEq(compliance.createdCallCount(), before + 1);
    }

    function test_Mint_EmitsMintedAndTransferEvents() public {
        vm.expectEmit(true, false, false, true);
        emit IERC3643.Minted(bob, 500);
        vm.expectEmit(true, true, false, true);
        emit IERC3643.Transfer(address(0), bob, 500);
        token.mint(bob, 500);
    }

    function test_RevertWhen_Mint_NotOwner() public {
        vm.prank(attacker);
        vm.expectRevert(FCIToken_Tesis.Unauthorized.selector);
        token.mint(bob, 500);
    }

    function test_RevertWhen_Mint_ToFrozenAddress() public {
        token.setAddressFrozen(bob, true);
        vm.expectRevert(abi.encodeWithSelector(FCIToken_Tesis.AddressFrozenError.selector, bob));
        token.mint(bob, 500);
    }

    function test_RevertWhen_Mint_ComplianceRejects() public {
        compliance.setTransferAllowed(false);
        vm.expectRevert("Falla en Compliance o KYC");
        token.mint(bob, 500);
    }

    // =========================================================
    // [C] Burn
    // =========================================================

    function test_Burn_DecreasesTotalSupply() public {
        uint256 before = token.totalSupply();
        token.burn(alice, 1_000);
        assertEq(token.totalSupply(), before - 1_000);
    }

    function test_Burn_DeductsFromBalance() public {
        token.burn(alice, 1_000);
        assertEq(token.balanceOf(alice), MINT - 1_000);
    }

    function test_Burn_CallsComplianceDestroyed() public {
        uint256 before = compliance.destroyedCallCount();
        token.burn(alice, 1_000);
        assertEq(compliance.destroyedCallCount(), before + 1);
    }

    function test_Burn_EmitsBurnedAndTransferEvents() public {
        vm.expectEmit(true, false, false, true);
        emit IERC3643.Burned(alice, 1_000);
        vm.expectEmit(true, true, false, true);
        emit IERC3643.Transfer(alice, address(0), 1_000);
        token.burn(alice, 1_000);
    }

    /// @dev CRITICAL-1: Burning more than the available (non-frozen) balance must revert.
    ///      Without this fix, _frozenBalances would exceed _balances, causing every
    ///      subsequent call to availableBalanceOf to underflow and permanently brick the account.
    function test_RevertWhen_Burn_ExceedsAvailableBalance_WhenFrozenPresent() public {
        token.freezePartialTokens(alice, 5_000); // available = 5_000
        vm.expectRevert(FCIToken_Tesis.InsufficientAvailableBalance.selector);
        token.burn(alice, 5_001);                // tries to burn 1 more than available
    }

    /// @dev Verifies the account is NOT bricked after burning exactly the available portion.
    function test_Burn_WithPartialFreeze_DoesNotBrickAccount() public {
        token.freezePartialTokens(alice, 3_000);
        token.burn(alice, 7_000); // burns the full available portion

        // _balances = 3_000, _frozenBalances = 3_000 → available = 0, no underflow
        assertEq(token.balanceOf(alice),          3_000);
        assertEq(token.availableBalanceOf(alice),  0);
    }

    function test_RevertWhen_Burn_NotOwner() public {
        vm.prank(attacker);
        vm.expectRevert(FCIToken_Tesis.Unauthorized.selector);
        token.burn(alice, 1_000);
    }

    function test_RevertWhen_Burn_ExceedsTotalBalance() public {
        vm.expectRevert(FCIToken_Tesis.InsufficientAvailableBalance.selector);
        token.burn(alice, MINT + 1);
    }

    // =========================================================
    // [D] Transfer
    // =========================================================

    function test_Transfer_MovesTokens() public {
        vm.prank(alice);
        token.transfer(bob, 1_000);
        assertEq(token.balanceOf(alice), MINT - 1_000);
        assertEq(token.balanceOf(bob),   1_000);
    }

    function test_Transfer_EmitsTransferEvent() public {
        vm.expectEmit(true, true, false, true);
        emit IERC3643.Transfer(alice, bob, 1_000);
        vm.prank(alice);
        token.transfer(bob, 1_000);
    }

    function test_Transfer_CallsComplianceTransferred() public {
        uint256 before = compliance.transferredCallCount();
        vm.prank(alice);
        token.transfer(bob, 1_000);
        assertEq(compliance.transferredCallCount(), before + 1);
    }

    function test_RevertWhen_Transfer_SenderFrozen() public {
        token.setAddressFrozen(alice, true);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FCIToken_Tesis.AddressFrozenError.selector, alice));
        token.transfer(bob, 1_000);
    }

    /// @dev HIGH-2: Recipient freeze was not checked in v1 — must block transfer.
    function test_RevertWhen_Transfer_RecipientFrozen() public {
        token.setAddressFrozen(bob, true);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FCIToken_Tesis.AddressFrozenError.selector, bob));
        token.transfer(bob, 1_000);
    }

    /// @dev Frozen tokens reduce the available balance; transfer above available must fail.
    function test_RevertWhen_Transfer_ExceedsAvailableBalance() public {
        token.freezePartialTokens(alice, 8_000); // available = 2_000
        vm.prank(alice);
        vm.expectRevert(FCIToken_Tesis.InsufficientAvailableBalance.selector);
        token.transfer(bob, 3_000);
    }

    function test_Transfer_FrozenTokensDoNotMove() public {
        token.freezePartialTokens(alice, 8_000); // available = 2_000
        vm.prank(alice);
        token.transfer(bob, 2_000);              // exactly available
        // Alice still holds the 8_000 frozen tokens
        assertEq(token.balanceOf(alice),         8_000);
        assertEq(token.getFrozenTokens(alice),   8_000);
        assertEq(token.availableBalanceOf(alice), 0);
    }

    function test_RevertWhen_Transfer_Paused() public {
        token.pause();
        vm.prank(alice);
        vm.expectRevert(FCIToken_Tesis.ContractPaused.selector);
        token.transfer(bob, 1_000);
    }

    function test_RevertWhen_Transfer_ComplianceRejects() public {
        compliance.setTransferAllowed(false);
        vm.prank(alice);
        vm.expectRevert("Falla en Compliance o KYC");
        token.transfer(bob, 1_000);
    }

    // =========================================================
    // [E] ERC-20 allowance: approve / transferFrom
    // =========================================================

    function test_Approve_SetsAllowance() public {
        vm.prank(alice);
        token.approve(bob, 3_000);
        assertEq(token.allowance(alice, bob), 3_000);
    }

    function test_TransferFrom_MovesTokens() public {
        vm.prank(alice);
        token.approve(bob, 3_000);
        vm.prank(bob);
        token.transferFrom(alice, carol, 2_000);
        assertEq(token.balanceOf(alice), MINT - 2_000);
        assertEq(token.balanceOf(carol), 2_000);
    }

    function test_TransferFrom_DeductsAllowance() public {
        vm.prank(alice);
        token.approve(bob, 3_000);
        vm.prank(bob);
        token.transferFrom(alice, carol, 2_000);
        assertEq(token.allowance(alice, bob), 1_000);
    }

    function test_TransferFrom_CallsComplianceTransferred() public {
        vm.prank(alice);
        token.approve(bob, 3_000);
        uint256 before = compliance.transferredCallCount();
        vm.prank(bob);
        token.transferFrom(alice, carol, 1_000);
        assertEq(compliance.transferredCallCount(), before + 1);
    }

    function test_RevertWhen_TransferFrom_InsufficientAllowance() public {
        vm.prank(alice);
        token.approve(bob, 500);
        vm.prank(bob);
        vm.expectRevert(FCIToken_Tesis.InsufficientAllowance.selector);
        token.transferFrom(alice, carol, 1_000);
    }

    function test_RevertWhen_TransferFrom_SourceFrozen() public {
        token.setAddressFrozen(alice, true);
        vm.prank(alice);
        token.approve(bob, 3_000);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(FCIToken_Tesis.AddressFrozenError.selector, alice));
        token.transferFrom(alice, carol, 1_000);
    }

    function test_RevertWhen_TransferFrom_RecipientFrozen() public {
        token.setAddressFrozen(carol, true);
        vm.prank(alice);
        token.approve(bob, 3_000);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(FCIToken_Tesis.AddressFrozenError.selector, carol));
        token.transferFrom(alice, carol, 1_000);
    }

    function test_RevertWhen_TransferFrom_Paused() public {
        vm.prank(alice);
        token.approve(bob, 3_000);
        token.pause();
        vm.prank(bob);
        vm.expectRevert(FCIToken_Tesis.ContractPaused.selector);
        token.transferFrom(alice, carol, 1_000);
    }

    function test_RevertWhen_Approve_ZeroSpender() public {
        vm.prank(alice);
        vm.expectRevert(FCIToken_Tesis.ZeroAddress.selector);
        token.approve(address(0), 1_000);
    }

    // =========================================================
    // [F] Partial freeze / unfreeze
    // =========================================================

    function test_FreezePartialTokens_IncreasesFrozenBalance() public {
        token.freezePartialTokens(alice, 4_000);
        assertEq(token.getFrozenTokens(alice), 4_000);
    }

    function test_FreezePartialTokens_ReducesAvailableBalance() public {
        token.freezePartialTokens(alice, 4_000);
        assertEq(token.availableBalanceOf(alice), MINT - 4_000);
        assertEq(token.balanceOf(alice),          MINT); // total unchanged
    }

    function test_FreezePartialTokens_EmitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit IERC3643.TokensFrozen(alice, 4_000);
        token.freezePartialTokens(alice, 4_000);
    }

    function test_FreezePartialTokens_CanFreezeFullBalance() public {
        token.freezePartialTokens(alice, MINT);
        assertEq(token.availableBalanceOf(alice), 0);
    }

    function test_RevertWhen_FreezePartialTokens_ExceedsAvailable() public {
        token.freezePartialTokens(alice, 8_000);   // available = 2_000
        vm.expectRevert(FCIToken_Tesis.InsufficientAvailableBalance.selector);
        token.freezePartialTokens(alice, 2_001);   // 1 more than available
    }

    /// @dev MEDIUM-3: Only owner may freeze — investor must not be able to self-freeze
    ///      as a way to manipulate collateral accounting.
    function test_RevertWhen_FreezePartialTokens_NotOwner() public {
        vm.prank(alice);
        vm.expectRevert(FCIToken_Tesis.Unauthorized.selector);
        token.freezePartialTokens(alice, 1_000);
    }

    function test_UnfreezePartialTokens_ReducesFrozenBalance() public {
        token.freezePartialTokens(alice, 6_000);
        token.unfreezePartialTokens(alice, 2_000);
        assertEq(token.getFrozenTokens(alice),    4_000);
        assertEq(token.availableBalanceOf(alice), MINT - 4_000);
    }

    function test_UnfreezePartialTokens_EmitsEvent() public {
        token.freezePartialTokens(alice, 4_000);
        vm.expectEmit(true, false, false, true);
        emit IERC3643.TokensUnfrozen(alice, 4_000);
        token.unfreezePartialTokens(alice, 4_000);
    }

    function test_RevertWhen_UnfreezePartialTokens_ExceedsFrozen() public {
        token.freezePartialTokens(alice, 3_000);
        vm.expectRevert(FCIToken_Tesis.InsufficientFrozenBalance.selector);
        token.unfreezePartialTokens(alice, 3_001);
    }

    /// @dev MEDIUM-3: Investor must NOT be able to unfreeze their own collateral.
    function test_RevertWhen_UnfreezePartialTokens_NotOwner() public {
        token.freezePartialTokens(alice, 5_000);
        vm.prank(alice);
        vm.expectRevert(FCIToken_Tesis.Unauthorized.selector);
        token.unfreezePartialTokens(alice, 5_000);
    }

    // =========================================================
    // [G] Address-level freeze
    // =========================================================

    function test_SetAddressFrozen_FreezesAddress() public {
        token.setAddressFrozen(alice, true);
        assertTrue(token.isFrozen(alice));
    }

    function test_SetAddressFrozen_BlocksTransfer() public {
        token.setAddressFrozen(alice, true);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FCIToken_Tesis.AddressFrozenError.selector, alice));
        token.transfer(bob, 1_000);
    }

    function test_SetAddressFrozen_CanBeLifted() public {
        token.setAddressFrozen(alice, true);
        token.setAddressFrozen(alice, false);
        assertFalse(token.isFrozen(alice));
        vm.prank(alice);
        assertTrue(token.transfer(bob, 1_000));
    }

    function test_SetAddressFrozen_EmitsEvent() public {
        vm.expectEmit(true, true, true, false);
        emit IERC3643.AddressFrozen(alice, true, owner);
        token.setAddressFrozen(alice, true);
    }

    function test_RevertWhen_SetAddressFrozen_NotOwner() public {
        vm.prank(attacker);
        vm.expectRevert(FCIToken_Tesis.Unauthorized.selector);
        token.setAddressFrozen(alice, true);
    }

    // =========================================================
    // [H] Recovery address
    // =========================================================

    function test_RecoveryAddress_MovesEntireBalance() public {
        idRegistry.mockRegister(carol, aliceId, 32); // carol = alice's new wallet
        token.recoveryAddress(alice, carol, aliceId);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(carol), MINT);
    }

    /// @dev CRITICAL-1: Frozen balances must be migrated, not orphaned, after recovery.
    function test_RecoveryAddress_MigratesFrozenBalance() public {
        token.freezePartialTokens(alice, 3_000);
        idRegistry.mockRegister(carol, aliceId, 32);

        token.recoveryAddress(alice, carol, aliceId);

        // Lost wallet: all cleared
        assertEq(token.balanceOf(alice),          0);
        assertEq(token.getFrozenTokens(alice),     0);   // not orphaned
        assertEq(token.availableBalanceOf(alice),  0);   // no underflow

        // New wallet: receives full balance + freeze constraints
        assertEq(token.balanceOf(carol),          MINT);
        assertEq(token.getFrozenTokens(carol),    3_000);
        assertEq(token.availableBalanceOf(carol), MINT - 3_000);
    }

    function test_RecoveryAddress_CallsComplianceTransferred() public {
        idRegistry.mockRegister(carol, aliceId, 32);
        uint256 before = compliance.transferredCallCount();
        token.recoveryAddress(alice, carol, aliceId);
        assertEq(compliance.transferredCallCount(), before + 1);
    }

    function test_RecoveryAddress_EmitsTransferEvent() public {
        idRegistry.mockRegister(carol, aliceId, 32);
        vm.expectEmit(true, true, false, true);
        emit IERC3643.Transfer(alice, carol, MINT);
        token.recoveryAddress(alice, carol, aliceId);
    }

    /// @dev HIGH-3: _investorOnchainID must be validated — passing the wrong identity reverts.
    function test_RevertWhen_RecoveryAddress_IdentityMismatch() public {
        idRegistry.mockRegister(carol, aliceId, 32);
        vm.expectRevert(FCIToken_Tesis.IdentityMismatch.selector);
        token.recoveryAddress(alice, carol, bobId); // bobId ≠ aliceId
    }

    function test_RevertWhen_RecoveryAddress_NewWalletNotRegistered() public {
        // carol is NOT registered → contains(carol) == false
        vm.expectRevert(FCIToken_Tesis.WalletNotRegistered.selector);
        token.recoveryAddress(alice, carol, aliceId);
    }

    function test_RevertWhen_RecoveryAddress_ZeroBalance() public {
        idRegistry.mockRegister(carol, aliceId, 32);
        token.burn(alice, MINT);
        vm.expectRevert(FCIToken_Tesis.NoBalanceToRecover.selector);
        token.recoveryAddress(alice, carol, aliceId);
    }

    function test_RevertWhen_RecoveryAddress_NotOwner() public {
        idRegistry.mockRegister(carol, aliceId, 32);
        vm.prank(attacker);
        vm.expectRevert(FCIToken_Tesis.Unauthorized.selector);
        token.recoveryAddress(alice, carol, aliceId);
    }

    // =========================================================
    // [I] Pause / Unpause
    // =========================================================

    function test_Pause_SetsPausedFlag() public {
        token.pause();
        assertTrue(token.paused());
    }

    function test_Unpause_ClearsPausedFlag() public {
        token.pause();
        token.unpause();
        assertFalse(token.paused());
    }

    function test_Pause_BlocksTransfer() public {
        token.pause();
        vm.prank(alice);
        vm.expectRevert(FCIToken_Tesis.ContractPaused.selector);
        token.transfer(bob, 1_000);
    }

    function test_Unpause_RestoresTransfer() public {
        token.pause();
        token.unpause();
        vm.prank(alice);
        assertTrue(token.transfer(bob, 1_000));
    }

    function test_RevertWhen_Pause_NotOwner() public {
        vm.prank(attacker);
        vm.expectRevert(FCIToken_Tesis.Unauthorized.selector);
        token.pause();
    }

    function test_RevertWhen_Unpause_NotOwner() public {
        token.pause();
        vm.prank(attacker);
        vm.expectRevert(FCIToken_Tesis.Unauthorized.selector);
        token.unpause();
    }

    // =========================================================
    // [J] Two-step ownership transfer
    // =========================================================

    function test_TransferOwnership_SetsPendingOwner() public {
        token.transferOwnership(alice);
        assertEq(token.pendingOwner(), alice);
        assertEq(token.owner(),        owner); // not changed yet
    }

    function test_AcceptOwnership_ChangesOwner() public {
        token.transferOwnership(alice);
        vm.prank(alice);
        token.acceptOwnership();
        assertEq(token.owner(),        alice);
        assertEq(token.pendingOwner(), address(0));
    }

    function test_AcceptOwnership_NewOwnerCanMint() public {
        token.transferOwnership(alice);
        vm.startPrank(alice);
        token.acceptOwnership();
        token.mint(bob, 500);
        vm.stopPrank();
        assertEq(token.balanceOf(bob), 500);
    }

    function test_RevertWhen_TransferOwnership_ZeroAddress() public {
        vm.expectRevert(FCIToken_Tesis.ZeroAddress.selector);
        token.transferOwnership(address(0));
    }

    function test_RevertWhen_AcceptOwnership_NotPendingOwner() public {
        token.transferOwnership(alice);
        vm.prank(attacker);
        vm.expectRevert(FCIToken_Tesis.Unauthorized.selector);
        token.acceptOwnership();
    }

    function test_RevertWhen_TransferOwnership_NotOwner() public {
        vm.prank(attacker);
        vm.expectRevert(FCIToken_Tesis.Unauthorized.selector);
        token.transferOwnership(alice);
    }

    // =========================================================
    // [K] Module setters
    // =========================================================

    function test_SetIdentityRegistry_UpdatesModule() public {
        MockIdentityRegistry newReg = new MockIdentityRegistry();
        token.setIdentityRegistry(address(newReg));
        assertEq(address(token.identityRegistry()), address(newReg));
    }

    function test_SetIdentityRegistry_EmitsEvent() public {
        MockIdentityRegistry newReg = new MockIdentityRegistry();
        vm.expectEmit(true, false, false, false);
        emit FCIToken_Tesis.IdentityRegistrySet(address(newReg));
        token.setIdentityRegistry(address(newReg));
    }

    function test_RevertWhen_SetIdentityRegistry_ZeroAddress() public {
        vm.expectRevert(FCIToken_Tesis.ZeroAddress.selector);
        token.setIdentityRegistry(address(0));
    }

    function test_RevertWhen_SetIdentityRegistry_NotOwner() public {
        vm.prank(attacker);
        vm.expectRevert(FCIToken_Tesis.Unauthorized.selector);
        token.setIdentityRegistry(address(idRegistry));
    }

    function test_SetCompliance_UpdatesModule() public {
        MockCompliance newComp = new MockCompliance();
        token.setCompliance(address(newComp));
        assertEq(address(token.compliance()), address(newComp));
    }

    function test_SetCompliance_EmitsEvent() public {
        MockCompliance newComp = new MockCompliance();
        vm.expectEmit(true, false, false, false);
        emit FCIToken_Tesis.ComplianceSet(address(newComp));
        token.setCompliance(address(newComp));
    }

    function test_RevertWhen_SetCompliance_ZeroAddress() public {
        vm.expectRevert(FCIToken_Tesis.ZeroAddress.selector);
        token.setCompliance(address(0));
    }

    // =========================================================
    // [L] Token-info setters
    // =========================================================

    function test_SetName_UpdatesName() public {
        token.setName("Nuevo Nombre");
        assertEq(token.name(), "Nuevo Nombre");
    }

    function test_SetName_EmitsUpdateEvent() public {
        vm.expectEmit(false, false, false, true);
        emit IERC3643.UpdatedTokenInformation(
            "Nuevo Nombre", token.symbol(), token.decimals(), token.version(), token.onchainID()
        );
        token.setName("Nuevo Nombre");
    }

    function test_SetSymbol_UpdatesSymbol() public {
        token.setSymbol("NEWT");
        assertEq(token.symbol(), "NEWT");
    }

    function test_SetOnchainID_UpdatesOnchainID() public {
        address newId = makeAddr("newOnchainId");
        token.setOnchainID(newId);
        assertEq(token.onchainID(), newId);
    }

    function test_RevertWhen_SetName_NotOwner() public {
        vm.prank(attacker);
        vm.expectRevert(FCIToken_Tesis.Unauthorized.selector);
        token.setName("Hacked");
    }

    // =========================================================
    // [M] balanceOf / availableBalanceOf semantics
    // =========================================================

    /// @dev LOW-2: balanceOf must return the TOTAL balance (ERC-20 standard),
    ///      not the available/unfrozen portion.
    function test_BalanceOf_IncludesFrozenTokens() public {
        token.freezePartialTokens(alice, 4_000);
        assertEq(token.balanceOf(alice), MINT); // total, not 6_000
    }

    function test_AvailableBalanceOf_ExcludesFrozenTokens() public {
        token.freezePartialTokens(alice, 4_000);
        assertEq(token.availableBalanceOf(alice), MINT - 4_000);
    }

    function test_TotalSupply_EqualsBalanceSumAfterMintAndBurn() public {
        token.mint(bob, 5_000);
        token.burn(alice, 2_000);
        uint256 sumBalances = token.balanceOf(alice) + token.balanceOf(bob);
        assertEq(token.totalSupply(), sumBalances);
    }

    function test_TotalSupply_Invariant_IgnoresFreezeState() public {
        // Freezing tokens does not change totalSupply
        token.freezePartialTokens(alice, 6_000);
        assertEq(token.totalSupply(), MINT);
    }

    // =========================================================
    // [N] Fuzz tests
    // =========================================================

    function testFuzz_Mint_UpdatesSupplyAndBalance(uint128 amount) public {
        vm.assume(amount > 0);
        uint256 supplyBefore = token.totalSupply();
        token.mint(bob, amount);
        assertEq(token.totalSupply(), supplyBefore + amount);
        assertEq(token.balanceOf(bob), amount);
    }

    function testFuzz_Transfer_MovesExactAmount(uint256 amount) public {
        amount = bound(amount, 1, MINT);
        vm.prank(alice);
        token.transfer(bob, amount);
        assertEq(token.balanceOf(alice), MINT - amount);
        assertEq(token.balanceOf(bob),   amount);
    }

    /// @dev CRITICAL-1 invariant: no combination of freeze + burn should ever brick an account.
    ///      availableBalanceOf must always be computable (no underflow).
    function testFuzz_FreezeAndBurn_NeverBricksAccount(uint256 freezeAmt, uint256 burnAmt) public {
        freezeAmt = bound(freezeAmt, 0, MINT);
        burnAmt   = bound(burnAmt,   0, MINT - freezeAmt); // only available portion

        if (freezeAmt > 0) token.freezePartialTokens(alice, freezeAmt);
        if (burnAmt   > 0) token.burn(alice, burnAmt);

        // availableBalanceOf must be computable without reverting
        uint256 available = token.availableBalanceOf(alice);
        assertEq(available, MINT - freezeAmt - burnAmt);
    }

    function testFuzz_ApproveAndTransferFrom_CorrectAccountingAndAllowance(
        uint256 approved,
        uint256 spent
    ) public {
        approved = bound(approved, 1, MINT);
        spent    = bound(spent,    1, approved);

        vm.prank(alice);
        token.approve(bob, approved);

        vm.prank(bob);
        token.transferFrom(alice, carol, spent);

        assertEq(token.allowance(alice, bob), approved - spent);
        assertEq(token.balanceOf(carol),      spent);
    }

    // =========================================================
    // [O] forcedTransfer — RF-03 (mandato judicial)
    //
    // Diferencia con transfer(): omite freeze de dirección y canTransfer().
    // Diferencia con recoveryAddress(): transfiere un monto parcial, no toda
    // la billetera, y no requiere prueba de identidad.
    // =========================================================

    function test_ForcedTransfer_MovesTokens() public {
        token.forcedTransfer(alice, bob, 3_000);
        assertEq(token.balanceOf(alice), MINT - 3_000);
        assertEq(token.balanceOf(bob),   3_000);
    }

    function test_ForcedTransfer_EmitsForcedTransferAndTransferEvents() public {
        vm.expectEmit(true, true, false, true);
        emit IERC3643.ForcedTransfer(alice, bob, 3_000);
        vm.expectEmit(true, true, false, true);
        emit IERC3643.Transfer(alice, bob, 3_000);
        token.forcedTransfer(alice, bob, 3_000);
    }

    function test_ForcedTransfer_CallsComplianceTransferred() public {
        uint256 before = compliance.transferredCallCount();
        token.forcedTransfer(alice, bob, 1_000);
        assertEq(compliance.transferredCallCount(), before + 1);
    }

    /// @dev Omite el freeze de dirección del remitente — la orden judicial lo supera.
    function test_ForcedTransfer_BypassesSenderAddressFreeze() public {
        token.setAddressFrozen(alice, true);
        // transfer() revertirá; forcedTransfer() debe proceder.
        token.forcedTransfer(alice, bob, 1_000);
        assertEq(token.balanceOf(alice), MINT - 1_000);
    }

    /// @dev Omite el freeze de dirección del destinatario.
    function test_ForcedTransfer_BypassesRecipientAddressFreeze() public {
        token.setAddressFrozen(bob, true);
        token.forcedTransfer(alice, bob, 1_000);
        assertEq(token.balanceOf(bob), 1_000);
    }

    /// @dev Omite el rechazo de canTransfer() — la orden judicial supera las reglas del fondo.
    function test_ForcedTransfer_BypassesComplianceCanTransfer() public {
        compliance.setTransferAllowed(false);
        // transfer() revertirá; forcedTransfer() debe proceder.
        token.forcedTransfer(alice, bob, 1_000);
        assertEq(token.balanceOf(bob), 1_000);
    }

    /// @dev Los tokens pignorados como colateral LTV no son transferibles forzadamente.
    ///      Una orden de descongelamiento separada debe preceder a la ejecución sobre ellos.
    function test_ForcedTransfer_RespectsLTVCollateral() public {
        token.freezePartialTokens(alice, 8_000); // sólo 2_000 disponibles
        token.forcedTransfer(alice, bob, 2_000); // transfiere exactamente lo disponible
        assertEq(token.balanceOf(alice),          8_000); // colateral intacto
        assertEq(token.getFrozenTokens(alice),    8_000);
        assertEq(token.availableBalanceOf(alice), 0);
    }

    /// @dev forcedTransfer sobre tokens congelados debe revertir.
    function test_RevertWhen_ForcedTransfer_ExceedsAvailableBalance_FrozenPresent() public {
        token.freezePartialTokens(alice, 8_000); // disponible = 2_000
        vm.expectRevert(FCIToken_Tesis.InsufficientAvailableBalance.selector);
        token.forcedTransfer(alice, bob, 2_001);
    }

    function test_RevertWhen_ForcedTransfer_ExceedsTotalBalance() public {
        vm.expectRevert(FCIToken_Tesis.InsufficientAvailableBalance.selector);
        token.forcedTransfer(alice, bob, MINT + 1);
    }

    /// @dev Solo el owner (en producción: el multisig con resolución judicial) puede ejecutar.
    function test_RevertWhen_ForcedTransfer_NotOwner() public {
        vm.prank(attacker);
        vm.expectRevert(FCIToken_Tesis.Unauthorized.selector);
        token.forcedTransfer(alice, bob, 1_000);
    }

    function testFuzz_ForcedTransfer_MovesExactAmountRegardlessOfFreeze(
        uint256 freezeAmt,
        uint256 transferAmt
    ) public {
        freezeAmt   = bound(freezeAmt,   0, MINT - 1);         // deja al menos 1 disponible
        transferAmt = bound(transferAmt, 1, MINT - freezeAmt); // dentro del disponible

        if (freezeAmt > 0) token.freezePartialTokens(alice, freezeAmt);
        token.forcedTransfer(alice, bob, transferAmt);

        assertEq(token.balanceOf(alice), MINT - transferAmt);
        assertEq(token.balanceOf(bob),   transferAmt);
        // El colateral permanece intacto
        assertEq(token.getFrozenTokens(alice), freezeAmt);
    }
}
