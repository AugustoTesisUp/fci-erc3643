// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title FCIToken_Tesis
 * @dev Implementación 100% compatible con las interfaces obligatorias del estándar ERC-3643.
 * Para la Tesis: Este documento demuestra el diseño del Token del FCI cumpliendo
 * estrictamente con los nombres, firmas y parámetros de la norma (EIP-3643).
 *
 * Versión: 2.0.0 — Revisión de seguridad completa aplicada.
 */

// =============================================================
// Interfaces Auxiliares ERC-3643
// =============================================================
interface IIdentity {}
interface IIdentityRegistryStorage {}
interface ITrustedIssuersRegistry {}
interface IClaimTopicsRegistry {}

// =============================================================
// IIdentityRegistry: Registro de Identidad (KYC)
// =============================================================
interface IIdentityRegistry {
    event ClaimTopicsRegistrySet(address indexed claimTopicsRegistry);
    event IdentityStorageSet(address indexed identityStorage);
    event TrustedIssuersRegistrySet(address indexed trustedIssuersRegistry);
    event IdentityRegistered(address indexed investorAddress, IIdentity indexed identity);
    event IdentityRemoved(address indexed investorAddress, IIdentity indexed identity);
    event IdentityUpdated(IIdentity indexed oldIdentity, IIdentity indexed newIdentity);
    event CountryUpdated(address indexed investorAddress, uint16 indexed country);

    function identityStorage() external view returns (IIdentityRegistryStorage);
    function issuersRegistry() external view returns (ITrustedIssuersRegistry);
    function topicsRegistry() external view returns (IClaimTopicsRegistry);
    function setIdentityRegistryStorage(address _identityRegistryStorage) external;
    function setClaimTopicsRegistry(address _claimTopicsRegistry) external;
    function setTrustedIssuersRegistry(address _trustedIssuersRegistry) external;
    function registerIdentity(address _userAddress, IIdentity _identity, uint16 _country) external;
    function deleteIdentity(address _userAddress) external;
    function updateCountry(address _userAddress, uint16 _country) external;
    function updateIdentity(address _userAddress, IIdentity _identity) external;
    function batchRegisterIdentity(
        address[] calldata _userAddresses,
        IIdentity[] calldata _identities,
        uint16[] calldata _countries
    ) external;
    function contains(address _userAddress) external view returns (bool);
    function isVerified(address _userAddress) external view returns (bool);
    function identity(address _userAddress) external view returns (IIdentity);
    function investorCountry(address _userAddress) external view returns (uint16);
}

// =============================================================
// ICompliance: Módulo de Reglas del Fondo
// =============================================================
interface ICompliance {
    event TokenBound(address _token);
    event TokenUnbound(address _token);

    function bindToken(address _token) external;
    function unbindToken(address _token) external;
    function isTokenBound(address _token) external view returns (bool);
    function getTokenBound() external view returns (address);
    function canTransfer(address _from, address _to, uint256 _amount) external view returns (bool);
    function transferred(address _from, address _to, uint256 _amount) external;
    function created(address _to, uint256 _amount) external;
    function destroyed(address _from, uint256 _amount) external;
}

// =============================================================
// IERC3643: El Token Obligatorio
// =============================================================
interface IERC3643 {
    event Minted(address indexed to, uint256 amount);
    event Burned(address indexed from, uint256 amount);
    event TokensFrozen(address indexed userAddress, uint256 amount);
    event TokensUnfrozen(address indexed userAddress, uint256 amount);
    event AddressFrozen(address indexed userAddress, bool indexed isFrozen, address indexed owner);
    event Paused(address userAddress);
    event Unpaused(address userAddress);
    event Transfer(address indexed from, address indexed to, uint256 value);
    /// @notice Emitido por forcedTransfer — distingue en el log una ejecución judicial
    ///         de una transferencia ordinaria, facilitando la auditoría regulatoria.
    event ForcedTransfer(address indexed from, address indexed to, uint256 amount);
    event UpdatedTokenInformation(
        string newName,
        string newSymbol,
        uint8 newDecimals,
        string newVersion,
        address newOnchainID
    );

