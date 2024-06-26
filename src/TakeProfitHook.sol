// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.21;

import {BaseHook} from "../lib/periphery-next/contracts/BaseHook.sol";
import {ERC1155} from "openzeppelin-contracts/contracts/token/ERC1155/ERC1155.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolId, PoolIdLibrary} from "v4-core/libraries/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

contract TakeProfitsHook is BaseHook, ERC1155 {
    using PoolIdLibrary for IPoolManager.PoolKey;
    using CurrencyLibrary for Currency;
    mapping(PoolId poolId => int24 tickLower) public tickLowerLasts;
    mapping(PoolId poolId => mapping(int24 tickLower => mapping(zeroForone => int256 amount)))
        public takeProfitPositions;

    // tokenIdExists is a mapping to store whether a given tokenId (i.e. a take-profit order) exists given a token id
    mapping(uint256 tokenId => bool exists) public tokenIdExists;
    // tokenIdClaimable is a mapping that stores how many swapped tokens are claimable for a given tokenId
    mapping(uint256 tokenId => uint256 claimable) public tokenIdClaimable;
    // tokenIdTotalSupply is a mapping that stores how many tokens need to be sold to execute the take-profit order
    mapping(uint256 tokenId => uint256 supply) public tokenIdTotalSupply;
    // tokenIdData is a mapping that stores the PoolKey, tickLower, and zeroForOne values for a given tokenId
    mapping(uint256 tokenId => TokenData) public tokenIdData;

    struct TokenData {
        PoolKey poolKey;
        int24 tick;
        bool zeroForOne;
    }

    // Initialize BaseHook and ERC1155 parent contracts in the constructor
    constructor(
        IPoolManager _poolManager,
        string memory _uri
    ) BaseHook(_poolManager) ERC1155(_uri) {}

    // Required override function for BaseHook to let the PoolManager know which hooks are implemented
    function getHooksCalls() public pure override returns (Hooks.Calls memory) {
        return
            Hooks.Calls({
                beforeInitialize: false,
                afterInitialize: true,
                beforeModifyPosition: false,
                afterModifyPosition: false,
                beforeSwap: false,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false
            });
    }
    //Helper Functions
    function _setLowerTickLast(PoolId poolId, int24 tickLower) private {
        tickLowerLasts[poolId] = tickLower;
    }
    function _getLowerTickLast(
        int24 actualTick,
        int24 tickSpacing
    ) private pure returns (int24) {
        int24 intervals = actualTick / tickSpacing;
        if (actualTick < 0 && actualTick % tickSpacing != 0) intervals--;
        return intervals * tickSpacing;
    }
    //Hooks
    function afterInitialize(
        address,
        IPoolManager.PoolKey calldata key,
        uint160,
        int24 tick
    ) {
        _setLowerTickLast(key.toId(), _getLowerTickLast(tick, key.tickSpacing));
        return TakeProfitsHook.afterInitialize.selector;
    }
    //ERC-1155 Helpers
    function getTokenId(
        IPoolManager.PoolKey calldata key,
        int24 tickLower,
        bool zeroForOne
    ) public pure returns (uint256) {
        return
            uint256(keccak256(abi.encodePacked(poolId, tickLower, zeroForOne)));
    }
    function afterSwap(
        address,
        IPoolManager.PoolKey calldata key,
        int24 tick,
        bool zeroForOne,
        int256 amountIn
    ) external override poolManagerOnly returns(bytes4){
        int24 lastTickLower = tickLowerLasts[key.toId()];
        (, int24 currentTick,,,) = poolmanager.getSlot(key.toId());

        int24 currentTickLower = _getLowerTickLast(currentTick, key.tickSpacing);

        bool swapZeroForOne = !params.zeroForOne;
        int256 swapAmountIn;

        // Tick has increases i.e. price of Token0 has increased
        if(lastTickLower < currentTickLower){
            for(int24 tick = lastTickLower; tick < currentTickLower;){
                swapAmountIn = takeProfitPositions[key.toId()][tick][swapZeroForOne];
                if(swapAmountIn > 0){
                    fillOrder(key, tick, swapZeroForOne, swapAmountIn);
                }
                tick += key.tickSpacing;
            }
        }
        else{

            for(int24 tick = lastTickLower; tick > currentTickLower;){
                swapAmountIn = takeProfitPositions[key.toId()][tick][swapZeroForOne];
                if(swapAmountIn > 0){
                    fillOrder(key, tick, swapZeroForOne, swapAmountIn);
                }
                tick -= key.tickSpacing;
            }
        
        }
        tickLowerLasts[key.toId()] = currentTickLower;
        return TakeProfitsHook.afterSwap.selector;
    }
    // Core Utilities
    function placeOrder(
        IPoolManager.PoolKey calldata key,
        int24 tick,
        uint256 amountIn,
        bool zeroForOne
    ) external returns (int24) {
        int24 tickLower = _getLowerTickLast(tick, key.tickSpacing);
        takeProfitPositions[key.toId()][tickLower][zeroForOne] += int256(
            amountIn
        );
        uint256 tokenId = getTokenId(key, tickLower, zeroForOne);
        if (!tokenIdExists[tokenId]) {
            tokenIdExists[tokenId] = true;
            tokenIdData[tokenId] = TokenData(key, tickLower, zeroForOne);
        }
        _mint(msg.sender, tokenId, amountIn, "");
        tokenIdTotalSupply[tokenId] += amountIn;

        address tokenToBeSoldContract = zeroForOne
            ? Currency.unwrap(key.currency0)
            : Currency.unwrap(key.currency1);
        IERC20(tokenToBeSoldContract).transferFrom(
            msg.sender,
            address(this),
            amountIn
        );
        return tickLower;
    }
    function cancelOrder(
        IPoolManager.PoolKey calldata key,
        int24 tick,
        bool zeroForOne
    ) external {
        int24 tickLower = _getLowerTickLast(tick, key.tickSpacing);
        uint256 tokenId = getTokenId(key, tickLower, zeroForOne);
        require(tokenIdExists[tokenId], "Token ID does not exist");
        //balanceOf is an ERC1155 function that returns the balance of a given tokenId for a given address
        uint256 amountIn = balanceOf(msg.sender, tokenId);
        require(amountIn > 0, "No balance to cancel");
        takeProfitPositions[key.toId()][tickLower][zeroForOne] -= int256(
            amountIn
        );
        tokenIdTotalSupply[tokenId] -= amountIn;
        tokenIdClaimable[tokenId] -= amountIn;
        _burn(msg.sender, tokenId, amountIn);
        address tokenToBeSoldContract = zeroForOne
            ? Currency.unwrap(key.currency0)
            : Currency.unwrap(key.currency1);
        IERC20(tokenToBeSoldContract).transfer(msg.sender, amountIn);
    }
    function fillOrder(
        IPoolManager.PoolKey calldata key,
        int24 tick,
        bool zeroForOne,
        int256 amountIn
    ) internal {
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountIn,
            sqrtPriceLimitX96: zeroForOne
                ? TickMath.getSqrtRatioAtTick(tick)
                : TickMath.getSqrtRatioAtTick(tick + 1)
        });
        BalanceDelta delta = abi.decode(
            poolManager.lock(
                abi.encodeCall(this._handleSwap, (key, SwapParams))
            )(BalanceDelta)
        );
        takeProfitPositions[key.toId()][tickLower][zeroForOne] -= amountIn;
        uint256 tokenId = getTokenId(key, tickLower, zeroForOne);
        uint256 amountOfTokensReceivedFromSwap = zeroForOne
            ? uint256(int256(-delta.amount1()))
            : uint256(int256(-delta.amount0()));
        tokenIdClaimable[tokenId] += amountOfTokensReceivedFromSwap;
    }
    function _handleSwap(
        IPoolManager.PoolKey calldata key,
        IPoolManager.SwapParams calldata params
    ) external returns (BalannceDelta) {
        BalanceDelta delta = poolManager.swap(key, params);

        if (params.zeroForOne) {
            if (delta.amount0() > 0) {
                IERC20(Currency.unwrap(key.currency0)).transfer(
                    address(poolManager),
                    uint128(delta.amount0())
                );
                poolManager.settle(key, currency0);
            }
            if (delta.amount1() < 0) {
                poolManager.take(
                    key.currency1,
                    address(this),
                    uint128(-delta.amount1())
                );
            }
        } else {
            if (delta.amount1() > 0) {
                IERC20(Currency.unwrap(key.currency1)).transfer(
                    address(poolManager),
                    uint128(delta.amount1())
                );
                poolManager.settle(key, currency1);
            }
            if (delta.amount0() < 0) {
                poolManager.take(
                    key.currency0,
                    address(this),
                    uint128(-delta.amount0())
                );
            }
        }
        return delta;
    }
}
