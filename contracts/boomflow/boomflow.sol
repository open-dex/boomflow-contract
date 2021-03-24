pragma solidity 0.5.16;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/access/roles/WhitelistAdminRole.sol";
import "@openzeppelin/contracts/access/roles/WhitelistedRole.sol";
import "@openzeppelin/contracts/lifecycle/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/* Remix IDE
import "github.com/OpenZeppelin/openzeppelin-contracts/blob/v2.5.0/contracts/access/roles/WhitelistAdminRole.sol";
import "github.com/OpenZeppelin/openzeppelin-contracts/blob/v2.5.0/contracts/access/roles/WhitelistedRole.sol";
import "github.com/OpenZeppelin/openzeppelin-contracts/blob/v2.5.0/contracts/lifecycle/Pausable.sol";
import "github.com/OpenZeppelin/openzeppelin-contracts/blob/v2.5.0/contracts/utils/ReentrancyGuard.sol";
*/

import "../crc-l/ICRCL.sol";

import "./libs/LibOrder.sol";
import "./libs/LibFillResults.sol";
import "./libs/LibSignatureValidator.sol";
import "./libs/LibRequest.sol";

contract Boomflow is WhitelistAdminRole, WhitelistedRole, LibOrder, ReentrancyGuard, LibSignatureValidator, LibRequest, Pausable {
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

    // Mapping of orderHash => all instantExchange base orders
    mapping (bytes32 => Order[]) baseMakerOrders;

    // Mapping of orderHash => all instantExchange quote orders
    mapping (bytes32 => Order[]) quoteMakerOrders;

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
        bool flag;
    }

    function getOrderData(bytes32 orderHash)
        public
        view
        returns (OrderData memory orderData)
    {
        bool hasMakerOrdersRecorded = (baseMakerOrders[orderHash].length != 0) || (quoteMakerOrders[orderHash].length != 0);
        orderData = OrderData({
            filled: filled[orderHash],
            max: max[orderHash],
            cancelled: cancelled[orderHash],
            flag: hasMakerOrdersRecorded
        });
    }

    function getBaseMakerOrders(bytes32 orderHash)
        public
        view
        returns (Order[] memory orders)
    {
        orders = baseMakerOrders[orderHash];
    }

    function getQuoteMakerOrders(bytes32 orderHash)
        public
        view
        returns (Order[] memory orders)
    {
        orders = quoteMakerOrders[orderHash];
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

    // Exchange
    /**
     * Record the matched base maker orders and quote maker orders for a specific taker order.
     * The function should be called prior to `executeInstantExchangeTrade`
     * Only Whitelistlisted (DEX) have the access permission.
     *
     * The function could be run in batches for a single taker order, and `makerOrders` could
     * contains a mixture of base and quote maker orders, as long as DEX ensures the order of
     * base maker orders and that of quote maker orders are unploaded in the exact order, respectively.
     *
     * Requirements:
     * - All base maker orders should have the same base and quote assets
     * - All quote maker orders should have the same base and quote assets
     * - All base maker orders should have the same base assets as the taker order
     * - All quote maker orders should have the same quote assets as the taker order
     */
    function recordInstantExchangeOrders(
        Order memory takerOrder,
        Order[] memory makerOrders,
        bytes memory takerSignature,
        bytes[] memory makerSignatures
    )
        public
        onlyWhitelisted
        whenNotPaused
        nonReentrant
    {
        // Taker order must be market order in Instant Exchange
        require(OrderType(takerOrder.orderType) == OrderType.Market, "INVALID_TAKER_TYPE");

        // Base and quote makerOrder arrays are compatible
        require(makerOrders.length == makerSignatures.length, "SIGNATURE_LENGTH_MISMATCH");

        OrderInfo memory takerOrderInfo = getOrderInfo(takerOrder);

        // Record the order if not seen before
        if (takerOrderInfo.filledAmount == 0) {
            max[takerOrderInfo.orderHash] = takerOrder.amount;
        }

        // Assert if the taker order is valid
        assertFillableOrder(
            takerOrder,
            takerOrderInfo,
            takerSignature
        );

        for (uint i = 0; i < makerOrders.length; i++) {
            require(OrderType(makerOrders[i].orderType) == OrderType.Limit, "INVALID_MAKER_TYPE");

            OrderInfo memory makerOrderInfo = getOrderInfo(makerOrders[i]);

            // Record the order if not seen before
            if (makerOrderInfo.filledAmount == 0) {
                max[makerOrderInfo.orderHash] = makerOrders[i].amount;
            }

            // Assert if the maker order is valid
            assertFillableOrder(
                makerOrders[i],
                makerOrderInfo,
                makerSignatures[i]
            );

            // If a maker order's base assets is equal to the taker order's base asset, then push it to `baseMakerOrders`
            // If a maker order's quote assets is equal to the taker order's base asset, push it to `quoteMakerOrders`
            // Ignore Otherwise
            if (takerOrder.baseAssetAddress == makerOrders[i].baseAssetAddress) {
                // For base maker order, the side should always be the opposite of the taker order's
                require(takerOrder.side != makerOrders[i].side, "INVALID_SIDE");

                if (baseMakerOrders[takerOrderInfo.orderHash].length > 0) {
                    // Check if all makerOrders are for the same asset pair
                    require(baseMakerOrders[takerOrderInfo.orderHash][0].baseAssetAddress == makerOrders[i].baseAssetAddress, "baseMakerOrders: wrong baseAssetAddress");
                    require(baseMakerOrders[takerOrderInfo.orderHash][0].quoteAssetAddress == makerOrders[i].quoteAssetAddress, "baseMakerOrders: wrong quoteAssetAddress");
                }
                baseMakerOrders[takerOrderInfo.orderHash].push(makerOrders[i]);
            } else if (takerOrder.quoteAssetAddress == makerOrders[i].baseAssetAddress) {
                // For quote maker order, the side should always be the same as the taker order's
                require(takerOrder.side == makerOrders[i].side, "INVALID_SIDE");

                if (quoteMakerOrders[takerOrderInfo.orderHash].length > 0) {
                    // Check if all makerOrders are for the same asset pair
                    require(quoteMakerOrders[takerOrderInfo.orderHash][0].baseAssetAddress == makerOrders[i].baseAssetAddress, "quoteMakerOrders: wrong baseAssetAddress");
                    require(quoteMakerOrders[takerOrderInfo.orderHash][0].quoteAssetAddress == makerOrders[i].quoteAssetAddress, "quoteMakerOrders: wrong quoteAssetAddress");
                }
                quoteMakerOrders[takerOrderInfo.orderHash].push(makerOrders[i]);
            }
        }

        // Make sure all the maker orders share the same quote asset:
        // Note that with the previous checks, we could only guarantee that maker orders match the first order in base and quote queues, respectively;
        // in order to check both queues, we need to further validate the match between the first order in base and quote queues
        if (baseMakerOrders[takerOrderInfo.orderHash].length > 0 && quoteMakerOrders[takerOrderInfo.orderHash].length > 0) {
            require(baseMakerOrders[takerOrderInfo.orderHash][0].quoteAssetAddress == quoteMakerOrders[takerOrderInfo.orderHash][0].quoteAssetAddress, "INVALID_QUOTE_ASSET");
        }
    }

    /**
     * Execute orders in batches.
     * Only Whitelistlisted (DEX) have the access permission.
     *
     * The function will iteratively execute each pair of orders
     */
    function batchExecuteInstantExchangeTrade(
        Order[] memory takerOrders,
        bytes[] memory takerSignatures,
        uint256 threshold,
        uint256[] memory makerContractFees,
        uint256[] memory takerContractFees,
        address[] memory contractFeeAddresses
    )
        public
        onlyWhitelisted
        whenNotPaused
        nonReentrant
    {
        require(takerOrders.length == takerSignatures.length, "ORDER_LENGTH_MISMATCH");
        require(takerOrders.length == makerContractFees.length, "CONTRACT_FEE_ADDRESS_LENGTH_MISMATCH");
        require(takerOrders.length == takerContractFees.length, "CONTRACT_FEE_ADDRESS_LENGTH_MISMATCH");
        require(takerOrders.length == contractFeeAddresses.length, "CONTRACT_FEE_ADDRESS_LENGTH_MISMATCH");

        for(uint i = 0; i < takerOrders.length; i++){
            _setContractFee(makerContractFees[i], takerContractFees[i]);

            _executeInstantExchangeTrade(takerOrders[i], takerSignatures[i], threshold, contractFeeAddresses[i]);
        }
    }

    /**
     * Execute all the recorded base maker orders and quote maker orders for a specific taker order.
     * The function should be called after `recordInstantExchangeOrders`
     * Only Whitelistlisted (DEX) have the access permission.
     */
    function executeInstantExchangeTrade(
        Order memory takerOrder,
        bytes memory takerSignature,
        uint256 threshold,
        uint256 makerContractFee,
        uint256 takerContractFee,
        address contractFeeAddress
    )
        public
        onlyWhitelisted
        whenNotPaused
        nonReentrant
    {
        _setContractFee(makerContractFee, takerContractFee);

        _executeInstantExchangeTrade(takerOrder, takerSignature, threshold, contractFeeAddress);
    }

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
     * Execute all the recorded base maker orders and quote maker orders for a specific taker order.
     * The function should be called after `recordInstantExchangeOrders`
     * Only Whitelistlisted (DEX) have the access permission.
     *
     * The function will atomically perform the following operations:
     *
     *      1. Impersonate a taker order between the taker-owned asset and intermediate asset
     *      2. Calculate the results for the first exchange roundtrip
     *      3. Impersonate another taker order between intermediate asset the taker-asked asset
     *      4. Calculate the results for the second exchange roundtrip
     *      5. Settle all the exchanges
     *
     * Requirements:
     * - The length of base and quote makerOrder lists should be either both zero or both nonzero
     * - The amount of intermediate asset left after the second exchange roundtrip should be less than `threshold`
     */
    function _executeInstantExchangeTrade(
        Order memory takerOrder,
        bytes memory takerSignature,
        uint256 threshold,
        address contractFeeAddress
    )
        internal
    {
        OrderInfo memory takerOrderInfo = getOrderInfo(takerOrder);

        // Either the taker order is still valid or we revert
        assertFillableOrder(
            takerOrder,
            takerOrderInfo,
            takerSignature
        );

        Order[] memory firstOrderLists;
        Order[] memory secondOrderLists;

        // If taker order is buy, then it goes through 1st exchange roundtrip
        // with quote maker orders, then base maker orders; vice versa
        if (!takerOrder.side) {
            firstOrderLists = baseMakerOrders[takerOrderInfo.orderHash];
            secondOrderLists = quoteMakerOrders[takerOrderInfo.orderHash];
        } else {
            firstOrderLists = quoteMakerOrders[takerOrderInfo.orderHash];
            secondOrderLists = baseMakerOrders[takerOrderInfo.orderHash];
        }

        // Two makerOrder lists have either both zero lengths or nonzero lengths
        require(
            (firstOrderLists.length != 0) == (secondOrderLists.length != 0),
            "INVALID_LENGTH"
        );

        // Simply cancel the takerOrder if orderlists are empty
        if (firstOrderLists.length > 0) {
            // Mimic 1st roundtrip takerOrder: A-B.
            // Note that the constructed taker order is always on Sell side
            // because based on the rules for instant exchange asset pairs,
            // the intermediate asset is always the quote asset.
            Order memory firstTakerOrder = Order({
                userAddress: takerOrder.userAddress,
                amount: takerOrder.amount,
                price: takerOrder.price,
                orderType: takerOrder.orderType,
                side: false,
                salt: takerOrder.salt,
                baseAssetAddress: firstOrderLists[0].baseAssetAddress,
                quoteAssetAddress: firstOrderLists[0].quoteAssetAddress,
                feeAddress: address(0),
                makerFeePercentage: 0,
                takerFeePercentage: 0
            });

            // Calculate matching results for the 1st roundtrip
            LibFillResults.MatchedMarketFillResults memory firstMatchedResults = _calculateMarketOrder(firstTakerOrder, firstOrderLists, takerOrderInfo, firstTakerOrder.amount, contractFeeAddress);

            // Mimic 2nd roundtrip takerOrder: C-B
            // Note that the constructed taker order is always on Buy side
            // for the same reason the 1st taker order is always on Sell side
            Order memory secondTakerOrder = Order({
                userAddress: takerOrder.userAddress,
                amount: firstMatchedResults.totalTakerFill,
                price: takerOrder.price,
                orderType: takerOrder.orderType,
                side: true,
                salt: takerOrder.salt,
                baseAssetAddress: secondOrderLists[0].baseAssetAddress,
                quoteAssetAddress: secondOrderLists[0].quoteAssetAddress,
                feeAddress: takerOrder.feeAddress,
                makerFeePercentage: 0,
                takerFeePercentage: takerOrder.takerFeePercentage
            });

            // Calculate matching results for the 2nd roundtrip
            LibFillResults.MatchedMarketFillResults memory secondMatchedResults = _calculateMarketOrder(secondTakerOrder, secondOrderLists, takerOrderInfo, secondTakerOrder.amount, contractFeeAddress);

            // Ensure that there is almost no intermediate B left
            // Note that it is very likely that the match is not perfect, and in the case where there are a slight
            // amount of B left, we would still allow the transaction and transfer B to the user as a by-product
            if (SafeMath.sub(firstMatchedResults.totalTakerFill, secondMatchedResults.totalTradeAmount) <= threshold) {
                // Settle the result for takerOrder
                updateFilledStates(
                    takerOrderInfo,
                    secondMatchedResults.totalTakerFee,
                    secondMatchedResults.totalTakerContractFee,
                    contractFeeAddress,
                    takerOrder.side ? firstMatchedResults.totalTradeFunds : firstMatchedResults.totalTradeAmount
                );

                // Settle maker orders from 1st round trip
                for (uint i = 0; i < firstOrderLists.length; i++) {
                    // Update exchange states
                    OrderInfo memory makerOrderInfo = getOrderInfo(firstOrderLists[i]);
                    updateFilledStates(
                        makerOrderInfo,
                        firstMatchedResults.fillResults[i].makerFee,
                        firstMatchedResults.fillResults[i].makerContractFee,
                        contractFeeAddress,
                        firstMatchedResults.fillResults[i].tradeAmount
                    );

                    // Settle orders
                    settleTrade(firstOrderLists[i], takerOrder, contractFeeAddress, firstMatchedResults.fillResults[i]);
                }

                // Settle maker orders from 2st round trip
                for (uint i = 0; i < secondOrderLists.length; i++) {
                    // Update exchange states
                    OrderInfo memory makerOrderInfo = getOrderInfo(secondOrderLists[i]);
                    updateFilledStates(
                        makerOrderInfo,
                        secondMatchedResults.fillResults[i].makerFee,
                        secondMatchedResults.fillResults[i].makerContractFee,
                        contractFeeAddress,
                        secondMatchedResults.fillResults[i].tradeAmount
                    );

                    // Settle orders
                    settleTrade(secondOrderLists[i], takerOrder, contractFeeAddress, secondMatchedResults.fillResults[i]);
                }
            }
        }

        // Delete the stored maker orders
        delete baseMakerOrders[takerOrderInfo.orderHash];
        delete quoteMakerOrders[takerOrderInfo.orderHash];

        // Cancel the taker order
        finalizeOrder(takerOrder, takerSignature);
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

    function _min(uint256 value1, uint256 value2) internal pure returns (uint256) {
        if (value1 > value2) {
            return value2;
        }
        return value1;
    }

    // Calculate the matching results of one taker order against multiple maker orders
    function _calculateMarketOrder(
        Order memory takerOrder,
        Order[] memory makerOrders,
        OrderInfo memory takerOrderInfo,
        uint256 takerOrderMax,
        address contractFeeAddress
    )
        internal
        view
        returns (LibFillResults.MatchedMarketFillResults memory matchedMarketFillResults)
    {
        // Initialize fill results
        matchedMarketFillResults.totalMakerFill = 0;
        matchedMarketFillResults.totalTakerFill = 0;
        matchedMarketFillResults.totalTradeAmount = 0;
        matchedMarketFillResults.totalTradeFunds = 0;
        matchedMarketFillResults.totalTakerFee = 0;
        matchedMarketFillResults.totalTakerContractFee = 0;

        matchedMarketFillResults.fillResults = new LibFillResults.MatchedFillResults[](makerOrders.length);

        for (uint i = 0; i < makerOrders.length; i++) {
            // Get maker order info
            OrderInfo memory makerOrderInfo = getOrderInfo(makerOrders[i]);

            // Calculate the matching result between one maker and one taker order
            LibFillResults.MatchedFillResults memory matchedFillResults = LibFillResults.calculateMatchedFillResults(
                makerOrders[i],
                takerOrder,
                makerOrderInfo.filledAmount,
                SafeMath.add(takerOrderInfo.filledAmount, matchedMarketFillResults.totalTakerFill),
                max[makerOrderInfo.orderHash],
                takerOrderMax,
                contractFeeAddress,
                makerFeePercentage,
                takerFeePercentage
            );

            // Record the match results
            matchedMarketFillResults.fillResults[i] = matchedFillResults;

            matchedMarketFillResults.totalMakerFill += matchedMarketFillResults.fillResults[i].makerFillAmount;
            matchedMarketFillResults.totalTakerFill += matchedMarketFillResults.fillResults[i].takerFillAmount;
            matchedMarketFillResults.totalTradeAmount += matchedMarketFillResults.fillResults[i].tradeAmount;
            matchedMarketFillResults.totalTradeFunds += matchedMarketFillResults.fillResults[i].tradeFunds;
            matchedMarketFillResults.totalTakerFee += matchedMarketFillResults.fillResults[i].takerFee;
            matchedMarketFillResults.totalTakerContractFee += matchedMarketFillResults.fillResults[i].takerContractFee;
        }

        // Reset all the temporarily cancelled orders
        /*for (uint i = 0; i < makerOrders.length; i++) {
            cancelled[orderHashes[i]] = false;
        }*/

        return matchedMarketFillResults;
    }
}