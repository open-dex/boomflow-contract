pragma solidity 0.5.16;

import "./LibOrder.sol";
import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

/* Remix IDE
import "github.com/OpenZeppelin/openzeppelin-contracts/blob/v2.5.0/contracts/math/Math.sol";
import "github.com/OpenZeppelin/openzeppelin-contracts/blob/v2.5.0/contracts/math/SafeMath.sol";
*/

library LibFillResults {
    using SafeMath for uint256;

    struct MatchedFillResults {
        uint256 tradeAmount;
        uint256 tradeFunds;
        uint256 makerFillAmount;
        uint256 takerFillAmount;
        uint256 makerFee;
        uint256 takerFee;
        uint256 makerContractFee;
        uint256 takerContractFee;
    }

    struct Context {
        uint256 tradeAmount;
        uint256 makerContractFee;
        uint256 takerContractFee;
        address contractFeeAddress;
    }

    struct MatchedMarketFillResults {
        MatchedFillResults[] fillResults;             // Fill results for right orders
        uint256 totalMakerFill;
        uint256 totalTakerFill;
        uint256 totalTradeAmount;
        uint256 totalTradeFunds;
        uint256 totalTakerFee;
        uint256 totalTakerContractFee;
    }

    // Calculate the matching results between one maker and one taker order
    function calculateMatchedFillResults(
        LibOrder.Order memory makerOrder,
        LibOrder.Order memory takerOrder,
        uint256 makerFilledAmount,
        uint256 takerFilledAmount,
        uint256 makerOriginalAmount,
        uint256 takerOriginalAmount,
        address feeAddress,
        uint256 makerFeePercentage,
        uint256 takerFeePercentage
    )
        internal
        pure
        returns (MatchedFillResults memory matchedFillResults)
    {
        // Get the available amount to trade for each order
        uint256 makerLeftAmount = SafeMath.sub(makerOriginalAmount, makerFilledAmount);
        uint256 takerLeftAmount = SafeMath.sub(takerOriginalAmount, takerFilledAmount);

        // Calculate `tradeAmount` in base asset unit. To guarantee that at least one of the two
        // orders is completely filled, `tradeAmount` is always the min of the order available amounts
        //
        // Note that for market buy taker order in particular, since the amount filled by the taker is
        // in fact in quote asset unit, we need to first calculate `takerAmount` from `takerLeftAmount`
        // with maker order's price
        if (LibOrder.OrderType(takerOrder.orderType) == LibOrder.OrderType.Limit || !takerOrder.side) {
            matchedFillResults.tradeAmount = Math.min(makerLeftAmount, takerLeftAmount);
        } else {
            uint256 takerAmount = SafeMath.div(SafeMath.mul(takerLeftAmount, uint256(10**18)), makerOrder.price);
            matchedFillResults.tradeAmount = Math.min(makerLeftAmount, takerAmount);
        }

        // Calculate corresponding `tradeFunds` in quote asset unit
        matchedFillResults.tradeFunds = SafeMath.div(SafeMath.mul(matchedFillResults.tradeAmount, makerOrder.price), uint256(10**18));

        // Assign exchange amounts according to the side of `takerOrder`
        if (takerOrder.side) {
            // Calculate dex fee
            matchedFillResults.takerFee = SafeMath.div(SafeMath.mul(matchedFillResults.tradeAmount, takerOrder.takerFeePercentage), uint256(10**18));
            matchedFillResults.makerFee = SafeMath.div(SafeMath.mul(matchedFillResults.tradeFunds,  makerOrder.makerFeePercentage), uint256(10**18));

            // Calculate the net results
            matchedFillResults.takerFillAmount = SafeMath.sub(SafeMath.sub(matchedFillResults.tradeAmount, matchedFillResults.takerFee), matchedFillResults.takerContractFee);
            matchedFillResults.makerFillAmount = SafeMath.sub(SafeMath.sub(matchedFillResults.tradeFunds,  matchedFillResults.makerFee), matchedFillResults.makerContractFee);
        } else {
            // Calculate dex fee
            matchedFillResults.takerFee = SafeMath.div(SafeMath.mul(matchedFillResults.tradeFunds,  takerOrder.takerFeePercentage), uint256(10**18));
            matchedFillResults.makerFee = SafeMath.div(SafeMath.mul(matchedFillResults.tradeAmount, makerOrder.makerFeePercentage), uint256(10**18));

            // Calculate the net results
            matchedFillResults.takerFillAmount = SafeMath.sub(SafeMath.sub(matchedFillResults.tradeFunds,  matchedFillResults.takerFee), matchedFillResults.takerContractFee);
            matchedFillResults.makerFillAmount = SafeMath.sub(SafeMath.sub(matchedFillResults.tradeAmount, matchedFillResults.makerFee), matchedFillResults.makerContractFee);
        }

        // Calculate match fee if feeAddress is not null address
        if (feeAddress != address(0)) {
            matchedFillResults.takerContractFee = matchedFillResults.takerFee.mul(takerFeePercentage).div(uint256(10**18));
            matchedFillResults.makerContractFee = matchedFillResults.makerFee.mul(makerFeePercentage).div(uint256(10**18));

            matchedFillResults.takerFee = matchedFillResults.takerFee.sub(matchedFillResults.takerContractFee);
            matchedFillResults.makerFee = matchedFillResults.makerFee.sub(matchedFillResults.makerContractFee);
        }

        return matchedFillResults;
    }
}