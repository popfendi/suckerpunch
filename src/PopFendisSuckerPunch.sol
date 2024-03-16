// SPDX-License-Identifier: MIT
// By PopFendi https://github.com/popfendi
// for EthLondon Hackathon 2024
pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/BaseHook.sol";

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";


    // NOTE: ---------------------------------------------------------
    // currently for ETH pairs only
    // rewards holders by reducing fees based on hold duration
    // MEVs get sucker punched 🥊
    // ---------------------------------------------------------------

contract PopFendisSuckerPunch is BaseHook {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    struct BuyData{
        uint256 timestamp;
        uint128 amount;
    }

    // Map PoolId -> User -> Timestamp
    mapping(PoolId => mapping(address => BuyData)) public buyDataMap;

    // flag for whether we're buying or selling
    bool private inBuy;

    // Starting & ending fees (starts at 5% and decays to 0.05% over 90 days)
    uint128 public constant BASE_FEE = 500_000;
    uint128 public constant MIN_FEE = 500;

    uint128 public constant decayRate = 642;

    // 9.9% for sandwichers
    uint128 public constant MEV_FEE = 999_999;

    function setFee(PoolKey calldata key) public {
        PoolId poolId = key.toId();
        uint24 _currentFee;

        // No fee on buys
        if (inBuy) {
            _currentFee = 0;
        }

        // sandwich attack
        else if (buyDataMap[poolId][tx.origin].timestamp == block.timestamp) {
            _currentFee = uint24(MEV_FEE);
        }

        // users who didnt buy from the pool just get the base fee
        else if (buyDataMap[poolId][tx.origin].timestamp == 0) {
            _currentFee = uint24(BASE_FEE);
        }

        // all other users get a dynamic fee based on how long they've held
        else {
            unchecked{
                uint256 timeElapsed = block.timestamp - buyDataMap[poolId][tx.origin].timestamp;
                _currentFee = timeElapsed >= 7776000 ? uint24(MIN_FEE) : uint24(BASE_FEE - (timeElapsed * decayRate));
                //_currentFee = timeElapsed > 7776000 ? uint24(MIN_FEE) : uint24((BASE_FEE - (timeElapsed * decayRate)) / 10);
            }
        } 

        poolManager.updateDynamicSwapFee(key, _currentFee);
    }

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false
        });
    }

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        override
        returns (bytes4)
    {
        require(key.currency0.isNative(), "currency0 is not native.");
        inBuy = params.zeroForOne;
        setFee(key);
        return BaseHook.beforeSwap.selector;
    }

    function afterSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, BalanceDelta delta, bytes calldata)
        external
        override
        returns (bytes4)
    {
        PoolId poolId = key.toId();

        // if we're selling
        if (!inBuy) {
            uint128 newBalance = uint128(delta.amount0());

            // check if we've sold more than 1/2 of our holdings & have bought (not had tokens transfered to us from other source), if so your holding fee resets
                if ((buyDataMap[poolId][tx.origin].amount != 0) && (newBalance > buyDataMap[poolId][tx.origin].amount / 2)) {
                    unchecked{
                        uint128 newAmount = buyDataMap[poolId][tx.origin].amount - newBalance;
                        buyDataMap[poolId][tx.origin] = BuyData({timestamp: block.timestamp, amount: newAmount});
                    }
                    return BaseHook.afterSwap.selector;
                } 
            return BaseHook.afterSwap.selector;
        }

        // first buy
        else if (buyDataMap[poolId][tx.origin].timestamp == 0) {
            uint128 newBalance = uint128(delta.amount1());
            buyDataMap[poolId][tx.origin] = BuyData({timestamp: block.timestamp, amount: newBalance});
            return BaseHook.afterSwap.selector;
        }


        return BaseHook.afterSwap.selector;
    }

}