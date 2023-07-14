pragma solidity 0.5.16;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/access/roles/WhitelistAdminRole.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC777/IERC777Recipient.sol";
import "@openzeppelin/contracts/introspection/IERC1820Registry.sol";
import "@openzeppelin/contracts/lifecycle/Pausable.sol";

import "./ICRCL.sol";
import "./TimeLock.sol";
import "../ERC777/IWrappedCfx.sol";
import "../ERC777/ITokenBase.sol";
import "./libs/LibEIP712.sol";
import "./libs/LibRequest.sol";
import "../boomflow/libs/LibSignatureValidator.sol";
import "../ERC1820Context.sol";

contract CRCL is ICRCL, WhitelistAdminRole, TimeLock, IERC777Recipient, LibSignatureValidator, LibRequest, Pausable, ERC1820Context {
    using SafeMath for uint256;

    string _name;
    string _symbol;
    uint256 _decimals;

    address _tokenAddr;
    address _boomflow;

    bool _isCFX;

    uint256 private _totalSupply;
    mapping (address => uint256) private _balances;

    // Mapping of requestHash => timestamp; request hash only shows
    // up if it is completed
    mapping (bytes32 => uint256) public timestamps;

    // Current min timestamp for valid requests
    uint256 private _timestamp;

    constructor (string memory name, string memory symbol, uint8 decimals, address tokenAddr, address boomflow, uint256 deferTime, bool isCFX)
        TimeLock(deferTime) public {
        _name = name;
        _symbol = symbol;
        _decimals = decimals;
        _tokenAddr = tokenAddr;
        _boomflow = boomflow;
        _isCFX = isCFX;

        ERC1820_REGISTRY.setInterfaceImplementer(address(this), keccak256("ERC777TokensRecipient"), address(this));
    }

    // -------------------- Getters --------------------

    function name() public view returns (string memory) {
        return _name;
    }

    function symbol() public view returns (string memory) {
        return _symbol;
    }

    function decimals() public view returns (uint256) {
        return _decimals;
    }

    function totalSupply() public view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view returns (uint256) {
        return _balances[account];
    }

    function getTokenAddress() public view returns (address) {
        return _tokenAddr;
    }

    function getBoomflow() public view returns (address) {
        return _boomflow;
    }

    //----------------- Storage Optimization ---------------
    function getTimestamp() public view returns (uint256) {
        return _timestamp;
    }

    function setTimestamp(uint256 newTimestamp)
        public
        onlyWhitelistAdmin
    {
        require(newTimestamp > _timestamp, "INVALID_NEW_TIMESTAMP");
        _timestamp = newTimestamp;
    }

    function removeObsoleteData(bytes32[] memory hashes)
        public
        onlyWhitelistAdmin
    {
        for (uint i = 0; i < hashes.length; i++) {
            // Request hash is finished
            require(timestamps[hashes[i]] != 0, "INVALID_FINISHED_STATUS");

            // Request timestamp is lower than current timestamp
            require(timestamps[hashes[i]] < _timestamp, "INVALID_TIMESTAMP");

            // Remove requst data
            removeData(hashes[i]);
        }
    }

    function removeData(bytes32 requestHash) internal {
        if (timestamps[requestHash] != 0) delete timestamps[requestHash];
    }
    //----------------- End Storage Optimization -----------

    /**
     * Transfer the amount of token from sender to recipient.
     * Only `boomflow` contract have the access permission.
     * Emits an {Transfer} event indicating the amount transferred.
     *
     * Requirements:
     * - `msg.sender` must be the `boomflow` contract.
     * - `sender` and `recipient` cannot be the zero address.
     * - `sender` must have a balance of at least `amount`.
     */
    function transferFrom(address sender, address recipient, uint256 amount) public whenNotPaused {
        require(_msgSender() == _boomflow, "CRCL: boomflow required");
        require(sender != address(0), "CRCL: transfer from the zero address");
        require(recipient != address(0), "CRCL: transfer to the zero address");

        if (amount > 0) {
            _transfer(sender, recipient, amount);
        }
    }

    /**
     * Transfer tokens from one sender to a list of recipients according to a list of amounts.
     * Only WhitelistAdmin have the access permission.
     * Emits an {Transfer} event indicating the amount transferred.
     *
     * Requirements:
     * - `request.userAddress` cannot be zero address.
     * - `request.amounts` and `request.recipients` must have the same length.
     */
    function transferFor(TransferRequest memory request, bytes memory signature) public onlyWhitelistAdmin whenNotPaused {
        require(request.userAddress != address(0), "CRCL: transfer for zero address");
        require(request.amounts.length == request.recipients.length, "CRCL: amount length mismatch");

        bytes32 requestHash = getTransferRequestHash(request);
        require(isValidSignature(requestHash, request.userAddress,signature), "CRCL: INVALID_TRANSFER_SIGNATURE");

        // Validate timestamp
        require(request.nonce >= _timestamp, "CRCL: request expired");
        timestamps[requestHash] = request.nonce;

        for (uint i = 0; i < request.recipients.length; i++) {
            _transfer(request.userAddress, request.recipients[i], request.amounts[i]);
        }
    }

    // Implement ERC777Recipient interface for users to deposit.
    function tokensReceived(
        address,
        address from,
        address to,
        uint256 amount,
        bytes memory userData,
        bytes memory
    )
        public
        whenNotPaused
    {
        require(_msgSender() == _tokenAddr, "CRCL: deposit not authorized");
        require(to == address(this), "CRCL: deposit not to CRCL");

        // Recover the recipient address
        require(userData.length == 20, "CRCL: userData should be an address");
        address addr = address(0);
        assembly {
            addr := mload(add(userData, 20))
        }

        require(addr != address(0), "CRCL: deposit to zero address");
        _deposit(from, addr, amount);
    }

    function deposit(address to, uint256 amount) public whenNotPaused {
        require(to != address(0), "CRCL: deposit to zero address");
        IERC20(_tokenAddr).transferFrom(_msgSender(), address(this), amount);
        _deposit(_msgSender(), to, amount);
    }

    /**
     * Withdraw the amount of token from sender's CRCL to recipient's ERC777 asset.
     * Only WhitelistAdmin (DEX) have the access permission.
     * The function will atomically perform the following operations:
     *
     *      1. Validate the user signature
     *      2. Burn `request.amount` of CRCL token from `request.userAddress`
     *      3. Transfer equal amount of ERC777 token from the contract address to `request.recipient`
     *
     * The ERC777 token emits a {Transfer} event indicating the amount transferred.
     * The CRCL token emits a {Withdraw} event indicating the amount withdrawn.
     *
     * Requirements:
     * - The request hash has to be unique.
     */
    function withdraw(WithdrawRequest memory request, bytes memory signature) public onlyWhitelistAdmin whenNotPaused {
        // Validate the user signature
        bytes32 requestHash = getRequestHash(request);
        require(isValidSignature(requestHash,request.userAddress,signature), "INVALID_WITHDRAW_SIGNATURE");

        // Validate timestamp
        require(request.nonce >= _timestamp, "CRCL: request expired");
        timestamps[requestHash] = request.nonce;

        // unless for DEX-CFX in which case isCrosschain == true will
        // withdraw directly to CFX instead of WCFX.
        require(!request.burn || _isCFX, "CRCL: should call withdrawCrossChain");

        // Special handling to withdraw WCFX => CFX
        if (request.burn) {
            // Burn the `request.amount` of WCFX from the current CRCL address, and receive CFX
            IWrappedCfx(_tokenAddr).burn(request.amount, abi.encodePacked(request.recipient));

            // Burn the `request.amount` of CRCL from the `request.userAddress`
            _burn(request.userAddress, request.amount);
        } else {
            // Withdraw the `request.amount` of CRCL
            _withdraw(request.userAddress, request.recipient, request.amount);
        }
    }

    /**
     * Withdraw the amount of token from sender's CRCL to recipient's crosschain asset.
     * Only WhitelistAdmin (DEX) have the access permission.
     * The function will atomically perform the following operations:
     *
     *      1. Validate the user signature
     *      2. Burn `request.amount` of CRCL token from `request.userAddress`
     *      3. Burn equal amount of ERC777 token from the contract address
     *
     * Note that For the full-fledged crosschain withdraw, we are depending
     * on Custodian counterparts to perform the actual crosschain operations
     *
     * The ERC777 token emits a {Burned} event indicating the amount withdrawn.
     * The CRCL token emits a {Transfer} to null address event indicating the amount withdrawn.
     *
     * Requirements:
     * - The request hash has to be unique.
     */
    function withdrawCrossChain(WithdrawCrossChainRequest memory request, bytes memory signature) public onlyWhitelistAdmin whenNotPaused {
        // Validate the user signature
        bytes32 requestHash = getWithdrawCrossChainRequestHash(request);
        require(isValidSignature(requestHash,request.userAddress,signature), "INVALID_WITHDRAW_SIGNATURE");

        // Validate timestamp
        require(request.nonce >= _timestamp, "CRCL: request expired");
        timestamps[requestHash] = request.nonce;

        // Burn the `request.amount` of ERC777 from the current CRCL address
        ITokenBase(_tokenAddr).burn(request.userAddress, request.amount, request.fee, request.recipient, request.defiRelayer);

        // Burn the `request.amount` of CRCL from the `request.userAddress`
        _burn(request.userAddress, request.amount);
    }

    /**
     * Request for a force withdraw of all sender's CRCL token.
     * The function acknowledges the request and records the request time.
     *
     * Emits a {ScheduleWithdraw} event indicating the withdraw has been scheduled.
     */
    function requestForceWithdraw() public {
        setScheduleTime(_msgSender(), block.timestamp);
    }

    /**
     * Force withdraw all msg.sender's CRCL token to recipient's ERC20 token.
     * The function acknowledges the request and records the request time.
     *
     * Emits a {Withdraw} event indicating the amount withdrawn.
     */
    function forceWithdraw(address recipient) public withdrawRequested pastTimeLock {
        _withdraw(_msgSender(), recipient, _balances[_msgSender()]);

        setScheduleTime(_msgSender(), 0);
    }

    /**
     * Pause the majority of functionalities of CRCL.
     * Only WhitelistAdmin (DEX) have the access permission.
     *
     * Note that `requestForceWithdraw` and `forceWithdraw` is not subject to pause
     */
    function Pause() public onlyWhitelistAdmin {
        pause();
    }

    /**
     * Resume all paused functionalities of Boomflow.
     * Only WhitelistAdmin (DEX) have the access permission.
     */
    function Resume() public onlyWhitelistAdmin {
        unpause();
    }

    //Helper Functions
    function _transfer(address sender, address recipient, uint256 amount) internal {
        _balances[sender] = _balances[sender].sub(amount, "CRCL: transfer amount exceeds locked balance");
        _balances[recipient] = _balances[recipient].add(amount);
        emit Transfer(sender, recipient, amount);
    }

    function _mint(address account, uint256 amount) internal {
        require(account != address(0), "CRCL: mint to the zero address");
        _totalSupply = _totalSupply.add(amount);
        _balances[account] = _balances[account].add(amount);
        emit Transfer(address(0), account, amount);
    }

    function _burn(address account, uint256 amount) internal {
        require(account != address(0), "CRCL: burn from the zero address");

        _balances[account] = _balances[account].sub(amount, "CRCL: burn amount exceeds balance");
        _totalSupply = _totalSupply.sub(amount);
        emit Transfer(account, address(0), amount);
    }

    function _deposit(address sender, address recipient, uint256 amount) internal {
        require(recipient != address(0), "CRCL: deposit to the zero address");
        require(sender != address(this), "CRCL: deposit from the CRCL address");

        _mint(recipient, amount);

        emit Deposit(sender, recipient, amount);
    }

    function _withdraw(address sender, address recipient, uint256 amount) internal {
        _burn(sender, amount);
        IERC20(_tokenAddr).transfer(recipient, amount);
        emit Withdraw(sender, recipient, amount);
    }

    function _min(uint256 value1, uint256 value2) internal pure returns (uint256) {
        if (value1 > value2) {
            return value2;
        }
        return value1;
    }
}