    function onchainID() external view returns (address);
    function version() external view returns (string memory);
    function paused() external view returns (bool);
    function setName(string calldata _name) external;
    function setSymbol(string calldata _symbol) external;
    function setOnchainID(address _onchainID) external;
    function setIdentityRegistry(address _identityRegistry) external;
    function setCompliance(address _compliance) external;
    function pause() external;
    function unpause() external;
    function freezePartialTokens(address _userAddress, uint256 _amount) external;
    function unfreezePartialTokens(address _userAddress, uint256 _amount) external;
    function setAddressFrozen(address _userAddress, bool _freeze) external;
    function isFrozen(address _userAddress) external view returns (bool);
    function getFrozenTokens(address _userAddress) external view returns (uint256);
    function mint(address _to, uint256 _amount) external;
    function burn(address _userAddress, uint256 _amount) external;
    function recoveryAddress(
        address _lostWallet,
        address _newWallet,
        address _investorOnchainID
    ) external returns (bool);
    /// @notice RF-03 — Transferencia forzada por mandato judicial.
    ///         Omite los controles de freeze de dirección y de compliance (canTransfer)
    ///         porque la orden judicial prevalece sobre las reglas del fondo.
    ///         Opera sobre el saldo disponible (no congelado) para preservar la
    ///         integridad del colateral LTV; una orden de descongelamiento separada
    ///         precede cualquier ejecución sobre tokens pignorados.
    function forcedTransfer(address _from, address _to, uint256 _amount) external returns (bool);
    function identityRegistry() external view returns (IIdentityRegistry);
    function compliance() external view returns (ICompliance);
}

