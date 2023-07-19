pragma solidity 0.5.16;
pragma experimental ABIEncoderV2;

import "../../boomflow/libs/LibEIP712.sol";

contract CRCLRequest is
    LibEIP712("CRCL")
{
    // solhint-disable max-line-length
    // Withdraw type hash
    string private constant REQUEST_TYPE = "WithdrawRequest(address userAddress,uint256 amount,address recipient,bool burn,uint256 nonce)";
    bytes32 private constant REQUEST_TYPEHASH = keccak256(abi.encodePacked(REQUEST_TYPE));

    // Crosschain withdraw type hash
    string private constant WITHDRAW_CROSSCHAIN_REQUEST_TYPE = "WithdrawRequest(address userAddress,uint256 amount,string recipient,address defiRelayer,uint256 fee,uint256 nonce)";
    bytes32 private constant WITHDRAW_CROSSCHAIN_REQUEST_TYPEHASH = keccak256(abi.encodePacked(WITHDRAW_CROSSCHAIN_REQUEST_TYPE));

    // Transfer type hash
    string private constant TRANSFER_REQUEST_TYPE = "TransferRequest(address userAddress,uint256[] amounts,address[] recipients,uint256 nonce)";
    bytes32 private constant TRANSFER_REQUEST_TYPEHASH = keccak256(abi.encodePacked(TRANSFER_REQUEST_TYPE));

    struct WithdrawRequest {
        address userAddress;
        uint256 amount;
        address recipient;
        bool burn;
        uint256 nonce;
    }

    struct WithdrawCrossChainRequest {
        address userAddress;
        uint256 amount;
        string recipient;
        address defiRelayer;
        uint256 fee;
        uint256 nonce;
    }

     struct TransferRequest {
        address userAddress;
        uint256[] amounts;
        address[] recipients;
        uint256 nonce;
    }

    /// @dev Calculates Keccak-256 hash of the withdraw request.
    /// @param request The request structure.
    /// @return Keccak-256 EIP712 hash of the withdraw request.
    function getRequestHash(WithdrawRequest memory request)
        public
        view
        returns (bytes32 requestHash)
    {
        requestHash = hashEIP712Message(hashRequest(request));
        return requestHash;
    }

    /// @dev Calculates Keccak-256 hash of the crosschain withdraw request.
    /// @param request The request structure.
    /// @return Keccak-256 EIP712 hash of the crosschain withdraw request.
    function getWithdrawCrossChainRequestHash(WithdrawCrossChainRequest memory request)
        public
        view
        returns (bytes32 requestHash)
    {
        requestHash = hashEIP712Message(hashWithdrawCrossChainRequest(request));
        return requestHash;
    }

    /// @dev Calculates Keccak-256 hash of the transfer request.
    /// @param request The request structure.
    /// @return Keccak-256 EIP712 hash of the transfer request.
    function getTransferRequestHash(TransferRequest memory request)
        public
        view
        returns (bytes32 requestHash)
    {
        requestHash = hashEIP712Message(hashTransferRequest(request));
        return requestHash;
    }

    /// @dev Calculates EIP712 hash of the withdraw request.
    /// @param request The request structure.
    /// @return EIP712 hash of the withdraw request.
    function hashRequest(WithdrawRequest memory request)
        internal
        pure
        returns (bytes32 result)
    {
        return keccak256(abi.encode(
            REQUEST_TYPEHASH,
            request.userAddress,
            request.amount,
            request.recipient,
            request.burn,
            request.nonce
        ));
    }

    /// @dev Calculates EIP712 hash of the crosschain withdraw request.
    /// @param request The request structure.
    /// @return EIP712 hash of the crosschain withdraw request.
    function hashWithdrawCrossChainRequest(WithdrawCrossChainRequest memory request)
        internal
        pure
        returns (bytes32 result)
    {
        return keccak256(abi.encode(
            WITHDRAW_CROSSCHAIN_REQUEST_TYPEHASH,
            request.userAddress,
            request.amount,
            keccak256(abi.encodePacked(request.recipient)),
            request.defiRelayer,
            request.fee,
            request.nonce
        ));
    }

    /// @dev Calculates EIP712 hash of the transfer request.
    /// @param request The request structure.
    /// @return EIP712 hash of the transfer request.
    function hashTransferRequest(TransferRequest memory request)
        internal
        pure
        returns (bytes32 result)
    {
        return keccak256(abi.encode(
            TRANSFER_REQUEST_TYPEHASH,
            request.userAddress,
            keccak256(abi.encodePacked(request.amounts)),
            keccak256(abi.encodePacked(request.recipients)),
            request.nonce
        ));
    }
}