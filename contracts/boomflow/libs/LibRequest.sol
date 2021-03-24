pragma solidity 0.5.16;
pragma experimental ABIEncoderV2;

import "./LibEIP712.sol";
import "./LibOrder.sol";

contract LibRequest is
    LibEIP712, LibOrder
{
    // solhint-disable max-line-length
    string private constant REQUEST_TYPE = "CancelRequest(Order order,uint256 nonce)Order(address userAddress,uint256 amount,uint256 price,uint256 orderType,bool side,uint256 salt,address baseAssetAddress,address quoteAssetAddress,address feeAddress,uint256 makerFeePercentage,uint256 takerFeePercentage)";
    bytes32 private constant REQUEST_TYPEHASH = keccak256(abi.encodePacked(REQUEST_TYPE));

    struct CancelRequest {
        Order order;
        uint256 nonce;
    }

    /// @dev Calculates Keccak-256 hash of the request.
    /// @param request The request structure.
    /// @return Keccak-256 EIP712 hash of the request.
    function getRequestHash(CancelRequest memory request)
        public
        view
        returns (bytes32 requestHash)
    {
        requestHash = hashEIP712Message(hashRequest(request));
        return requestHash;
    }

    /// @dev Calculates EIP712 hash of the request.
    /// @param request The request structure.
    /// @return EIP712 hash of the request.
    function hashRequest(CancelRequest memory request)
        internal
        pure
        returns (bytes32 result)
    {
        return keccak256(abi.encode(
            REQUEST_TYPEHASH,
            hashOrder(request.order),
            request.nonce
        ));
    }

}