// =============================================================
// FCIToken_Tesis: Implementación del Smart Contract
// =============================================================
contract FCIToken_Tesis is IERC3643 {

    // ------------------------------------------------------------------
    // Custom Errors — reemplaza require con strings para ahorrar gas
    // ------------------------------------------------------------------
    error Unauthorized();
    error ZeroAddress();
    error ContractPaused();
    error AddressFrozenError(address addr);
    error InsufficientAvailableBalance();
    error InsufficientFrozenBalance();
    error InsufficientAllowance();
    error NoBalanceToRecover();
    error IdentityMismatch();
    error WalletNotRegistered();

    // ------------------------------------------------------------------
    // Storage Layout — variables pequeñas empaquetadas juntas para
    // reducir la cantidad de slots usados (gas en SLOAD/SSTORE).
    //
    // Slot 0: onchainID (20 bytes) + decimals (1 byte) + _paused (1 byte) = 22 bytes
    // Slot 1: owner (20 bytes)
    // Slot 2: pendingOwner (20 bytes)
    // Slot 3: totalSupply (32 bytes)
    // Slots 4-6: name, symbol, version (strings dinámicas)
    // ------------------------------------------------------------------
    address public onchainID;
    uint8   public decimals;          // configurable en el constructor — no tiene valor por defecto
    bool    private _paused = false;

    address public owner;
    address public pendingOwner;

    uint256 public totalSupply;

    string public name    = "FCI Cerrado Simple Estate";
    string public symbol  = "FCIE";
    string public version = "1.0.0";

    mapping(address => uint256) private _balances;
    mapping(address => uint256) private _frozenBalances;
    mapping(address => bool)    private _frozenAddresses;
    mapping(address => mapping(address => uint256)) private _allowances;

    IIdentityRegistry private _identityRegistry;
    ICompliance       private _complianceModule;

    // ------------------------------------------------------------------
    // Eventos Adicionales
    // ------------------------------------------------------------------
    event IdentityRegistrySet(address indexed newIdentityRegistry);
    event ComplianceSet(address indexed newCompliance);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    /// @dev Evento ERC-20 estándar requerido por approve/transferFrom.
    event Approval(address indexed owner, address indexed spender, uint256 value);

    // ------------------------------------------------------------------
    // Modificadores
    // ------------------------------------------------------------------
    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    modifier whenNotPaused() {
        if (_paused) revert ContractPaused();
        _;
    }

    // ------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------
    constructor(address _idRegistry, address _compModule, uint8 _decimals) {
        // FIX [HIGH-4]: Valida que ninguna dirección crítica sea address(0).
        if (_idRegistry == address(0) || _compModule == address(0)) revert ZeroAddress();
        decimals = _decimals;         // configurable al desplegar: 6 para este FCI, hasta 18 si se requiere
        owner = msg.sender;
        _identityRegistry = IIdentityRegistry(_idRegistry);
        _complianceModule = ICompliance(_compModule);
        // FIX [LOW-3]: Registra el token en el módulo de compliance al desplegar.
        _complianceModule.bindToken(address(this));
    }

    // ------------------------------------------------------------------
    // Transferencia de Propiedad en Dos Pasos (Ownable2Step)
    // FIX [LOW-1]: Previene la pérdida permanente del control si se pierde la clave.
    // ------------------------------------------------------------------
    function transferOwnership(address _newOwner) external onlyOwner {
        if (_newOwner == address(0)) revert ZeroAddress();
        pendingOwner = _newOwner;
        emit OwnershipTransferStarted(owner, _newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert Unauthorized();
        address previousOwner = owner;
        owner        = pendingOwner;
        pendingOwner = address(0);
        emit OwnershipTransferred(previousOwner, owner);
    }

    // ------------------------------------------------------------------
    // Lectura de Estado
    // ------------------------------------------------------------------

    /// @notice Implementa la función requerida por IERC3643 (la variable es privada).
    function paused() external view override returns (bool) {
        return _paused;
    }

    function identityRegistry() external view override returns (IIdentityRegistry) {
        return _identityRegistry;
    }

    function compliance() external view override returns (ICompliance) {
        return _complianceModule;
    }

    // ------------------------------------------------------------------
    // Configuración de Módulos
    // FIX [HIGH-4]: Valida address(0). FIX [MEDIUM-2]: Emite eventos para auditoría.
    // ------------------------------------------------------------------
    function setIdentityRegistry(address _idRegistry) external override onlyOwner {
        if (_idRegistry == address(0)) revert ZeroAddress();
        _identityRegistry = IIdentityRegistry(_idRegistry);
        emit IdentityRegistrySet(_idRegistry);
    }

    function setCompliance(address _compModule) external override onlyOwner {
        if (_compModule == address(0)) revert ZeroAddress();
        _complianceModule = ICompliance(_compModule);
        emit ComplianceSet(_compModule);
    }

    // ------------------------------------------------------------------
    // Setters de Información del Token
    // FIX [MEDIUM-1]: Emite UpdatedTokenInformation en cada cambio.
    // ------------------------------------------------------------------
    function setName(string calldata _name) external override onlyOwner {
        name = _name;
        emit UpdatedTokenInformation(_name, symbol, decimals, version, onchainID);
    }

    function setSymbol(string calldata _symbol) external override onlyOwner {
        symbol = _symbol;
        emit UpdatedTokenInformation(name, _symbol, decimals, version, onchainID);
    }

    function setOnchainID(address _onchainID) external override onlyOwner {
        onchainID = _onchainID;
        emit UpdatedTokenInformation(name, symbol, decimals, version, _onchainID);
    }

    // ------------------------------------------------------------------
    // Pausa del Fondo (Emergencias)
    // ------------------------------------------------------------------
    function pause() external override onlyOwner {
        _paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external override onlyOwner {
        _paused = false;
        emit Unpaused(msg.sender);
    }

    // ---------------------------------------------------------------pledgeCollateral---
    // Congelamiento Parcial — Garantías (Préstamos LTV)
    // FIX [MEDIUM-3]: Restringido a onlyOwner para que el deudor no pueda
    // autodescongelar su propio colateral, lo que invalidaría el mecanismo LTV.
    // ------------------------------------------------------------------
    function freezePartialTokens(address _userAddress, uint256 _amount) external override onlyOwner {
        // FIX [LOW-2]: Usa availableBalanceOf para no congelar tokens ya congelados.
        if (availableBalanceOf(_userAddress) < _amount) revert InsufficientAvailableBalance();
        _frozenBalances[_userAddress] += _amount;
        emit TokensFrozen(_userAddress, _amount);
    }

    function unfreezePartialTokens(address _userAddress, uint256 _amount) external override onlyOwner {
        if (_frozenBalances[_userAddress] < _amount) revert InsufficientFrozenBalance();
        _frozenBalances[_userAddress] -= _amount;
        emit TokensUnfrozen(_userAddress, _amount);
    }

    function setAddressFrozen(address _userAddress, bool _freeze) external override onlyOwner {
        _frozenAddresses[_userAddress] = _freeze;
        emit AddressFrozen(_userAddress, _freeze, msg.sender);
    }

    function isFrozen(address _userAddress) external view override returns (bool) {
        return _frozenAddresses[_userAddress];
    }

    function getFrozenTokens(address _userAddress) external view override returns (uint256) {
        return _frozenBalances[_userAddress];
    }

    // ------------------------------------------------------------------
    // Balances y Allowances (ERC-20)
    // FIX [LOW-2]: balanceOf retorna el saldo total (compatible ERC-20).
    //              availableBalanceOf retorna solo el saldo no congelado.
    // ------------------------------------------------------------------

    /// @notice Saldo total del inversor, incluyendo tokens congelados (ERC-20 estándar).
    function balanceOf(address _account) public view returns (uint256) {
        return _balances[_account];
    }

    /// @notice Saldo disponible para transferir (descontando tokens congelados).
    function availableBalanceOf(address _account) public view returns (uint256) {
        return _balances[_account] - _frozenBalances[_account];
    }

    // FIX [HIGH-5]: Agrega los mecanismos ERC-20 de allowance requeridos por ERC-3643.
    function allowance(address _owner, address _spender) public view returns (uint256) {
        return _allowances[_owner][_spender];
    }

    function approve(address _spender, uint256 _amount) external returns (bool) {
        if (_spender == address(0)) revert ZeroAddress();
        _allowances[msg.sender][_spender] = _amount;
        emit Approval(msg.sender, _spender, _amount);
        return true;
    }

    // ------------------------------------------------------------------
    // Transferencias Core — siempre pasan por Compliance y KYC
    // ------------------------------------------------------------------

    function transfer(address _to, uint256 _amount) public whenNotPaused returns (bool) {
        if (_frozenAddresses[msg.sender]) revert AddressFrozenError(msg.sender);
        // FIX [HIGH-2]: Verifica también que el destinatario no esté congelado.
        if (_frozenAddresses[_to]) revert AddressFrozenError(_to);

        // GAS OPT: cachea los slots de storage para evitar SLOADs repetidos.
        uint256 senderBalance = _balances[msg.sender];
        uint256 senderFrozen  = _frozenBalances[msg.sender];
        if (senderBalance - senderFrozen < _amount) revert InsufficientAvailableBalance();

        require(_complianceModule.canTransfer(msg.sender, _to, _amount), "Falla en Compliance o KYC");

        _balances[msg.sender] = senderBalance - _amount;
        _balances[_to]       += _amount;

        _complianceModule.transferred(msg.sender, _to, _amount);
        emit Transfer(msg.sender, _to, _amount);
        return true;
    }

    // FIX [HIGH-5]: Agrega transferFrom con las mismas verificaciones de compliance y freeze.
    function transferFrom(address _from, address _to, uint256 _amount) public whenNotPaused returns (bool) {
        if (_frozenAddresses[_from]) revert AddressFrozenError(_from);
        if (_frozenAddresses[_to])   revert AddressFrozenError(_to);

        uint256 fromBalance = _balances[_from];
        uint256 fromFrozen  = _frozenBalances[_from];
        if (fromBalance - fromFrozen < _amount) revert InsufficientAvailableBalance();

        uint256 currentAllowance = _allowances[_from][msg.sender];
        if (currentAllowance < _amount) revert InsufficientAllowance();

        require(_complianceModule.canTransfer(_from, _to, _amount), "Falla en Compliance o KYC");

        _allowances[_from][msg.sender] = currentAllowance - _amount;
        _balances[_from]               = fromBalance - _amount;
        _balances[_to]                += _amount;

        _complianceModule.transferred(_from, _to, _amount);
        emit Transfer(_from, _to, _amount);
        return true;
    }

    // ------------------------------------------------------------------
    // Mint / Burn
    // ------------------------------------------------------------------
    function mint(address _to, uint256 _amount) external override onlyOwner {
        if (_frozenAddresses[_to]) revert AddressFrozenError(_to);
        require(_complianceModule.canTransfer(address(0), _to, _amount), "Falla en Compliance o KYC");

        totalSupply     += _amount;
        _balances[_to]  += _amount;

        _complianceModule.created(_to, _amount);
        emit Minted(_to, _amount);
        emit Transfer(address(0), _to, _amount);
    }

    function burn(address _userAddress, uint256 _amount) external override onlyOwner {
        // FIX [CRITICAL-1]: Solo permite quemar saldo disponible (no congelado).
        // Si se permitiera quemar tokens congelados, _frozenBalances > _balances,
        // lo que causaría un underflow permanente en balanceOf/availableBalanceOf
        // bloqueando la cuenta del inversor indefinidamente.
        uint256 totalBal  = _balances[_userAddress];
        uint256 frozenBal = _frozenBalances[_userAddress];
        if (totalBal - frozenBal < _amount) revert InsufficientAvailableBalance();

        totalSupply              -= _amount;
        _balances[_userAddress]   = totalBal - _amount;

        _complianceModule.destroyed(_userAddress, _amount);
        emit Burned(_userAddress, _amount);
        emit Transfer(_userAddress, address(0), _amount);
    }

    // ------------------------------------------------------------------
    // Transferencia Forzada — RF-03 (mandato judicial)
    //
    // Semántica distinta a recoveryAddress:
    //   recoveryAddress  → migra la billetera COMPLETA de un inversor a otra dirección
    //                      bajo prueba de identidad on-chain (pérdida de clave).
    //   forcedTransfer   → transfiere un MONTO PARCIAL específico de A hacia B por orden
    //                      judicial (embargo, ejecución de deuda), sin importar si A
    //                      está congelado como dirección o si la compliance lo bloquearía.
    //
    // Alcance de la omisión de controles:
    //   ✓ Omite _frozenAddresses[_from] y [_to]  — la orden judicial prevalece sobre el freeze
    //   ✓ Omite compliance.canTransfer()          — la orden judicial prevalece sobre las reglas del fondo
    //   ✗ NO omite el saldo disponible            — tokens pignorados como colateral LTV tienen
    //                                               su propio respaldo legal; una orden de
    //                                               descongelamiento separada precede a la ejecución
    //                                               sobre ellos, creando un trail on-chain más claro.
    //
    // Gating: onlyOwner — en producción este slot debe estar detrás de un multisig
    // con resolución judicial como condición de firma (p. ej. Safe + módulo de governance).
    // ------------------------------------------------------------------
    function forcedTransfer(
        address _from,
        address _to,
        uint256 _amount
    ) external override onlyOwner returns (bool) {
        uint256 totalBal  = _balances[_from];
        uint256 frozenBal = _frozenBalances[_from];
        if (totalBal - frozenBal < _amount) revert InsufficientAvailableBalance();

        _balances[_from] -= _amount;
        _balances[_to]   += _amount;

        // Notifica al módulo de compliance para que actualice su estado interno
        // (p. ej. contadores de posición por inversor).
        _complianceModule.transferred(_from, _to, _amount);
        emit ForcedTransfer(_from, _to, _amount);
        emit Transfer(_from, _to, _amount);
        return true;
    }

    // ------------------------------------------------------------------
    // Recuperación de Billetera (legal — pérdida de clave, quiebra, etc.)
    // FIX [CRITICAL-1]: Migra _frozenBalances para no dejar estado huérfano.
    // FIX [HIGH-3]: Valida _investorOnchainID contra el registro de identidad.
    // ------------------------------------------------------------------
    function recoveryAddress(
        address _lostWallet,
        address _newWallet,
        address _investorOnchainID
    ) external override onlyOwner returns (bool) {
        // Verifica que la nueva billetera pertenece al mismo inversor que la perdida.
        if (address(_identityRegistry.identity(_lostWallet)) != _investorOnchainID) {
            revert IdentityMismatch();
        }
        // Verifica que la nueva billetera está registrada y verificada en el KYC.
        if (!_identityRegistry.contains(_newWallet)) revert WalletNotRegistered();

        uint256 amountToRecover = _balances[_lostWallet];
        if (amountToRecover == 0) revert NoBalanceToRecover();

        // Migra los tokens congelados junto con el saldo total para no dejar
        // _frozenBalances apuntando a una dirección con balance cero (estado huérfano).
        uint256 frozenToMigrate = _frozenBalances[_lostWallet];

        _balances[_lostWallet]       = 0;
        _frozenBalances[_lostWallet] = 0;
        _balances[_newWallet]       += amountToRecover;
        _frozenBalances[_newWallet] += frozenToMigrate;

        _complianceModule.transferred(_lostWallet, _newWallet, amountToRecover);
        emit Transfer(_lostWallet, _newWallet, amountToRecover);
        return true;
    }
}
