pragma solidity 0.5.16;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/access/roles/WhitelistAdminRole.sol";
import "@openzeppelin/contracts/access/roles/WhitelistedRole.sol";
import "@openzeppelin/contracts/lifecycle/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "../crc-l/ICRCL.sol";
import "./libs/LibFillResults.sol";
import "./libs/LibSignatureValidator.sol";
import "./libs/LibRequest.sol";

contract Boomflow is WhitelistAdminRole, WhitelistedRole, ReentrancyGuard, LibSignatureValidator, LibRequest, Pausable {
    using SafeMath for uint;

    // Contract fee cannot float over 30%
    uint256 public constant MAX_CONTRACT_FEE = 3 * 10 ** 17;

    // Fill event is emitted whenever an order is filled.
    event Fill(
        bytes32 orderHash,                  // Order's hash
        uint256 fee,                        // Fee order creator to pay
        uint256 contractFee,                // Fee order creator pay for contract
        address contractFeeAddress,         // Address to receive contract fee
        address matcherAddress,             // DEX operator that submitted the order
        uint256 tradeAmount                 // Total amount traded
    );

    // Mapping of orderHash => amount of baseAsset already sold by user; for Market Buy, it is in amount of quoteAsset
    mapping (bytes32 => uint256) public filled;

    // Mapping of orderHash => max amount of baseAsset from user; for Market Buy, it is in amount of quoteAsset
    mapping (bytes32 => uint256) public max;

    // Mapping of orderHash => cancelled
    mapping (bytes32 => bool) public cancelled;

    // Mapping of orderHash => timestamp; order hash only shows
    // up if it's status is one of (cancelled or finalized or filled)
    mapping (bytes32 => uint256) public timestamps;

    // Mapping of orderHash => recorded order
    mapping (bytes32 => bool) public recorded;

    // Current min timestamp for valid orders
    uint256 public timestamp = 0;

    // Contract Fee Percentage
    uint256 public makerFeePercentage = 0;
    uint256 public takerFeePercentage = 0;

    // Contract Fee Lock Period
    uint public lastTime;
    uint public minimumLockTime = 24 hours; // default minimum waiting period after issuing synths

    // DeFi Oracle
    struct Volumes {
        uint256 baseVolume;
        uint256 quoteVolume;
    }

    mapping (bytes32 => uint256) public lastestPrice;
    mapping (bytes32 => uint256) public lastestCount;
    mapping (bytes32 => Volumes) public lastestVolume;

    constructor () public {
        addWhitelisted(_msgSender());
        Pause();
    }

    struct OrderData {
        uint256 filled;
        uint256 max;
        bool cancelled;
        bool flag; // whether recorded
    }

    function getOrderData(bytes32 orderHash)
        public
        view
        returns (OrderData memory orderData)
    {
        orderData = OrderData({
            filled: filled[orderHash],
            max: max[orderHash],
            cancelled: cancelled[orderHash],
            flag: recorded[orderHash]
        });
    }

    //----------------- Storage Optimization ---------------
    function getTimestamp() public view returns (uint256) {
        return timestamp;
    }

    /**
     * Upload the unmatched order hashes.
     * The function should be called prior to `setTimestamp`
     * Only onlyWhitelistAdmin (DEX) have the access permission.
     */
    function recordOrders(
        Order[] memory orders
    )
        public
        onlyWhitelistAdmin
    {
        for (uint i = 0; i < orders.length; i++) {
            // timestamp check
            if (orders[i].salt >= timestamp) {
                bytes32 orderHash = getOrderHash(orders[i]);
                recorded[orderHash] = true;
            }
        }
    }

    function setTimestamp(uint256 newTimestamp)
        public
        onlyWhitelistAdmin
    {
        require(newTimestamp > timestamp, "INVALID_NEW_TIMESTAMP");
        timestamp = newTimestamp;
    }

    function removeObsoleteData(bytes32[] memory hashes)
        public
        onlyWhitelistAdmin
    {
        for (uint i = 0; i < hashes.length; i++) {
            // Order timestamp is lower than current timestamp
            require(timestamps[hashes[i]] < timestamp, "INVALID_TIMESTAMP");

            // Remove order data
            removeData(hashes[i]);
        }
    }

    function removeData(bytes32 orderHash) internal {
        if (filled[orderHash] != 0) delete filled[orderHash];
        if (max[orderHash] != 0) delete max[orderHash];
        if (cancelled[orderHash]) delete cancelled[orderHash];
        if (recorded[orderHash]) delete recorded[orderHash];
        if (timestamps[orderHash] != 0) delete timestamps[orderHash];
    }
    //----------------- End Storage Optimization -----------

    //----------------- DeFi Index -------------------------
    function getPrice(address baseAssetAddress, address quoteAssetAddress) public view returns (uint256 price) {
        bytes32 pairHash = keccak256(abi.encodePacked(baseAssetAddress, quoteAssetAddress));
        price = lastestPrice[pairHash];
    }

    function getCount(address baseAssetAddress, address quoteAssetAddress) public view returns (uint256 count) {
        bytes32 pairHash = keccak256(abi.encodePacked(baseAssetAddress, quoteAssetAddress));
        count = lastestCount[pairHash];
    }

    function getVolume(address baseAssetAddress, address quoteAssetAddress) public view returns (uint256 baseVolume, uint256 quoteVolume) {
        bytes32 pairHash = keccak256(abi.encodePacked(baseAssetAddress, quoteAssetAddress));
        baseVolume = lastestVolume[pairHash].baseVolume;
        quoteVolume = lastestVolume[pairHash].quoteVolume;
    }

    function _updatePriceAndCountAndVolume(
        Order memory makerOrder,
        LibFillResults.MatchedFillResults memory matchedFillResults
    )
        internal
    {
        bytes32 pairHash = keccak256(abi.encodePacked(makerOrder.baseAssetAddress, makerOrder.quoteAssetAddress));

        lastestPrice[pairHash] = makerOrder.price;

        lastestCount[pairHash] = lastestCount[pairHash].add(1);

        lastestVolume[pairHash].baseVolume = lastestVolume[pairHash].baseVolume.add(matchedFillResults.tradeAmount);
        lastestVolume[pairHash].quoteVolume = lastestVolume[pairHash].quoteVolume.add(matchedFillResults.tradeFunds);
    }

    //----------------- End DeFi Index ---------------------

    /**
     * Execute orders in batches.
     * Only Whitelistlisted (DEX) have the access permission.
     *
     * The function will iteratively execute each pair of orders
     */
    function batchExecuteTrade(
        Order[] memory makerOrders,
        Order[] memory takerOrders,
        bytes[] memory makerSignatures,
        bytes[] memory takerSignatures,
        LibFillResults.Context[] memory contexts
    )
        public
        onlyWhitelisted
        whenNotPaused
        nonReentrant
    {
        require(makerOrders.length == takerOrders.length, "ORDER_LENGTH_MISMATCH");
        require(makerOrders.length == makerSignatures.length, "MAKER_SIGNATURE_LENGTH_MISMATCH");
        require(takerOrders.length == takerSignatures.length, "TAKER_SIGNATURE_LENGTH_MISMATCH");
        require(makerOrders.length == contexts.length, "CONTEXT_LENGTH_MISMATCH");

        LibFillResults.MatchedFillResults memory matchedFillResults;
        for(uint i = 0; i < makerOrders.length; i++){
            _setContractFee(contexts[i].makerContractFee, contexts[i].takerContractFee);

            matchedFillResults = _executeTrade(makerOrders[i], takerOrders[i], makerSignatures[i], takerSignatures[i], contexts[i]);

            _updatePriceAndCountAndVolume(makerOrders[i], matchedFillResults);
        }
    }

    /**
     * Execute the exchange between a maker order and a taker order.
     * Only Whitelistlisted (DEX) have the access permission.
     */
    function executeTrade(
        Order memory makerOrder,
        Order memory takerOrder,
        bytes memory makerSignature,
        bytes memory takerSignature,
        LibFillResults.Context memory context
    )
        public
        onlyWhitelisted
        whenNotPaused
        nonReentrant
        returns (LibFillResults.MatchedFillResults memory matchedFillResults)
    {
        _setContractFee(context.makerContractFee, context.takerContractFee);

        matchedFillResults = _executeTrade(makerOrder, takerOrder, makerSignature, takerSignature, context);

        _updatePriceAndCountAndVolume(makerOrder, matchedFillResults);
    }

    /**
     * Cancel orders in batches.
     * Only Whitelistlisted (DEX) have the access permission.
     *
     * The function will iteratively cancel each order specified
     */
    function cancelOrders(CancelRequest[] memory requests, bytes[] memory signatures)
        public
        onlyWhitelisted
        whenNotPaused
    {
        require(requests.length == signatures.length, "INVALID_SIGNATURE_LENGTH");
        for(uint i = 0; i < requests.length; i++){
            cancelOrder(requests[i], signatures[i]);
        }
    }

    /**
     * Cancel an order with user-signed request.
     * Only Whitelistlisted (DEX) have the access permission.
     *
     * The function will cancel a single order
     */
    function cancelOrder(CancelRequest memory request, bytes memory signature)
        public
        onlyWhitelisted
        whenNotPaused
    {
        // Validate user signature
        bytes32 requestHash = getRequestHash(request);
        require(isValidSignature(requestHash,request.order.userAddress,signature), "INVALID_CANCEL_SIGNATURE");

        bytes32 orderHash = getOrderHash(request.order);

        cancelled[orderHash] = true;
        timestamps[orderHash] = request.order.salt;
    }

    /**
     * Cancel an order without user-signed request.
     * Only Whitelistlisted (DEX) have the access permission.
     *
     * The function will cancel a single order when DEX decides that there are
     * no more matching orders available
     */
    function finalizeOrder(Order memory order, bytes memory signature)
        public
        onlyWhitelisted
        whenNotPaused
    {
        //require(OrderType(order.orderType) == OrderType.Market, "INVALID_TYPE");
        bytes32 orderHash = getOrderHash(order);

        // Validate user signature (check only if first time seen)
        require(isValidSignature(orderHash,order.userAddress,signature), "INVALID_ORDER_SIGNATURE");

        cancelled[orderHash] = true;
        timestamps[orderHash] = order.salt;
    }

    /**
     * Pause the majority of functionalities of Boomflow.
     * Only WhitelistAdmin (DEX) have the access permission.
     *
     * Note that when deployed, Boomflow is by default paused.
     */
    function Pause()
        public
        onlyWhitelistAdmin
    {
        pause();
    }

    /**
     * Resume all paused functionalities of Boomflow.
     * Only WhitelistAdmin (DEX) have the access permission.
     *
     */
    function Resume()
        public
        onlyWhitelistAdmin
    {
        unpause();
    }
// ----------------------------- Helper Functions -----------------------------
    /**
     * Modify the contract fees.
     * Note that contract fees could be adjusted by DEX during trade execution, but there
     * is hard-coded lock period between every adjustment to throttle the number of times
     * DEX modify the value
     */
    function _setContractFee(
        uint256 _makerFeePercentage,
        uint256 _takerFeePercentage
    )
        internal
    {
        require(_makerFeePercentage < MAX_CONTRACT_FEE, "INVALID_MAKER_CONTRACT_FEE");
        require(_takerFeePercentage < MAX_CONTRACT_FEE, "INVALID_TAKER_CONTRACT_FEE");

        if (makerFeePercentage != _makerFeePercentage || takerFeePercentage != _takerFeePercentage) {
            require(lastTime.add(minimumLockTime) < block.timestamp, "CONTRACT_FEE_STILL_LOCKED");
            lastTime = block.timestamp;

            makerFeePercentage = _makerFeePercentage;
            takerFeePercentage = _takerFeePercentage;
        }
    }

    /**
     * Execute the exchange between a maker order and a taker order.
     * Only Whitelistlisted (DEX) have the access permission.
     *
     * The function will atomically perform the following operations:
     *
     *      1. Validate both taker order, maker order and the match
     *      2. Calculate the matching results
     *      3. Settle the exchanges
     */
    function _executeTrade(
        Order memory makerOrder,
        Order memory takerOrder,
        bytes memory makerSignature,
        bytes memory takerSignature,
        LibFillResults.Context memory context
    )
        internal
        returns (LibFillResults.MatchedFillResults memory matchedFillResults)
    {
        // We assume that the two order sides are opposite, takerOrder.quoteAssetAddress == makerOrder.quoteAssetAddress and takerOrder.baseAssetAddress == makerOrder.baseAssetAddress.
        // If this assumption isn't true, the match will fail at signature validation.
        require(makerOrder.side != takerOrder.side, "INVALID_SIDE");
        require(OrderType(makerOrder.orderType) == OrderType.Limit, "INVALID_MAKER_TYPE");

        takerOrder.baseAssetAddress = makerOrder.baseAssetAddress;
        takerOrder.quoteAssetAddress = makerOrder.quoteAssetAddress;

        // Get left & right order info
        OrderInfo memory makerOrderInfo = getOrderInfo(makerOrder);
        OrderInfo memory takerOrderInfo = getOrderInfo(takerOrder);

        // Record the order if not seen before
        if (makerOrderInfo.filledAmount == 0) {
            max[makerOrderInfo.orderHash] = makerOrder.amount;
        }
        if (takerOrderInfo.filledAmount == 0) {
            max[takerOrderInfo.orderHash] = takerOrder.amount;
        }

        // Either our context is valid or we revert
        assertFillableOrder(
            makerOrder,
            makerOrderInfo,
            makerSignature
        );
        assertFillableOrder(
            takerOrder,
            takerOrderInfo,
            takerSignature
        );

        // Either it is a valid match or we revert
        assertValidMatch(makerOrder, takerOrder);

        // Compute proportional fill amounts
        matchedFillResults = LibFillResults.calculateMatchedFillResults(
            makerOrder,
            takerOrder,
            makerOrderInfo.filledAmount,
            takerOrderInfo.filledAmount,
            max[makerOrderInfo.orderHash],
            max[takerOrderInfo.orderHash],
            context.contractFeeAddress,
            makerFeePercentage,
            takerFeePercentage
        );

        // Either the calculation match with offchain execution or we revert
        assertValidContext(matchedFillResults, context);

        // Update exchange state
        updateFilledStates(
            makerOrderInfo,
            matchedFillResults.makerFee,
            matchedFillResults.makerContractFee,
            context.contractFeeAddress,
            matchedFillResults.tradeAmount
        );
        updateFilledStates(
            takerOrderInfo,
            matchedFillResults.takerFee,
            matchedFillResults.takerContractFee,
            context.contractFeeAddress,
            (takerOrder.side && OrderType(takerOrder.orderType) == OrderType.Market) ? matchedFillResults.tradeFunds : matchedFillResults.tradeAmount
        );

        // Settle matched orders. Succeeds or throws.
        settleTrade(makerOrder, takerOrder, context.contractFeeAddress, matchedFillResults);

        if (filled[makerOrderInfo.orderHash] >= max[makerOrderInfo.orderHash]) {
            timestamps[makerOrderInfo.orderHash] = makerOrder.salt;
        }

        if (filled[takerOrderInfo.orderHash] >= max[takerOrderInfo.orderHash]) {
            timestamps[takerOrderInfo.orderHash] = takerOrder.salt;
        }

        return matchedFillResults;
    }

    function getOrderInfo(Order memory order)
        public
        view
        returns (OrderInfo memory orderInfo)
    {
        // Compute the order hash
        orderInfo.orderHash = getOrderHash(order);

        // Fetch operated amount
        orderInfo.filledAmount = filled[orderInfo.orderHash];

        // Validate the order amount
        if (order.amount == 0) {
            orderInfo.orderStatus = uint8(OrderStatus.INVALID_AMOUNT);
            return orderInfo;
        }

        // Validate the order type
        if (OrderType(order.orderType) != OrderType.Limit &&
          OrderType(order.orderType) != OrderType.Market) {
            orderInfo.orderStatus = uint8(OrderStatus.INVALID_TYPE);
            return orderInfo;
        }

        // Validate the order price
        if (OrderType(order.orderType) == OrderType.Limit && order.price == 0) {
            orderInfo.orderStatus = uint8(OrderStatus.INVALID_PRICE);
            return orderInfo;
        }

        // Validate order availability
        if (max[orderInfo.orderHash] != 0 && orderInfo.filledAmount >= max[orderInfo.orderHash]) {
            orderInfo.orderStatus = uint8(OrderStatus.FULLY_FILLED);
            return orderInfo;
        }

        // Validate if order is cancelled
        if (cancelled[orderInfo.orderHash]) {
            orderInfo.orderStatus = uint8(OrderStatus.CANCELLED);
            return orderInfo;
        }

        // Validate order expiration, if the order has been neither settled nor recorded
        if (orderInfo.filledAmount == 0 && !recorded[orderInfo.orderHash] && order.salt < timestamp) {
            orderInfo.orderStatus = uint8(OrderStatus.EXPIRED);
            return orderInfo;
        }

        // All other statuses are ruled out: order is Fillable
        orderInfo.orderStatus = uint8(OrderStatus.FILLABLE);
        return orderInfo;
    }

    function assertFillableOrder(
        Order memory order,
        OrderInfo memory orderInfo,
        bytes memory signature
    )
        public
        pure
    {
        require(orderInfo.orderStatus != uint8(OrderStatus.INVALID_AMOUNT), "INVALID_AMOUNT");
        require(orderInfo.orderStatus != uint8(OrderStatus.INVALID_PRICE), "INVALID_PRICE");
        require(orderInfo.orderStatus != uint8(OrderStatus.INVALID_TYPE), "INVALID_TYPE");
        require(orderInfo.orderStatus != uint8(OrderStatus.INVALID), "INVALID");
        require(orderInfo.orderStatus != uint8(OrderStatus.FULLY_FILLED), "FULLY_FILLED");
        require(orderInfo.orderStatus != uint8(OrderStatus.EXPIRED), "EXPIRED");
        require(orderInfo.orderStatus != uint8(OrderStatus.CANCELLED), "CANCELLED");
        require(
            orderInfo.orderStatus == uint8(OrderStatus.FILLABLE),
            "ORDER_UNFILLABLE"
        );

        // Validate the order fee percentage is less than 1
        require(uint256(10**18) > order.makerFeePercentage, "INVALID_FEE_PERCENTAGE");
        require(uint256(10**18) > order.takerFeePercentage, "INVALID_FEE_PERCENTAGE");

        // Validate user signature (check only if first time seen)
        if (orderInfo.filledAmount == 0) {
            require(isValidSignature(orderInfo.orderHash,order.userAddress,signature), "INVALID_ORDER_SIGNATURE");
        }
    }

    /**
     * Make sure there is a profitable spread when both taker and maker orders are limit order.
     * There is a profitable spread iff the cost per unit bought (OrderA.MakerAmount/OrderA.TakerAmount) for each order is greater
     * or equal than the profit per unit sold of the matched order (OrderB.TakerAmount/OrderB.MakerAmount).
     */
    function assertValidMatch(
        LibOrder.Order memory makerOrder,
        LibOrder.Order memory takerOrder
    )
        internal
        pure
    {
        if (OrderType(takerOrder.orderType) == OrderType.Limit) {
            if (makerOrder.side) {
                require(
                    makerOrder.price >= takerOrder.price,
                    "NEGATIVE_SPREAD_REQUIRED"
                );
            } else {
                require(
                    makerOrder.price <= takerOrder.price,
                    "NEGATIVE_SPREAD_REQUIRED"
                );
            }
        }
    }

    function assertValidContext(
        LibFillResults.MatchedFillResults memory result,
        LibFillResults.Context memory context
    )
        internal
        pure
    {
        require(
            result.tradeAmount == context.tradeAmount,
            "TRADE_AMOUNT_MISMATCHED"
        );
    }

    // Update state with results of a fill order.
    function updateFilledStates(
        OrderInfo memory orderInfo,
        uint256 fee,
        uint256 contractFee,
        address contractFeeAddress,
        uint256 value
    )
        internal
    {
        // Update maker state
        filled[orderInfo.orderHash] = SafeMath.add(orderInfo.filledAmount, value);
        emit Fill(
            orderInfo.orderHash,
            fee,
            contractFee,
            contractFeeAddress,
            msg.sender,
            value
        );
    }

    // Settle the trade between one maker and one taker order
    function settleTrade(
        Order memory makerOrder,
        Order memory takerOrder,
        address contractFeeAddress,
        LibFillResults.MatchedFillResults memory matchedFillResults
    )
        internal
    {
        address makerFillAsset = makerOrder.side ? makerOrder.baseAssetAddress : makerOrder.quoteAssetAddress;
        address takerFillAsset = makerOrder.side ? makerOrder.quoteAssetAddress : makerOrder.baseAssetAddress;

        // Settle net results
        ICRCL(takerFillAsset).transferFrom(makerOrder.userAddress,takerOrder.userAddress,matchedFillResults.takerFillAmount);
        ICRCL(makerFillAsset).transferFrom(takerOrder.userAddress,makerOrder.userAddress,matchedFillResults.makerFillAmount);

        // Settle dex fees
        ICRCL(takerFillAsset).transferFrom(makerOrder.userAddress,takerOrder.feeAddress,matchedFillResults.takerFee);
        ICRCL(makerFillAsset).transferFrom(takerOrder.userAddress,makerOrder.feeAddress,matchedFillResults.makerFee);

        // Settle contract fees if feeAddress is not null address
        if (contractFeeAddress != address(0)) {
            ICRCL(takerFillAsset).transferFrom(makerOrder.userAddress,contractFeeAddress,matchedFillResults.takerContractFee);
            ICRCL(makerFillAsset).transferFrom(takerOrder.userAddress,contractFeeAddress,matchedFillResults.makerContractFee);
        }
    }

}