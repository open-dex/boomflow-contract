pragma solidity 0.5.16;

import "./LibEIP712.sol";

contract LibOrder is
    LibEIP712("Boomflow")
{
    string private constant ORDER_TYPE = "Order(address userAddress,uint256 amount,uint256 price,uint256 orderType,bool side,uint256 salt,address baseAssetAddress,address quoteAssetAddress,address feeAddress,uint256 makerFeePercentage,uint256 takerFeePercentage)";
    bytes32 private constant ORDER_TYPEHASH = keccak256(abi.encodePacked(ORDER_TYPE));

    // A valid order remains fillable until it is expired, fully filled, or cancelled.
    // An order's state is unaffected by external factors, like account balances.
    enum OrderStatus {
        INVALID,                    // Default value
        INVALID_AMOUNT,             // Order does not have a valid amount
        INVALID_PRICE,              // Order does not have a valid price
        FILLABLE,                   // Order is fillable
        EXPIRED,                    // Order has already expired
        FULLY_FILLED,               // Order is fully filled
        CANCELLED,                  // Order is cancelled
        INVALID_TYPE
    }

    // solhint-disable max-line-length
    struct Order {
        address userAddress;           // Address that created the order.
        uint256 amount;
        uint256 price;
        uint256 orderType;                   // 0 is Limit, 1 is Market
        bool side;                      // Buy side is true
        uint256 salt;                   // Arbitrary number to facilitate uniqueness of the order's hash.
        address baseAssetAddress;           // Encoded data that can be decoded by a specified proxy contract when transferring makerAsset. The last byte references the id of this proxy.
        address quoteAssetAddress;           // Encoded data that can be decoded by a specified proxy contract when transferring takerAsset. The last byte references the id of this proxy.
        address feeAddress;
        uint256 makerFeePercentage;
        uint256 takerFeePercentage;
    }
    // solhint-enable max-line-length

    struct OrderInfo {
        uint8 orderStatus;                    // Status that describes order's validity and fillability.
        bytes32 orderHash;                    // EIP712 hash of the order (see LibOrder.getOrderHash).
        uint256 filledAmount;  // Amount of order that has already been filled.
    }

    // Allowed order types.
    enum OrderType {
        Limit,      // 0x00, default value
        Market      // 0x01
    }

    /// @dev Calculates Keccak-256 hash of the order.
    /// @param order The order structure.
    /// @return Keccak-256 EIP712 hash of the order.
    function getOrderHash(Order memory order)
        internal
        view
        returns (bytes32 orderHash)
    {
        orderHash = hashEIP712Message(hashOrder(order));
        return orderHash;
    }

    /// @dev Calculates EIP712 hash of the order.
    /// @param order The order structure.
    /// @return EIP712 hash of the order.
    function hashOrder(Order memory order)
        internal
        pure
        returns (bytes32 result)
    {
        // Assembly for more efficiently computing:
        /*return keccak256(abi.encode(
                ORDER_TYPEHASH,
                order.userAddress,
                order.amount,
                order.price,
                order.orderType,
                order.side,
                order.salt,
                order.baseAssetAddress,
                order.quoteAssetAddress,
                order.feeAddress,
                order.makerFeePercentage,
                order.takerFeePercentage
        ));*/

        bytes32 schemaHash = ORDER_TYPEHASH;

        assembly {
            // Assert order offset (this is an internal error that should never be triggered)
            if lt(order, 32) {
                invalid()
            }

            // Calculate memory addresses that will be swapped out before hashing
            let pos1 := sub(order, 32)

            // Backup
            let temp1 := mload(pos1)

            // Hash in place
            mstore(pos1, schemaHash)
            result := keccak256(pos1, 384)

            // Restore
            mstore(pos1, temp1)
        }

        return result;
    }

}